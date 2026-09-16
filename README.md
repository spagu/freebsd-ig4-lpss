# ig4(4) on ACPI-enumerated Intel LPSS — a patch

![FreeBSD](https://img.shields.io/badge/FreeBSD-15.1--RELEASE-red)
![Driver](https://img.shields.io/badge/driver-ig4iic-blue)
![Hardware](https://img.shields.io/badge/hardware-Broadwell--U%20LPSS-lightgrey)
![Status](https://img.shields.io/badge/status-tested%20on%20XPS%2013%209343-brightgreen)

Intel LPSS I2C controllers enumerated through ACPI rather than PCI never attach
on Haswell and Broadwell. On a Dell XPS 13 9343 that hides the I2C HID touchpad
(`DLL0665`, Synaptics `06CB:76AD`), so the system falls back to PS/2, which the
firmware does not restore after an S3 resume.

## Symptoms

```
ig4iic1: <Designware I2C Controller> iomem 0xfe105000-0xfe105fff irq 7 on acpi0
ig4iic1: controller error during attach-1
device_attach: ig4iic1 attach returned 6
```

After resume, on the PS/2 fallback:

```
atkbdc0: resume: selftest=1 cmdbyte=0x47 auxcmd=1 auxport=0 reset=0 tries=60
psm0: failed to enable the aux device.
psm0: the aux device has gone! (reinitialize).
```

## Causes

Three independent defects in `sys/dev/ichiic`:

1. **The controller is left in D3.** `ig4iic_acpi_attach()` never runs `_PS0`.
   Its registers then read as all-ones and `set_controller()` fails with
   `controller error during attach-1`. On the XPS 13 9343 the PMCSR of the I2C1
   function (`0xfe106000 + 0x84`) reads `0x0b`, meaning D3hot, right after boot.
2. **Broadwell is classified as an Atom SoC.** The ACPI path assigns `IG4_ATOM`
   to every identifier except `APMC0D0F`, although `INT33C2`/`INT33C3`
   (Lynx Point-LP) and `INT3432`/`INT3433` (Wildcat Point-LP) are the same
   hardware that `ig4_pci.c` maps to `IG4_HASWELL`.
3. **The LPSS functional clock is left gated.** Nothing sets bit 0 of
   `IG4_REG_CLK_PARMS` (`0x800`). The controller then accepts writes into the
   TX FIFO (`TXFLR` climbs to `0x20`) but never drives the bus: the activity bit
   in `IG4_REG_I2C_STA` and `RAW_INTR_STAT` stay at zero and every transfer ends
   in `IIC_ETIMEOUT`. Linux does the same ungating in `acpi_lpss.c`
   (`LPSS_CLK_GATE`, `prv_offset 0x800`).

With the clock gated the controller also raises no interrupts: `vmstat -i`
reports zero for `irq7`. Transfers only made progress because `wait_intr()`
re-reads the status registers every 10 ms. That also explains sporadic
`codec: I2C read failed: 60` errors from an out-of-tree Intel SST audio driver
sharing I2C0 on the same machine.

## What the patch changes

Before:

```
psm0: model Synaptics Touchpad, device ID 3        # PS/2, lost on every resume
```

After:

```
ig4iic1: <Designware I2C Controller> iomem 0xfe105000-0xfe105fff irq 7 on acpi0
iicbus7: <Philips I2C bus (ACPI-hinted)> on ig4iic1
iichid0: <DLL0665:00 06CB:76AD I2C HID device> at addr 0x2c irq 39 on iicbus7
hmt1: <DLL0665:00 06CB:76AD TouchPad> on hidbus1
hmt1: Multitouch touchpad with 0 external buttons, click-pad
hmt1: 3 contacts with [C] properties. Report range [0:0] - [1216:680]
```

The touchpad survives an S3 cycle, multi-touch works, and `irq7` starts counting
interrupts from the controller.

## Usage

Run these on the FreeBSD machine, not on a workstation:

```sh
make patch     # applies the patch to /usr/src, keeping *.orig copies
make build     # builds ig4.ko with KERNBUILDDIR set
make install   # backs up /boot/kernel/ig4.ko, installs, runs kldxref
make revert    # restores the original module and sources
make diff      # regenerates ig4-lpss-acpi.diff from the sources
```

`make install` needs a reboot afterwards: `ig4` is loaded by `devmatch` early in
the boot sequence.

## Known limitations

- **`freebsd-update` overwrites `/boot/kernel/ig4.ko`.** Repeat
  `make build install` after every system update. The previous module is kept as
  `/boot/ig4.ko.orig-<date>`.
- Tested only on Broadwell-U (`INT3432`/`INT3433`). The `INT33C2`/`INT33C3`
  mapping follows the table in the PCI path but was not verified on hardware.
- The PCI path (`ig4_pci.c`) does not know the Wildcat Point-LP device IDs
  (`8086:9ce1`, `8086:9ce2`). That does not affect machines whose LPSS is in
  ACPI mode.

## Reporting it to FreeBSD

Three files, in the order they are used:

- [bugzilla-report.txt](bugzilla-report.txt) — the text to paste into the
  *Description* field. Plain text, because Bugzilla renders no Markdown: code
  indented by four spaces, prose wrapped at 78 columns, `dmesg` lines left
  whole.
- [commit-message.txt](commit-message.txt) — the attachment description and a
  commit message in FreeBSD style, ready for a committer.
- [bugzilla-report.md](bugzilla-report.md) — the same content in Markdown, for
  reading in an editor.

Product *Base System*, component *kern*, version *15.1-RELEASE*, with
`ig4-lpss-acpi.diff` attached as `text/plain` and the *patch* flag ticked.

A separate matter, untouched by this patch: `atkbdc(4)` has no `device_resume`
method, so no i8042 controller is reconfigured after S3. That was not the cause
here, but the gap is real.

## Test machine

Dell XPS 13 9343, BIOS A20, FreeBSD 15.1-RELEASE-p3, `GENERIC`. The PS/2 path is
disabled there (`hint.psm.0.disabled="1"` in `/boot/loader.conf`) so that it does
not duplicate the events coming from the I2C touchpad.
