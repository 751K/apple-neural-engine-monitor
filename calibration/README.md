# ANE calibration data and tools

The committed datasets behind the compute-efficiency method and historical
anemon validation were measured on an M4 Mac mini (Mac16,10; ANE architecture
h16g, 16 cores) running macOS 27 (build 26A428). A separate M6 calibration
result is recorded below; its raw captures are not part of these datasets.

## Findings

### Where the numbers come from

| Question | Source | Root |
|---|---|---|
| Is the ANE executing a task, and for how long? | kdebug firmware events `0x061b0125` (start) and `0x061b0126` (end) | yes |
| Per-inference hardware counters | ANE PMU through `aned` (`kANEFPerformanceStatsMask`), only for the process that submits the request | no |
| Power | SMC rail `PP0b` minus the CPU cluster on the same rail (M4, M6); elsewhere `powermetrics -s cpu_power,ane_power`, if it exposes ANE power | rail: no; powermetrics: yes |
| DRAM traffic, interrupts | IOReport `AMC Stats` (M4) or `PMP / DCS BW` histograms (M6), and `Interrupt Statistics` | no |

On the measured M4 / h16g system, the ANE IOReport energy reading stayed at 0
even when sampled as root, while `powermetrics` reported estimates (about
650–680 mW under one tested load). This is an observation for that M4 setup,
not a general macOS 27 rule.

On the M6 / h18g system (macOS 27.0.1, build 26A434), `powermetrics` produced
no separate ANE power field, including during calibration. Its IOReport
`Energy Model` subscription exposed six GPU/PCIe channels and no ANE energy
channel. The full IOReport channel list contains `ANE0` and `ANE1` under
`PMP / Fast-Die CE` and ANE state channels under `SoC Stats`; these are not
watt readings. Calibration's 136.8 GB/s bandwidth result is an estimate from
model bytes per evaluation time because the live M6 DRAM fields remained
null. IOReport lists the M6 counters in `AMC Stats / Perf Counters` as
`ANE0 DCS RD/WR`, `ANE1 DCS RD/WR` and `ANEXL0/1 DCS RD/WR`, but
`IOReportCreateSubscription` returns NULL for that group, even for only the
eight ANE DCS channels and even as root, so no samples can be read. The
`Fast-Die CE` counters were observed empty under the recorded M4 and M6
workloads; channel names being present does not mean they yielded usable
readings.

anemon instead reads M6 ANE traffic from the `PMP / DCS BW` per-link
histograms and estimates ANE power from SMC key `PP0b` (shared with the
CPU cluster `PACC0`, which on M6 holds the Super and Performance cores) minus
the IOReport `PMP / Energy` cluster histograms. The top-level
README describes both methods and their check against anebench workloads.

### M6 calibration result (h18g, 32 cores, macOS 27.0.1)

The latest calibration (2026-10-03, random inputs) passed the busy check:

| Workload | Host | anemon | Result |
|---|---:|---:|---|
| a8w8 3×3 conv ×5, 19.4 ms/eval, 100% duty | 100.0% | 96.6% | pass |
| same, 50% duty | 50.9% | 48.3% | pass |

It reported 71.2 INT8 TOPS, ANE power 0.00 W idle and 16.2 W peak (INT8 3×3
stack; the 5×5 peak-compute load read 8.9 W in this run and 10.1–13.3 W in
two others), and 123.7 GB/s read bandwidth from weight bytes per evaluation
time. These values are built into anemon for M6 machines without their own
calibration. With 10–12 ms busy-check tasks the full-duty reading was
94.9–95.1%, right at the 5-point limit: the host share includes 0.4–0.6 ms of
submit/complete overhead per two-engine call.

The earlier calibration (2026-09-30: 75.9 TOPS, 4.96 W, 132.5 GB/s) fed
all-zero inputs, which the M6 ANE processes faster and at far lower power
than real data. anebench now
fills inputs with random FP16 values by default (`ANERUN_FILL=zero` restores
zeros). The same workloads on the M6, zero against random inputs:

| Workload | Zero inputs | Random inputs |
|---|---:|---:|
| calibration peak (INT8 5×5, 1024 ch, 4 layers) | 80.1 TOPS, 5.1 W | 71–73 TOPS, 8.9–13.3 W |
| INT8 3×3, 512 ch, 8 layers | 106 TOPS | 85–91 TOPS; 16.2–17 W |
| FP16 3×3, 512 ch, 8 layers | 55.5 TOPS | 50.1 TOPS |
| calibration bandwidth (FP16 1×1 GEMV) | 131.8 GB/s, 2.6 W | 132.4 GB/s, 2.7 W |

Power is anemon's SMC rail estimate (median of the steady phase). On the M4, zero and random inputs give the same
throughput (36.5 against 36.7 TOPS, 18.8 against 18.8 TOPS), but not the
same power: `powermetrics` read 4.14 W for eight chained 5×5 INT8 convs (1024
ch, 38.3 TOPS) with zero inputs and 12.93 W with random inputs, and the
whole machine (SMC `PSTR`) rose by 4.1 W and 17.7 W. The M4 power table
below was measured with zero inputs.

Earlier runs used a single layer, which takes only 3.9 ms per evaluation on
the M6. anemon then read 92.9–95.3% against the host's 100%, and one run
failed the 5-point check. Per-engine output showed both engines running each
evaluation in lockstep at 250 tasks/s × 3.72 ms ≈ 93% busy; the remaining
~0.19 ms per evaluation is submit and completion overhead that the host
counts but the ANE spends idle. Calibration now stacks layers until one
evaluation takes at least 10 ms.

### ANE task events (`data/trace/`)

| Load | Firmware start→end | Host `Eval` time |
|---|---|---|
| W8A8 3×3 conv, 1024 ch, 128² | 9.909 ms | 10.056 ms |
| FP16 3×3 conv, 1024 ch, 128² | 42.22 ms | 42.42 ms |
| 64×64 1×1 conv, spatial 1 | ~1.3 µs | – |

- arg1 is the program handle. arg3 is a transaction id that counts up per
  program and restarts near zero in each new process.
- For tiny tasks, only about a third of the tasks get a start event.
- `scripts/trace_pairs.py` reproduces these numbers from the saved traces.

### PMU counters (`data/pmu_first_round.csv`, `data/pmu_sweep.csv`)

The PMU register names come from
[ane_pmu_profiler](https://github.com/freedomtan/ane_pmu_profiler). These
calibrations check which ones hold up:

- **`NE_NOMINAL_CYCLES`** advances at about 37.5×10⁹ per second of ANE time.
  It works as a time base.
- **`NE_COMPUTE_CYCLES` is not a utilization counter.** MACs per compute cycle
  range from 2 to 50,000 across shapes, and the counter is highest for the
  least efficient work (depthwise conv, weight-bound layers).
- `INT8_CYCLES` and `FP16_CYCLES` read 0 in every run. The stall and DMA
  counters do not track the obvious bottlenecks.
- **Compute efficiency = MACs ÷ `NE_NOMINAL_CYCLES` ÷ peak.** Peak is 512 when
  both activations and weights are INT8 (or INT4), and 256 otherwise:
  512 × 37.5×10⁹ × 2 = 38.4 TOPS, Apple's rated figure.

### Numeric formats (`data/format_sweep.csv`, `data/format_report.txt`)

| Format | On the ANE | Effect |
|---|---|---|
| FP16 compute | native | about 14.6 TOPS on 3×3 conv |
| INT8 activations × INT8 or INT4 weights | native, 2× peak | 24–26 TOPS on 3×3 conv |
| UINT8 activations | same path as INT8 | same |
| INT8/UINT8/INT4/UINT4 weights (per channel), 1–8-bit palettes | decompressed to FP16 | weight-bound layers go from 38% to 82–88%; compute-bound layers barely change |
| INT8 activations with FP16 or palettized weights | no INT8 path | same speed as FP16 |
| 50% / 75% sparse weights | decompressed, no skipping | 1×1 conv slows from 73% to 42% |
| sub-channel block quantization (block 32–256) | compile fails | – |
| FP32 compute, BF16 (I/O, weights, compute), FP8 | compile fails | – |
| FP32 I/O | cast in-graph | about 46% slower on 1×1 conv |

### Peak throughput (`data/peak.txt`)

- **38.2 TOPS**, 99.6% of 38.4, with eight chained 5×5 W8A8 convs (1024 ch,
  128², "same" padding).
- Counting only non-padding MACs: about 37.5 TOPS.
- A single "valid" layer: 36.1 TOPS.
- Throughput halves to about 19 TOPS once a layer's INT8 weights pass roughly
  30–60 MB.

### M4 power (`data/power_report.txt`)

| Load | Throughput | ANE power (estimate) |
|---|---|---|
| idle | – | 0 W |
| tiny tasks, ~7k/s | ≈0 | 0.66 W |
| FP16 depthwise 3×3 | 0.34 TOPS | 1.72 W |
| FP16 3×3, weight-bound | 7.4 TOPS | 2.11 W |
| FP16 3×3, 512 ch | 16.2 TOPS | 2.57 W |
| INT8 weights, FP16 compute | 17.2 TOPS | 2.58 W |
| W8A8 3×3, 1024 ch | 31.3 TOPS | 3.37 W |

Power has a large fixed floor, so power alone does not indicate utilization.

### anemon validation (`data/anemon_verify.txt`)

Busy % agrees with duty-cycled workloads to within 3 percentage points, from
idle to 99.5%.

## JSON fields

Each line is one interval. Fields besides the metrics on the screen:

| Field | Values |
|---|---|
| `ane_busy_source` | `firmware` (ANE task events), `host` (driver events, includes queueing) or `none` |
| `ane_busy_status` | `measured`, `idle`, `unverified` or `unsupported` (ANE active but no task events; `ane_busy_pct` is then null) |
| `programs` | Up to 16 entries: `handle`, `pid`, `process`, `tasks`, `busy_ms` |
| `ane_power_source` | `powermetrics` or `smc_estimate` |
| `dram_source` | `amc` (byte counters) or `histogram` |
| `dram_clipped_pct` | Share of samples at the top of the histogram range; above 10% the reading is a lower bound |
| `slept_since_boot_s` | Time the Mac has slept since boot |
| `validated` | The busy check has passed for this chip and macOS major version |
| `calibrated` | A calibration profile exists for this machine |
| `host_cpu_power_w`, `host_cpu_extra_w` | CPU cluster power and its excess over idle |
| `memory_power_w` | Memory rail power (M6) |
| `ane_state` | Per engine: `running`, `off` or `transition` |
| `ane_idle_s`, `ane_power_off_in_s` | Seconds since the last ANE activity; seconds until power-off (M6) |
| `ane_throttle_pct`, `ane_throttle_kinds` | Throttled share of the interval and the active triggers |
| `dram_level`, `dram_level_pct`, `dram_peak_gbs` | Dominant memory clock level, its share, and its peak bandwidth where known |
| `programs[].energy_mj_per_task` | ANE energy per task for that program |

## anemon validation

### M4 (validation)

busy % against the share of wall time spent in the ANE on the host:

| Workload | Host | anemon |
|---|---|---|
| idle | 0% | 0.0% |
| 10 ms tasks, continuous | 100% | 98.3–98.8% |
| 10 ms tasks, 50% duty | 51.4% | 50.9% |
| 10 ms tasks, 25% duty | 26.7% | 26.8% |
| 42 ms tasks, continuous | 100% | 99.5% |
| 5–8 ms tasks, 50% duty | 53.8% | 51.1% |
| 18.6 ms tasks, 50% duty (macOS 27.0.1) | 53.9% | 54.4% |
| 10.7 ms tasks, 50% duty, after sleep | 50.8% | 51.1% |

- Two processes sharing the ANE: 100% busy, no task events lost, each attributed to its own PID.
- Peak INT8 throughput 35–38 TOPS across runs (theoretical 38.4).
- Power with random inputs, PP0b rail (median, `anemon calibrate`): 12.8 W on
  the INT8 3×3 stack, 11.3 W at full INT8 throughput (38 TOPS, 5×5 stack;
  `powermetrics` reads 12.9–13.1 W there). On an
  FP16 3×3 conv chain the rail gives about 9.5 W against 9.6 W from
  `powermetrics`. Measured earlier with all-zero inputs (powermetrics): 0.66 W
  with tiny tasks, 2.1–2.6 W for FP16 convolutions, 3.4–4.1 W for INT8.
- Read bandwidth 64.6–66 GB/s, matching the weight traffic of the test GEMV.
  The 2026-10-03 calibration (12.8 W, 65.3 GB/s, busy check 98.2 / 50.5%)
  is built in for M4 machines without their own calibration.
- A MacBook Air M4 with SIP enabled gave the same results.

### M6 (validation)

| Workload | Host | anemon |
|---|---|---|
| 10.3 ms tasks, continuous | 100% | 96.5% |
| 10.3 ms tasks, 50% duty | 48.8% | 48.3% |
| two processes, 3.9 ms tasks | 100% | 99.9–100% |

- Two processes: task events lost dropped from about 10% to 0.1%, and each program was attributed to its PID.
- Peak throughput with random inputs: INT8 85–91 TOPS, FP16 50 TOPS (eight
  chained 3×3 convs, 512 channels). With all-zero inputs the same models run
  10–20% faster (106 and 55 TOPS); the M4 shows no such difference.
- DRAM against the weight traffic of an FP16 GEMV:

| Duty | Weight traffic | anemon |
|---:|---:|---:|
| 100% | 133.5 GB/s | 115 GB/s (lower bound) |
| 50% | 59.8 GB/s | 50–55 GB/s |
| 25% | 28.1 GB/s | 25 GB/s |

- `anemon calibrate` (2026-10-03, random inputs): peak compute 71–73 TOPS
  INT8; peak power 16.2–16.4 W on the INT8 3×3 stack (the 5×5 peak-compute
  load read 8.9–13.3 W across three runs), with brief ADCLK and DITHER
  throttling; read bandwidth 123.8 GB/s; busy check 96.6 / 48.3% against
  100 / 50.9%. These values are built in for M6 machines without a
  calibration. The 5×5 calibration load with
  all-zero inputs reads about 5 W. Readings return to 0 within two seconds.
  Generating text with a
  4B language model (Core ML, 85% busy, 74 GB/s read) read 2.4 W, while the
  whole machine drew 12.3 W. For a real model there is no independent ANE
  reading to check this against.

## Notes on M6, power and M5

- On M6, Core ML runs a model compiled for two engines on both in lockstep;
  a single-engine model runs on ANE0, and one compiled program is executed
  serially within a process. Different models or processes can occupy both
  engines (about 1.8× the throughput). anemon's per-engine busy % has not
  been checked against separate workloads on the two engines.
- The power estimate subtracts the CPU cluster that shares PP0b. With only
  the cores that call the ANE busy, the error is within about 0.3 W; when
  other threads keep the Performance cores busy too, the baseline shifts by
  up to about 1 W (the screen notes this when the cluster reads above 10 W).
- busy % does not tell how fast the ANE runs. macOS (CLPC) sets the ANE clock
  from its utilization and aims for about 77% busy: when the caller leaves
  gaps between requests it lowers the clock (on M6 down to 852 MHz from
  2.58 GHz, about 2.8× slower per task). Rising ms/task at the same busy % is
  the sign of a lower clock.
- Calibration measures peak power on two loads because the highest-compute
  load is not the highest-power one: the INT8 5×5 stack used for peak
  throughput read 8.9–13.3 W on M6, a stack of smaller INT8 3×3 convolutions
  16.2–16.4 W. The busy check uses tasks of at least 20 ms so that the host's
  submit/complete overhead per call (up to 0.6 ms on M6) stays near 2–3%.
- After the Mac has slept, firmware task events stop until the next reboot and
  anemon falls back to driver events: busy % stays within about 1.5 points,
  but on M6 tasks/s doubles and the two engines can no longer be told apart.
- M5: no firmware task events, no interrupt counts; DRAM comes from link
  histograms that clip at 32 GB/s. One calibration ran the ANE at half speed
  (15 instead of 28 TOPS) and read 64% busy at 100% duty. The likely cause is
  throttling of the fanless machine after the peak load (the driver throttles
  by holding requests, which driver events count as idle); not confirmed.

## How anemon reads each metric

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
submit/complete events (`0x061b00a0`).

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

`powermetrics` reports ANE power as a model estimate from activity
counters, and on M6 not at all. IOReport's `Energy Model / ANE` channel exists
on M4 but reads 0, even under load. The SMC power key `PP0b`, a measured
rail, feeds the ANE and the CPU cluster IOReport calls `PACC`:

| Chip | Cores on `PACC` / `PP0b` | Not on it |
|---|---|---|
| M4 (h16g) | 4 Performance cores | 6 Efficiency cores (`EACC`) |
| M6 (h18g) | 2 Super cores (`PCPU0–1`) and 4 Performance cores (`MCPU2–5`) | 6 Efficiency cores |

IOReport's `PMP / Energy` histograms give that cluster's power (`PACC0` plus
`PACC0 SRAM`) in 1 W bins. anemon reports

    ANE power = PP0b − cluster power − baseline

Measured rail − cluster (W):

| Load | M4 | M6 |
|---|---:|---:|
| idle | −1.25 | −1.1 |
| one spinning thread | −1.5 | −1.1 (on a Super core) |
| two | | −1.4 (both Super cores) |
| four | −2.7 | −2.2 (Super + 2 Performance) |
| six | | −2.0 (Super + 4 Performance) |
| FP16 conv on the ANE | +7.4 (`powermetrics`: 9.6 W ANE) | |
| six threads on the Efficiency cores | | PP0b stays 0 |

So the baseline holds within about 0.3 W while only the calling thread runs,
and shifts by up to about 1 W when other threads keep the Performance cores
busy.

The baseline is the median of the last eight readings of the difference
while the ANE is idle, learned as anemon runs; the power field stays null
until the ANE has been idle for about five seconds. A single reading is not
enough: when anemon starts together with other tools, the first interval can
catch a CPU burst in only one of the two sources, and a baseline taken
from it overstated ANE power by 3.5 W. Readings from the first 2 s of each
idle spell are skipped, because the rail lags the ANE by about a second. The
ANE counts as idle when its links are off or read less than 1 GB/s with
fewer than 50 interrupts/s (M6), when busy % is below 0.5% (root), or, on M4
without root, when it raises fewer than 50 interrupts/s and reads less than
1 GB/s. The SMC updates `PP0b` about once a second, out of step with
anemon's interval, so a short CPU burst can reach the two sources one
interval apart. Each value is the median of the last three intervals, which
removes those dips. `anemon calibrate` reports the median power of its steady
peak phase, since rail readings are noisier than a single maximum should set
the power bar's full scale.

### Firmware events after sleep

On an M4 with macOS 27.0.1 the ANE driver still passes every task
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

## Reproducing

Requirements:

- `anebench`, built by `make` at the repository root. It generates and runs
  the test models.
- `dump_ane_pmu_objc` from
  [ane_pmu_profiler](https://github.com/freedomtan/ane_pmu_profiler), for the
  PMU scripts.
- Python with `coremltools==9.0` and NumPy, for the Core ML format sweep.

```
make                                          # at the repository root
cd calibration
export PROFILER=/path/to/dump_ane_pmu_objc    # PMU scripts only
export PYTHON=/path/to/venv/bin/python        # Core ML scripts only
```

| Script | Measures | Root |
|---|---|---|
| `scripts/pmu_run.sh MODE OP CIN COUT H W K` | one PMU profile as a CSV row | no |
| `scripts/pmu_sweep.sh` → `scripts/pmu_analyze.py` | data type × op × size sweep | no |
| `scripts/format_sweep.sh` | Core ML storage and compute formats | no |
| `scripts/rawmil_types.py DIR` | BF16/FP8/FP32 raw-MIL variants for `--mil` | no |
| `scripts/peak.sh C HW K LAYERS PAD` | sustained W8A8 throughput | no |
| `scripts/power.sh` | ANE power per workload | yes |
| `scripts/trace_decode.sh` | captures and pairs ANE task events | yes |
| `scripts/verify_anemon.sh` | anemon busy % against known duty cycles | yes |

Generated models and raw outputs go to `calibration/.work/`, which is not
committed.

### anebench

- **`anebench gen DIR MODE OP CIN COUT H W K [--valid] [--layers N]`** writes a
  MIL model with one conv layer, or N chained layers, and prints its MAC count.
  MODE is `fp16`, `w8` (INT8 weights) or `a8w8` (INT8 weights and
  activations); OP is `conv` or `dw`.
- **`anebench run DIR [-t SECONDS] [--duty F] [--period MS]`** keeps the ANE
  busy with the model, optionally with a duty cycle. It prints the time per
  evaluation and the share of wall time spent inside evaluations.

anebench compiles and runs models through the private `_ANEClient` API. It
maps the I/O surfaces once and calls `doEvaluateDirectWithModel`, as
`github.com/tmc/apple` does. With a tight loop on a tiny model, the
`evaluateWithModel` path through aned, the direct path and the in-memory model
path all take 112–119 µs per call.

Weight file format. A MIL blob file starts with a 64-byte header
`{u32 count, u32 version = 2}`, then one 64-byte descriptor per blob
`{u32 0xDEADBEEF, u32 dtype, u64 size, u64 offset}`, then the data.
`BLOBFILE` offsets point at the descriptor, not at the data. The
`mil.BlobWriter` in `github.com/tmc/apple` v0.4.4 writes the header as
`{u64 count, u32 version}`, and the ANE compiler rejects that.

The first calibration runs used Go versions of these tools. anebench generates
the same MIL text and the same weight layout, with different random weight
values. Interleaved runs give the same per-evaluation time: 0.119–0.122 ms
against 0.115–0.117 ms for the Go runner on a tiny model, and about 10 ms for
both on large models.
