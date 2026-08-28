#!/bin/sh
# Boot the 4D maze "OS" in qemu.  The default -vga std exposes VESA modes
# up to 3840x2160x16, which the game picks automatically; -m 256 is plenty
# (maze RAM = the largest free E820 chunk, here ~200+ MiB => max N ~ 120).
# Extra qemu args pass through, e.g.: ./run.sh -vga virtio -m 4096
cd "$(dirname "$0")"
exec qemu-system-x86_64 -m 256 -drive format=raw,file=maze4d.img "$@"
