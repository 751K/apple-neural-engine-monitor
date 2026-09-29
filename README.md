# Apple Neural Engine Monitor (anemon)

A terminal monitor for the Apple Neural Engine (ANE) on Apple Silicon Macs.

```
sudo .build/make/anemon            # full-screen view, q to quit
sudo .build/make/anemon --json     # one JSON object per interval
     .build/make/anemon --json     # without root: DRAM and interrupt counters only
```

Options: `--interval SECONDS` (default 1), `--count N`, `--no-power`.

## Build

```
make
```

The Makefile calls `clang` and `swiftc` directly. A `Package.swift` is included,
but SwiftPM fails to link manifests with the Command Line Tools on this machine
(macOS 27), so the Makefile is the supported path.

## Metrics

| Field | Meaning | Source | Needs root |
|---|---|---|---|
| busy % | Share of wall time the ANE was executing a task | kdebug firmware task events | yes |
| tasks/s, ms/task | Completed ANE tasks and their mean execution time | same | yes |
| programs | Busy time and task rate per compiled program (model) handle | same | yes |
| power | ANE power estimate | `powermetrics` | yes |
| DRAM read/write | ANE traffic at the DRAM controllers (AMC DCS counters) | IOReport | no |
| interrupts | ANE interrupt rate | IOReport | no |

**busy % is time occupancy, not compute utilization.** It says whether the ANE had
work, like the GPU "active" figure, not how many of its 16 cores or MAC units
were in use. A model can keep the ANE 100% busy while using a few percent of its
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
- Event codes, the IOReport counters and the powermetrics output format are
  private or undocumented and may change between macOS releases or chips. So
  far this has only been validated on M4 with macOS 27. The per-device split is
  implemented for chips with two ANEs (for example an M6 with two H11ANE
  instances) but has not been tested there.
- Processes are not identified: the task events carry a program handle, not a PID.

## License

MIT. See [LICENSE](LICENSE).
