# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] — 2026-09-16

### Added

- `ig4-lpss-acpi.diff`, a patch against `sys/dev/ichiic`:
  - run `_PS0` when attaching a controller enumerated through ACPI (LPSS
    functions can be left in D3, where every register reads as all-ones),
  - classify `INT33C2`/`INT33C3`/`INT3432`/`INT3433` as `IG4_HASWELL` rather
    than `IG4_ATOM`,
  - ungate the LPSS functional clock (`IG4_REG_CLK_PARMS`, bit 0) on Haswell
    and Broadwell, without which the controller never drives the bus.
- A `Makefile` with `patch`, `build`, `install`, `revert` and `diff` targets.
- `bugzilla-report.md`, the same report as `bugzilla-report.txt` in the plain
  text Bugzilla actually renders, and `commit-message.txt` with the attachment
  description and a commit message in FreeBSD style.
- A README covering the symptoms, the causes and the result on hardware.

### Confirmed on hardware

- Dell XPS 13 9343 (Broadwell-U), FreeBSD 15.1-RELEASE-p3: the `DLL0665` /
  Synaptics `06CB:76AD` touchpad attaches as `iichid0` → `hmt1` and keeps
  working across an S3 suspend and resume, which the PS/2 path (`psm0`) never
  managed.
- Interrupts from the I2C controller (`irq7`) are now reported. The counter
  used to stay at zero, with transfers making progress only through the 10 ms
  polling loop in `wait_intr()`.
