import Foundation

let usage = """
usage: sudo anemon [--interval SECONDS] [--json] [--count N] [--no-power]
       sudo anemon calibrate
       sudo anemon diagnose

Monitors the Apple Neural Engine:
  busy %     time the ANE spent executing tasks (kdebug firmware events, root)
  tasks/s    completed ANE tasks, with average task duration
  power      ANE power from the SMC rail PP0b minus the CPU cluster that
             shares it (M4, M5, M6; no root needed); on other chips from
             powermetrics (root), whose ANE figure is a model estimate
  DRAM       ANE memory traffic and interrupt rate (IOReport, no root needed)

Without root, busy % and powermetrics are unavailable; some chips do not
expose counters that anemon currently recognizes.

`anemon calibrate` runs reference workloads (about 2 min) to measure available
power and bandwidth data, peak compute, and busy % against known duty cycles.
Power may be unavailable; bandwidth may be estimated if DRAM counters are
missing. Results are saved for later runs.

`anemon diagnose` (about 3 min) records every IOReport channel and SMC power
key while running reference workloads, and writes anemon-diagnose-<chip>.json
to the current directory: for chips anemon does not know yet. The file holds
the chip model, macOS version, channel names and readings; nothing personal.
"""

switch CommandLine.arguments.dropFirst().first {
case "calibrate": exit(Calibrate.run())
case "diagnose": exit(Diagnose.run())
default: break
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
    let data = try! JSONSerialization.data(withJSONObject: monitor.fields(s, debug: debug), options: [.sortedKeys])
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
