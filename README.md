# Anemon — Apple Neural Engine monitor

A terminal monitor for the Apple Neural Engine (ANE) on Apple Silicon Macs:
how busy it is, which processes use it, how much memory traffic it makes and
how much power it draws.

![Anemon on an M6 with two processes using both engines](docs/screenshot-m6.png)

## Install

```
make
sudo make install       # copies anemon and anebench to /usr/local/bin
```

Then run it from any terminal:

```
sudo anemon             # full-screen view, q to quit
anemon                  # without root: no busy %, tasks or programs
anemon --json           # one JSON object per interval
sudo anemon calibrate   # optional, about 2.5 min; M4 and M6 have built-in values
sudo anemon diagnose    # other chips: about 2 min, writes a JSON report to send back
```

Options: `--interval SECONDS` (default 1), `--count N`, `--no-power`. After
pulling a new version, run `make && sudo make install` again. Without
installing, run `.build/make/anemon` from the repository.

## What the screen shows

| Line | Meaning | Root |
|---|---|---|
| `ANE busy` | Share of time each engine was executing a task; tasks/s and mean ms/task | yes |
| `State` | Each engine running or off (JSON also gives the countdown to power-off) | no |
| `Throttled` | Shown while a throttle trigger is active | no |
| `Power` | ANE power from the SMC rail PP0b minus the CPU cluster on the same rail (M4, M5, M6) | no |
| `Host CPU` | Power of the cores that call the ANE; warns when they draw more than the ANE (many small calls) | no |
| `Memory` | M5, M6: power of the DRAM rails, for all of memory's clients | no |
| `DRAM` | ANE read/write traffic and interrupts (JSON also gives the memory clock level) | no |
| `programs` | Per process: share of the ANE, tasks/s, ms/task and energy per task (mJ) | yes |

**busy % is time occupancy, not compute utilization**, and not speed either:
macOS lowers the ANE clock when the caller leaves gaps between requests. A
single process calling a model synchronously rarely keeps the ANE 100% busy
(about 0.3–0.4 ms of submit/complete overhead per call); longer tasks,
batching or several processes fill the gaps, as in the screenshot.

After the Mac has slept, busy % comes from driver events until the next
reboot and is less precise; reboot first on a benchmark machine.

## Supported chips

| | M4 | M5 | M6 |
|---|---|---|---|
| busy %, programs | ✓ | driver events only | ✓ (both engines) |
| DRAM | exact | lower bound above 32 GB/s | lower bound at full speed |
| power | ✓ | ✓ | ✓ |

Tested on macOS 27.0.0 and 27.0.1. These are private macOS interfaces and may change
between releases. On other chips, `sudo anemon calibrate` checks busy %;
DRAM and power stay empty until the chip has been characterized.

## Benchmarks

ANE figures measured with `anemon calibrate` and `anemon diagnose`:

| | M4 | M5 | M6 |
|---|---|---|---|
| ANE | 16 cores | 16 cores | 2 × 16 cores |
| macOS | 27.0.1 | 27.0.0 | 27.0.1 |
| INT8, 5×5 conv stack | 37.7 TOPS | 30.0 TOPS | 71.2 TOPS |
| INT8, 3×3 conv stack | 31.7 TOPS | 38.2 TOPS | – |
| DRAM read (FP16 GEMV) | 65.3 GB/s | 69.0 GB/s | 123.7 GB/s |
| Peak ANE power | 12.8 W | 6.2 W ¹ | 16.2 W |
| busy % at 100 / 50% duty | 98.2 / 50.5% (host 100 / 50.6) | 98.8 / 51.7% (host 100 / 52.8) | 96.6 / 48.3% (host 100 / 50.9) |

TOPS count the model's nominal multiply-adds per second at batch 1; the
compiler maps kernel sizes differently on each chip, so no single load shows
every chip's peak. DRAM read is the weight bytes the GEMV streams per second.
¹ From one `anemon diagnose` run (PP0b estimate), not a calibration.

## Calibration

`sudo anemon calibrate` runs reference loads (close other ANE and GPU work
first): idle and peak power, peak INT8 throughput, read bandwidth, and a
check of busy % against known duty cycles. It sets the scale of the power and
DRAM bars; M4 and M6 have built-in values for machines without their own.

## Limitations

- While anemon runs, Instruments, `ktrace` and `fs_usage` cannot trace.
- Programs are shown by process, not by model name.
- Compute utilization is not available: the ANE's performance counters go
  only to the process that submitted the work.

How each metric is read, how it was validated on each chip, and the JSON
fields are in [`calibration/README.md`](calibration/README.md).

## License

MIT. See [LICENSE](LICENSE).
