#!/bin/sh
# Build maze4d.img (bootable flat binary). Works on Linux (gcc/binutils)
# and FreeBSD (clang/lld). cc -c is required: cpp expands the A() macro.
#
# Pipeline: assemble maze4d.S -> link as a flat binary at 0x7C00 (the BIOS
# boot address; tries several linkers, then an ELF+objcopy fallback) ->
# enforce the size limit -> pad to 1 MiB.
#
# The 32256-byte (63-sector) limit: the boot sector loads NSECT=62 more
# sectors after itself (63 * 512 = 32256).  If the binary outgrows it,
# NSECT in maze4d.S must be raised together with this check.
set -e
cd "$(dirname "$0")"
CC="${CC:-cc}"

$CC -c -o maze4d.o maze4d.S

link_bin() {
    "$1" $2 --oformat binary -Ttext 0x7C00 -e _start -o maze4d.bin maze4d.o 2>/dev/null
}
ok=0
for LD in ld ld.lld ld.bfd; do
    command -v "$LD" >/dev/null 2>&1 || continue
    if link_bin "$LD" "-m elf_x86_64"; then ok=1; break; fi
    if link_bin "$LD" ""; then ok=1; break; fi
done
if [ "$ok" != 1 ]; then
    # fallback: ELF link + objcopy
    for LD in ld ld.lld ld.bfd; do
        command -v "$LD" >/dev/null 2>&1 || continue
        if "$LD" -Ttext 0x7C00 -e _start -o maze4d.elf maze4d.o 2>/dev/null; then
            objcopy -O binary maze4d.elf maze4d.bin && ok=1 && break
        fi
    done
fi
[ "$ok" = 1 ] || { echo "ERROR: could not link" >&2; exit 1; }

SZ=$(wc -c < maze4d.bin)
if [ "$SZ" -gt 32256 ]; then
    echo "ERROR: binary $SZ bytes exceeds 63 sectors" >&2
    exit 1
fi
cp maze4d.bin maze4d.img
# pad to 1 MiB so BIOS CHS reads never run off the end
if command -v truncate >/dev/null 2>&1; then
    truncate -s 1048576 maze4d.img
else
    dd if=/dev/zero bs=1 count=1 seek=1048575 of=maze4d.img conv=notrunc 2>/dev/null
fi
echo "OK: maze4d.img ($SZ bytes of code/data, padded to 1 MiB)"
