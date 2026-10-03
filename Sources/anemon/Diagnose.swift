import CANEMon
import Foundation

/// `anemon diagnose`: records everything anemon could read on a chip it does
/// not know yet, under reference workloads, into one JSON file to send back.
///
/// Phases: idle, CPU only (to see which SMC rails follow the CPU cluster
/// rather than the ANE), a sustained peak-compute load (throttling), the
/// peak-power load, a DRAM-streaming load, busy % at 100% and 50% duty, and
/// idle again until the ANE powers off. For each phase it keeps the delta of
/// every IOReport channel that moved, the mean of every SMC power key, and
/// anemon's own per-second snapshot.
enum Diagnose {
    static func run() -> Int32 {
        guard geteuid() == 0 else {
            print("anemon diagnose needs root for kernel tracing: sudo anemon diagnose")
            return 1
        }
        let anebench = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("anebench").path
        guard FileManager.default.isExecutableFile(atPath: anebench) else {
            print("anebench not found next to anemon (\(anebench)); build both with make")
            return 1
        }
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig) { _ in
                anemon_kd_stop()
                exit(130)
            }
        }

        let runner = WorkloadRunner(anebench: anebench)
        let monitor = Monitor(intervalS: 1, useTrace: true, usePower: true)
        let smc = SMCKeys()
        var unsubscribed: Int32 = 0
        let ior = anemon_ior_open_all(&unsubscribed)
        defer {
            monitor.stop()
            runner.cleanup()
            if let ior { anemon_ior_close(ior) }
        }
        let dev = monitor.device
        let os = ProcessInfo.processInfo.operatingSystemVersion
        print("Diagnosing \(dev.chip) · ANE \(dev.architecture) · \(dev.cores) cores · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        print("This takes about three minutes; close other apps that use the ANE or GPU.\n")
        if let err = monitor.traceError { print("note: busy % unavailable: \(err)") }
        if ior == nil { print("note: IOReport could not be opened") }

        var report: [String: Any] = [
            "tool": "anemon diagnose",
            "date": ISO8601DateFormatter().string(from: Date()),
            "system": [
                "chip": dev.chip, "ane_architecture": dev.architecture, "ane_cores": dev.cores,
                "ane_instances": dev.instances, "model": sysctlString("hw.model"),
                "macos": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                "macos_build": sysctlString("kern.osversion"),
                "perf_levels": (0..<4).compactMap { l -> [String: Any]? in
                    let n = sysctlInt("hw.perflevel\(l).logicalcpu")
                    return n.map { ["level": l, "name": sysctlString("hw.perflevel\(l).name"), "cpus": $0] }
                },
            ] as [String: Any],
            "trace_error": monitor.traceError ?? NSNull(),
            "ioreport_unsubscribed_groups": Int(unsubscribed),
            "smc_float_keys": smc.keys,
        ]
        let channels = ChannelList()
        _ = anemon_ior_list_all({ ctx, g, s, n, fmt, _, _, _ in
            let c = Unmanaged<ChannelList>.fromOpaque(ctx!).takeUnretainedValue()
            c.names.append("\(String(cString: g!)) / \(String(cString: s!)) / \(String(cString: n!)) [\(fmt)]")
        }, Unmanaged.passUnretained(channels).toOpaque())
        report["ioreport_channels"] = channels.names

        var phases: [[String: Any]] = []
        let total = 9
        var step = 0

        /// Runs one phase: an optional workload for `seconds`, sampling once a second.
        func phase(_ name: String, _ what: String, seconds: Int, model: (dir: String, macs: Int)? = nil,
                   duty: Double = 1, cpuThreads: Int = 0) {
            step += 1
            print("[\(step)/\(total)] \(what)…")
            fflush(stdout)
            if let ior { _ = anemon_ior_visit(ior, { _, _, _, _, _, _, _, _ in }, nil) }
            smc.reset()
            _ = monitor.snapshot()
            let job = model.map { runner.start($0.dir, seconds: seconds, duty: duty) }
            let spin = cpuThreads > 0 ? CPUSpinner(threads: cpuThreads) : nil
            var snaps: [[String: Any]] = []
            for _ in 0..<seconds {
                for _ in 0..<4 { usleep(250_000); smc.sample() }
                let s = monitor.snapshot()
                snaps.append(monitor.fields(s, debug: true))
            }
            spin?.stop()
            var p: [String: Any] = ["name": name, "workload": what, "seconds": seconds, "snapshots": snaps,
                                    "smc_mean_w": smc.means(), "smc_max_w": smc.maxima()]
            if let ior {
                let d = ChannelDeltas()
                _ = anemon_ior_visit(ior, { ctx, g, s, n, _, nv, labels, values in
                    let d = Unmanaged<ChannelDeltas>.fromOpaque(ctx!).takeUnretainedValue()
                    let key = "\(String(cString: g!)) / \(String(cString: s!)) / \(String(cString: n!))"
                    if labels == nil {
                        if nv == 1, values![0] != 0 { d.values[key] = Int(values![0]) }
                    } else {
                        var states: [String: Int] = [:]
                        for i in 0..<Int(nv) where values![i] > 0 {
                            states[String(cString: labels![i]!).trimmingCharacters(in: .whitespaces)] = Int(values![i])
                        }
                        if !states.isEmpty { d.values[key] = states }
                    }
                }, Unmanaged.passUnretained(d).toOpaque())
                p["ioreport"] = d.values
            }
            if let job {
                if let r = job.finish() {
                    var w: [String: Any] = ["ms_per_eval": r.msPerEval, "host_busy_pct": r.hostBusyPct]
                    if let m = model, m.macs > 0 { w["tops"] = 2 * Double(m.macs) / (r.msPerEval / 1e3) / 1e12 }
                    p["result"] = w
                } else {
                    p["result"] = "workload failed"
                }
            }
            phases.append(p)
        }

        let pcores = sysctlInt("hw.perflevel0.logicalcpu") ?? 4
        phase("idle", "idle", seconds: 8)
        phase("cpu", "CPU only, \(pcores) spinning threads, no ANE", seconds: 8, cpuThreads: pcores)
        phase("sustained", "sustained peak compute (INT8 5x5 conv, 4 layers), 30 s",
              seconds: 30, model: runner.generate("peak", "a8w8", "conv", 1024, 1024, 128, 128, 5, layers: 4))
        phase("power", "peak power (INT8 3x3 conv, 512 channels, 8 layers)",
              seconds: 12, model: runner.generate("power", "a8w8", "conv", 512, 512, 32, 32, 3, layers: 8))
        phase("bandwidth", "DRAM read (FP16 2560x65536 GEMV)",
              seconds: 10, model: runner.generate("bw", "fp16", "conv", 2560, 65536, 1, 1, 1))
        // About 20 ms per evaluation, so per-call host overhead stays small
        // (the same model `anemon calibrate` uses for its busy % check).
        var busy = runner.generate("busy", "a8w8", "conv", 1024, 1024, 128, 128, 3)
        if let m = busy, let r = runner.start(m.dir, seconds: 2).finish(), r.msPerEval < 20 {
            let layers = Int((20 / r.msPerEval).rounded(.up))
            busy = runner.generate("busy\(layers)", "a8w8", "conv", 1024, 1024, 128, 128, 3, layers: layers)
        }
        phase("duty100", "busy check, 100% duty", seconds: 10, model: busy, duty: 1)
        phase("duty50", "busy check, 50% duty", seconds: 10, model: busy, duty: 0.5)
        // A single small model called back to back: the host overhead case.
        phase("small", "small model called back to back (FP16 1x1 conv 256ch 16x16)",
              seconds: 8, model: runner.generate("small", "fp16", "conv", 256, 256, 16, 16, 1))
        phase("tail", "idle until the ANE powers off", seconds: 10)
        report["phases"] = phases

        let file = "anemon-diagnose-\(dev.architecture).json"
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: file))
            // Hand the file to the user who ran sudo.
            if let uid = ProcessInfo.processInfo.environment["SUDO_UID"].flatMap({ uid_t($0) }),
               let gid = ProcessInfo.processInfo.environment["SUDO_GID"].flatMap({ gid_t($0) }) {
                chown(file, uid, gid)
            }
            print(String(format: "\nWrote %@ (%.1f MB). Please send this file back.", file, Double(data.count) / 1e6))
        } catch {
            print("\ncould not write \(file): \(error.localizedDescription)")
            return 1
        }
        return 0
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var b = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &b, &size, nil, 0)
        return String(cString: b)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
    }
}

private final class ChannelList { var names: [String] = [] }
private final class ChannelDeltas { var values: [String: Any] = [:] }

/// Every SMC key that reads as a float watt value ("P..." power keys), sampled
/// on demand. Keys are found once, by index.
private final class SMCKeys {
    private(set) var keys: [String] = []
    private var sum: [String: Double] = [:]
    private var peak: [String: Double] = [:]
    private var n = 0

    init() {
        guard anemon_smc_open() == 0 else { return }
        let count = anemon_smc_key_count()
        var buf = [CChar](repeating: 0, count: 5)
        for i in 0..<max(count, 0) {
            guard anemon_smc_key_at(UInt32(i), &buf) == 0 else { continue }
            let k = String(cString: buf)
            var v: Float = 0
            if k.hasPrefix("P"), anemon_smc_read_float(k, &v) == 0 { keys.append(k) }
        }
    }

    func reset() { sum = [:]; peak = [:]; n = 0 }

    func sample() {
        for k in keys {
            var v: Float = 0
            guard anemon_smc_read_float(k, &v) == 0 else { continue }
            sum[k, default: 0] += Double(v)
            peak[k] = max(peak[k] ?? -.infinity, Double(v))
        }
        n += 1
    }

    func means() -> [String: Double] { sum.mapValues { ($0 / Double(max(n, 1)) * 1000).rounded() / 1000 } }
    func maxima() -> [String: Double] { peak.mapValues { ($0 * 1000).rounded() / 1000 } }
}

/// Busy-loops threads to load the CPU without touching the ANE.
private final class CPUSpinner {
    private let lock = NSLock()
    private var running = true

    init(threads: Int) {
        for _ in 0..<threads {
            Thread.detachNewThread { [self] in
                var x = 1.0
                while self.isRunning {
                    for _ in 0..<100_000 { x = x * 1.0000001 + 1e-9 }
                }
                if x == 0 { print(x) }
            }
        }
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    func stop() { lock.lock(); running = false; lock.unlock() }
}
