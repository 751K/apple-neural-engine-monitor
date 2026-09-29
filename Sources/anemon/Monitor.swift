import CANEMon
import Foundation

/// Whether the busy figures can be trusted on this machine.
enum BusyStatus: String {
    case measured       // task events seen
    case idle           // no task events and no other sign of ANE activity
    case unverified     // no task events, and no independent counter to confirm idleness
    case unsupported    // the ANE is active per IOReport but no task events arrive
}

/// One reporting interval, combining all sources.
struct Snapshot {
    var busySource = BusySource.none
    var busyStatus = BusyStatus.unverified
    var time = Date()
    var intervalS = 1.0
    var busyPct: [Double] = []          // per ANE device
    var tasksPerS: [Double] = []
    var avgTaskMs: [Double?] = []
    var estimatedPct: [Double] = []     // share of tasks whose start was inferred
    var programs: [ProgramStats] = []
    var powerW: Double?
    var dramReadGBs: Double?
    var dramWriteGBs: Double?
    var interruptsPerS: Double?
    var traceErrors = 0
    var traceEventsPerS = 0.0
    var traceRestarts = 0
}

/// Collects snapshots at a fixed interval from the available sources.
final class Monitor {
    let device = DeviceInfo.read()
    private(set) var trace: ANETrace?
    private(set) var traceError: String?
    private var power: PowerMetrics?
    private let counters = ANECounters()
    private let intervalS: Double
    // kdebug records reach us with some delay; account a window that ends
    // this far in the past so late events still land in the right window.
    private let lagNs = 250e6
    private var lastTo: Double = 0
    /// Consecutive intervals with ANE activity in IOReport but no task events.
    private var silentActive = 0
    private var unsupported = false

    /// Configurations where busy % was checked against known workloads when
    /// anemon was written; `anemon calibrate` adds the local machine.
    static let validated: [(arch: String, macOSMajor: Int)] = [("h16g", 27)]
    /// Highest ANE power measured per architecture (W), for the power bar.
    static let maxPowerW: [String: Double] = ["h16g": 3.4]
    private var observedMaxPowerW = 1.0
    /// This machine's calibration, from `sudo anemon calibrate`.
    let profile: Profile?

    var isValidated: Bool {
        let os = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if let p = profile, p.macOSMajor == os { return p.busyCheckPassed }
        return Self.validated.contains { $0.arch == device.architecture && $0.macOSMajor == os }
    }

    /// Full-scale value for the power bar: this machine's calibrated maximum,
    /// else the built-in value for a known chip, else the highest value seen.
    var powerScaleW: (watts: Double, measured: Bool) {
        if let w = profile?.maxPowerW { return (w, true) }
        if let w = Self.maxPowerW[device.architecture] { return (w, true) }
        return (observedMaxPowerW, false)
    }

    /// Calibrated ANE read bandwidth, for the DRAM bar.
    var maxReadGBs: Double? { profile?.maxReadGBs }

    init(intervalS: Double, useTrace: Bool, usePower: Bool) {
        self.intervalS = intervalS
        profile = Profile.load(architecture: device.architecture)
        if useTrace {
            let t = ANETrace()
            do {
                try t.start()
                trace = t
            } catch {
                traceError = "\(error)"
            }
        }
        if usePower { power = PowerMetrics(intervalMs: Int(intervalS * 1000)) }
        lastTo = anemon_mach_to_ns(anemon_mach_now()) - lagNs
    }

    var hasPower: Bool { power != nil }

    func snapshot() -> Snapshot {
        var s = Snapshot()
        s.intervalS = intervalS
        let to = anemon_mach_to_ns(anemon_mach_now()) - lagNs
        let from = lastTo
        lastTo = to
        let span = max(to - from, 1)
        if let trace {
            let w = trace.window(from: from, to: to)
            s.busySource = w.source
            for d in w.devices {
                s.busyPct.append(100 * d.busyNs / span)
                s.tasksPerS.append(Double(d.tasks) / (span / 1e9))
                s.avgTaskMs.append(d.tasks > 0 ? d.taskNsSum / Double(d.tasks) / 1e6 : nil)
                s.estimatedPct.append(d.tasks > 0 ? 100 * Double(d.estimatedTasks) / Double(d.tasks) : 0)
            }
            s.programs = w.programs
            s.traceErrors = w.droppedReads
            s.traceEventsPerS = Double(w.eventsRead) / (span / 1e9)
            s.traceRestarts = w.restarts
        }
        s.powerW = power?.watts
        if let p = s.powerW { observedMaxPowerW = max(observedMaxPowerW, p) }
        if let c = counters?.sample() {
            s.dramReadGBs = c.read.map { Double($0) / intervalS / 1e9 }
            s.dramWriteGBs = c.write.map { Double($0) / intervalS / 1e9 }
            s.interruptsPerS = c.interrupts.map { Double($0) / intervalS }
        }
        classify(&s)
        return s
    }

    /// Tells an idle ANE apart from one whose task events this chip or OS does
    /// not produce, using IOReport as an independent witness.
    private func classify(_ s: inout Snapshot) {
        guard trace != nil else { return }
        if s.busySource != .none {
            silentActive = 0
            unsupported = false
            s.busyStatus = .measured
            return
        }
        let irq = s.interruptsPerS, rd = s.dramReadGBs
        let active = (irq ?? 0) > 20 || (rd ?? 0) > 0.2
        if active {
            silentActive += 1
            // A few seconds of activity with no events at all: not a timing gap.
            if silentActive >= 3 { unsupported = true }
        }
        if unsupported {
            s.busyStatus = .unsupported
        } else if active || (irq == nil && rd == nil) {
            s.busyStatus = .unverified
            s.busyPct = [0]; s.tasksPerS = [0]; s.avgTaskMs = [nil]; s.estimatedPct = [0]
        } else {
            s.busyStatus = .idle
            s.busyPct = [0]; s.tasksPerS = [0]; s.avgTaskMs = [nil]; s.estimatedPct = [0]
        }
    }

    func stop() {
        trace?.stop()
        power?.stop()
    }
}
