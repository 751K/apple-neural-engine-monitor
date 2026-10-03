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
    /// Length of the kdebug window the busy figures cover (s). The loop sleeps
    /// for the nominal interval, then spends time sampling, so it runs longer.
    var spanS = 1.0
    var busyPct: [Double] = []          // per ANE device
    var tasksPerS: [Double] = []
    var avgTaskMs: [Double?] = []
    var estimatedPct: [Double] = []     // share of tasks whose start was inferred
    var programs: [ProgramStats] = []
    var powerW: Double?
    var powerSource: String?            // "powermetrics" or "smc_estimate"
    var dramReadGBs: Double?
    var dramWriteGBs: Double?
    var dramSource: String?             // "amc" (byte counters) or "histogram"
    var dramClippedPct: Double?         // histogram samples in the top bin
    var railW: Double?                  // raw inputs of the SMC power estimate
    var pclusterW: Double?
    /// CPU cluster that runs the ANE's callers (IOReport "PACC": on M6 the
    /// 2 Super and 4 Performance cores), in W. High while the ANE is busy with
    /// small, frequent calls: the host side, not the ANE, then draws most power.
    var hostCPUW: Double?
    /// hostCPUW minus its median while the ANE is idle.
    var hostCPUExtraW: Double?
    /// SMC rails that rise with DRAM traffic (M6: PP2b + PP4b). Includes
    /// every client of memory, not only the ANE.
    var memoryPowerW: Double?
    /// Per engine: "off", "running" or "transition" (the IOP's dominant state).
    var aneState: [String] = []
    /// Seconds since the ANE last showed activity (tasks or interrupts).
    var aneIdleS: Double?
    /// Seconds until the driver's power-off timer fires, if known for this chip.
    var anePowerOffInS: Double?
    /// Share of the interval with any ANE throttle trigger active, and which.
    var throttlePct: Double?
    var throttleKinds: [String] = []
    /// DRAM frequency level with the most residency ("F9"), and its share.
    var dramLevel: String?
    var dramLevelPct: Double?
    /// Peak DRAM bandwidth at that level, where the level's speed is known.
    var dramPeakGBs: Double?
    var interruptsPerS: Double?
    var traceErrors = 0
    var traceEventsPerS = 0.0
    var traceRestarts = 0
    /// Time the Mac has slept since boot. Once it is non-zero the ANE driver
    /// stamps firmware task events that far in the past (seen on M4, macOS
    /// 27.0.1), and the kernel drops every one of them; only the driver's
    /// submit/complete events remain until the next reboot.
    var sleptS = 0.0
    var traceMaxLateMs = 0.0
    var traceLateTasks = 0
    var traceLateBusyMs = 0.0
}

extension Snapshot {
    /// Number of ANE engines the busy figures cover.
    var engines: Int { max(busyPct.count, 1) }

    /// A program's share of the ANE's total capacity: its busy time over the
    /// window times the number of engines. A model compiled for both M6
    /// engines runs one task on each per inference, so dividing by one
    /// engine's time would read up to 200%.
    func share(_ p: ProgramStats) -> Double { 100 * p.busyNs / (spanS * 1e9 * Double(engines)) }

    /// ANE energy per task for one program (mJ): the interval's ANE energy
    /// split by each program's share of ANE busy time. Includes the share of
    /// fixed ANE power, so it is the energy a task costs at this load.
    func energyPerTaskMJ(_ p: ProgramStats) -> Double? {
        guard let w = powerW, w > 0, p.tasks > 0 else { return nil }
        let busy = programs.reduce(0) { $0 + $1.busyNs }
        guard busy > 0 else { return nil }
        return w * spanS * (p.busyNs / busy) / Double(p.tasks) * 1000
    }
}

/// Per-architecture knowledge for sources that need it.
struct ChipModel {
    /// PMP "DCS BW" histogram samples per second on one active link:
    /// 24 MHz / 5400 on h18g (measured 4438–4453/s at 100% duty), 4406–4409/s
    /// measured on h16g, 4745–4786/s on h17 (M5, which has no AMC byte
    /// counters even as root). Used only when the AMC byte counters are
    /// unavailable. The ANE0 read histogram on h17 tops out at 32 GB/s, so a
    /// weight-streaming load (69 GB/s by its weight traffic) reads as a
    /// clipped lower bound.
    var histSamplesPerS: Double?
    /// SMC power key for the rail that feeds the ANE. PP0b also feeds the
    /// CPU cluster IOReport calls "PACC" (h16g: the P cores; h18g: the Super
    /// and Performance cores), whose power IOReport reports separately. On
    /// h16g, rail − cluster reads −1.25 W idle and +7.4 W under an FP16 conv
    /// load that powermetrics puts at 9.6 W. powermetrics' figure is a model
    /// estimate, so the rail is used whenever the chip has one.
    var aneRail: String?
    /// SMC rails that track DRAM traffic. On h18g, PP2b and PP4b rise by about
    /// 2.1 W while the ANE streams weights at 97 GB/s and stay below 0.1 W
    /// under a compute-bound load (their sum follows PZD1); h17 is similar.
    var memoryRails: [String] = []
    /// Seconds after the last inference until the driver powers the ANE off:
    /// 5.68 s on h18g (kernel log `HWDevicePowerOffTimerTimeOut`, IOP state
    /// traces). The first call after power-off pays a firmware boot of about 50 ms.
    var powerOffS: Double?
    /// DRAM levels whose speed is known: level → (MT/s, peak GB/s). On h18g
    /// (16 GB, 8 × 16-bit channels) DCS_F9 is the top level, 10656 MT/s; the
    /// device tree hides the frequencies of the lower levels.
    var dramLevels: [Int: (mts: Double, peakGBs: Double)] = [:]
    /// Which cores the IOReport "PACC" cluster holds: on h18g the Super and
    /// Performance cores share it; on earlier chips it is the P cores.
    var hostClusterName = "P cluster"

    static let known: [String: ChipModel] = [
        "h16g": ChipModel(histSamplesPerS: 4408, aneRail: "PP0b"),
        // h17 (M5, macOS 27.0.0, `anemon diagnose`): PP0b rises 6.2 W under
        // an ANE load with the cluster flat, and 11 W with only the Super
        // cores (IOReport "PACC") busy; PP2b and PP4b rise 3 W while the ANE
        // streams weights at 71 GB/s.
        "h17": ChipModel(histSamplesPerS: 4770, aneRail: "PP0b", memoryRails: ["PP2b", "PP4b"],
                         hostClusterName: "S cluster"),
        "h18g": ChipModel(histSamplesPerS: 24e6 / 5400, aneRail: "PP0b", memoryRails: ["PP2b", "PP4b"],
                          powerOffS: 5.68, dramLevels: [9: (10656, 170.5)], hostClusterName: "S+P cluster"),
    ]
}

/// Collects snapshots at a fixed interval from the available sources.
final class Monitor {
    let device = DeviceInfo.read()
    private(set) var trace: ANETrace?
    private(set) var traceError: String?
    private var power: PowerMetrics?
    private var rail: SMCRail?
    private var memoryRails: [SMCRail] = []
    /// Recent CPU cluster readings while the ANE is idle; their median is the
    /// host's own baseline.
    private var idleHostW: [Double] = []
    /// When the ANE last showed activity (ns, mach time).
    private var lastActiveNs: Double?
    /// rail - P-cluster while the ANE is idle: the rest of the rail's load
    /// plus the bias of the 1 W-wide cluster histogram bins.
    private var railOffsetW: Double?
    /// Recent idle readings of rail - P-cluster; the baseline is their median.
    private var idleRawW: [Double] = []
    /// Seconds the ANE has been idle without a break.
    private var idleForS = 0.0
    /// Recent per-interval estimates while the ANE is active.
    private var recentPowerW: [Double] = []
    private let counters = ANECounters()
    let chipModel: ChipModel?
    private let intervalS: Double
    // kdebug records reach us with some delay; account a window that ends
    // this far in the past so late events still land in the right window.
    private let lagNs = 250e6
    private var lastTo: Double = 0
    /// When the IOReport counters were last sampled (ns); rates use the real
    /// elapsed time, which runs longer than the nominal interval.
    private var lastCountersNs = anemon_mach_to_ns(anemon_mach_now())
    /// Consecutive intervals with ANE activity in IOReport but no task events.
    private var silentActive = 0
    private var unsupported = false

    /// Configurations where busy % was checked against known workloads when
    /// anemon was written; `anemon calibrate` adds the local machine.
    /// h17 (M5) uses driver events (no firmware task events) and read 99% and
    /// 50-54% busy at 100% and 52% duty.
    static let validated: [(arch: String, macOSMajor: Int)] = [("h16g", 27), ("h17", 27), ("h18g", 27)]
    /// Built-in calibration, used when this machine has none: ANE peak power
    /// (W, PP0b rail estimate, median of the steady phase, the larger of the
    /// INT8 5x5 peak-compute load and the INT8 3x3 stack; random inputs) and
    /// read bandwidth (GB/s, weight bytes of an FP16 GEMV per evaluation).
    /// M4 Mac mini and M6, macOS 27.0.1, `anemon calibrate` on 2026-10-03;
    /// M5 MacBook Air read bandwidth, macOS 27.0.0, the same day.
    static let maxPowerW: [String: Double] = ["h16g": 12.8, "h18g": 16.2]
    static let builtinReadGBs: [String: Double] = ["h16g": 65.3, "h17": 69.0, "h18g": 123.8]
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
        // A load can still draw more than the calibrated peak, so the scale
        // grows to the highest value seen.
        if let w = profile?.maxPowerW ?? Self.maxPowerW[device.architecture] {
            return (max(w, observedMaxPowerW), observedMaxPowerW <= w)
        }
        return (observedMaxPowerW, false)
    }

    /// Calibrated ANE read bandwidth, for the DRAM bar.
    var maxReadGBs: Double? { profile?.maxReadGBs ?? Self.builtinReadGBs[device.architecture] }

    init(intervalS: Double, useTrace: Bool, usePower: Bool) {
        self.intervalS = intervalS
        profile = Profile.load(architecture: device.architecture)
        chipModel = ChipModel.known[device.architecture]
        if useTrace {
            let t = ANETrace()
            do {
                try t.start()
                trace = t
            } catch {
                traceError = "\(error)"
            }
        }
        if usePower {
            // A measured rail beats powermetrics' modelled "ANE Power"; use
            // powermetrics only on chips without a known rail.
            rail = chipModel?.aneRail.flatMap { SMCRail(key: $0) }
            if rail == nil { power = PowerMetrics(intervalMs: Int(intervalS * 1000)) }
            memoryRails = (chipModel?.memoryRails ?? []).compactMap { SMCRail(key: $0) }
        }
        lastTo = anemon_mach_to_ns(anemon_mach_now()) - lagNs
    }

    var hasPower: Bool { power != nil || rail != nil }
    /// The SMC estimate is running but has not seen an idle ANE yet.
    var awaitingPowerBaseline: Bool { rail != nil && railOffsetW == nil }

    func snapshot() -> Snapshot {
        var s = Snapshot()
        s.intervalS = intervalS
        let to = anemon_mach_to_ns(anemon_mach_now()) - lagNs
        let from = lastTo
        lastTo = to
        let span = max(to - from, 1)
        s.spanS = span / 1e9
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
            s.traceMaxLateMs = w.maxLateNs / 1e6
            s.traceLateTasks = w.lateTasks
            s.traceLateBusyMs = w.lateBusyNs / 1e6
        }
        s.sleptS = anemon_slept_ns() / 1e9
        s.powerW = power?.watts
        if s.powerW != nil { s.powerSource = "powermetrics" }
        let railW = rail?.takeMean()
        var pclusterW: Double?
        var linkSamples: UInt64?
        let nowNs = anemon_mach_to_ns(anemon_mach_now())
        let dt = max((nowNs - lastCountersNs) / 1e9, 0.01)
        lastCountersNs = nowNs
        if let c = counters?.sample() {
            if c.found & Int32(ANEMON_IOR_DRAM) != 0 {
                s.dramReadGBs = Double(c.dram_rd_bytes) / dt / 1e9
                s.dramWriteGBs = Double(c.dram_wr_bytes) / dt / 1e9
                s.dramSource = "amc"
            } else if c.found & Int32(ANEMON_IOR_DRAM_HIST) != 0, let rate = chipModel?.histSamplesPerS {
                s.dramReadGBs = c.hist_rd / rate / dt
                s.dramWriteGBs = c.hist_wr / rate / dt
                s.dramSource = "histogram"
                s.dramClippedPct = c.hist_rd_samples > 0 ? 100 * Double(c.hist_rd_top) / Double(c.hist_rd_samples) : 0
                linkSamples = c.hist_rd_samples
            }
            if c.found & Int32(ANEMON_IOR_INTERRUPTS) != 0 { s.interruptsPerS = Double(c.interrupts) / dt }
            if c.found & Int32(ANEMON_IOR_PCLUSTER) != 0 { pclusterW = c.pcluster_w }
            readStates(&s, c)
        }
        classify(&s)
        s.railW = railW
        s.pclusterW = pclusterW
        s.hostCPUW = pclusterW
        if !memoryRails.isEmpty {
            let w = memoryRails.compactMap { $0.takeMean() }
            if w.count == memoryRails.count { s.memoryPowerW = w.reduce(0, +) }
        }
        trackActivity(&s, nowNs: nowNs)
        if s.powerW == nil, let railW, let pclusterW {
            estimatePower(&s, raw: railW - pclusterW, linkSamples: linkSamples)
        }
        if let p = s.powerW { observedMaxPowerW = max(observedMaxPowerW, p) }
        return s
    }

    /// ANE power from a shared SMC rail: rail minus P-cluster power, minus
    /// what that difference reads while the ANE is idle. The ANE counts as
    /// idle when its memory links are off or only trickling (links stay on
    /// at the lowest bin for a few seconds after work stops) with no
    /// interrupt traffic; without link histograms, when the trace saw no
    /// tasks. The baseline is the median of the last eight idle readings,
    /// set once there are three, so a CPU burst caught by only one of the two
    /// sources (common in the first interval, while other tools start) does
    /// not become the baseline. Readings from the first 2 s of an idle spell
    /// are left out: the rail lags the ANE by about a second, and short gaps
    /// between tasks otherwise pulled the baseline up by about 1 W.
    ///
    /// The SMC updates the rail about once a second, out of phase with our
    /// IOReport window, so a short CPU burst can land in the cluster reading
    /// one interval before it reaches the rail. The median of the last three
    /// estimates drops those single-interval dips.
    private func estimatePower(_ s: inout Snapshot, raw: Double, linkSamples: UInt64?) {
        let idle: Bool
        if let n = linkSamples {
            idle = n == 0 || ((s.dramReadGBs ?? 0) < 1 && (s.interruptsPerS ?? 0) < 50)
        } else if s.busyStatus == .measured || s.busyStatus == .idle {
            idle = s.busyPct.reduce(0, +) < 0.5
        } else if let irq = s.interruptsPerS {
            // No busy % (not root): the ANE is idle when it raises no
            // interrupts and reads almost nothing from DRAM (h16g, AMC counters).
            idle = irq < 50 && (s.dramReadGBs ?? 0) < 1
        } else {
            idle = false
        }
        idleForS = idle ? idleForS + intervalS : 0
        if idle {
            if idleForS > 2 {
                idleRawW.append(raw)
                if idleRawW.count > 8 { idleRawW.removeFirst() }
            }
            if idleRawW.count >= 3 { railOffsetW = idleRawW.sorted()[idleRawW.count / 2] }
            recentPowerW.removeAll()
            s.powerW = 0
        } else if let off = railOffsetW {
            recentPowerW.append(max(0, raw - off))
            if recentPowerW.count > 3 { recentPowerW.removeFirst() }
            let v = recentPowerW.sorted()
            s.powerW = v.count == 2 ? (v[0] + v[1]) / 2 : v[v.count / 2]
        }
        if s.powerW != nil { s.powerSource = "smc_estimate" }
    }

    /// ANE throttle triggers, in the order of anemon_ior_values.throttle_ticks.
    static let throttleNames = ["SW", "HW", "ADCLK", "DITHER", "PPT", "EXT0", "EXT1", "EXT2", "EXT3"]

    /// IOP state per engine, ANE throttling and the DRAM level, from IOReport.
    private func readStates(_ s: inout Snapshot, _ c: anemon_ior_values) {
        if c.found & Int32(ANEMON_IOR_IOP) != 0 {
            var t = c.iop_ticks
            let a: [UInt64] = withUnsafeBytes(of: &t) { Array($0.bindMemory(to: UInt64.self)) }
            let k = Int(ANEMON_IOP_KINDS)
            var states: [String] = []
            for e in 0..<Int(c.iop_engines) {
                let off = a[e * k + Int(ANEMON_IOP_OFF)]
                let run = a[e * k + Int(ANEMON_IOP_RUNNING)]
                let other = a[e * k + Int(ANEMON_IOP_OTHER)]
                states.append(run >= off && run >= other ? "running" : off >= other ? "off" : "transition")
            }
            s.aneState = states
        }
        if c.found & Int32(ANEMON_IOR_THROTTLE) != 0, c.throttle_span_ticks > 0 {
            var t = c.throttle_ticks
            let ticks = withUnsafeBytes(of: &t) { Array($0.bindMemory(to: UInt64.self)) }
            let maxTicks = ticks.max() ?? 0
            s.throttlePct = 100 * Double(maxTicks) / Double(c.throttle_span_ticks)
            s.throttleKinds = ticks.indices.filter { ticks[$0] > 0 && $0 < Self.throttleNames.count }.map { Self.throttleNames[$0] }
        }
        if c.found & Int32(ANEMON_IOR_DCS_LEVELS) != 0 {
            var t = c.dcs_level_ticks
            let ticks = withUnsafeBytes(of: &t) { Array($0.bindMemory(to: UInt64.self)) }
            let total = ticks.reduce(0, +)
            if total > 0, let top = ticks.indices.max(by: { ticks[$0] < ticks[$1] }) {
                s.dramLevel = "F\(top)"
                s.dramLevelPct = 100 * Double(ticks[top]) / Double(total)
                s.dramPeakGBs = chipModel?.dramLevels[top]?.peakGBs
            }
        }
    }

    /// Time since the ANE last worked, the power-off countdown, and the
    /// host CPU's power above its own idle level.
    private func trackActivity(_ s: inout Snapshot, nowNs: Double) {
        let active = s.busyPct.reduce(0, +) > 0.5 || (s.interruptsPerS ?? 0) > 20
        if active { lastActiveNs = nowNs }
        if let last = lastActiveNs {
            let idle = max(0, (nowNs - last) / 1e9)
            s.aneIdleS = idle
            let running = s.aneState.isEmpty || s.aneState.contains("running")
            if let off = chipModel?.powerOffS, !active, running, idle < off { s.anePowerOffInS = off - idle }
        }
        if let h = s.hostCPUW {
            if !active && (s.aneIdleS ?? 99) > 2 {
                idleHostW.append(h)
                if idleHostW.count > 8 { idleHostW.removeFirst() }
            }
            if idleHostW.count >= 3 { s.hostCPUExtraW = max(0, h - idleHostW.sorted()[idleHostW.count / 2]) }
        }
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
        rail?.stop()
        memoryRails.forEach { $0.stop() }
    }
}

extension Monitor {
    /// One snapshot as JSON fields (`anemon --json`). debug adds the raw
    /// inputs of the power estimate and trace timing.
    func fields(_ s: Snapshot, debug: Bool) -> [String: Any] {
        var d: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: s.time),
            "interval_s": s.intervalS,
        ]
        d["validated"] = isValidated
        d["calibrated"] = profile != nil
        if trace != nil {
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
            d["trace_error"] = traceError ?? NSNull()
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
        return d
    }
}
