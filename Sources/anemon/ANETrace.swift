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
enum ANEEvent {
    static let classSubclass: UInt16 = 0x061b
    static let taskStart: UInt32 = 0x061b_0125
    static let taskEnd: UInt32 = 0x061b_0126
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
    private var recentDur: [UInt64: [Double]] = [:]
    private var intervals: [UInt32: [TaskInterval]] = [:]
    private var programOf: [UInt32: [(end: Double, handle: UInt64, dur: Double, count: Int)]] = [:]
    private var readErrors = 0
    private var eventsRead = 0
    private var restarts = 0
    private(set) var knownDevices: Set<UInt32> = []
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
                lock.lock()
                eventsRead += Int(n)
                for i in 0..<Int(n) { handle(buf[i]) }
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
        guard e.debugid == ANEEvent.taskStart || e.debugid == ANEEvent.taskEnd else { return }
        let ts = anemon_mach_to_ns(e.timestamp)
        let cpu = e.cpuid
        knownDevices.insert(cpu)
        let program = ProgramKey(cpu: cpu, handle: e.arg1)
        let key = TaskKey(program: program, txn: e.arg3)
        if e.debugid == ANEEvent.taskStart {
            pendingStart[key] = (ts, e.arg1, cpu)
            return
        }
        // Tasks of this program the firmware did not report since the last one.
        var missing = 0
        if let last = lastTxn[program], e.arg3 > last + 1, e.arg3 - last < 1_000_000 {
            missing = Int(e.arg3 - last - 1)
        }
        if e.arg3 > lastTxn[program] ?? 0 { lastTxn[program] = e.arg3 }
        // A program's tasks finish in order: earlier starts whose end was not
        // reported are over, not still running.
        let stale = pendingStart.keys.filter { $0.program == program && $0.txn < e.arg3 }
        for k in stale { pendingStart.removeValue(forKey: k) }

        var start: Double
        var estimated = false
        if let s = pendingStart.removeValue(forKey: key) {
            start = s.ts
            var d = recentDur[e.arg1, default: []]
            d.append(ts - start)
            if d.count > 64 { d.removeFirst(d.count - 64) }
            recentDur[e.arg1] = d
        } else {
            start = ts - typicalDuration(e.arg1)
            estimated = true
        }
        // One ANE executes one task at a time: never overlap the previous task.
        let prevEnd = lastEnd[cpu]
        if let prev = prevEnd, start < prev { start = min(prev, ts) }
        if missing > 0 {
            // Charge unreported tasks their typical duration, but never more
            // than the idle gap they must have run in.
            let room = max(0, start - (prevEnd ?? start))
            let fill = min(Double(missing) * typicalDuration(e.arg1, fallback: ts - start), room)
            intervals[cpu, default: []].append(TaskInterval(start: start - fill, end: start, estimated: true, count: missing))
            programOf[cpu, default: []].append((start, e.arg1, fill, missing))
        }
        lastEnd[cpu] = ts
        intervals[cpu, default: []].append(TaskInterval(start: start, end: ts, estimated: estimated))
        programOf[cpu, default: []].append((ts, e.arg1, ts - start, 1))
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
        for cpu in knownDevices.sorted() {
            var w = DeviceWindow(cpuid: cpu)
            for iv in intervals[cpu] ?? [] where iv.end >= from && iv.start <= to {
                w.busyNs += min(iv.end, to) - max(iv.start, from)
                if iv.end <= to {
                    w.tasks += iv.count
                    w.taskNsSum += iv.end - iv.start
                    if iv.estimated { w.estimatedTasks += iv.count }
                }
            }
            // A task that started but has not ended yet is busy until `to`.
            let busyUntil = w.busyNs
            var inflight = 0.0
            for (_, s) in pendingStart where s.cpu == cpu && s.ts < to {
                let begin = max(s.ts, lastEnd[cpu] ?? 0, from)
                // Starts whose end we never saw are dropped after 10 s.
                if to - s.ts < 10e9 { inflight = max(inflight, to - begin) }
            }
            w.busyNs = min(busyUntil + inflight, to - from)
            for p in programOf[cpu] ?? [] where p.end >= from && p.end <= to {
                programs[p.handle, default: ProgramStats(handle: p.handle)].tasks += p.count
                programs[p.handle]!.busyNs += min(p.dur, p.end - from)
            }
            devices.append(w)
            intervals[cpu]?.removeAll { $0.end < from }
            programOf[cpu]?.removeAll { $0.end < from }
        }
        pendingStart = pendingStart.filter { to - $0.value.ts < 10e9 }
        defer { readErrors = 0; eventsRead = 0; restarts = 0 }
        return TraceWindow(startNs: from, endNs: to, devices: devices,
                           programs: programs.values.sorted { $0.busyNs > $1.busyNs },
                           droppedReads: readErrors, eventsRead: eventsRead, restarts: restarts)
    }
}
