import CANEMon
import Foundation

/// Per-machine results of `anemon calibrate`, used as full-scale values and
/// to decide whether busy % has been checked on this chip and OS.
struct Profile: Codable {
    var architecture: String
    var chip: String
    var macOSMajor: Int
    var macOSBuild: String
    var date: String
    var idlePowerW: Double?
    var maxPowerW: Double?
    var peakTOPS: Double?
    var maxReadGBs: Double?
    var busySource: String
    var busyChecks: [BusyCheck]
    var busyCheckPassed: Bool

    struct BusyCheck: Codable {
        var workload: String
        var hostBusyPct: Double
        var anemonBusyPct: Double
    }

    static let directory = URL(fileURLWithPath: "/Library/Application Support/anemon")

    static func url(for architecture: String) -> URL {
        directory.appendingPathComponent("\(architecture).json")
    }

    static func load(architecture: String) -> Profile? {
        guard let data = try? Data(contentsOf: url(for: architecture)) else { return nil }
        return try? JSONDecoder().decode(Profile.self, from: data)
    }
}

/// Runs reference workloads on the ANE and records this machine's limits.
enum Calibrate {
    static func run() -> Int32 {
        guard geteuid() == 0 else {
            print("anemon calibrate needs root for kernel tracing and powermetrics: sudo anemon calibrate")
            return 1
        }
        let anebench = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("anebench").path
        guard FileManager.default.isExecutableFile(atPath: anebench) else {
            print("anebench not found next to anemon (\(anebench)); build both with make")
            return 1
        }
        // Hand kdebug back even if calibration is interrupted.
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig) { _ in
                anemon_kd_stop()
                exit(130)
            }
        }
        let runner = WorkloadRunner(anebench: anebench)
        let monitor = Monitor(intervalS: 1, useTrace: true, usePower: true)
        defer { monitor.stop(); runner.cleanup() }
        if let err = monitor.traceError { print("warning: \(err); busy % will not be checked") }
        let dev = monitor.device
        let os = ProcessInfo.processInfo.operatingSystemVersion
        print("Calibrating \(dev.chip) · ANE \(dev.architecture) · \(dev.cores) cores · macOS \(os.majorVersion)")
        print("This takes about two minutes; keep other ANE and GPU work closed.\n")

        func sample(_ seconds: Int, skip: Int = 2) -> [Snapshot] {
            var out: [Snapshot] = []
            for i in 0..<seconds {
                sleep(1)
                let s = monitor.snapshot()
                if i >= skip { out.append(s) }
            }
            return out
        }
        func median(_ v: [Double]) -> Double? {
            guard !v.isEmpty else { return nil }
            let s = v.sorted()
            return s[s.count / 2]
        }

        // 1. Idle.
        _ = monitor.snapshot()
        print("[1/4] idle baseline…")
        // Long enough for the SMC rail estimate to learn its idle baseline
        // (three idle readings after 2 s of idleness).
        let idle = sample(8, skip: 1)
        let idlePower = median(idle.compactMap(\.powerW))

        // 2. Peak compute: chained 5x5 INT8 convolutions (38 TOPS on M4).
        print("[2/4] peak compute (INT8 5x5 conv, 4 layers)…")
        var peakTOPS: Double?
        var maxPower: Double?
        if let m = runner.generate("peak", "a8w8", "conv", 1024, 1024, 128, 128, 5, layers: 4) {
            let job = runner.start(m.dir, seconds: 14)
            let snaps = sample(13, skip: 4)
            if let r = job.finish() { peakTOPS = 2 * Double(m.macs) / (r.msPerEval / 1e3) / 1e12 }
            // Median of the steady phase: the rail estimate is noisier than a
            // single reading should set the power bar's full scale.
            maxPower = median(snaps.compactMap(\.powerW))
        }

        // 3. Read bandwidth: a tall FP16 GEMV streams its weights from DRAM.
        print("[3/4] DRAM read bandwidth (FP16 2560x65536 GEMV)…")
        var maxRead: Double?
        if let m = runner.generate("bw", "fp16", "conv", 2560, 65536, 1, 1, 1) {
            let job = runner.start(m.dir, seconds: 10)
            let snaps = sample(9, skip: 3)
            _ = job.finish()
            maxRead = snaps.compactMap { $0.dramSource == "amc" ? $0.dramReadGBs : nil }.max()
            if maxRead == nil, let r = job.result {
                // No byte counters on this chip (link histograms clip at full
                // speed): fall back to weight bytes per second.
                maxRead = 2560.0 * 65536 * 2 / (r.msPerEval / 1e3) / 1e9
            }
        }

        // 4. Busy % against workloads whose share of wall time is known.
        print("[4/4] busy % check (tasks of at least 10 ms at 100% and 50% duty)…")
        var checks: [Profile.BusyCheck] = []
        var source = BusySource.none
        // The host share includes the per-evaluation submit/complete overhead
        // (about 0.2 ms), when the ANE is really idle. Stack layers until one
        // evaluation takes at least 10 ms so that overhead stays near 2% on
        // fast chips too (one layer takes 3.9 ms on M6, 10 ms on M4).
        var busyModel = monitor.trace != nil ? runner.generate("busy", "a8w8", "conv", 1024, 1024, 128, 128, 3) : nil
        var layers = 1
        if let m = busyModel, let r = runner.start(m.dir, seconds: 2).finish(), r.msPerEval < 10 {
            layers = Int((10 / r.msPerEval).rounded(.up))
            busyModel = runner.generate("busy\(layers)", "a8w8", "conv", 1024, 1024, 128, 128, 3, layers: layers)
        }
        if let m = busyModel {
            var evalMs = 0.0   // per evaluation, from the full-duty run
            for duty in [1.0, 0.5] {
                let job = runner.start(m.dir, seconds: 9, duty: duty)
                let snaps = sample(8, skip: 3)
                guard let r = job.finish() else { continue }
                if duty == 1 { evalMs = r.msPerEval }
                // Engines of a multi-ANE chip run one evaluation in lockstep:
                // take the busiest one.
                let busy = median(snaps.compactMap { $0.busyStatus == .measured ? $0.busyPct.max() : nil }) ?? 0
                source = snaps.last?.busySource ?? source
                checks.append(.init(workload: String(format: "a8w8 3x3 conv x%ld (%.1f ms/eval), duty %ld%%", layers, evalMs, Int(duty * 100)),
                                    hostBusyPct: r.hostBusyPct, anemonBusyPct: busy))
            }
        }
        let passed = checks.count == 2 && checks.allSatisfy { abs($0.hostBusyPct - $0.anemonBusyPct) <= 5 }

        let fmt = ISO8601DateFormatter()
        let profile = Profile(architecture: dev.architecture, chip: dev.chip, macOSMajor: os.majorVersion,
                              macOSBuild: osBuild(), date: fmt.string(from: Date()),
                              idlePowerW: idlePower, maxPowerW: maxPower, peakTOPS: peakTOPS,
                              maxReadGBs: maxRead, busySource: source.rawValue, busyChecks: checks,
                              busyCheckPassed: passed)

        func f(_ v: Double?, _ spec: String) -> String { v.map { String(format: spec, $0) } ?? "n/a" }
        print("""

        Results
          ANE power      idle \(f(idlePower, "%.2f W"))   max \(f(maxPower, "%.2f W"))
          peak compute   \(f(peakTOPS, "%.1f TOPS")) (INT8)
          read bandwidth \(f(maxRead, "%.1f GB/s"))
          busy source    \(source.rawValue)
        """)
        for c in checks {
            print(String(format: "  busy check     %@: host %.1f%%, anemon %.1f%%", c.workload, c.hostBusyPct, c.anemonBusyPct))
        }
        print(passed ? "  busy %          PASS (within 5 points)" :
              "  busy %          FAIL — anemon will mark busy % as unvalidated on this machine")

        do {
            try FileManager.default.createDirectory(at: Profile.directory, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let url = Profile.url(for: dev.architecture)
            try enc.encode(profile).write(to: url)
            chmod(url.path, 0o644)
            print("\nSaved \(url.path)")
        } catch {
            print("\ncould not save profile: \(error.localizedDescription)")
            return 1
        }
        return passed ? 0 : 2
    }

    private static func osBuild() -> String {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var b = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("kern.osversion", &b, &size, nil, 0)
        return String(cString: b)
    }
}

/// Generates and runs anebench workloads as the user who invoked sudo, whose
/// ANE compiler cache and temporary directory the model compile expects.
final class WorkloadRunner {
    let anebench: String
    let work: String
    private let user = ProcessInfo.processInfo.environment["SUDO_USER"]
    private lazy var userTmp: String? = user.flatMap {
        Self.capture("/usr/bin/sudo", ["-u", $0, "/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(anebench: String) {
        self.anebench = anebench
        var tmpl = Array("/tmp/anemon-calibrate.XXXXXX".utf8CString)
        work = tmpl.withUnsafeMutableBufferPointer { String(cString: mkdtemp($0.baseAddress!)) }
        chmod(work, 0o777)
    }

    func cleanup() { try? FileManager.default.removeItem(atPath: work) }

    private func command(_ args: [String]) -> (String, [String]) {
        guard let user, let tmp = userTmp else { return (anebench, args) }
        return ("/usr/bin/sudo", ["-u", user, "/usr/bin/env", "HOME=/Users/\(user)", "TMPDIR=\(tmp)", anebench] + args)
    }

    func generate(_ name: String, _ mode: String, _ op: String, _ cin: Int, _ cout: Int,
                  _ h: Int, _ w: Int, _ k: Int, layers: Int = 1) -> (dir: String, macs: Int)? {
        let dir = "\(work)/\(name)"
        let (exe, args) = command(["gen", dir, mode, op] + [cin, cout, h, w, k].map(String.init) + ["--layers", "\(layers)"])
        guard let out = Self.capture(exe, args), let macs = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            print("  could not generate the \(name) model")
            return nil
        }
        return (dir, macs)
    }

    final class Job {
        let process = Process()
        let pipe = Pipe()
        var result: (msPerEval: Double, hostBusyPct: Double)?

        /// Waits for the run and parses "… X ms/eval  host-busy=Y%".
        func finish() -> (msPerEval: Double, hostBusyPct: Double)? {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            let ms = text.range(of: #"[\d.]+(?= ms/eval)"#, options: .regularExpression).map { Double(text[$0]) } ?? nil
            let hb = text.range(of: #"(?<=host-busy=)[\d.]+"#, options: .regularExpression).map { Double(text[$0]) } ?? nil
            if let ms, let hb { result = (ms, hb) } else { print("  workload failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))") }
            return result
        }
    }

    func start(_ dir: String, seconds: Int, duty: Double = 1) -> Job {
        let job = Job()
        let (exe, args) = command(["run", dir, "-t", "\(seconds)", "--duty", "\(duty)"])
        job.process.executableURL = URL(fileURLWithPath: exe)
        job.process.arguments = args
        job.process.standardOutput = job.pipe
        job.process.standardError = job.pipe
        try? job.process.run()
        return job
    }

    static func capture(_ exe: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
