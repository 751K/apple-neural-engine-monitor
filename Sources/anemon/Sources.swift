import CANEMon
import Foundation
import IOKit

/// ANE power estimate from the `ANE Power` line in `powermetrics` (root only).
/// Availability varies by chip and OS. On M6 / h18g with macOS 27.0.1,
/// powermetrics emits no ANE field; Monitor then estimates ANE power from
/// an SMC rail instead (see `ChipModel`).
final class PowerMetrics {
    private let proc = Process()
    private let lock = NSLock()
    private var latestMilliwatts: Double?
    private var partial = ""

    init?(intervalMs: Int) {
        guard geteuid() == 0, FileManager.default.isExecutableFile(atPath: "/usr/bin/powermetrics") else { return nil }
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        proc.arguments = ["-s", "cpu_power,ane_power", "-i", String(intervalMs)]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let self else { return }
            self.consume(String(decoding: data, as: UTF8.self))
        }
        do { try proc.run() } catch { return nil }
    }

    private func consume(_ s: String) {
        lock.lock()
        defer { lock.unlock() }
        partial += s
        while let nl = partial.firstIndex(of: "\n") {
            let line = partial[..<nl]
            partial = String(partial[partial.index(after: nl)...])
            if line.hasPrefix("ANE Power:"),
               let mw = Double(line.dropFirst("ANE Power:".count).trimmingCharacters(in: .whitespaces)
                   .replacingOccurrences(of: " mW", with: "")) {
                latestMilliwatts = mw
            }
        }
    }

    var watts: Double? {
        lock.lock()
        defer { lock.unlock() }
        return latestMilliwatts.map { $0 / 1000 }
    }

    func stop() {
        if proc.isRunning { proc.terminate() }
    }
}

/// ANE traffic, interrupt rates and P-cluster power from IOReport (no root needed).
final class ANECounters {
    private let ior: OpaquePointer

    init?() {
        guard let r = anemon_ior_open() else { return nil }
        ior = r
        var v = anemon_ior_values()
        _ = anemon_ior_sample(ior, &v)
    }

    /// Deltas since the previous call; check `found` before using a field.
    func sample() -> anemon_ior_values? {
        var v = anemon_ior_values()
        guard anemon_ior_sample(ior, &v) == 0 else { return nil }
        return v
    }

    deinit { anemon_ior_close(ior) }
}

/// Averages one SMC power key, read every 100 ms on a background thread.
final class SMCRail {
    let key: String
    private let lock = NSLock()
    private var sum = 0.0
    private var count = 0
    private var running = true

    init?(key: String) {
        var probe: Float = 0
        guard anemon_smc_open() == 0, anemon_smc_read_float(key, &probe) == 0 else { return nil }
        self.key = key
        Thread.detachNewThread { [weak self] in
            while let self, self.isRunning {
                var w: Float = 0
                if anemon_smc_read_float(self.key, &w) == 0 {
                    self.lock.lock(); self.sum += Double(w); self.count += 1; self.lock.unlock()
                }
                usleep(100_000)
            }
        }
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// Mean watts since the previous call, or nil if no read succeeded.
    func takeMean() -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard count > 0 else { return nil }
        let m = sum / Double(count)
        sum = 0; count = 0
        return m
    }

    func stop() { lock.lock(); running = false; lock.unlock() }
}

/// Static description of the ANE hardware from the H11ANEIn services.
struct DeviceInfo {
    var architecture = "?"
    var cores = 0
    var instances = 0
    var chip = "?"

    static func read() -> DeviceInfo {
        var info = DeviceInfo()
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        if size > 0 {
            var b = [CChar](repeating: 0, count: size)
            sysctlbyname("machdep.cpu.brand_string", &b, &size, nil, 0)
            info.chip = String(cString: b)
        }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("H11ANEIn"), &iter) == KERN_SUCCESS
        else { return info }
        defer { IOObjectRelease(iter) }
        while case let svc = IOIteratorNext(iter), svc != 0 {
            defer { IOObjectRelease(svc) }
            info.instances += 1
            guard let props = IORegistryEntryCreateCFProperty(svc, "DeviceProperties" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            info.cores += props["ANEDevicePropertyNumANECores"] as? Int ?? 0
            if let a = props["ANEDevicePropertyTypeANEArchitectureTypeStr"] as? String { info.architecture = a }
        }
        return info
    }
}
