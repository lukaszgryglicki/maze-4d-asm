#!/bin/sh
# Boot the 4D maze "OS" in qemu.
cd "$(dirname "$0")"
exec qemu-system-x86_64 -m 256 -drive format=raw,file=maze4d.img "$@"
