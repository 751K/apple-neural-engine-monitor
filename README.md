# Apple Neural Engine Monitor (anemon)

A terminal monitor for the Apple Neural Engine (ANE) on Apple Silicon Macs.
It shows how much of the time the ANE is executing work, which models are
using it, how much memory traffic it generates and how much power it draws.

```
make
sudo .build/make/anemon calibrate   # once per machine, about 2 min
sudo .build/make/anemon             # full-screen view, q to quit
sudo .build/make/anemon --json      # one JSON object per interval
     .build/make/anemon --json      # without root: DRAM, interrupts and, on M6, power
```

Options: `--interval SECONDS` (default 1), `--count N`, `--no-power`.

`make` builds two binaries in `.build/make/`: `anemon`, the monitor, and
`anebench`, a small tool that generates convolution models and runs them on
the ANE. Calibration uses `anebench` for its test workloads.

## What it reports

| Metric | Meaning | Needs root |
|---|---|---|
| busy % | Share of wall time the ANE was executing a task | yes |
| tasks/s, ms/task | Completed ANE tasks and their mean duration | yes |
| programs | Busy time and task rate per compiled model (program handle), with the process that submits it | yes |
| power | ANE power estimate | M4: yes. M6: no |
| DRAM read/write | ANE traffic to memory | no |
| interrupts | ANE interrupt rate | no |

**busy % is time occupancy, not compute utilization.** Like the GPU "active"
figure, it says whether the ANE had work, not how many of its cores or MAC
units were in use. A model can keep the ANE 100% busy while using a few
percent of its arithmetic throughput. Compute efficiency needs the ANE's
per-request PMU counters, which only the process that submits the request
gets back; [`calibration/`](calibration/) shows how to use them.

A metric that is unavailable on a chip is reported as null, never as 0.

## Supported chips

Where each metric comes from depends on the chip. All of these are private or
undocumented macOS interfaces and may change between releases.

| | M4 (h16g) | M6 (h18g), macOS 27.0.1 |
|---|---|---|
| busy %, tasks, programs | kdebug firmware task events, validated; driver events after the Mac has slept (see below) | firmware task events, busy check passed |
| DRAM | IOReport byte counters, exact; histogram fallback, about half the real value at full speed | IOReport per-link bandwidth histograms, a lower bound at full speed |
| power | `powermetrics` | SMC rail minus P-core power, an estimate |

**After the Mac has slept, firmware task events are lost until the next
reboot.** On an M4 with macOS 27.0.1 the ANE driver still passes every task
event to `kernel_debug_enter` (seen with DTrace), but with a timestamp that
lies in the past by exactly the time the Mac has slept since boot
(`mach_continuous_time() − mach_absolute_time()`: 78.6 minutes on the machine
tested). The kernel drops all of them as stale, so no firmware events reach
anemon or `ktrace`. The driver's submit/complete events are unaffected, and
anemon falls back to them (see [Driver events](#driver-events)); the TUI
names the cause and JSON reports `slept_since_boot_s`. The M6 tested had not
slept since boot and received firmware events normally, and after a reboot
the M4 did too (98.7% busy from firmware events on the same workload) until
it sleeps again. To keep firmware events on a benchmark machine, disable
system sleep.

On other chips busy % works if the firmware uses the same event codes; run
`sudo anemon calibrate` to check. DRAM and power need chip-specific
knowledge (`ChipModel` in `Sources/anemon/Monitor.swift`) and stay null
until a chip has been characterized. If busy % shows as unsupported, please
report the output of `calibration/scripts/trace_decode.sh`.

## How it works

### Busy time

The ANE firmware logs two kdebug events per task in class 0x06, subclass
0x1b: code 0x49 with `DBG_FUNC_START` (`0x061b0125`) and `DBG_FUNC_END`
(`0x061b0126`). Both carry the program handle in arg1 and a per-program
transaction id in arg3.

The kernel drops coprocessor events that arrive stamped earlier than its
oldest valid time and leaves a `0x07020018` (past events) record instead
(`bsd/kern/kdebug.c` in xnu). That time rises to the newest record returned by
every read. ANE firmware events reach the kernel a fraction of a millisecond
after the driver's own events for the same task, so when the reader keeps
picking up other ANE driver events, some firmware events arrive already "in
the past". Tracing the whole ANE subclass (about 90,000 driver events per
second on M6) lost about 10% of the firmware events this way. anemon therefore
records only the three event ids it uses (`KDBG_VALCHECK`, at most four ids);
the M6 then lost about 0.1%.

Some tasks still arrive without both events, and the firmware omits the start
of many very short tasks. anemon charges each incomplete task the median
duration of the program's recent complete tasks:

- start only: from the start, for that duration
- end only: that duration before the end
- neither (a gap in the program's transaction ids): into the engine's idle
  time since the program's previous task, latest first

Busy time is the union of these intervals on each engine, so overlapping
estimates are not counted twice. A task that has started but not ended counts
as busy up to the end of the interval, so long inferences do not read as
idle. The window lags real time by 250 ms because events reach the reader late.

When no firmware events arrive, anemon falls back to the driver's
submit/complete events (`0x061b00a0`); see [Driver events](#driver-events).

### Processes

Neither the firmware events nor the driver's submit/complete events identify
the process. The driver emits them from its own work loop thread. Event
`0x061b0071` (the start of code 0x1c) does. The driver logs it on the calling
thread each time a process submits a request, with the program handle in arg1.
The first time anemon sees a handle, it takes the thread id from that record
and finds the owning process by listing every process's threads
(`proc_pidinfo`). Model names are not available, because no event carries
one.

`KERN_KDREADTR` returns at most about 3,900 records per call, so the reader
drains the kernel buffer in a loop. Tracing runs in ring-buffer mode and is
re-enabled if the kernel stops it.

### Driver events

The driver logs `0x061b00a0` when it submits a request (arg1 = 0) and when
the firmware reports it complete (arg1 = 1), with the program handle in arg2
and the transaction id in arg4. A span from submit to completion includes the
time the request waited in the driver, but since one engine runs one task at
a time, the union of the spans is still the time the ANE had work. The M6
logs both kinds of events, so the same workloads were measured each way
(`ANEMON_FORCE_HOST=1` ignores the firmware events):

| Workload | Firmware events | Driver events |
|---|---:|---:|
| 10 ms evaluations, continuous | 96.7% | 97.6% |
| 10 ms evaluations, 50% duty | 47.1% | 47.7% |
| 3.9 ms evaluations, continuous | 92.9% | 94.2% |
| 0.24 ms evaluations, continuous | 45.6% | 45.4% |
| µs evaluations, 50% duty | 0.1% | 0.0% |
| two processes, 3.9 ms each | 99.9% | 100.0% |

Busy % from driver events is within about 1.5 points of the firmware figure.
Task counts are not: the M6 driver logs one request per engine for each
evaluation, so tasks/s is twice the evaluation rate. Driver events also
cannot split busy time between engines, and they mark `ane_busy_source` as
`host`.

### DRAM traffic

**M4:** the IOReport channels `AMC Stats / Perf Counters / ANE DCS RD` and
`ANE DCS WR` count bytes at the DRAM controllers, with or without System
Integrity Protection: a MacBook Air M4 with SIP enabled read 66.0 GB/s, the
same as the weight traffic of the test GEMV. If the subscription ever fails
on an M4, anemon falls back to the
`PMP / DCS BW` histogram of its single ANE link (`ANE0 RD` / `ANE0 WR`),
sampled about 4408 times per second while the link is on. That link's
histogram also stops at 32 GB/s, about half of what the M4 ANE can read, so
under heavy load the fallback reports roughly half the real traffic and flags
it as clipped. With a streaming FP16 GEMV the byte counters read 65.5 GB/s
and the fallback 32 GB/s (98% of samples in the top bin); at 50% duty,
31.7 GB/s against 16 GB/s. `ANEMON_NO_AMC=1` forces the fallback for testing.

**M6:** the same channels exist as `ANE0/ANE1 DCS RD/WR`, but the kernel
refuses to subscribe to them, even for root. SIP does not explain it (the M4
subscribes with SIP enabled), so it looks like a restriction of the newer
chip. anemon reads `PMP / DCS BW` instead. It has a histogram for each of the four ANE memory links (`ANE0 L0`,
`ANE0 L1`, `ANE1 L0`, `ANE1 L1`, read and write) with 1 GB/s bins up to
32 GB/s. A link is sampled 24 MHz / 5400 = 4444 times per second while it is
on. anemon sums bin midpoint × sample count over the links and divides by
that rate and the elapsed time.

The top bin is open-ended, so a link running above 32 GB/s is counted at 32.
`dram_clipped_pct` is the share of read samples in that bin; above 10% the
TUI marks the reading as a lower bound.

### Power

**M4:** the `ANE Power` line of `powermetrics`, which needs root.

**M6:** `powermetrics` reports no ANE power, and IOReport has no ANE energy
channel. The SMC power key `PP0b` is a rail shared by the ANE and the
P-cores: one busy P-core adds about 6 W to it, a full INT8 ANE load about
5.3 W, and the two add up. IOReport's `PMP / Energy` histograms give the
P-cluster's power (`PACC0` plus `PACC0 SRAM`) in 1 W bins. anemon reports

    ANE power = PP0b − P-cluster power − baseline

The baseline is the same difference while the ANE is idle, learned as anemon
runs, so the power field stays null until the ANE has been idle for one
interval. The ANE counts as idle when its links are off, or read less than
1 GB/s with fewer than 50 interrupts/s. The SMC updates `PP0b` about once a
second, out of step with anemon's interval, so a short CPU burst can reach
the two sources one interval apart. Each value is the median of the last
three intervals, which removes those dips.

## JSON output

Each line is one interval. Besides the metrics above:

| Field | Values |
|---|---|
| `ane_busy_source` | `firmware`, `host` (driver events, includes queueing) or `none` |
| `ane_busy_status` | `measured`, `idle`, `unverified` or `unsupported`. `unsupported` means IOReport shows ANE activity but no task events arrive; `ane_busy_pct` is then null |
| `programs` | Up to 16 entries: `handle`, `pid`, `process` (null if the submitting thread was not found), `tasks`, `busy_ms` |
| `ane_power_source` | `powermetrics` or `smc_estimate` |
| `dram_source` | `amc` (byte counters) or `histogram` |
| `dram_clipped_pct` | For histograms, the share of read samples in the open-ended top bin |
| `validated` | The busy check has passed for this chip and macOS major version |
| `calibrated` | A calibration profile exists for this machine |

With `ANEMON_DEBUG=1` the JSON also carries the inputs of the M6 power
estimate, `debug_rail_w` and `debug_pcluster_w`.

## Calibration

`sudo anemon calibrate` runs reference workloads through `anebench` for about
two minutes. Close other ANE and GPU work first. It measures whatever the
machine exposes of:

- idle and maximum ANE power, with a stack of INT8 5×5 convolutions
- peak INT8 throughput
- read bandwidth, with an FP16 GEMV shaped like an LLM output head. Without
  byte counters this comes from weight bytes per evaluation time, because the
  link histograms clip at full speed
- busy % against INT8 convolutions at 100% and 50% duty. The check passes if
  anemon is within 5 percentage points of the share measured on the host.
  The host share also counts about 0.2 ms of submit and completion overhead
  per evaluation, when the ANE is idle, so calibration stacks layers until
  one evaluation takes at least 10 ms and that overhead stays near 2%

The profile is saved to `/Library/Application Support/anemon/<architecture>.json`.
anemon uses it for the full scale of the power and DRAM bars, and treats busy %
as validated if the check passed on the same macOS major version. A
measurement the machine does not expose is left out of the profile.

## Validation

### M4 (h16g)

On macOS 27.0 (build 26A428), with firmware task events, busy % against the share of wall time a workload spent inside synchronous
`Eval` calls on the host:

| Workload | Host | anemon |
|---|---|---|
| idle | 0% | 0.0% |
| 10 ms tasks, continuous | 100% | 98.3–98.8% |
| 10 ms tasks, 50% duty | 51.4% | 50.9% |
| 10 ms tasks, 25% duty | 26.7% | 26.8% |
| 42 ms tasks, continuous | 100% | 99.5% |
| 5–8 ms tasks, 50% duty | 53.8% | 51.1% |
| ~2 µs tasks, 12k evals/s | (host overhead) | 3.2%, 13.5k tasks/s |

For tiny tasks the host is busy submitting while the ANE mostly idles, so the
host share is not a reference. The firmware logs about 14% more tasks than
there are `Eval` calls; a raw `ktrace` capture shows the same ratio with
consecutive transaction ids, so the extra tasks are real work.

Power from `powermetrics`: 0.66 W with tiny tasks, 2.1–2.6 W for FP16
convolutions, 3.4 W for INT8 at 31 TOPS. Peak INT8 throughput: 38.2 TOPS
against a theoretical 38.4.

After the machine had slept (macOS 27.0.1, build 26A434), with driver events only, calibration passed
the busy check with 10.7 ms evaluations: host 100.0% vs anemon 98.9% at full
duty, 50.8% vs 51.1% at 50% duty. It measured 35.4 INT8 TOPS, 3.87 W peak
power and 66.0 GB/s read bandwidth.

After a reboot, with firmware events again (macOS 27.0.1): host 100.0% vs
anemon 99.3% at full duty and 53.9% vs 54.4% at 50% duty, with two stacked
layers (18.6 ms per evaluation); 37.2 INT8 TOPS, 4.06 W peak power,
66.6 GB/s read bandwidth.

Two anebench processes with the exact event filter: 672 starts and 672 ends
for 672 submits in 6.5 seconds, 100% busy, and each program attributed to its
own anebench PID.

A MacBook Air M4 with SIP enabled (macOS 27.0.1, 37 hours asleep since boot)
behaved the same: driver events only, 98.9% busy and 95 tasks/s on a 10.5 ms
convolution, 3.41 W from `powermetrics`, and DRAM from the AMC byte counters
without root.

### M6 (h18g, 32 cores, macOS 27.0.1)

Calibration measured 75.9 INT8 TOPS. The two engines run each evaluation in
lockstep and report the same busy %. Busy check with three stacked layers
(10.3 ms per evaluation): host 100.0% vs anemon 96.5% at full duty, 48.8% vs
48.3% at 50% duty. With a single layer (3.9 ms per evaluation) anemon read
93%, which matches 250 tasks/s × 3.72 ms; the rest of the host's 100% was
the overhead between evaluations.

Two anebench processes sharing the ANE: 99.9% busy with firmware events,
matching the union of the start-to-end spans in a `ktrace` capture (100%).
Before anemon estimated tasks with lost events, this read 82%. The two
programs were attributed to the two anebench PIDs. With the exact event
filter, a 7-second dump held 2,015/2,013 and 2,014/2,013 starts/ends on the two
engines for 4,034 submits, and 8 past-event records. Tracing the whole subclass
gave 1,458/1,315 and 1,397/1,230 in 5.9 seconds, with 604 past-event records.

DRAM against the weight traffic of an FP16 GEMV, which reads its weights once
per evaluation:

| Duty | Weight bytes / time | anemon |
|---:|---:|---:|
| 100% | 133.5 GB/s | 115 GB/s, 80% of samples in the top bin |
| 50% | 59.8 GB/s | 50–55 GB/s |
| 25% | 28.1 GB/s | 25 GB/s |

Power: the INT8 convolution stack read 5.0–5.4 W while `PP0b` rose by 5.3 W,
and the GEMV at 50% duty read 0.8 W. After the load stopped the reading
returned to 0 within two seconds. Neither estimate has been checked against a
real model yet.

## Limitations

- kdebug has a single owner. While anemon runs, Instruments, `ktrace` and
  `fs_usage` cannot trace, and anemon cannot start while one of them is tracing.
- Programs are identified by handle and process, not by model name.
- busy % says when the ANE was running, not how much of its compute was used.
  The driver's performance counters and stats buffers go to the process that
  submitted the request. The driver's debug client (`ANEDriverDebugClient`)
  cannot be opened by an unsigned process, even as root: only the load
  balancer's two regular client types open.
- busy % is reported per engine. On M6 both engines have so far always run
  the same work in lockstep; separate workloads on the two engines have not
  been tested.

## Repository

- `Sources/anemon`: the monitor (Swift).
- `Sources/CANEMon`: kdebug, IOReport and SMC readers (C).
- `Sources/anebench`, `Sources/CANERun`: the workload generator and runner.
- [`calibration/`](calibration/): the measurements, scripts and data behind
  the event decoding, the compute-efficiency method and the power figures.

## License

MIT. See [LICENSE](LICENSE).
