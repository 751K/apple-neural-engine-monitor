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
    var powerSource: String?            // "powermetrics" or "smc_estimate"
    var dramReadGBs: Double?
    var dramWriteGBs: Double?
    var dramSource: String?             // "amc" (byte counters) or "histogram"
    var dramClippedPct: Double?         // histogram samples in the top bin
    var railW: Double?                  // raw inputs of the SMC power estimate
    var pclusterW: Double?
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
    /// SMC power key for the rail that feeds the ANE. On h18g, PP0b also
    /// feeds the P-cores, whose power IOReport reports separately.
    var aneRail: String?

    static let known: [String: ChipModel] = [
        "h16g": ChipModel(histSamplesPerS: 4408, aneRail: nil),
        "h17": ChipModel(histSamplesPerS: 4770, aneRail: nil),
        "h18g": ChipModel(histSamplesPerS: 24e6 / 5400, aneRail: "PP0b"),
    ]
}

/// Collects snapshots at a fixed interval from the available sources.
final class Monitor {
    let device = DeviceInfo.read()
    private(set) var trace: ANETrace?
    private(set) var traceError: String?
    private var power: PowerMetrics?
    private var rail: SMCRail?
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
            power = PowerMetrics(intervalMs: Int(intervalS * 1000))
            rail = chipModel?.aneRail.flatMap { SMCRail(key: $0) }
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
        }
        classify(&s)
        s.railW = railW
        s.pclusterW = pclusterW
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
        } else {
            idle = (s.busyStatus == .measured || s.busyStatus == .idle) && s.busyPct.reduce(0, +) < 0.5
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
    }
}
