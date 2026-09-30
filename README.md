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
| programs | Busy time and task rate per compiled model (program handle) | yes |
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
| busy %, tasks, programs | macOS 27.0: kdebug firmware task events, validated. macOS 27.0.1: driver events only (see below), busy check passed | firmware task events, busy check passed |
| DRAM | IOReport byte counters, exact | IOReport per-link bandwidth histograms, a lower bound at full speed |
| power | `powermetrics` | SMC rail minus P-core power, an estimate |

**The M4 firmware stopped logging task events with macOS 27.0.1.** Since
that update (build 26A434) a 3-second capture of every event in the ANE
subclass under full load contains no `0x061b0125`/`0x061b0126` and nothing
stamped on the ANE's own trace CPU, whatever submits the work (anebench,
Core ML, `powermetrics -s ane_power` beforehand). The driver's
submit/complete events are still there, so anemon reports `ane_busy_source`
`host`: a task's time then includes its wait in the driver queue, and no
per-engine split is possible. The M6 on the same build still logs firmware
events.

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

- A task's interval is its start-to-end span. Many short tasks have no start
  event; they are charged the median duration of the program's recent paired
  tasks.
- Gaps in a program's transaction ids are tasks that were not reported at
  all. They are charged the same median, bounded by the idle time around them.
- A task that has started but not yet ended counts as busy up to the end of
  the interval, so long inferences do not read as idle.
- The window lags real time by 250 ms because events reach the reader late.
- If the firmware events are missing, anemon falls back to the driver's
  submit/complete events (`0x061b00a0`), which include queueing time.

`KERN_KDREADTR` returns at most about 3,900 records per call, so the reader
drains the kernel buffer in a loop. Tracing runs in ring-buffer mode and is
re-enabled if the kernel stops it.

### DRAM traffic

**M4:** the IOReport channels `AMC Stats / Perf Counters / ANE DCS RD` and
`ANE DCS WR` count bytes at the DRAM controllers.

**M6:** the same channels exist as `ANE0/ANE1 DCS RD/WR`, but the kernel
refuses to subscribe to them, even for root. anemon reads `PMP / DCS BW`
instead. It has a histogram for each of the four ANE memory links (`ANE0 L0`,
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

On macOS 27.0.1 (build 26A434), with driver events only, calibration passed
the busy check with 10.7 ms evaluations: host 100.0% vs anemon 98.9% at full
duty, 50.8% vs 51.1% at 50% duty. It measured 35.4 INT8 TOPS, 3.87 W peak
power and 66.0 GB/s read bandwidth.

### M6 (h18g, 32 cores, macOS 27.0.1)

Calibration measured 75.9 INT8 TOPS. The two engines run each evaluation in
lockstep and report the same busy %. Busy check with three stacked layers
(10.3 ms per evaluation): host 100.0% vs anemon 96.5% at full duty, 48.8% vs
48.3% at 50% duty. With a single layer (3.9 ms per evaluation) anemon read
93%, which matches 250 tasks/s × 3.72 ms; the rest of the host's 100% was
the overhead between evaluations.

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
- At very high task rates (about 10k/s) the subclass produces over a million
  records per second, and anemon spends noticeable CPU decoding them.
- Processes are not identified: task events carry a program handle, not a PID.
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
