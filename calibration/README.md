# How anemon measures, and how it was checked

This document covers where each of anemon's figures comes from, how they were
validated on each chip, and the research data and scripts in this folder. For
installing and using anemon, see the [top-level README](../README.md).

- [Chips tested](#chips-tested)
- [How each metric is read](#how-each-metric-is-read)
- [Calibration and diagnose](#calibration-and-diagnose)
- [Validation](#validation)
- [Reading the numbers](#reading-the-numbers)
- [JSON fields](#json-fields)
- [Research data](#research-data)
- [Reproducing](#reproducing)

## Chips tested

| | M4 | M5 | M6 |
|---|---|---|---|
| ANE architecture | h16g, 16 cores | h17, 16 cores | h18g, 2 engines × 16 cores |
| macOS | 27.0.1 | 27.0.0 | 27.0.1 |
| busy % | firmware task events | driver events | firmware task events, per engine |
| DRAM | AMC byte counters (exact) | link histogram, clips at 32 GB/s | 4 link histograms, clip at full speed |
| Power | PP0b rail − P cluster | PP0b rail − Super cluster | PP0b rail − Super/Performance cluster |
| Memory power | – | PP2b + PP4b | PP2b + PP4b |
| Throttle triggers | `ANE_ADCLK_TRIG`, … | `ANE_THROTTLE_*_TRIG` | `ANE_THROTTLE_*_TRIG` |

All of these are private macOS interfaces; any of them can change with a
macOS release.

## How each metric is read

| Metric | Source | Root |
|---|---|---|
| busy %, tasks, programs | kdebug events from the ANE firmware or driver | yes |
| Power | SMC key `PP0b` minus IOReport CPU cluster power; on other chips `powermetrics` | rail: no |
| Host CPU | IOReport `PMP / Energy` cluster histograms | no |
| Memory power | SMC keys `PP2b` + `PP4b` | no |
| DRAM traffic | IOReport `AMC Stats` byte counters or `PMP / DCS BW` histograms | no |
| Interrupts | IOReport `Interrupt Statistics` | no |
| State | IOReport `ANE` / `ANE1` `IOP State` | no |
| Throttling, memory clock | IOReport `SoC Stats / Events` | no |

### Busy time

The ANE firmware logs two kdebug events per task (class 0x06, subclass 0x1b,
code 0x49): `0x061b0125` at the start and `0x061b0126` at the end. Both carry
the program handle in arg1 and a per-program transaction id in arg3, which
counts up and restarts near zero in each new process.

**Lost events.** The kernel drops coprocessor events stamped earlier than its
oldest valid time and leaves a `0x07020018` record instead (`bsd/kern/kdebug.c`
in xnu). That time moves up to the newest record of every read, and firmware
events reach the kernel a fraction of a millisecond after the driver's events
for the same task. Tracing the whole ANE subclass (about 90,000 driver events
per second on M6) therefore lost about 10% of the firmware events. anemon
traces only the event ids it uses (`KDBG_VALCHECK`, at most four), which
brought the loss on M6 down to about 0.1%. `ANEMON_KD_ALL=1` traces the whole
subclass for research.

**Incomplete tasks.** Some tasks still arrive without both events, and the
firmware omits the start of many very short tasks. anemon charges each one
the median duration of the program's recent complete tasks: from the start
(start only), before the end (end only), or into the engine's idle time
before the next task (a gap in transaction ids). Busy time is the union of
these intervals per engine, so overlaps are not counted twice. A task that
has started but not ended counts as busy until the end of the interval. The
window runs 250 ms behind real time because events arrive late.

**Driver events.** Without firmware events anemon uses the driver's
submit/complete event `0x061b00a0` (arg1 = 0 submit, 1 complete; handle in
arg2, transaction id in arg4). A span from submit to completion includes time
the request waited in the driver, but one engine runs one task at a time, so
the union of the spans is still the time the ANE had work. On M6, which logs
both (`ANEMON_FORCE_HOST=1` ignores the firmware events):

| Workload | Firmware events | Driver events |
|---|---:|---:|
| 10 ms evaluations, continuous | 96.7% | 97.6% |
| 10 ms evaluations, 50% duty | 47.1% | 47.7% |
| 3.9 ms evaluations, continuous | 92.9% | 94.2% |
| 0.24 ms evaluations, continuous | 45.6% | 45.4% |
| µs evaluations, 50% duty | 0.1% | 0.0% |
| two processes, 3.9 ms each | 99.9% | 100.0% |

Busy % agrees within about 1.5 points. Task counts do not: the M6 driver logs
one request per engine, so tasks/s doubles, and driver events cannot split
busy time between engines. `ane_busy_source` is then `host`. M5 produces only
driver events.

**After sleep.** On M4 (macOS 27.0.1) the driver still passes every firmware
event to `kernel_debug_enter`, but stamped in the past by exactly the time the
Mac has slept since boot (`mach_continuous_time() − mach_absolute_time()`),
so the kernel drops all of them, for `ktrace` too. anemon falls back to
driver events until the next reboot, says so on screen, and reports
`slept_since_boot_s`. On a benchmark machine, reboot and disable sleep.

### Processes

Neither kind of task event names the process: the driver emits them from its
own work loop. Event `0x061b0071` is logged on the calling thread whenever a
process submits a request, with the program handle in arg1. The first time
anemon sees a handle, it maps that thread to its process by listing every
process's threads (`proc_pidinfo`). No event carries a model name.

`KERN_KDREADTR` returns at most about 3,900 records per call, so anemon drains
the buffer in a loop. Tracing runs in ring-buffer mode and is re-enabled if
the kernel stops it.

### DRAM traffic

**AMC byte counters (M4).** `AMC Stats / Perf Counters / ANE DCS RD` and
`ANE DCS WR` count bytes at the DRAM controllers. They work without root and
with SIP on, and match the weight traffic of a streaming GEMV (65.5 against
64.6 GB/s). M5 and M6 list the same counters (M6: `ANE0/ANE1 DCS RD/WR`), but
the kernel refuses the subscription or returns nothing, even for root.

**Link histograms (M5, M6, and the M4 fallback).** `PMP / DCS BW` has a
histogram per ANE memory link and direction (`ANE0 RD`; on M6 `ANE0 L0 RD` …
`ANE1 L1 WR`, four links) in 1 GB/s bins up to 32 GB/s. A link is sampled at
a fixed rate while it is on (24 MHz / 5400 ≈ 4444/s on M6, about 4408/s on
M4, 4745–4786/s on M5), so

    GB/s = Σ (bin midpoint × samples) / samples per second / seconds

summed over links. The top bin is open-ended: a link above 32 GB/s counts as
32. `dram_clipped_pct` is the share of read samples in that bin; above 10% the
reading is shown as a lower bound. One M4 or M5 link carries all of the
ANE's traffic, so a streaming load reads about half of the real figure there
(M5: 29.5 against 71.3 GB/s). M6 spreads traffic over four links and clips
only near full speed (115 against 133.5 GB/s). `ANEMON_NO_AMC=1` forces the
histograms on M4.

M5 also has `PMP / SOC-NI Util BW / SOC-NI3 ANE UP`, which reaches 64 GB/s
(62 GB/s under the same GEMV), but it counts all of the ANE's fabric traffic,
cache hits included (22 GB/s against 9 GB/s of DRAM reads under a
compute-bound load). anemon does not use it yet.

### Power

`powermetrics` reports ANE power as a model estimate (and on M6 not at all);
IOReport `Energy Model / ANE` reads 0 on M4. The SMC key `PP0b` is a measured
rail that feeds the ANE and the CPU cluster IOReport calls `PACC`:

| Chip | On `PP0b` with the ANE | Not on it |
|---|---|---|
| M4 | 4 Performance cores | 6 Efficiency cores |
| M5 | 4 Super cores | 6 Efficiency cores |
| M6 | 2 Super cores (`PCPU0–1`), 4 Performance cores (`MCPU2–5`) | 6 Efficiency cores |

IOReport `PMP / Energy` gives the cluster's power (`PACC0` + `PACC0 SRAM`) in
1 W bins, and anemon reports

    ANE power = PP0b − cluster power − baseline

The baseline is what the difference reads while the ANE is idle:

| Load (no ANE work) | M4 | M5 | M6 |
|---|---:|---:|---:|
| idle | −1.25 W | −0.8 W | −1.1 W |
| one spinning thread | −1.5 W | | −1.1 W |
| four threads | −2.7 W | −3.1 W | −2.2 W |
| six threads | | | −2.0 W |

It holds within about 0.3 W while only the calling thread runs and shifts by
1–2 W when other threads load the same cores; the screen notes when the host
cluster draws more than the ANE.

anemon learns the baseline as it runs: the median of the last eight idle
readings, once there are three, so a CPU burst caught by only one of the two
sources does not become the baseline. Power stays empty until the ANE has
been idle for about five seconds. Readings from the first 2 s of an idle
spell are skipped, because the rail lags the ANE by about a second. The ANE
counts as idle when its links are off or read under 1 GB/s with under 50
interrupts/s, or when busy % is below 0.5%. The SMC updates `PP0b` about once
a second, out of step with anemon's interval, so each value is the median of
the last three intervals.

**Memory power.** On M5 and M6, `PP2b` and `PP4b` rise with DRAM traffic
(M6: +2.1 W at 97 GB/s; M5: +3 W at 71 GB/s) and stay flat under
compute-bound loads. They cover every client of memory, not only the ANE.

### State, throttling and memory clock

- **State:** the `IOP State` residency of each engine's firmware processor:
  off, running, or in transition. On M6 the driver powers an engine off
  5.68 s after its last request, and the first request after that pays a
  firmware boot of about 50 ms.
- **Throttling:** `SoC Stats / Events` has a residency channel per ANE
  throttle trigger. M5 and M6 name them `ANE_THROTTLE_<ADCLK|DITHER|PPT>_TRIG`
  and `ANE_THROTTLE_EXT_TRIG0–3`; M4 uses `ANE_ADCLK_TRIG`, `ANE_DITHR_TRIG`,
  `ANE_PPT_TRIG` and `ANE_EXT_TRIG0–3`. The per-source sub-triggers (`…_SW_`,
  `…_HW_`) are covered by their parent and not read.
- **Memory clock:** `SoC Stats / Events / DCS_F<n>` residency gives the
  dominant DRAM frequency level. On M6 the top level F9 is 10656 MT/s,
  170.5 GB/s peak; the speeds of the other levels are not known.

## Calibration and diagnose

`sudo anemon calibrate` (about 2.5 minutes) runs `anebench` workloads with
random inputs and saves the results to
`/Library/Application Support/anemon/<architecture>.json`:

1. **Idle:** 8 s, long enough to learn the power baseline.
2. **Peak compute:** INT8 5×5 conv, 1024 channels, 128×128, 4 layers.
3. **Peak power:** INT8 3×3 conv, 512 channels, 32×32, 8 layers. The
   highest-compute load is not the highest-power one (M6: 8.9–13.3 W against
   16.2 W), so calibration keeps the larger of the two.
4. **Read bandwidth:** FP16 GEMV, 2560 × 65536. Without byte counters the
   result is the weight bytes per second.
5. **busy % check:** a 3×3 conv stack lengthened to at least 20 ms per
   evaluation, at 100% and 50% duty. It passes when anemon is within 5
   points of the host's share of wall time. Shorter tasks inflate the host
   figure with the 0.2–0.6 ms of submit/complete overhead per call.

Peak power and read bandwidth set the full scale of the power and DRAM bars.
Built-in values are used on machines without their own calibration:

| | Peak power | Read bandwidth |
|---|---:|---:|
| M4 | 12.8 W | 65.3 GB/s |
| M5 | – | 69.0 GB/s |
| M6 | 16.2 W | 123.8 GB/s |

All three come from `anemon calibrate` runs on 2026-10-03.

`sudo anemon diagnose` (about 2 minutes) is for chips anemon does not know.
It records every IOReport channel name and every SMC float key starting with
`P`, then runs idle, CPU-only, sustained peak compute (30 s), peak power,
bandwidth, 100% and 50% duty, a small model called back to back, and idle
until power-off. For each phase it saves the delta of every IOReport channel
that moved, the mean and maximum of each SMC key, anemon's per-second
readings and the workload's ms/eval, TOPS and host-busy share. The result,
`anemon-diagnose-<architecture>.json`, holds no user or host names. The M5
support was built from one such file.

## Validation

### M4

busy % against the share of wall time the host spent in ANE calls:

| Workload | Host | anemon |
|---|---:|---:|
| idle | 0% | 0.0% |
| 10 ms tasks, continuous | 100% | 98.3–98.8% |
| 10 ms tasks, 50% duty | 51.4% | 50.9% |
| 10 ms tasks, 25% duty | 26.7% | 26.8% |
| 42 ms tasks, continuous | 100% | 99.5% |
| 5–8 ms tasks, 50% duty | 53.8% | 51.1% |
| 18.5 ms tasks, continuous / 50% duty (calibration) | 100 / 50.6% | 98.2 / 50.5% |
| 10.7 ms tasks, 50% duty, after sleep (driver events) | 50.8% | 51.1% |

- Two processes sharing the ANE: 100% busy, no events lost, each program
  attributed to its process.
- Peak INT8 throughput 35–38 TOPS across runs (theoretical 38.4).
- Power, PP0b rail: 12.8 W on the INT8 3×3 stack, 11.3 W at 38 TOPS on the
  5×5 stack (`powermetrics` 12.9–13.1 W), about 9.5 W on an FP16 3×3 chain
  (`powermetrics` 9.6 W).
- DRAM: 64.6–66 GB/s, the weight traffic of the GEMV.
- A MacBook Air M4 with SIP on gave the same results.

### M5

From `anemon diagnose` and `anemon calibrate` on macOS 27.0.0:

| Workload | Host | anemon |
|---|---:|---:|
| 20.2 ms tasks, continuous / 50% duty (calibration) | 100 / 52.8% | 98.8 / 51.7% |
| 26 ms tasks, continuous / 50% duty (diagnose) | 100 / 52.2% | 99 / 50–54% |

- INT8 throughput: 30.0–30.9 TOPS on the 5×5 stack, 38.2 TOPS on the 3×3
  stack (M4: 37.7 and 31.7). The 5×5 load runs steadily slower from the first
  second with no throttling and lower power, so the compiler likely splits
  5×5 kernels differently on this chip.
- Read bandwidth 69.0–71.3 GB/s, from weight bytes per second.
- Power, PP0b estimate: about 6.2 W on both peak loads (`powermetrics`
  7.1–8.7 W). Peak power has not yet been calibrated from the rail.
- Throttle triggers were active under 0.5% of the time at full load, and
  10–15% (ADCLK, DITHER) at 50% duty, while the clock steps up and down.
- An earlier calibration ran at half speed and read 64% busy at 100% duty;
  later runs with the same loads did not reproduce it.

### M6

| Workload | Host | anemon |
|---|---:|---:|
| 10.3 ms tasks, continuous | 100% | 96.5% |
| 10.3 ms tasks, 50% duty | 48.8% | 48.3% |
| 19.4 ms tasks, continuous / 50% duty (calibration) | 100 / 50.9% | 96.6 / 48.3% |
| two processes, 3.9 ms tasks | 100% | 99.9–100% |

- Peak INT8 throughput: 68–73 TOPS on the 5×5 stack. The 3×3 stack (512
  channels, 8 layers) reaches 85–91 TOPS at 128×128 but only 59.1 TOPS at the
  calibration's 32×32, where each evaluation takes 0.65 ms and the per-call
  host overhead dominates. FP16 50 TOPS at 128×128.
- Power, PP0b estimate: 16.2–17 W on the INT8 3×3 stack, 8.9–13.3 W on the
  5×5 stack, with brief ADCLK and DITHER throttling. Readings return to 0
  within two seconds of the load stopping.
- DRAM against the weight traffic of an FP16 GEMV:

| Duty | Weight traffic | anemon |
|---:|---:|---:|
| 100% | 133.5 GB/s | 115 GB/s (lower bound) |
| 50% | 59.8 GB/s | 50–55 GB/s |
| 25% | 28.1 GB/s | 25 GB/s |

- A 4B language model generating text through Core ML read 85% busy,
  74 GB/s and 2.4 W of ANE power while the whole machine drew 12.3 W. There is
  no independent ANE reading to check a real model against.

## Reading the numbers

- **busy % is occupancy, not speed.** macOS (CLPC) sets the ANE clock from
  its utilization and aims for about 77% busy. When the caller leaves gaps,
  the clock drops (on M6 from 2.58 GHz to 852 MHz, about 2.8× slower per
  task). Rising ms/task at the same busy % is the sign of a lower clock.
- **Host overhead.** Each synchronous call costs the host 0.2 ms (M4) to
  0.6 ms (M6, two engines) during which the ANE is idle, so one process
  calling a model back to back rarely shows 100%.
- **Inputs matter for power.** All-zero inputs draw far less power than real
  data (M4: 4.1 W against 12.9 W on the same INT8 load; M6: 5.1 W against
  8.9–13.3 W) and run 10–20% faster on M6. anebench fills inputs with random
  values (`ANERUN_FILL=zero` restores zeros); calibrations before 2026-10-03
  used zeros.
- **M6's two engines.** Core ML runs a model compiled for two engines on both
  in lockstep; a single-engine model runs on ANE0, and one compiled program
  runs serially within a process. Different models or processes can use both
  engines (about 1.8× the throughput). A program's share is its busy time
  over the capacity of both engines.
- **Power has a large fixed floor**, so power alone does not indicate
  utilization (see [M4 power](#m4-power-zero-inputs)).

## JSON fields

`anemon --json` prints one object per interval. Fields beyond the on-screen
metrics:

| Field | Values |
|---|---|
| `ane_busy_source` | `firmware`, `host` (driver events, includes queueing) or `none` |
| `ane_busy_status` | `measured`, `idle`, `unverified`, or `unsupported` (ANE active but no task events; `ane_busy_pct` is then null) |
| `programs` | Up to 16: `handle`, `pid`, `process`, `tasks`, `busy_ms`, `energy_mj_per_task` |
| `ane_power_source` | `smc_estimate` or `powermetrics` |
| `dram_source` | `amc` or `histogram` |
| `dram_clipped_pct` | Share of read samples in the top histogram bin; above 10% the reading is a lower bound |
| `host_cpu_power_w`, `host_cpu_extra_w` | CPU cluster power, and its excess over idle |
| `memory_power_w` | Memory rail power (M5, M6) |
| `ane_state` | Per engine: `running`, `off` or `transition` |
| `ane_idle_s`, `ane_power_off_in_s` | Seconds since the last ANE activity; seconds until power-off (M6) |
| `ane_throttle_pct`, `ane_throttle_kinds` | Throttled share of the interval, and the active triggers |
| `dram_level`, `dram_level_pct`, `dram_peak_gbs` | Dominant memory clock level, its share, and its peak bandwidth where known |
| `slept_since_boot_s` | Time the Mac has slept since boot |
| `validated` | The busy check has passed for this chip and macOS major version |
| `calibrated` | This machine has its own calibration |

`ANEMON_DEBUG=1` adds the raw rail and cluster readings and trace timing.

## Research data

Measured on the M4 Mac mini (macOS 27, build 26A428) while developing
anemon. The files are in [`data/`](data).

### Task events (`data/trace/`)

| Load | Firmware start → end | Host `Eval` time |
|---|---:|---:|
| W8A8 3×3 conv, 1024 ch, 128² | 9.909 ms | 10.056 ms |
| FP16 3×3 conv, 1024 ch, 128² | 42.22 ms | 42.42 ms |
| 64×64 1×1 conv, spatial 1 | ~1.3 µs | – |

For tiny tasks only about a third get a start event.
`scripts/trace_pairs.py` reproduces these numbers.

### PMU counters (`data/pmu_first_round.csv`, `data/pmu_sweep.csv`)

Register names from
[ane_pmu_profiler](https://github.com/freedomtan/ane_pmu_profiler). The PMU
reports only to the process that submitted the work, so anemon cannot use it.

- `NE_NOMINAL_CYCLES` advances about 37.5×10⁹ times per second of ANE time
  and works as a time base.
- `NE_COMPUTE_CYCLES` is not a utilization counter: MACs per compute cycle
  range from 2 to 50,000 across shapes, and it is highest for the least
  efficient work.
- `INT8_CYCLES` and `FP16_CYCLES` read 0; the stall and DMA counters do not
  track the obvious bottlenecks.
- Compute efficiency = MACs ÷ `NE_NOMINAL_CYCLES` ÷ peak, where peak is 512
  MACs per cycle with INT8 activations and weights and 256 otherwise:
  512 × 37.5×10⁹ × 2 = 38.4 TOPS, Apple's rated figure.

### Numeric formats (`data/format_sweep.csv`, `data/format_report.txt`)

| Format | On the ANE | Effect |
|---|---|---|
| FP16 | native | about 14.6 TOPS on 3×3 conv |
| INT8 activations × INT8 or INT4 weights | native, 2× peak | 24–26 TOPS on 3×3 conv |
| UINT8 activations | same path as INT8 | same |
| INT8/UINT8/INT4/UINT4 weights per channel, 1–8-bit palettes | decompressed to FP16 | weight-bound layers go from 38% to 82–88%; compute-bound layers barely change |
| INT8 activations with FP16 or palettized weights | no INT8 path | same as FP16 |
| 50% / 75% sparse weights | decompressed, no skipping | 1×1 conv slows from 73% to 42% |
| sub-channel block quantization | compile fails | – |
| FP32 compute, BF16, FP8 | compile fails | – |
| FP32 I/O | cast in-graph | about 46% slower on 1×1 conv |

### Peak throughput (`data/peak.txt`)

- 38.2 TOPS (99.6% of 38.4) with eight chained 5×5 W8A8 convs, 1024 ch,
  128², "same" padding; about 37.5 TOPS counting only non-padding MACs.
- A single "valid" layer: 36.1 TOPS.
- Throughput halves to about 19 TOPS once a layer's INT8 weights pass
  roughly 30–60 MB.

### M4 power, zero inputs (`data/power_report.txt`)

`powermetrics` estimates with all-zero inputs, so lower than with real data:

| Load | Throughput | ANE power |
|---|---:|---:|
| idle | – | 0 W |
| tiny tasks, ~7k/s | ≈0 | 0.66 W |
| FP16 depthwise 3×3 | 0.34 TOPS | 1.72 W |
| FP16 3×3, weight-bound | 7.4 TOPS | 2.11 W |
| FP16 3×3, 512 ch | 16.2 TOPS | 2.57 W |
| INT8 weights, FP16 compute | 17.2 TOPS | 2.58 W |
| W8A8 3×3, 1024 ch | 31.3 TOPS | 3.37 W |

## Reproducing

Requirements: `anebench` (built by `make` at the repository root),
`dump_ane_pmu_objc` from
[ane_pmu_profiler](https://github.com/freedomtan/ane_pmu_profiler) for the
PMU scripts, and Python with `coremltools==9.0` and NumPy for the Core ML
format sweep.

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
| `scripts/rawmil_types.py DIR` | BF16/FP8/FP32 raw-MIL variants | no |
| `scripts/peak.sh C HW K LAYERS PAD` | sustained W8A8 throughput | no |
| `scripts/power.sh` | ANE power per workload | yes |
| `scripts/trace_decode.sh` | captures and pairs ANE task events | yes |
| `scripts/verify_anemon.sh` | busy % against known duty cycles | yes |

Generated models and raw output go to `calibration/.work/`, which is not
committed.

### anebench

- `anebench gen DIR MODE OP CIN COUT H W K [--valid] [--layers N]` writes a
  MIL model of one conv layer, or N chained layers, and prints its MAC count.
  MODE is `fp16`, `w8` (INT8 weights) or `a8w8` (INT8 weights and
  activations); OP is `conv` or `dw`.
- `anebench run DIR [-t SECONDS] [--duty F] [--period MS]` keeps the ANE busy
  with the model, optionally at a duty cycle, and prints the time per
  evaluation and the share of wall time spent inside evaluations.

anebench compiles and runs models through the private `_ANEClient` API,
mapping the I/O surfaces once and calling `doEvaluateDirectWithModel`. On a
tiny model, that path, `evaluateWithModel` through aned, and the in-memory
model path all take 112–119 µs per call.

A MIL weight file starts with a 64-byte header `{u32 count, u32 version = 2}`,
then one 64-byte descriptor per blob `{u32 0xDEADBEEF, u32 dtype, u64 size,
u64 offset}`, then the data; `BLOBFILE` offsets point at the descriptor. The
`mil.BlobWriter` in `github.com/tmc/apple` v0.4.4 writes the header as
`{u64 count, u32 version}`, which the ANE compiler rejects.
