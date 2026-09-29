# Apple Neural Engine Monitor (anemon)

A terminal monitor for the Apple Neural Engine (ANE) on Apple Silicon Macs.

```
sudo .build/make/anemon calibrate  # once per machine: measure limits, check busy %
sudo .build/make/anemon            # full-screen view, q to quit
sudo .build/make/anemon --json     # one JSON object per interval
     .build/make/anemon --json     # without root: IOReport counters, when available
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

ANE power was **not read**: calibration printed `idle n/a / max n/a`.
`powermetrics` plist samples had no `processor.ane_power` field, and an
IOReport `Energy Model` subscription returned GPU/PCIe channels but no ANE
energy channel. The reported 136.8 GB/s read-bandwidth figure was the
benchmark-throughput fallback, not a direct DRAM-counter measurement. Live
`dram_read_gbs` / `dram_write_gbs` remain unavailable on this M6 build. IOReport
lists the channels in `AMC Stats / Perf Counters` as `ANE0 DCS RD/WR` and
`ANE1 DCS RD/WR` (anemon matches these names and sums the two engines; the
separate `ANEXL0/1 DCS` channels are not included), but
`IOReportCreateSubscription` returns NULL for that group, even for only the
ANE DCS channels and even as root. On M4 the same subscription works without root.

The machine exposes `ANE0` and `ANE1` in other IOReport groups, including
`PMP / Fast-Die CE` and `SoC Stats`. These are activity/state counters, not ANE
watts; anemon does not currently use them as a power substitute. Per-engine
busy reporting has not yet been independently validated by the calibration
check.

## Metrics

| Field | Meaning | Source | Needs root |
|---|---|---|---|
| busy % | Share of wall time the ANE was executing a task | kdebug firmware task events | yes |
| tasks/s, ms/task | Completed ANE tasks and their mean execution time | same | yes |
| programs | Busy time and task rate per compiled program (model) handle | same | yes |
| power | ANE power estimate, when exposed by the sampler; otherwise null | `powermetrics` | yes |
| DRAM read/write | ANE traffic at the DRAM controllers, when recognized; otherwise null | IOReport | no |
| interrupts | ANE interrupt rate | IOReport | no |

The JSON output also reports:

- `ane_busy_source`: where busy % came from. `firmware` means ANE firmware task
  events; `host` means the driver's submit/complete events, which include
  queueing time; `none` means no task events have been seen.
- `ane_busy_status`: `measured`, `idle`, `unverified` or `unsupported`. It is
  `unsupported` when IOReport shows the ANE working but no task events arrive
  on that chip or macOS version. In that case `ane_busy_pct` is null rather
  than 0.
- `validated` and `calibrated`.

An unavailable or unrecognized counter is null, not 0. Calibration may report
an estimated bandwidth fallback when direct DRAM counters are unavailable;
that estimate does not populate the live `dram_read_gbs` field.

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
