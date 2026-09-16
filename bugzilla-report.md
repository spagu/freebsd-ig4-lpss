# FreeBSD Bugzilla submission

Ready-to-paste report for https://bugs.freebsd.org/bugzilla/enter_bug.cgi?product=Base%20System

- **Product:** Base System
- **Component:** kern
- **Version:** 15.1-RELEASE
- **Hardware / OS:** amd64 / FreeBSD
- **Summary:** `ig4(4)`: ACPI-enumerated Intel LPSS I2C controllers never work on Haswell/Broadwell (D3 at attach, wrong version, gated functional clock)
- **Attachment:** `ig4-lpss-acpi.diff`

---

## Description

On Haswell/Broadwell laptops whose LPSS is enumerated through ACPI rather than
PCI, `ig4iic` never attaches, so every device behind those I2C buses is lost.
On a Dell XPS 13 9343 this hides the I2C HID touchpad (`DLL0665`, Synaptics
`06CB:76AD`), leaving only the PS/2 fallback, which does not survive S3 resume.

Three independent defects, all on the ACPI attach path:

**1. The controller is left in D3.** `ig4iic_acpi_attach()` never runs `_PS0`.
Firmware on this machine leaves both LPSS I2C functions in D3hot, so all
registers read as `0xffffffff` and attach fails:

```
ig4iic0: <Designware I2C Controller> iomem 0xfe103000-0xfe103fff irq 7 on acpi0
ig4iic0: controller error during attach-1
device_attach: ig4iic0 attach returned 6
```

PCI config space of the I2C1 function (`8086:9ce2`, config space mapped at
`0xfe106000`), PMCSR at offset `0x84`, read from `/dev/mem` right after boot:

```
0xfe106000+0x000 = 0x9ce28086
0xfe106000+0x084 = 0x0000000b      /* PowerState = D3hot */
```

Clearing the low two bits (what the DSDT `_PS0` -> `LPD0` does) makes the
registers readable and `ig4iic_attach()` succeed.

**2. Broadwell is treated as an Atom SoC.** `ig4iic_acpi_attach()` assigns
`IG4_ATOM` to every HID except `APMC0D0F`, although `INT33C2`/`INT33C3`
(Lynx Point-LP) and `INT3432`/`INT3433` (Wildcat Point-LP) are the same
hardware that `ig4_pci.c` maps to `IG4_HASWELL`:

```c
	{ PCI_CHIP_LYNXPT_LP_I2C_1, "Intel Lynx Point-LP I2C Controller-1", IG4_HASWELL},
	{ PCI_CHIP_LYNXPT_LP_I2C_2, "Intel Lynx Point-LP I2C Controller-2", IG4_HASWELL},
```

The version selects, among other things, whether `IG4_GENERAL_SWMODE` is
programmed and which FIFO/timing parameters are used.

**3. The LPSS functional clock is left gated.** Nothing in the driver sets
bit 0 of `IG4_REG_CLK_PARMS` (`0x800`). With the clock gated the controller
accepts writes into the TX FIFO but never drives the bus, so every transfer
ends in `IIC_ETIMEOUT` and `iichid` probe fails silently. Registers with the
controller enabled, target address programmed and a transfer pending:

```
0xfe105000+0x070 (IC_STATUS)      = 0x00000000   /* no activity, TFE/TFNF clear */
0xfe105000+0x074 (TXFLR)          = 0x00000020   /* TX FIFO full, nothing drains */
0xfe105000+0x034 (RAW_INTR_STAT)  = 0x00000000
0xfe105000+0x800 (CLK_PARMS)      = 0x00000000
```

After setting bit 0 of `CLK_PARMS`, with nothing else changed:

```
0xfe105000+0x070 = 0x0000000e
0xfe105000+0x074 = 0x00000000                    /* FIFO drained */
0xfe105000+0x034 = 0x00000714                    /* STOP_DET, ACTIVITY, TX_EMPTY, RX_FULL */
```

and the touchpad answers a HID-over-I2C descriptor read at `0x2c`:

```
1e 00 00 01 09 02 21 00 24 00 3c 00 25 00 17 00 22 00 23 00 cb 06 ad 76 06 00 00 00 00 00
wHIDDescLength=30 bcdVersion=0x0100 wReportDescLength=521 wMaxInputLength=60 VID=0x06cb PID=0x76ad
```

Linux does the same ungating for these parts in `drivers/acpi/acpi_lpss.c`
(`lpt_i2c_dev_desc`, `LPSS_CLK_GATE`, `prv_offset = 0x800`).

A side effect of the gated clock: the controller raises no interrupts at all.
Before the patch `vmstat -i` reported `irq7: ig4iic0+ 0`; transfers on the
bus that did attach only made progress because `wait_intr()` re-reads the
status registers every 10 ms. After the patch the counter increases normally.
This also explains sporadic `codec: I2C read failed: 60` errors seen by an
out-of-tree Intel SST audio driver sharing I2C0 on the same machine.

## Steps to reproduce

1. Boot FreeBSD 15.1 on a Broadwell-U laptop whose LPSS is in ACPI mode
   (Dell XPS 13 9343, BIOS A20; `INT3432` / `INT3433` present in DSDT).
2. `dmesg | grep ig4iic` shows `controller error during attach-1`.
3. No `iicbus` is created, so the I2C HID touchpad (`_SB.PCI0.I2C1.TPD8`,
   `_HID DLL0665`, `_CID PNP0C50`, address `0x2c`) is never probed.

## Fix

Attached patch, against `sys/dev/ichiic`:

- `ig4_acpi.c`: call `acpi_set_powerstate(dev, ACPI_STATE_D0)` before mapping
  the registers, and map `INT33C2`/`INT33C3`/`INT3432`/`INT3433` to
  `IG4_HASWELL` instead of `IG4_ATOM`.
- `ig4_iic.c`: in `ig4iic_set_config()`, ungate the functional clock for
  `IG4_HASWELL` (set bit 0 of `IG4_REG_CLK_PARMS` when clear). Doing it in
  `set_config()` also covers the resume path.
- `ig4_reg.h`: add `IG4_CLK_PARMS_EN`.

## Test result

Same machine, patched module, no manual steps:

```
ig4iic1: <Designware I2C Controller> iomem 0xfe105000-0xfe105fff irq 7 on acpi0
iicbus7: <Philips I2C bus (ACPI-hinted)> on ig4iic1
iicbus7: <unknown card> at addr 0x2c
iichid0: <DLL0665:00 06CB:76AD I2C HID device> at addr 0x2c irq 39 on iicbus7
hidbus1: <HID bus> on iichid0
hmt1: <DLL0665:00 06CB:76AD TouchPad> on hidbus1
hmt1: Multitouch touchpad with 0 external buttons, click-pad
hmt1: 3 contacts with [C] properties. Report range [0:0] - [1216:680]
hms0: <DLL0665:00 06CB:76AD Mouse> on hidbus1
```

The touchpad works, multi-touch included, and keeps working across an S3
suspend/resume cycle. The PS/2 path (`psm0`) on this machine does not:

```
atkbdc0: resume: selftest=1 cmdbyte=0x47 auxcmd=1 auxport=0 reset=0 tries=60
psm0: failed to enable the aux device.
psm0: the aux device has gone! (reinitialize).
```

Tested only on Broadwell-U (`INT3432`/`INT3433`). The `INT33C2`/`INT33C3`
mapping follows the PCI table but was not verified on hardware.

## Related reports

- [bug 275115](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=275115)
  (`ig4(4)`: Intel Ice Lake I2C not recognized), and the older
  [245654](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=245654) and
  [240485](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=240485), report the
  same user-visible symptom — a touchpad missing because `ig4` does not bring up
  the controller — but a different cause: the controller ID was not in the
  driver's tables, so it never probed. Here the controller probes and attaches,
  and fails afterwards. The `_PS0` part of this patch is generation-independent
  and may also matter on those machines once their IDs are matched, since ACPI
  enumeration is where the D3 assumption breaks.

## Unrelated observation

`atkbdc(4)` has no `device_resume` method; it relies on `bus_generic_resume`,
so the i8042 is never reconfigured after S3 while its children immediately
start talking to it. Not the cause of this bug, and not touched by this patch,
but worth a separate report.

## Source references

- `sys/dev/ichiic/ig4_acpi.c` — https://cgit.freebsd.org/src/tree/sys/dev/ichiic/ig4_acpi.c
- `sys/dev/ichiic/ig4_iic.c` — https://cgit.freebsd.org/src/tree/sys/dev/ichiic/ig4_iic.c
- `sys/dev/ichiic/ig4_reg.h` — https://cgit.freebsd.org/src/tree/sys/dev/ichiic/ig4_reg.h
- `sys/dev/ichiic/ig4_pci.c` (version table) — https://cgit.freebsd.org/src/tree/sys/dev/ichiic/ig4_pci.c
- Linux LPSS clock handling — https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/acpi/acpi_lpss.c
