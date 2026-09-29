import CANEMon
import Foundation
import IOKit

/// ANE power estimate from `powermetrics` (root only). On macOS 27 the
/// IOReport energy counters read as zero outside Apple-entitled processes,
/// so powermetrics is the only source. Its `ane_power` sampler prints nothing
/// on its own, hence `cpu_power` is requested alongside.
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

/// ANE traffic and interrupt rates from IOReport (no root needed).
final class ANECounters {
    private let ior: OpaquePointer

    init?() {
        guard let r = anemon_ior_open() else { return nil }
        ior = r
        var a: UInt64 = 0, b: UInt64 = 0, c: UInt64 = 0
        var found: Int32 = 0
        _ = anemon_ior_sample(ior, &a, &b, &c, &found)
    }

    /// Byte and interrupt deltas since the previous call. A counter whose
    /// channels do not exist on this chip is nil rather than zero.
    func sample() -> (read: UInt64?, write: UInt64?, interrupts: UInt64?)? {
        var rd: UInt64 = 0, wr: UInt64 = 0, irq: UInt64 = 0
        var found: Int32 = 0
        guard anemon_ior_sample(ior, &rd, &wr, &irq, &found) == 0 else { return nil }
        let dram = found & Int32(ANEMON_IOR_DRAM) != 0
        let ints = found & Int32(ANEMON_IOR_INTERRUPTS) != 0
        return (dram ? rd : nil, dram ? wr : nil, ints ? irq : nil)
    }

    deinit { anemon_ior_close(ior) }
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
