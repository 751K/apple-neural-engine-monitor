import CANEMon
import Foundation

/// One reporting interval, combining all sources.
struct Snapshot {
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

    init(intervalS: Double, useTrace: Bool, usePower: Bool) {
        self.intervalS = intervalS
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
            for d in w.devices {
                s.busyPct.append(100 * d.busyNs / span)
                s.tasksPerS.append(Double(d.tasks) / (span / 1e9))
                s.avgTaskMs.append(d.tasks > 0 ? d.taskNsSum / Double(d.tasks) / 1e6 : nil)
                s.estimatedPct.append(d.tasks > 0 ? 100 * Double(d.estimatedTasks) / Double(d.tasks) : 0)
            }
            if w.devices.isEmpty {
                // No ANE task seen yet since start: report an idle device.
                s.busyPct = [0]; s.tasksPerS = [0]; s.avgTaskMs = [nil]; s.estimatedPct = [0]
            }
            s.programs = w.programs
            s.traceErrors = w.droppedReads
            s.traceEventsPerS = Double(w.eventsRead) / (span / 1e9)
            s.traceRestarts = w.restarts
        }
        s.powerW = power?.watts
        if let c = counters?.sample() {
            s.dramReadGBs = Double(c.read) / intervalS / 1e9
            s.dramWriteGBs = Double(c.write) / intervalS / 1e9
            s.interruptsPerS = Double(c.interrupts) / intervalS
        }
        return s
    }

    func stop() {
        trace?.stop()
        power?.stop()
    }
}
