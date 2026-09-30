import CANEMon
import Foundation

/// ANE firmware task events in kdebug class 0x06 (DBG_IOKIT), subclass 0x1b.
/// Code 0x49 brackets one task on the ANE: DBG_FUNC_START is emitted when the
/// firmware begins executing it and DBG_FUNC_END when it finishes. Both carry
/// the program handle in arg1 and the transaction id in arg3, and are stamped
/// on the ANE's own trace "CPU" (cpuid ≥ the application processor count).
/// Transaction ids count up per program (a new process starts near zero).
///
/// Validated on M4 (h16g), macOS 27: start→end spans match host-measured
/// inference latency (9.91 ms vs 10.06 ms, 42.22 ms vs 42.42 ms). For very
/// short tasks the firmware sometimes omits the start event; those tasks get
/// the median duration of recent paired tasks of the same program. At high
/// task rates (≈10k/s) the firmware reports only a few percent of tasks at
/// all; gaps in a program's transaction ids recover the count of unreported
/// tasks, which are charged that same median duration.
///
/// The driver also logs code 0x28 (debug-id 0x061b00a0) when it submits a
/// request (arg1 = 0) and when the firmware reports it complete (arg1 = 1),
/// with the program handle in arg2 and the transaction id in arg4. Xcode's
/// Neural Engine instrument reads the same event, so it is the fallback on
/// chips whose firmware events differ. Its spans include queueing: on M4 they
/// run a few microseconds longer than the firmware spans.
enum ANEEvent {
    static let classSubclass: UInt16 = 0x061b
    static let taskStart: UInt32 = 0x061b_0125
    static let taskEnd: UInt32 = 0x061b_0126
    static let hostRequest: UInt32 = 0x061b_00a0
}

/// Which events the busy figures come from.
enum BusySource: String {
    case firmware   // ANE firmware start/end (most precise)
    case host       // driver submit/complete (includes queueing)
    case none       // no ANE task event seen yet
}

/// A completed or in-flight task interval in nanoseconds (mach time based).
struct TaskInterval {
    var start: Double
    var end: Double
    var estimated: Bool
    var count = 1           // >1 for a block of unreported tasks
}

private struct ProgramKey: Hashable {
    var cpu: UInt32
    var handle: UInt64
}

private struct TaskKey: Hashable {
    var program: ProgramKey
    var txn: UInt64
}

/// Per-program accounting within one reporting window.
struct ProgramStats {
    var handle: UInt64
    var tasks = 0
    var busyNs = 0.0
}

/// Per-device accounting for one reporting window.
struct DeviceWindow {
    var cpuid: UInt32
    var busyNs = 0.0
    var tasks = 0
    var estimatedTasks = 0
    var taskNsSum = 0.0
}

struct TraceWindow {
    var startNs: Double
    var endNs: Double
    var devices: [DeviceWindow]
    var programs: [ProgramStats]
    var droppedReads: Int
    var eventsRead: Int
    var restarts: Int
    var source: BusySource
    /// Diagnostics: the longest delay from an event's timestamp to its read,
    /// and tasks that ended inside a window that had already been accounted.
    var maxLateNs: Double
    var lateTasks: Int
    var lateBusyNs: Double
}

/// Reads ANE task events from kdebug and turns them into busy time.
final class ANETrace {
    private var buf: [anemon_kd_buf]
    private let lock = NSLock()
    private var thread: Thread?
    private var running = false

    // State guarded by `lock`.
    private var pendingStart: [TaskKey: (ts: Double, handle: UInt64, cpu: UInt32)] = [:]
    private var lastTxn: [ProgramKey: UInt64] = [:]
    private var lastEnd: [UInt32: Double] = [:]
    /// End of each program's last reported task, per ANE.
    private var programEnd: [ProgramKey: Double] = [:]
    private var recentDur: [UInt64: [Double]] = [:]
    private var intervals: [UInt32: [TaskInterval]] = [:]
    private var programOf: [UInt32: [(end: Double, handle: UInt64, dur: Double, count: Int)]] = [:]
    private var readErrors = 0
    private var eventsRead = 0
    private var restarts = 0
    private var maxLateNs = 0.0
    private var lateTasks = 0
    private var lateBusyNs = 0.0
    /// End of the last accounted window; tasks ending before it are late.
    private var accountedTo = 0.0
    private var firmwareDevices: Set<UInt32> = []
    private var hostSeen = false
    /// Host-side requests have no ANE cpu; they are tracked as one device.
    private static let hostDevice: UInt32 = .max
    /// ANEMON_FORCE_HOST=1 ignores firmware events, to validate the fallback;
    /// ANEMON_IGNORE_EVENTS=1 ignores all task events, to simulate a chip
    /// whose events are unknown.
    private let forceHost = ProcessInfo.processInfo.environment["ANEMON_FORCE_HOST"] == "1"
    private let ignoreEvents = ProcessInfo.processInfo.environment["ANEMON_IGNORE_EVENTS"] == "1"
    /// ANEMON_DUMP=FILE writes every record as read, for offline replay.
    private let dump: FileHandle? = ProcessInfo.processInfo.environment["ANEMON_DUMP"].flatMap {
        FileManager.default.createFile(atPath: $0, contents: nil)
        return FileHandle(forWritingAtPath: $0)
    }
    /// Delay between drains of the kdebug buffer.
    private let readPeriodUs: UInt32 = {
        if let v = ProcessInfo.processInfo.environment["ANEMON_READ_MS"], let ms = UInt32(v) { return ms * 1000 }
        return 50_000
    }()

    init(capacity: Int = 1 << 16) {
        buf = [anemon_kd_buf](repeating: anemon_kd_buf(), count: capacity)
    }

    enum StartError: Error, CustomStringConvertible {
        case notRoot, busy(pid: Int32), failed(errno: Int32)
        var description: String {
            switch self {
            case .notRoot: return "kernel tracing needs root (run with sudo)"
            case .busy(let pid):
                return "kernel tracing is in use by another tool" + (pid > 0 ? " (pid \(pid))" : "") +
                    " — quit Instruments/ktrace/fs_usage and retry"
            case .failed(let e): return "kdebug setup failed: \(String(cString: strerror(e)))"
            }
        }
    }

    func start() throws {
        var csc = [ANEEvent.classSubclass]
        var owner: Int32 = -1
        let rc = anemon_kd_start(&csc, Int32(csc.count), 1 << 20, &owner)
        switch Int(rc) {
        case Int(ANEMON_KD_OK): break
        case Int(ANEMON_KD_NOT_ROOT): throw StartError.notRoot
        case Int(ANEMON_KD_BUSY): throw StartError.busy(pid: owner)
        default: throw StartError.failed(errno: errno)
        }
        running = true
        let t = Thread { [weak self] in self?.readLoop() }
        t.name = "anemon.kdebug"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    func stop() {
        running = false
        anemon_kd_stop()
    }

    private func readLoop() {
        while running {
            // KERN_KDREADTR returns at most a few thousand records per call
            // (≈3.9k on M4 / macOS 27) however large the buffer is, so keep
            // reading until the kernel buffer is empty; stopping early lets
            // the ring overwrite the rest.
            while running {
                let n = buf.withUnsafeMutableBufferPointer { anemon_kd_read($0.baseAddress, Int32($0.count)) }
                if n < 0 {
                    lock.lock(); readErrors += 1; lock.unlock()
                    break
                }
                if n == 0 { break }
                let now = anemon_mach_to_ns(anemon_mach_now())
                lock.lock()
                eventsRead += Int(n)
                for i in 0..<Int(n) {
                    maxLateNs = max(maxLateNs, now - anemon_mach_to_ns(buf[i].timestamp))
                    handle(buf[i])
                }
                lock.unlock()
            }
            var nolog: Int32 = 0
            if anemon_kd_status(&nolog, nil, nil) == 0, nolog != 0, running {
                anemon_kd_reenable()
                lock.lock(); restarts += 1; lock.unlock()
            }
            usleep(readPeriodUs)
        }
    }

    private func handle(_ e: anemon_kd_buf) {
        if ignoreEvents { return }
        if let dump {
            let line = String(format: "%llu %08x %u %llx %llx %llx %llx\n", e.timestamp, e.debugid, e.cpuid,
                              e.arg1, e.arg2, e.arg3, e.arg4)
            dump.write(Data(line.utf8))
        }
        switch e.debugid {
        case ANEEvent.taskStart, ANEEvent.taskEnd:
            guard !forceHost else { return }
            firmwareDevices.insert(e.cpuid)
            task(ts: anemon_mach_to_ns(e.timestamp), cpu: e.cpuid, handle: e.arg1, txn: e.arg3,
                 isStart: e.debugid == ANEEvent.taskStart)
        case ANEEvent.hostRequest where e.arg1 <= 1:
            hostSeen = true
            task(ts: anemon_mach_to_ns(e.timestamp), cpu: Self.hostDevice, handle: e.arg2, txn: e.arg4,
                 isStart: e.arg1 == 0)
        default:
            break
        }
    }

    private func task(ts: Double, cpu: UInt32, handle: UInt64, txn: UInt64, isStart: Bool) {
        let program = ProgramKey(cpu: cpu, handle: handle)
        let key = TaskKey(program: program, txn: txn)
        if isStart {
            pendingStart[key] = (ts, handle, cpu)
            return
        }
        // The kernel drops some coprocessor events (a TRACE_PAST_EVENTS
        // record marks each drop; ~5% of ANE events on M6), so a task can
        // lack its start, its end or both. Every case is charged the
        // program's typical duration, and busy time is the union of the
        // intervals when a window is accounted, so overlapping estimates are
        // not counted twice.
        let prevTxn = lastTxn[program]
        var missing = 0
        if let last = prevTxn, txn > last + 1, txn - last < 1_000_000 {
            missing = Int(txn - last - 1)
        }
        if txn > prevTxn ?? 0 { lastTxn[program] = txn }
        // A program's tasks finish in order: earlier starts whose end was
        // lost are over. They ran from their start for about the typical time.
        let typical = typicalDuration(handle)
        for k in pendingStart.keys where k.program == program && k.txn < txn {
            guard let s = pendingStart.removeValue(forKey: k) else { continue }
            let end = min(s.ts + typical, ts)
            append(cpu, TaskInterval(start: s.ts, end: end, estimated: true), handle: handle)
            if let last = prevTxn, k.txn > last, missing > 0 { missing -= 1 }
        }

        var start: Double
        var estimated = false
        if let s = pendingStart.removeValue(forKey: key) {
            start = s.ts
            var d = recentDur[handle, default: []]
            d.append(ts - start)
            if d.count > 64 { d.removeFirst(d.count - 64) }
            recentDur[handle] = d
        } else {
            start = ts - typical
            estimated = true
        }
        if missing > 0 {
            // Tasks with neither event ran while this ANE had no other work,
            // after the program's previous task: fill the idle gaps there,
            // latest first, up to their typical duration.
            fillIdle(cpu, handle: handle, from: programEnd[program] ?? start, to: start,
                     need: Double(missing) * typicalDuration(handle, fallback: ts - start), count: missing)
        }
        lastEnd[cpu] = max(lastEnd[cpu] ?? ts, ts)
        programEnd[program] = ts
        if ts < accountedTo {
            lateTasks += 1
            lateBusyNs += min(ts, accountedTo) - start
        }
        append(cpu, TaskInterval(start: start, end: ts, estimated: estimated), handle: handle)
    }

    private func append(_ cpu: UInt32, _ iv: TaskInterval, handle: UInt64) {
        intervals[cpu, default: []].append(iv)
        programOf[cpu, default: []].append((iv.end, handle, iv.end - iv.start, iv.count))
    }

    private func fillIdle(_ cpu: UInt32, handle: UInt64, from: Double, to: Double, need: Double, count: Int) {
        guard to > from, need > 0 else {
            append(cpu, TaskInterval(start: to, end: to, estimated: true, count: count), handle: handle)
            return
        }
        var busy = (intervals[cpu] ?? []).filter { $0.end > from && $0.start < to }.map { ($0.start, $0.end) }
        busy.sort { $0.0 < $1.0 }
        var gaps: [(Double, Double)] = []
        var cur = from
        for (a, b) in busy {
            if a > cur { gaps.append((cur, a)) }
            cur = max(cur, b)
        }
        if to > cur { gaps.append((cur, to)) }
        var left = need
        var first = true
        for (a, b) in gaps.reversed() where left > 0 {
            let take = min(left, b - a)
            // The task count goes with the first piece only.
            append(cpu, TaskInterval(start: b - take, end: b, estimated: true, count: first ? count : 0), handle: handle)
            first = false
            left -= take
        }
        // No idle time left: still count the tasks.
        if first { append(cpu, TaskInterval(start: to, end: to, estimated: true, count: count), handle: handle) }
    }

    private func typicalDuration(_ handle: UInt64, fallback: Double = 0) -> Double {
        guard let d = recentDur[handle], !d.isEmpty else { return fallback }
        return d.sorted()[d.count / 2]
    }

    /// Accounts busy time in [from, to] (ns, mach time base), including tasks
    /// still running at `to`, and drops history older than `from`.
    func window(from: Double, to: Double) -> TraceWindow {
        lock.lock()
        defer { lock.unlock() }
        var devices: [DeviceWindow] = []
        var programs: [UInt64: ProgramStats] = [:]
        let source: BusySource = !firmwareDevices.isEmpty ? .firmware : hostSeen ? .host : .none
        let cpus = source == .firmware ? firmwareDevices.sorted() : source == .host ? [Self.hostDevice] : []
        for cpu in cpus {
            var w = DeviceWindow(cpuid: cpu)
            var spans: [(Double, Double)] = []
            for iv in intervals[cpu] ?? [] where iv.end >= from && iv.start <= to {
                spans.append((max(iv.start, from), min(iv.end, to)))
                if iv.end <= to {
                    w.tasks += iv.count
                    w.taskNsSum += iv.end - iv.start
                    if iv.estimated { w.estimatedTasks += iv.count }
                }
            }
            // A task that started but has not ended yet is busy until `to`.
            // Starts older than the last end on this ANE are over; starts
            // whose end we never saw are dropped after 10 s.
            for (_, s) in pendingStart where s.cpu == cpu && s.ts < to && to - s.ts < 10e9 {
                let begin = max(s.ts, lastEnd[cpu] ?? 0, from)
                if begin < to { spans.append((begin, to)) }
            }
            // One ANE runs one task at a time: busy time is the union.
            spans.sort { $0.0 < $1.0 }
            var curStart = -Double.infinity, curEnd = -Double.infinity
            for (a, b) in spans {
                if a > curEnd {
                    if curEnd > curStart { w.busyNs += curEnd - curStart }
                    curStart = a; curEnd = b
                } else {
                    curEnd = max(curEnd, b)
                }
            }
            if curEnd > curStart { w.busyNs += curEnd - curStart }
            w.busyNs = min(w.busyNs, to - from)
            for p in programOf[cpu] ?? [] where p.end >= from && p.end <= to {
                programs[p.handle, default: ProgramStats(handle: p.handle)].tasks += p.count
                programs[p.handle]!.busyNs += min(p.dur, p.end - from)
            }
            devices.append(w)
        }
        for cpu in intervals.keys {
            intervals[cpu]?.removeAll { $0.end < from }
            programOf[cpu]?.removeAll { $0.end < from }
        }
        pendingStart = pendingStart.filter { to - $0.value.ts < 10e9 }
        defer { readErrors = 0; eventsRead = 0; restarts = 0; maxLateNs = 0; lateTasks = 0; lateBusyNs = 0 }
        accountedTo = max(accountedTo, to)
        return TraceWindow(startNs: from, endNs: to, devices: devices,
                           programs: programs.values.sorted { $0.busyNs > $1.busyNs },
                           droppedReads: readErrors, eventsRead: eventsRead, restarts: restarts,
                           source: source, maxLateNs: maxLateNs, lateTasks: lateTasks, lateBusyNs: lateBusyNs)
    }
}
