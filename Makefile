# Build and install the patched ig4(4) module.
# Run this ON THE TARGET MACHINE (FreeBSD), not on a workstation.

SRCDIR?=	/usr/src/sys/dev/ichiic
MODDIR?=	/usr/src/sys/modules/i2c/controllers/ichiic
KERNCONF?=	GENERIC
KERNBUILDDIR?=	/usr/obj/usr/src/${MACHINE}.${MACHINE_ARCH}/sys/${KERNCONF}
OBJDIR!=	cd ${MODDIR} && make -V .OBJDIR 2>/dev/null || echo /nonexistent
PATCHFILE?=	${.CURDIR}/ig4-lpss-acpi.diff
BACKUP?=	/boot/ig4.ko.orig-`date +%Y-%m-%d`
FILES=		ig4_reg.h ig4_acpi.c ig4_iic.c

all: build

# The .orig copies are made once, so a second run of this target is refused
# rather than silently patching an already patched tree.
patch:
.for f in ${FILES}
	@test -f ${SRCDIR}/${f}.orig || cp -p ${SRCDIR}/${f} ${SRCDIR}/${f}.orig
.endfor
	patch -d / -p0 -N < ${PATCHFILE}

# Without KERNBUILDDIR the module builds without DEV_ACPI: the ACPI attach path
# and acpi_iicbus go with it, the bus gets no children from the DSDT, and the
# touchpad never shows up.
build:
	@test -f ${KERNBUILDDIR}/opt_acpi.h || \
	    (echo "No ${KERNBUILDDIR}/opt_acpi.h - build the kernel first"; false)
	cd ${MODDIR} && make KERNBUILDDIR=${KERNBUILDDIR}

install: build
	@test -f ${BACKUP} || cp -p /boot/kernel/ig4.ko ${BACKUP}
	install -m 555 ${OBJDIR}/ig4.ko /boot/kernel/ig4.ko
	kldxref /boot/kernel
	@echo "Installed. Reboot required - devmatch loads ig4 during boot."

revert:
	@ls -1t /boot/ig4.ko.orig-* 2>/dev/null | head -1 | \
	    xargs -I{} sh -c 'install -m 555 {} /boot/kernel/ig4.ko && echo "restored {}"'
	kldxref /boot/kernel
.for f in ${FILES}
	@test ! -f ${SRCDIR}/${f}.orig || mv ${SRCDIR}/${f}.orig ${SRCDIR}/${f}
.endfor

# Headers are rewritten relative to the source tree so that the patch applies
# through "patch -d / -p0" wherever /usr/src lives.
diff:
.for f in ${FILES}
	@diff -u ${SRCDIR}/${f}.orig ${SRCDIR}/${f} | \
	    sed -e '1s|.*|--- sys/dev/ichiic/${f}.orig|' \
	        -e '2s|.*|+++ sys/dev/ichiic/${f}|' || true
.endfor

clean:
	cd ${MODDIR} && make clean

.PHONY: all patch build install revert diff clean
