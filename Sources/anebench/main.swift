import CANERun
import Foundation

let usage = """
usage:
  anebench gen DIR MODE OP CIN COUT H W K [--valid] [--layers N]
      Writes a MIL conv model to DIR and prints its MAC count.
      MODE fp16 | w8 (int8 weights) | a8w8 (int8 weights and activations)
      OP   conv | dw (depthwise)
      --valid uses valid instead of same padding; --layers chains N layers.
      PAD=valid and LAYERS=N in the environment do the same.
  anebench run DIR [-t SECONDS] [--duty FRACTION] [--period MS]
      Runs the model on the ANE for SECONDS (default 15). With --duty < 1 it
      submits work for FRACTION of each period (default 200 ms) and sleeps
      for the rest. Prints evaluations, time per evaluation and the share of
      wall time spent inside evaluations (host-busy).
"""

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { die(usage) }
args.removeFirst()

func takeFlag(_ name: String) -> Bool {
    if let i = args.firstIndex(of: name) { args.remove(at: i); return true }
    return false
}

func takeOption(_ names: String...) -> String? {
    for n in names {
        if let i = args.firstIndex(of: n), i + 1 < args.count {
            let v = args[i + 1]
            args.removeSubrange(i...i + 1)
            return v
        }
    }
    return nil
}

switch cmd {
case "gen":
    let env = ProcessInfo.processInfo.environment
    let valid = takeFlag("--valid") || env["PAD"] == "valid"
    let layers = Int(takeOption("--layers") ?? env["LAYERS"] ?? "1") ?? 1
    guard args.count == 8,
          let mode = ConvModel.Mode(rawValue: args[1]), let op = ConvModel.Op(rawValue: args[2]),
          let cin = Int(args[3]), let cout = Int(args[4]), let h = Int(args[5]), let w = Int(args[6]),
          let k = Int(args[7])
    else { die(usage) }
    let model = ConvModel(mode: mode, op: op, cin: cin, cout: cout, height: h, width: w, kernel: k,
                          validPadding: valid, layers: max(1, layers))
    do {
        try model.write(to: URL(fileURLWithPath: args[0], isDirectory: true))
    } catch {
        die("anebench: \(error.localizedDescription)")
    }
    print(model.macs)

case "run":
    let seconds = Double(takeOption("-t") ?? "15") ?? 15
    let duty = Double(takeOption("--duty", "-duty") ?? "1") ?? 1
    let periodMs = Double(takeOption("--period", "-period") ?? "200") ?? 200
    guard args.count == 1 else { die(usage) }
    let dir = args[0]
    var err = [CChar](repeating: 0, count: 512)
    guard let r = anerun_open(dir, &err, Int32(err.count)) else {
        die("anebench: \(String(cString: err))")
    }
    defer { anerun_close(r) }

    let clock = ContinuousClock()
    let start = clock.now
    let total = Duration.milliseconds(Int64(seconds * 1000))
    let period = Duration.milliseconds(Int64(periodMs))
    let on = period * duty
    var evals = 0
    var inEval = Duration.zero
    while clock.now - start < total {
        let periodStart = clock.now
        repeat {
            let t0 = clock.now
            if anerun_eval(r, &err, Int32(err.count)) != 0 { die("anebench: \(String(cString: err))") }
            inEval += clock.now - t0
            evals += 1
        } while (duty >= 1 || clock.now - periodStart < on) && clock.now - start < total
        if duty < 1 {
            let rest = period - (clock.now - periodStart)
            if rest > .zero { Thread.sleep(forTimeInterval: Double(rest.components.attoseconds) / 1e18 + Double(rest.components.seconds)) }
        }
    }
    let elapsed = clock.now - start
    func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) / 1e15 }
    let name = URL(fileURLWithPath: dir).lastPathComponent
    print(String(format: "%@ evals=%d  %.3f ms/eval  host-busy=%.1f%%",
                 name, evals, ms(elapsed) / Double(max(evals, 1)), 100 * ms(inEval) / ms(elapsed)))

default:
    die(usage)
}
