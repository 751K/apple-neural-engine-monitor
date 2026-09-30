import Foundation

/// Full-screen ANSI renderer.
final class TUI {
    private var history: [[Double]] = []   // busy % per device
    private var powerHistory: [Double] = []
    private var orig = termios()
    private let esc = "\u{1B}["

    func enter() {
        tcgetattr(STDIN_FILENO, &orig)
        var raw = orig
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        raw.c_cc.16 = 0 // VMIN
        raw.c_cc.17 = 0 // VTIME
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        out("\(esc)?1049h\(esc)?25l")
    }

    func leave() {
        out("\(esc)?25h\(esc)?1049l")
        tcsetattr(STDIN_FILENO, TCSANOW, &orig)
    }

    /// Returns true if the user pressed q.
    func quitRequested() -> Bool {
        var c: UInt8 = 0
        while read(STDIN_FILENO, &c, 1) == 1 {
            if c == UInt8(ascii: "q") || c == UInt8(ascii: "Q") || c == 3 { return true }
        }
        return false
    }

    private func out(_ s: String) {
        FileHandle.standardOutput.write(s.data(using: .utf8)!)
    }

    private var width: Int {
        var w = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0, w.ws_col > 20 { return Int(w.ws_col) }
        return 80
    }

    private func color(_ pct: Double) -> String {
        pct < 50 ? "\(esc)32m" : pct < 85 ? "\(esc)33m" : "\(esc)31m"
    }

    private func bar(_ frac: Double, _ n: Int) -> String {
        let f = max(0, min(1, frac)) * Double(n)
        let full = Int(f)
        let parts = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]
        let rem = parts[Int((f - Double(full)) * 8)]
        let s = String(repeating: "█", count: full) + rem
        return s + String(repeating: "·", count: max(0, n - full - (rem.isEmpty ? 0 : 1)))
    }

    private func spark(_ v: [Double], max top: Double, _ n: Int) -> String {
        let ticks = Array("▁▂▃▄▅▆▇█")
        let tail = v.suffix(n)
        let pad = String(repeating: " ", count: n - tail.count)
        return pad + String(tail.map { x in
            x <= 0 ? " " : ticks[min(7, Int(x / top * 7.999))]
        })
    }

    func render(_ s: Snapshot, monitor: Monitor) {
        let device = monitor.device
        let (maxW, maxMeasured) = monitor.powerScaleW
        let w = min(width, 100)
        let barW = max(10, w - 44)
        if history.count < s.busyPct.count { history += Array(repeating: [], count: s.busyPct.count - history.count) }
        for (i, b) in s.busyPct.enumerated() { history[i].append(b); if history[i].count > 200 { history[i].removeFirst() } }
        if let p = s.powerW { powerHistory.append(p); if powerHistory.count > 200 { powerHistory.removeFirst() } }

        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        var o = "\(esc)H\(esc)2J"
        o += "\(esc)1manemon\(esc)0m  Apple Neural Engine monitor   \(esc)2m\(device.chip) · \(device.architecture) · \(device.cores) cores · \(df.string(from: s.time))\(esc)0m\n"
        o += String(repeating: "─", count: w) + "\n"
        if !monitor.isValidated {
            let os = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
            if monitor.profile == nil {
                o += "\(esc)33m! \(device.architecture) / macOS \(os) not calibrated: run `sudo anemon calibrate` once\(esc)0m\n"
            } else {
                o += "\(esc)33m! busy % failed calibration on \(device.architecture) / macOS \(os): figures may be wrong\(esc)0m\n"
            }
        }

        if let note = monitor.traceError {
            o += "\(esc)33m! busy %: \(note)\(esc)0m\n"
        } else if s.busyStatus == .unsupported {
            o += "\(esc)33mANE busy   not available: IOReport shows ANE activity, but no ANE task events arrive\n"
            o += "           on this chip / macOS. Please report the output of calibration/scripts/trace_decode.sh.\(esc)0m\n"
        } else {
            if s.busySource == .host {
                o += "\(esc)2mANE busy from driver submit/complete events (firmware events absent); includes queueing time\(esc)0m\n"
            } else if s.busyStatus == .unverified {
                o += "\(esc)2mno ANE task events yet; idle cannot be confirmed from IOReport on this chip\(esc)0m\n"
            }
            for (i, b) in s.busyPct.enumerated() {
                let name = s.busyPct.count > 1 ? "ANE\(i) busy" : "ANE busy "
                let avg = s.avgTaskMs[i].map { String(format: "%8.3f ms/task", $0) } ?? "               "
                o += String(format: "%@  %@%@\(esc)0m %6.1f %%  %7.0f tasks/s %@\n",
                            name, color(b), bar(b / 100, barW), b, s.tasksPerS[i], avg)
                if s.estimatedPct[i] > 20 {
                    o += String(format: "\(esc)2m           %.0f%% of tasks were only partly reported by the firmware; their time is estimated\(esc)0m\n", s.estimatedPct[i])
                }
            }
        }
        if let p = s.powerW {
            // Full scale: the highest ANE power measured on this chip (M4: 3.4 W
            // at 31 TOPS INT8), or the highest value seen so far on others.
            let scale = maxMeasured ? "" : ", scale = max seen"
            let src = s.powerSource == "smc_estimate" ? "SMC rail − P-cores, estimate" : "powermetrics estimate"
            o += String(format: "Power      \(esc)36m%@\(esc)0m %6.2f W   \(esc)2m(%@%@)\(esc)0m\n",
                        bar(p / maxW, barW), p, src, scale)
        } else if !monitor.hasPower {
            o += "\(esc)2mPower      needs root (run with sudo)\(esc)0m\n"
        } else if monitor.awaitingPowerBaseline {
            o += "\(esc)2mPower      waiting for an idle ANE interval to set the baseline…\(esc)0m\n"
        } else {
            o += "\(esc)2mPower      waiting for powermetrics…\(esc)0m\n"
        }
        if let r = s.dramReadGBs, let maxR = monitor.maxReadGBs {
            o += String(format: "DRAM read  \(esc)35m%@\(esc)0m %6.1f GB/s  \(esc)2m(scale = calibrated %.0f GB/s)\(esc)0m\n",
                        bar(r / maxR, barW), r, maxR)
        }
        var dram = s.dramReadGBs.map { r in String(format: "read %6.2f GB/s   write %6.2f GB/s", r, s.dramWriteGBs ?? 0) }
            ?? "\(esc)2mn/a (no ANE DRAM counters on this chip)\(esc)0m"
        if let c = s.dramClippedPct, c > 10 {
            dram += String(format: "  \(esc)33m(lower bound: %.0f%% of samples at the histogram top)\(esc)0m", c)
        }
        let irq = s.interruptsPerS.map { String(format: "interrupts %7.0f/s", $0) } ?? "\(esc)2minterrupts n/a\(esc)0m"
        o += "DRAM       \(dram)   \(irq)\n"
        o += "\n"
        let sw = max(10, w - 14)
        for (i, h) in history.enumerated() {
            o += String(format: "%@ \(esc)32m%@\(esc)0m  100%%\n", history.count > 1 ? "busy ANE\(i)" : "busy     ", spark(h, max: 100, sw))
        }
        if !powerHistory.isEmpty {
            o += String(format: "power     \(esc)36m%@\(esc)0m %4.1fW\n", spark(powerHistory, max: maxW, sw), maxW)
        }
        if !s.programs.isEmpty {
            o += "\n\(esc)1mprograms (ANE time this interval)\(esc)0m\n"
            o += "  handle              share   tasks/s    ms/task\n"
            for p in s.programs.prefix(8) {
                let share = 100 * p.busyNs / (s.intervalS * 1e9)
                o += String(format: "  0x%-14llx %7.1f%% %9.0f %10.3f\n", p.handle, share,
                            Double(p.tasks) / s.intervalS, p.busyNs / Double(max(p.tasks, 1)) / 1e6)
            }
        }
        if s.traceErrors > 0 { o += "\(esc)31mkdebug read errors: \(s.traceErrors)\(esc)0m\n" }
        if s.traceRestarts > 0 {
            o += "\(esc)33mkdebug buffer overflowed and was restarted \(s.traceRestarts)× — busy % may be low this interval\(esc)0m\n"
        }
        o += "\n\(esc)2mq quit · busy % = time the ANE was executing a task (not how many of its cores or MACs were used)\(esc)0m\n"
        out(o)
    }
}
