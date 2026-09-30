# Apple Neural Engine Monitor (anemon)

A terminal monitor for the Apple Neural Engine (ANE) on Apple Silicon Macs.

```
sudo .build/make/anemon calibrate  # once per machine: measure limits, check busy %
sudo .build/make/anemon            # full-screen view, q to quit
sudo .build/make/anemon --json     # one JSON object per interval
     .build/make/anemon --json     # without root: DRAM, interrupts and (M6) power
```

Options: `--interval SECONDS` (default 1), `--count N`, `--no-power`.

## Build

```
make
```

This builds two binaries in `.build/make/`:

- **`anemon`**, the monitor.
- **`anebench`**, a small tool that generates convolution models and runs
  them on the ANE. The calibration scripts use it for their test workloads.

## Calibration

`sudo anemon calibrate` runs reference workloads through `anebench` for about
90 seconds. Keep other ANE and GPU work closed while it runs. It attempts to
measure:

- idle and maximum ANE power, using an INT8 5×5 convolution stack, when the
  system exposes an ANE power reading
- peak INT8 throughput
- ANE read bandwidth during an FP16 GEMV shaped like an LLM output head. If
  hardware DRAM counters are unavailable, the value is estimated from model
  weight bytes and evaluation time
- busy % against 10 ms tasks run at 100% and 50% duty. The check passes if
  anemon is within 5 percentage points of the host-measured share.

The results are saved to `/Library/Application Support/anemon/<architecture>.json`.
Unavailable measurements remain absent; a saved profile does not mean every
metric was measured. `validated` refers only to the busy-% duty-cycle check
passing on the same macOS major version.

### M6 / h18g result (macOS 27.0.1, build 26A434)

On one 32-core M6, calibration reported 76.9 INT8 TOPS and passed the busy-%
check: at 100% duty, host 100.0% vs anemon 95.3%; at 50% duty, host 49.4% vs
anemon 46.8%. These results validate ANE task timing for those test workloads.

The M4 sources for power and DRAM traffic do not work on this M6:
`powermetrics` reports no ANE power (and 0 mW CPU power), and the AMC
`ANE0/ANE1 DCS` byte counters are listed but `IOReportCreateSubscription`
returns NULL for them, even as root. anemon uses two other sources there,
neither of which needs root. Both are specific to h18g (`ChipModel` in
`Monitor.swift`); other chips report null until they are characterized.

**DRAM traffic** comes from the `PMP / DCS BW` histograms for the four ANE
memory links (`ANE0 L0/L1`, `ANE1 L0/L1`, RD and WR). Each has 1 GB/s bins
up to 32 GB/s and is sampled 24 MHz / 5400 = 4444 times per second, but only
while the link is on. anemon sums bin midpoint × samples over the links and
divides by that rate and the elapsed time. With a streaming FP16 GEMV
(anebench, weights read once per evaluation):

| Duty | Weight bytes / time | anemon |
|---:|---:|---:|
| 100% | 133.5 GB/s | 115 GB/s (80% of samples in the top bin) |
| 50% | 59.8 GB/s | 50–55 GB/s |
| 25% | 28.1 GB/s | 25 GB/s |

The top bin is open-ended, so a link above 32 GB/s is counted at 32 and the
figure becomes a lower bound. `dram_clipped_pct` gives the share of read
samples in that bin; the TUI flags it above 10%.

**ANE power** is an estimate. SMC key `PP0b` is a rail shared by the ANE and
the P-cores: one busy P-core adds about 6 W, a full INT8 ANE load about
5.3 W, and both together add up. IOReport's `PMP / Energy` histograms give
P-cluster power (`PACC0` plus `PACC0 SRAM`) in 1 W bins. anemon reports
`PP0b − P-cluster − baseline`, where the baseline is that difference while
the ANE is idle (its links off or trickling below 1 GB/s with fewer than 50
interrupts/s), learned while running. Until the first idle interval the
power field stays null. The SMC updates `PP0b` about once a second, out of
phase with anemon's window, so each value is the median of the last three
intervals. On the M6 it read 5.2–5.4 W for the INT8 convolution stack (rail
rise 5.3 W) and 0.8 W for the GEMV at 50% duty. `ane_power_source` is
`smc_estimate` for these values and `powermetrics` where that tool reports
ANE power.

## Metrics

| Field | Meaning | Source | Needs root |
|---|---|---|---|
| busy % | Share of wall time the ANE was executing a task | kdebug firmware task events | yes |
| tasks/s, ms/task | Completed ANE tasks and their mean execution time | same | yes |
| programs | Busy time and task rate per compiled program (model) handle | same | yes |
| power | ANE power estimate | `powermetrics`; on h18g an SMC rail minus IOReport P-cluster power | powermetrics: yes; SMC: no |
| DRAM read/write | ANE traffic at the DRAM controllers | IOReport AMC byte counters (M4); on h18g the PMP link histograms | no |
| interrupts | ANE interrupt rate | IOReport | no |

The JSON output also reports:

- `ane_busy_source`: where busy % came from. `firmware` means ANE firmware task
  events; `host` means the driver's submit/complete events, which include
  queueing time; `none` means no task events have been seen.
- `ane_busy_status`: `measured`, `idle`, `unverified` or `unsupported`. It is
  `unsupported` when IOReport shows the ANE working but no task events arrive
  on that chip or macOS version. In that case `ane_busy_pct` is null rather
  than 0.
- `ane_power_source`: `powermetrics` or `smc_estimate`.
- `dram_source`: `amc` (byte counters) or `histogram`, and
  `dram_clipped_pct`: for histograms, the share of read samples in the
  open-ended top bin. A high value means `dram_read_gbs` is a lower bound.
- `validated` and `calibrated`.

With `ANEMON_DEBUG=1` in the environment the JSON also carries the raw inputs
of the SMC estimate, `debug_rail_w` and `debug_pcluster_w`.

An unavailable or unrecognized counter is null, not 0. Calibration uses the
weight bytes per evaluation time of its bandwidth test when there are no byte
counters, since the link histograms clip at full speed.

**busy % is time occupancy, not compute utilization.** It says whether the ANE had
work, like the GPU "active" figure, not how many of its cores or MAC units were
in use. A model can keep the ANE 100% busy while using a few percent of its
arithmetic throughput. Compute efficiency needs the ANE's per-request PMU
counters, and only the process that submits a request gets them back. On M4,
`MACs / NE_NOMINAL_CYCLES` divided by 256 (FP16) or 512 (INT8 weights and
activations) gives the share of peak. A stack of 5×5 INT8 convolutions reached
38.2 TOPS against a 38.4 TOPS peak. The measurements, scripts and data are in
[`calibration/`](calibration/).

### How busy time is measured

The ANE firmware logs two kdebug events per task in class 0x06, subclass 0x1b:
code 0x49 with `DBG_FUNC_START` (`0x061b0125`) and `DBG_FUNC_END`
(`0x061b0126`). Both carry the program handle in arg1 and a per-program
transaction id in arg3, and are stamped on the ANE's own trace CPU.

- A task's interval is its start→end span. The start event is missing for many
  short tasks; those are charged the median duration of the program's recent
  paired tasks.
- Gaps in a program's transaction ids count tasks that were not reported at all.
  They are charged the same median, bounded by the idle time between tasks.
- A task that has started but not yet ended counts as busy up to the end of the
  interval, so long inferences do not read as idle.
- The window lags real time by 250 ms, because events reach the reader late.

`KERN_KDREADTR` returns at most about 3,900 records per call, so the reader
drains the kernel buffer in a loop each cycle. Tracing runs in ring-buffer mode
and is re-enabled if the kernel stops it.

## Validation (M4, h16g, macOS 27)

The reference is the share of wall time the workload spent inside synchronous
`Eval` calls, measured on the host:

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
host figure is not a reference. The firmware logs about 14% more tasks than
there are `Eval` calls. A raw `ktrace` capture shows the same ratio with
consecutive transaction ids, so the excess is real work.

Power (powermetrics estimate): 0.66 W with tiny tasks, 2.1–2.6 W for FP16
convolutions, 3.4 W for INT8 at 31 TOPS.

## Limitations

- kdebug has a single owner. While anemon runs, Instruments, `ktrace` and
  `fs_usage` cannot trace, and anemon cannot start while one of them is tracing.
- At very high task rates (≈10k/s) the subclass produces over a million records
  per second, and anemon spends noticeable CPU decoding them.
- Event codes, IOReport counters and the powermetrics output format are
  private or undocumented and may change between macOS releases or chips.
  Detailed timing validation is available for M4 / h16g on macOS 27; the M6
  / h18g duty-cycle check above also passed, but not every metric is available
  there. On other chips, run `anemon calibrate`. If busy % shows as
  unsupported, report the output of `calibration/scripts/trace_decode.sh`.
  M6 exposes separate `ANE0` / `ANE1` channels, but per-engine busy reporting
  has not yet been independently validated.
- Processes are not identified: the task events carry a program handle, not a PID.

## License

MIT. See [LICENSE](LICENSE).
