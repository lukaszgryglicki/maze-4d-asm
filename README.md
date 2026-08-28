# maze-4d-asm

A playable **4D maze game** that is its own **operating system**, written entirely in
**AMD64 GAS assembly** (one file: `maze4d.S`). It boots from the MBR on
`qemu-system-x86_64` or on a real BIOS PC, brings the CPU into 64-bit long mode
configured as *"modern unreal mode"* — every byte of physical RAM identity-mapped,
writable and executable, ring 0, no IDT, no protection whatsoever — and lets you
walk a randomly generated N×N×N×N voxel maze in 8 directions:

```
left / right   ±x      arrows
down / up      ±y      arrows
forward / back ±z      W / S
ata / kata     ±w      A / K     (the 4th dimension)
```

You start at voxel `(1,1,1,1)`; you win by reaching the exit in the far corner
(its exact coordinates are shown in the HUD). Score = number of successful moves
(lower is better — bumping into walls is free).

## How it works

### Boot chain (all in `maze4d.S`)

1. **Boot sector (16-bit real mode, 512 B)** — loads the remaining 62 sectors of
   the image at `0x7C00` using BIOS `int 13h` LBA reads (EDD), falling back to
   per-sector CHS reads with retries for old BIOSes/USB-FDD emulation.
2. **Stage 2 (16-bit)** —
   * enables the A20 gate (`int 15h AX=2401` + port `0x92`),
   * grabs the **E820 memory map** (up to 32 entries stored at `0x5000`),
   * copies the BIOS **8×8 VGA font** to `0x70000` (used later for text),
   * scans **VESA VBE** modes and picks the **highest-resolution** linear-
     framebuffer mode the hardware offers (no cap — 4K+ welcome; ties broken by
     color depth). Modes with misreported layouts (5:5:5 posing as 16 bpp,
     non-XRGB direct color) are rejected; if setting the best mode fails the
     next-best is tried automatically, and VGA mode 13h (320×200×8) remains
     the final fallback when VBE is absent,
   * builds a bootstrap 4 GiB identity map (2 MiB pages) at `0x10000`,
   * switches PE→PAE→LME→PG in one shot and jumps straight to 64-bit code.
3. **64-bit init ("modern unreal mode")** — long mode *requires* paging, so the
   game neutralizes it instead of using it:
   * builds the final identity map at `0x100000` covering **all usable RAM up to
     16 TiB** — with **1 GiB pages** when the CPU supports `pdpe1gb` (CPUID
     `80000001h EDX.26`), else **2 MiB pages**,
   * every page is present+RW, `CR0.WP=0`, no NX, ring 0, interrupts off
     permanently, **no IDT** — flat DOS-style memory, zero protection,
   * builds a 256-entry sine table with the x87 FPU (`fsin`) for the renderer,
   * picks the largest usable E820 region above the page tables as maze storage
     (1 byte per voxel) and derives **MAX N** from it: the largest N with N⁴
     bytes fitting (capped at 2000 → 16 TB).

### Maze generation

Perfect maze (every cell reachable, exactly one path between any two cells) via
**iterative depth-first search with backtracking**:

* Voxels with all-odd coordinates are *cells*; DFS carves the wall voxel between
  neighboring cells in a random unvisited direction (xorshift32 RNG seeded from
  `rdtsc` ⊕ PIT ⊕ RTC).
* No recursion stack is needed: each visited cell temporarily stores the
  direction it was entered from (bits 1-3) and is zeroed (opened) when the DFS
  unwinds — the maze itself is the stack, so N=500 works in O(1) extra memory.
* A progress bar tracks carving (N ≥ 150 takes a while under TCG emulation —
  it's a 4D volume: N=300 is 8.1 GiB and ~493 million cells).

### Rendering 4D

A 4D maze can't be drawn directly, so the game offers **two switchable
display modes** (TAB toggles between them).

**3D mode (default)** shows **four 3D orthographic dot-cloud views** in a 2×2
grid — the four 3D "hyperplanes" through the player:

| view | axes shown | axis held fixed at player's coordinate |
|------|-----------|------------------------------------------|
| 1    | X Y Z     | w |
| 2    | X Y W     | z |
| 3    | X Z W     | y |
| 4    | Y Z W     | x |

Each view renders every open voxel within a configurable window (±half around
you) as a square dot: **nearer = bigger + brighter** (4 depth bands). Yellow =
you (always centered), green = exit, blue = start — start/exit markers appear
in a view only when they actually lie in that view's 3D slice, which is itself
a useful 4D navigation hint. Colored dots near the center show the +x/+y/+z/+w
axis directions (orange/cyan/violet/white). Each view rotates (yaw/pitch) and
zooms independently; all transforms are 14-bit fixed-point integer math using
the x87-generated sine table. Text is drawn with the BIOS 8×8 font scaled to
the resolution (legend and view labels use a smaller scale so the views get
the maximum possible screen area).

**2D mode (TAB)** shows all **six 2D axis-aligned projections** — XY, XZ, XW,
YZ, YW, ZW — as flat maze slices in a 3×2 grid. Each panel fixes the two
remaining axes at your current coordinates and draws the resulting 2D slice:
light cells = open, dark = walls, yellow = you, green = exit, blue = start
(markers appear only when the two fixed coordinates match, same slice rule as
3D mode). The visible window auto-fits: the grid is scaled and centered so the
visible cells always fill the panel. U/O shrinks/grows the window (R resets),
and every panel scrolls with you through big mazes.

### Controls

| key | action |
|-----|--------|
| arrows | move ±x (left/right), ±y (down/up) |
| W / S | move +z / −z |
| A / K | move +w / −w (*ata / kata*) |
| TAB | toggle 4×3D views ↔ 6×2D projections |
| 1-4 | select active view (3D mode) |
| J / L | rotate active view (yaw, 3D mode) |
| I / M | rotate active view (pitch, 3D mode) |
| U / O | zoom in / out (smaller / larger window, both modes) |
| R | reset all views and zoom |
| X | **random move** — one uniformly random step among the open directions |
| H | **optimal move** — one step along the shortest path to the exit |
| ESC | back to the size menu |

Both X and H perform a real move and count toward your score. H finds the
next step by depth-first search from the exit to you through the open voxels,
using the maze bytes themselves as the DFS stack (the same zero-extra-memory
trick generation uses) — since the maze is perfect, the discovered path is
*the* unique shortest path. Holding H therefore auto-solves the maze; on huge
mazes under TCG emulation one press can take a moment (it may explore the
whole volume).

## Building

Requires only a C-capable toolchain driver (for the preprocessor) and a linker.
One command on either OS:

```sh
./build.sh          # produces maze4d.img (1 MiB, bootable)
```

* **Linux**: gcc or clang + GNU ld (binutils). Tested with gcc/binutils.
* **FreeBSD**: stock `cc` (clang) + stock `ld` (LLD). Tested on FreeBSD 14.

`build.sh` assembles with `cc -c` (the source uses `cpp` macros to compute
absolute addresses without relocations), then links a flat binary at `0x7C00`
(`--oformat binary`), trying `ld`, `ld.lld`, `ld.bfd`, and an ELF+`objcopy`
fallback. The image is padded to 1 MiB so CHS reads never run off the end.

## Running in qemu

```sh
./run.sh                    # qemu-system-x86_64 -m 256 (defaults)
./run.sh -m 4096            # more RAM for bigger mazes
qemu-system-x86_64 -m 12288 -drive format=raw,file=maze4d.img   # N=300
```

RAM sizing: the maze needs **N⁴ bytes** in one contiguous E820 region.

| N | maze size | suggested `-m` |
|---|-----------|----------------|
| 60 | 12 MiB | 256 (default) |
| 100 | 96 MiB | 512 |
| 127 | 248 MiB | 768 |
| 200 | 1.5 GiB | 2560 |
| 300 | 7.6 GiB | 12288 |
| 500 | 58 GiB | 65536 |

The boot menu prints how much RAM it found and the resulting MAX N, so you can
just experiment. Everything above 4 GiB is used transparently (identity-mapped
up to 16 TiB — an 8 TB machine is fine; N is additionally capped at 2000).
Note: without KVM (`-accel kvm`), generation of very large mazes is slow —
qemu's TCG interpreter executes the DFS ~50-100× slower than real hardware.

Keyboard: the game polls the PS/2 controller directly, so use qemu's default
PS/2 keyboard (no extra flags needed). It uses scancode set 1 make codes and
ignores mouse bytes, `E0/E1` prefixes and break codes.

## Running on a real machine

**Warning:** this is an OS. It runs with every byte of RAM mapped RWX at ring 0
with no exception handlers. It cannot touch your disks (it never writes to any
drive), but treat it accordingly.

Requirements: legacy/CSM **BIOS boot** (not UEFI-only), VESA VBE video BIOS,
PS/2 keyboard or USB keyboard with *USB legacy emulation* enabled in firmware
(nearly universal).

```sh
# write to a whole USB stick (not a partition!) — destroys its contents
sudo dd if=maze4d.img of=/dev/sdX bs=1M        # Linux
sudo dd if=maze4d.img of=/dev/daX bs=1m        # FreeBSD
```

Boot the stick via the BIOS boot menu ("USB-HDD"). The machine's full RAM is
available — 8 TB boxes welcome (16 TiB identity-map cap).

## Files

| file | purpose |
|------|---------|
| `maze4d.S` | the whole OS + game, GAS AT&T syntax, ~2500 lines |
| `build.sh` | build → `maze4d.img` (Linux + FreeBSD) |
| `run.sh` | convenience qemu launcher |
| `poc/maze4d_poc.c` | tiny portable C proof-of-concept of the same maze algorithm (generation + BFS solvability check + text walker); build: `cc -O2 -o maze4d_poc poc/maze4d_poc.c` |

## Implementation notes

* One source file, three CPU modes (16 → 32 → 64) — the 16/32-bit parts avoid
  relocations entirely via a `cpp` address macro, so any ELF linker works.
* The framebuffer is written directly (32/24/16/8 bpp paths); at 8 bpp the DAC
  palette is programmed manually via ports `3C8h/3C9h`.
* Interrupts stay off forever; there is no IDT — any exception would
  triple-fault and reboot, which doubles as a very honest crash handler.
* The player moves voxel-by-voxel: cells sit at odd coordinates, carved wall
  voxels between them are walkable too, so crossing cell→cell costs 2 moves.
* Every drawing primitive clips to the framebuffer, and the layout adapts to
  the mode geometry (text scale is chosen from both width and height), so any
  resolution a real VBE BIOS throws at it — 320×200 up to 4K+ — stays playable.
* Verified end-to-end in qemu: boot → menu → generation → all 8 move
  directions → per-view rotate/zoom → 2D/3D toggle → win screen → menu, at
  N=5…300, at 3840×2160×16 and 1920×1200×32 (stdvga), 1600×1200×8 and
  1152×864×8 (DAC palette path), 1280×1024×16 (cirrus) and 320×200×8
  (mode 13h), with the maze region placed above the 4 GiB boundary
  (`-m 12288`).
