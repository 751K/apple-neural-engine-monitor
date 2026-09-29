import Foundation

let usage = """
usage: sudo anemon [--interval SECONDS] [--json] [--count N] [--no-power]
       sudo anemon calibrate

Monitors the Apple Neural Engine:
  busy %     time the ANE spent executing tasks (kdebug firmware events, root)
  tasks/s    completed ANE tasks, with average task duration
  power      ANE power estimate from powermetrics (root)
  DRAM       ANE memory traffic and interrupt rate (IOReport, no root needed)

Without root only the DRAM/interrupt counters are available.

`anemon calibrate` runs reference workloads (about 90 s) to measure this
machine's ANE power, peak compute and read bandwidth, checks busy % against
known duty cycles, and saves the results for later runs.
"""

if CommandLine.arguments.dropFirst().first == "calibrate" {
    exit(Calibrate.run())
}

var interval = 1.0
var json = false
var count = 0
var usePower = true
var args = CommandLine.arguments.dropFirst()
while let a = args.popFirst() {
    switch a {
    case "--interval", "-i": interval = Double(args.popFirst() ?? "") ?? interval
    case "--json": json = true
    case "--count", "-n": count = Int(args.popFirst() ?? "") ?? 0
    case "--no-power": usePower = false
    case "-h", "--help": print(usage); exit(0)
    default: FileHandle.standardError.write("unknown argument \(a)\n\(usage)\n".data(using: .utf8)!); exit(2)
    }
}
interval = max(0.25, interval)

let monitor = Monitor(intervalS: interval, useTrace: true, usePower: usePower)
let tui = json ? nil : TUI()

// Always hand kdebug back and restore the terminal, however we exit.
func shutdown(_ code: Int32) -> Never {
    monitor.stop()
    tui?.leave()
    exit(code)
}
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig) { _ in
        monitor.stop()
        tui?.leave()
        exit(0)
    }
}

func jsonLine(_ s: Snapshot) -> String {
    var d: [String: Any] = [
        "timestamp": ISO8601DateFormatter().string(from: s.time),
        "interval_s": s.intervalS,
    ]
    d["validated"] = monitor.isValidated
    d["calibrated"] = monitor.profile != nil
    if monitor.trace != nil {
        d["ane_busy_source"] = s.busySource.rawValue
        d["ane_busy_status"] = s.busyStatus.rawValue
        // Unsupported: do not report a busy figure we cannot measure.
        d["ane_busy_pct"] = s.busyStatus == .unsupported ? NSNull() : s.busyPct as Any
        d["ane_tasks_per_s"] = s.tasksPerS
        d["ane_avg_task_ms"] = s.avgTaskMs.map { $0 ?? NSNull() as Any }
        d["ane_estimated_task_pct"] = s.estimatedPct
        d["trace_events_per_s"] = s.traceEventsPerS
        d["trace_restarts"] = s.traceRestarts
        d["programs"] = s.programs.prefix(16).map {
            ["handle": String(format: "0x%llx", $0.handle), "tasks": $0.tasks, "busy_ms": $0.busyNs / 1e6] as [String: Any]
        }
    } else {
        d["ane_busy_pct"] = NSNull()
        d["trace_error"] = monitor.traceError ?? NSNull()
    }
    d["ane_power_w"] = s.powerW ?? NSNull()
    d["dram_read_gbs"] = s.dramReadGBs ?? NSNull()
    d["dram_write_gbs"] = s.dramWriteGBs ?? NSNull()
    d["ane_interrupts_per_s"] = s.interruptsPerS ?? NSNull()
    let data = try! JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

if let err = monitor.traceError, json {
    FileHandle.standardError.write("anemon: \(err)\n".data(using: .utf8)!)
}
tui?.enter()
var n = 0
let tick = UInt32(interval * 1_000_000)
while true {
    // Poll for q while waiting out the interval.
    var slept: UInt32 = 0
    while slept < tick {
        usleep(50_000)
        slept += 50_000
        if tui?.quitRequested() == true { shutdown(0) }
    }
    let s = monitor.snapshot()
    if json {
        print(jsonLine(s))
        fflush(stdout)
    } else {
        tui!.render(s, monitor: monitor)
    }
    n += 1
    if count > 0 && n >= count { shutdown(0) }
}
