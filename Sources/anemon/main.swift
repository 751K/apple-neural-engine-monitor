import Foundation

let usage = """
usage: sudo anemon [--interval SECONDS] [--json] [--count N] [--no-power]
       sudo anemon calibrate

Monitors the Apple Neural Engine:
  busy %     time the ANE spent executing tasks (kdebug firmware events, root)
  tasks/s    completed ANE tasks, with average task duration
  power      ANE power estimate from powermetrics (root), or on M6 (h18g) from
             an SMC rail minus S+P-core power (no root needed)
  DRAM       ANE memory traffic and interrupt rate (IOReport, no root needed)

Without root, busy % and powermetrics are unavailable; some chips do not
expose counters that anemon currently recognizes.

`anemon calibrate` runs reference workloads (about 2 min) to measure available
power and bandwidth data, peak compute, and busy % against known duty cycles.
Power may be unavailable; bandwidth may be estimated if DRAM counters are
missing. Results are saved for later runs.
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

let debug = ProcessInfo.processInfo.environment["ANEMON_DEBUG"] != nil

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
        d["slept_since_boot_s"] = s.sleptS
        // Unsupported: do not report a busy figure we cannot measure.
        d["ane_busy_pct"] = s.busyStatus == .unsupported ? NSNull() : s.busyPct as Any
        d["ane_tasks_per_s"] = s.tasksPerS
        d["ane_avg_task_ms"] = s.avgTaskMs.map { $0 ?? NSNull() as Any }
        d["ane_estimated_task_pct"] = s.estimatedPct
        d["trace_events_per_s"] = s.traceEventsPerS
        d["trace_restarts"] = s.traceRestarts
        d["programs"] = s.programs.prefix(16).map {
            ["handle": String(format: "0x%llx", $0.handle), "pid": $0.pid.map { Int($0) } as Any? ?? NSNull(),
             "process": $0.process ?? NSNull(), "tasks": $0.tasks, "busy_ms": $0.busyNs / 1e6,
             "energy_mj_per_task": s.energyPerTaskMJ($0) ?? NSNull()] as [String: Any]
        }
    } else {
        d["ane_busy_pct"] = NSNull()
        d["trace_error"] = monitor.traceError ?? NSNull()
    }
    d["ane_power_w"] = s.powerW ?? NSNull()
    d["ane_power_source"] = s.powerSource ?? NSNull()
    d["dram_read_gbs"] = s.dramReadGBs ?? NSNull()
    d["dram_write_gbs"] = s.dramWriteGBs ?? NSNull()
    d["dram_source"] = s.dramSource ?? NSNull()
    d["dram_clipped_pct"] = s.dramClippedPct ?? NSNull()
    if debug {
        d["debug_rail_w"] = s.railW ?? NSNull()
        d["debug_pcluster_w"] = s.pclusterW ?? NSNull()
        d["debug_trace_max_late_ms"] = s.traceMaxLateMs
        d["debug_trace_late_tasks"] = s.traceLateTasks
        d["debug_trace_late_busy_ms"] = s.traceLateBusyMs
    }
    d["ane_interrupts_per_s"] = s.interruptsPerS ?? NSNull()
    d["host_cpu_power_w"] = s.hostCPUW ?? NSNull()
    d["host_cpu_extra_w"] = s.hostCPUExtraW ?? NSNull()
    d["memory_power_w"] = s.memoryPowerW ?? NSNull()
    d["ane_state"] = s.aneState.isEmpty ? NSNull() : s.aneState as Any
    d["ane_idle_s"] = s.aneIdleS ?? NSNull()
    d["ane_power_off_in_s"] = s.anePowerOffInS ?? NSNull()
    d["ane_throttle_pct"] = s.throttlePct ?? NSNull()
    d["ane_throttle_kinds"] = s.throttleKinds
    d["dram_level"] = s.dramLevel ?? NSNull()
    d["dram_level_pct"] = s.dramLevelPct ?? NSNull()
    d["dram_peak_gbs"] = s.dramPeakGBs ?? NSNull()
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
