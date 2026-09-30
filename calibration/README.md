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
| Power | `powermetrics -s cpu_power,ane_power`, if the sampler exposes ANE power; on M6 an SMC rail estimate | powermetrics: yes |
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
P-cores) minus the IOReport `PMP / Energy` P-cluster histograms. The top-level
README describes both methods and their check against anebench workloads.

### M6 calibration result (h18g, 32 cores, macOS 27.0.1)

The duty-cycle validation passed within the 5-point tolerance:

| Duty | Host | anemon | Result |
|---|---:|---:|---|
| 100% | 100.0% | 95.3% | pass |
| 50% | 49.4% | 46.8% | pass |

Calibration also reported 76.9 INT8 TOPS. ANE power was `n/a` at idle and
under peak compute. Read bandwidth was 136.8 GB/s, but this used the benchmark
fallback estimate rather than live DRAM counters. Therefore this M6 result
validates busy-time measurement for these workloads, not ANE power or direct
DRAM telemetry. Per-engine busy reporting has not been independently
validated.

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
