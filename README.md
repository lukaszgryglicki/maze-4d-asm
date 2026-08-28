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

You start at voxel `(0,0,0,0)`; you win by reaching the exit at the opposite
corner `(N−1,N−1,N−1,N−1)` (shown in the HUD). Score = number of successful
moves (lower is better — bumping into walls is free). At boot you choose the
maze size **N** (minimum 2), then the maze **type**: **perfect** (exactly one
path between any two rooms — the default) or **sparse** (a perfect maze with a
chosen number of walls knocked out, from 0 all the way to *every* wall voxel,
which leaves a completely open N⁴ box and makes the 4D labyrinth much
friendlier to actually solve by hand).

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

Perfect maze (every room reachable, exactly one path between any two rooms) via
**iterative depth-first search with backtracking**:

* Voxels with all-EVEN coordinates are *rooms* (`m = ⌈N/2⌉` per axis — there is
  **no outer wall shell**, the grid edge itself is the boundary); DFS carves the
  wall voxel between neighboring rooms in a random unvisited direction
  (xorshift32 RNG seeded from `rdtsc` ⊕ PIT ⊕ RTC).
* Start `(0,0,0,0)` is always a room. For **odd N** the exit corner
  `(N−1,…)` is a room too; for **even N** it lies one voxel beyond the last
  room layer, so after the DFS a 4-step staircase corridor is carved:
  `(N−2,N−2,N−2,N−2) → +x → +y → +z → +w → (N−1,N−1,N−1,N−1)` — still a
  perfect maze (a tree plus one attached dead-end path).
* **Minimum N = 2**: 16 voxels, a single room at the origin plus that
  staircase — start and exit differ in all four coordinates, so any win takes
  ≥ 4 moves through ≥ 3 free intermediate voxels; the other **11 voxels are
  walls** (the densest N=2 maze possible). N = 3 is the first properly random
  maze (2⁴ = 16 rooms).
* No recursion stack is needed: each visited room temporarily stores the
  direction it was entered from (bits 1-3) and is zeroed (opened) when the DFS
  unwinds — the maze itself is the stack, so N=500 works in O(1) extra memory.
* A progress bar tracks carving (N ≥ 150 takes a while under TCG emulation —
  it's a 4D volume: N=300 is 8.1 GiB and ~493 million cells).

### Sparse mazes (optional)

A perfect 4D maze is *dense* — with up to 8 ways out of every room and a
unique solution it is genuinely hard for humans. Choosing **2 = SPARSE** in
the type menu asks for a number **R** of walls to remove and then, after the
normal perfect carve, deletes **exactly R** randomly chosen wall voxels.
**Every** still-full voxel is a candidate:

```
X = N⁴ − (2m⁴ − 1) − (4 if N even)        (m = rooms per axis = ⌈N/2⌉)
```

(N⁴ voxels minus m⁴ rooms, m⁴−1 carved passages, and the 4 exit-corridor
voxels for even N; the menu shows X for your N — e.g. N=5 → 464, N=7 → 1890,
N=9 → 5312). The pass streams over the whole volume once and removes each
still-standing wall with probability `need/remaining` (sequential random
sampling), which picks every R-subset with equal probability using no extra
memory. R = 0 is a perfect maze; **R = X removes every wall, leaving a
completely open N⁴ box** (shortest path = the Manhattan distance 4·(N−1)).
Removed walls create loops — multiple routes to the exit exist, shortest
paths get much shorter, and the 2D projections visibly open up.

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
| H | **hint move** — one converging step toward the exit (DFS path) |
| B | **best move** — one step along a true shortest path (BFS) |
| ESC | back to the size menu |

X, H and B all perform a real move and count toward your score.

**H (hint)** finds its step by a deterministic depth-first search from the
exit to you through the open voxels, storing the came-from direction in the
maze bytes themselves (the same zero-extra-memory trick generation uses) and
sweeping the marks afterwards. Because the search is deterministic it always
walks the same DFS spanning tree rooted at the exit, and each press moves you
one step *up* that tree — so repeatedly pressing H **always converges** to
the exit, from anywhere, even after you wander off. On a **perfect** maze the
tree path is *the* unique path, so H is optimal there; on a **sparse** maze it
is a valid route but possibly far from the shortest one.

**B (best)** runs a full breadth-first search from the exit (wave queues live
in the spare maze-region memory) and steps along a genuine shortest path —
on any maze type, from any position. If the region has no spare room for the
BFS queues, B transparently falls back to H's DFS. On a fully-opened sparse
maze B walks the straight Manhattan route (e.g. N=5: exactly 16 moves).
Holding H or B auto-solves the maze; on huge mazes under TCG emulation one
press can take a moment (it may explore the whole volume).

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
| `maze4d.S` | the whole OS + game, GAS AT&T syntax, ~3100 lines |
| `build.sh` | build → `maze4d.img` (Linux + FreeBSD) |
| `run.sh` | convenience qemu launcher |
| `poc/maze4d_poc.c` | tiny portable C proof-of-concept of the same maze algorithms (generation + sparse removal + BFS solvability/shortest-path checks + text walker); build: `cc -O2 -o maze4d_poc poc/maze4d_poc.c` |

## Implementation notes

* One source file, three CPU modes (16 → 32 → 64) — the 16/32-bit parts avoid
  relocations entirely via a `cpp` address macro, so any ELF linker works.
* The framebuffer is written directly (32/24/16/8 bpp paths); at 8 bpp the DAC
  palette is programmed manually via ports `3C8h/3C9h`.
* Interrupts stay off forever; there is no IDT — any exception would
  triple-fault and reboot, which doubles as a very honest crash handler.
* The player moves voxel-by-voxel: rooms sit at even coordinates with no outer
  wall shell, carved wall voxels between them are walkable too, so crossing
  room→room costs 2 moves.
* Every drawing primitive clips to the framebuffer, and the layout adapts to
  the mode geometry (text scale is chosen from both width and height), so any
  resolution a real VBE BIOS throws at it — 320×200 up to 4K+ — stays playable.
* Verified end-to-end in qemu: boot → menu → generation → all 8 move
  directions → per-view rotate/zoom → 2D/3D toggle → win screen → menu, at
  N=2…300, at 3840×2160×16 and 1920×1200×32 (stdvga), 1600×1200×8 and
  1152×864×8 (DAC palette path), 1280×1024×16 (cirrus) and 320×200×8
  (mode 13h), with the maze region placed above the 4 GiB boundary
  (`-m 12288`). Sparse mazes and the assist keys are verified too: the wall
  formula/count matches the C PoC, N=2 wins in exactly 4 moves (the 11-wall
  staircase micro-maze), B wins a fully-open N=5 sparse maze in exactly
  16 moves (the Manhattan optimum 4·(N−1)), H converges to the win on looped
  mazes after arbitrary wandering, and B/H agree on perfect mazes.
