/* maze4d.S - 4D maze game as a tiny AMD64 long-mode OS (GAS, AT&T syntax).
 *
 * ----------------------------------------------------------------------
 * BOOT CHAIN
 * ----------------------------------------------------------------------
 *   BIOS -> boot sector at 0x7C00 (loads NSECT more sectors via INT 13h
 *   LBA, CHS fallback) -> 16-bit stage2 (enable A20, E820 memory map,
 *   copy 8x8 BIOS font, pick + set best VESA mode) -> 32-bit protected
 *   mode trampoline (builds a bootstrap 4 GiB identity map with 2 MiB
 *   pages) -> 64-bit long mode -> final page tables identity-map ALL
 *   detected physical RAM (up to 16 TiB, 1 GiB pages when the CPU has
 *   pdpe1gb, else 2 MiB pages).
 *
 *   The result is "modern unreal mode": flat 64-bit ring 0, the whole
 *   address space identity-mapped RWX, WP=0, no NX, no IDT, interrupts
 *   off, keyboard polled straight from port 0x60 - all memory, zero
 *   protection, exactly like the old real-mode "unreal" trick but for
 *   the full 64-bit world.
 *
 * ----------------------------------------------------------------------
 * PHYSICAL MEMORY MAP
 * ----------------------------------------------------------------------
 *   0x05000  E820 map (count word, entries at +0x10)
 *   0x05800  VBE controller info      0x05900  VBE mode info
 *   0x07C00  this image (boot sector + <= NSECT sectors, <= 32256 B)
 *   0x10000  bootstrap page tables (4 GiB, 2 MiB pages)
 *   0x70000  8x8 BIOS font copy       0x90000  64-bit stack (grows down)
 *   0x100000 final page tables        largest E820 region: the maze
 *
 *   Maze region layout: N^4 voxel bytes at mazeb, then (16-aligned)
 *   the rest of the region is scratch for find_best's two BFS wave
 *   buffers (wvA/wvB, wvcap bytes each).
 *
 * ----------------------------------------------------------------------
 * MAZE REPRESENTATION
 * ----------------------------------------------------------------------
 *   N^4 voxels, one byte each, index = x + N*y + N^2*z + N^3*w.
 *   bit0 = 1 wall, bit0 = 0 open.  Upper bits are TEMPORARY search /
 *   generator marks: 0x40|(came_from_dir<<1) visited, bit4 = root
 *   sentinel; sweep_marks() clears everything but bit0 afterwards.
 *
 *   "Rooms" live at all-EVEN coordinates 0..maxc (m = ceil(N/2) rooms
 *   per axis, maxc = 2m-2); the voxels between adjacent rooms are the
 *   carvable walls.  There is NO outer wall shell: the grid edge itself
 *   is the boundary.  START = (0,0,0,0), EXIT = (N-1,N-1,N-1,N-1).
 *   For odd N the exit corner is a room (maxc = N-1); for even N it
 *   lies one layer beyond the rooms, so gen_maze carves a 4-step
 *   staircase corridor (maxc,..) -> (N-1,..) after the DFS.  Minimum
 *   N = 2: a single room plus that corridor = a 4-move micro maze.
 *   Directions are numbered 0..7 = +x,-x,+y,-y,+z,-z,+w,-w: axis =
 *   dir>>1, sign = dir&1 (dsgn1), opposite = dir^1, single-voxel byte
 *   offset = sdtab[dir] = +-stride[axis].
 *
 * ----------------------------------------------------------------------
 * ALGORITHMS
 * ----------------------------------------------------------------------
 *   gen_maze   iterative DFS backtracker carving a PERFECT maze (every
 *              pair of cells joined by exactly one path).  The stack is
 *              the maze itself: each visited cell stores its came-from
 *              direction in the voxel byte, so backtracking follows the
 *              marks and needs no extra memory.
 *   sparse     optional second pass: remove exactly R of the
 *              X = N^4 - (2m^4-1) - (4 if N even) still-full voxels
 *              (ALL walls are candidates), chosen uniformly by
 *              sequential random sampling over one linear scan
 *              (candidate removed with probability need/remaining),
 *              turning the maze into a braided/looped one, up to a
 *              completely open N^4 box at R = X.
 *   find_opt   H key "hint": deterministic DFS from the exit that keeps
 *              its visited marks for the whole search, i.e. it walks a
 *              FIXED spanning tree rooted at the exit.  Every press
 *              moves the player one step up that tree, so the distance
 *              to the exit strictly decreases - guaranteed convergence
 *              even on looped sparse mazes (where the route may be
 *              sub-optimal).  On a perfect maze the tree path IS the
 *              unique (optimal) route.
 *   find_best  B key "best": true shortest next step - breadth-first
 *              search from the exit using wave buffers in the maze
 *              region's slack memory; falls back to find_opt if the
 *              slack cannot hold a wave.  Marks are wiped afterwards.
 *   rng        xorshift32, seeded from the TSC at boot.
 *
 * ----------------------------------------------------------------------
 * DISPLAY & CONTROLS
 * ----------------------------------------------------------------------
 *   Picks the highest-resolution VESA LFB mode the card reports
 *   (32/24/16/8 bpp, tried best-first with next-best retry; VGA 13h
 *   fallback).  Two view modes, TAB toggles:
 *     3D: four rotatable/zoomable axonometric views XYZ, XYW, XZW, YZW,
 *         each a 3D slice through the player along the missing axis.
 *     2D: all six axis-pair projections XY, XZ, XW, YZ, YW, ZW in a
 *         3x2 grid, sliced at the player's other two coordinates.
 *   Keys: arrows = +-X/+-Y, W/S = +-Z, A/K = +-W (ata/kata),
 *   1-4 select 3D view, J/L/I/M rotate, U/O zoom, R reset, X random
 *   move, H hint move, B best move, ESC menu, any key after winning.
 *
 *   Menu flow: N >= 2 (maze is N^4 voxels) -> maze type (1 perfect /
 *   2 sparse) -> for sparse: how many walls to remove (0..X).
 *   Score = number of moves, lower is better.
 *
 * Build: cc -c (cpp needed for A()), link flat binary at 0x7C00.
 */

#define A(x) (LOAD + (x) - _start)

    .set LOAD,   0x7C00
    .set NSECT,  62            /* sectors loaded after boot sector */
    .set E820AT, 0x5000        /* count word, entries at +0x10 */
    .set VBEI,   0x5800
    .set MODEI,  0x5900
    .set BPML4,  0x10000       /* bootstrap page tables (4 GiB) */
    .set BPDPT,  0x11000
    .set BPD,    0x12000       /* 4 pages */
    .set FONT,   0x70000       /* 8x8 BIOS font copy */
    .set STK64,  0x90000
    .set TBL,    0x100000      /* final page tables (up to 16 TiB) */

    /* color ids */
    .set ID_BG,    0
    .set ID_G0,    1           /* 4 depth-shaded grays 1..4 */
    .set ID_PLY,   5
    .set ID_EXIT,  6
    .set ID_START, 7
    .set ID_AX,    8           /* +world axis 0..3 */
    .set ID_TXT,   12
    .set ID_DIM,   13
    .set ID_ACC,   14
    .set ID_ERR,   15
    .set ID_BORD,  16
    .set ID_BAR,   17
    .set NCOL,     18

    .text
    .code16
    .globl _start
_start:
    cli
    xorw %ax,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    movw $LOAD,%sp
    sti
    cld
    ljmpw $0,$A(bs_go)
bs_go:
    movb %dl,A(drv)
    movw $A(dap),%si            /* try LBA read first */
    movb $0x42,%ah
    movb A(drv),%dl
    int $0x13
    jnc bs_ok
    movb $8,%ah                 /* CHS fallback: get geometry */
    movb A(drv),%dl
    int $0x13
    jc bs_err
    andb $0x3F,%cl
    movb %cl,A(spt)
    movb %dh,A(hds)
    movw $1,A(clba)
    movw $NSECT,A(scnt)
    movw $0x07E0,A(dseg)
bs_next:
    movw A(clba),%ax
    xorw %dx,%dx
    xorw %bx,%bx
    movb A(spt),%bl
    divw %bx                    /* ax=lba/spt dx=rem */
    incw %dx
    movw %dx,%cx                /* sector in cl */
    xorw %dx,%dx
    xorw %bx,%bx
    movb A(hds),%bl
    incw %bx
    divw %bx                    /* ax=cyl dx=head */
    movb %dl,%dh
    movb %ah,%bl
    shlb $6,%bl
    orb %bl,%cl
    movb %al,%ch
    movw A(dseg),%ax
    movw %ax,%es
    xorw %bx,%bx
    movw $3,%si
bs_retry:
    movb $0x02,%ah
    movb $1,%al
    movb A(drv),%dl
    int $0x13
    jnc bs_got
    xorw %ax,%ax
    movb A(drv),%dl
    int $0x13
    decw %si
    jnz bs_retry
    jmp bs_err
bs_got:
    addw $0x20,A(dseg)
    incw A(clba)
    decw A(scnt)
    jnz bs_next
bs_ok:
    xorw %ax,%ax
    movw %ax,%es
    jmp stage2
bs_err:
    movw $A(s_derr),%si
1:  lodsb
    testb %al,%al
    jz 2f
    movb $0x0E,%ah
    movw $7,%bx
    int $0x10
    jmp 1b
2:  hlt
    jmp 2b

drv:  .byte 0
spt:  .byte 18
hds:  .byte 1
clba: .word 0
scnt: .word 0
dseg: .word 0
s_derr: .asciz "DISK ERR"
    .p2align 2
dap:
    .byte 0x10,0
    .word NSECT
    .word 0x7E00,0
    .quad 1

    .org 446                   /* partition table for picky BIOSes */
    .byte 0x80,0,2,0,0x83,0xFE,0xFF,0xFF
    .long 1,2048
    .org 510
    .word 0xAA55

/* ---------------- 16-bit stage 2 ---------------- */
stage2:
    movw $0x2401,%ax           /* A20 via BIOS */
    int $0x15
    inb $0x92,%al              /* and fast gate */
    orb $2,%al
    andb $0xFE,%al
    outb %al,$0x92

    xorl %ebx,%ebx             /* E820 memory map -> E820AT */
    movw $0,E820AT
    movw $E820AT+0x10,%di
e8l:
    movl $0xE820,%eax
    movl $0x534D4150,%edx
    movl $24,%ecx
    int $0x15
    jc e8d
    cmpl $0x534D4150,%eax
    jne e8d
    incw E820AT
    addw $24,%di
    cmpw $E820AT+0x10+24*32,%di
    jae e8d
    testl %ebx,%ebx
    jnz e8l
e8d:
    pushw %ds                  /* copy 8x8 BIOS font to FONT */
    movw $0x1130,%ax
    movb $3,%bh
    int $0x10                  /* ES:BP = font */
    pushw %es
    popw %ds
    movw %bp,%si
    movw $(FONT>>4),%ax
    movw %ax,%es
    xorw %di,%di
    movw $512,%cx
    rep movsw
    popw %ds
    xorw %ax,%ax
    movw %ax,%es

    movl $0x32454256,VBEI      /* "VBE2" */
    movw $0x4F00,%ax
    movw $VBEI,%di
    int $0x10
    cmpw $0x004F,%ax
    jne vbe_fb
    cmpl $0x41534556,VBEI      /* "VESA" */
    jne vbe_fb
    movw VBEI+0x0E,%si         /* mode list far ptr */
    movw VBEI+0x10,%ax
    movw %ax,%fs
    movl $0,A(bestlim)
    decl A(bestlim)            /* no upper score limit yet */
vbe_scan:
    movw VBEI+0x0E,%si
    movl $0,A(bestsc)
    movw $0,A(bestmd)
    movw $128,A(mcnt)
vbe_l:
    movw %fs:(%si),%cx
    cmpw $0xFFFF,%cx
    je vbe_sel
    addw $2,%si
    movw %cx,A(curmd)
    pushw %si
    movw $0x4F01,%ax
    movw $MODEI,%di
    int $0x10
    popw %si
    cmpw $0x004F,%ax
    jne vbe_n
    movw MODEI,%ax             /* attrs: supported|graphics|LFB */
    andw $0x91,%ax
    cmpw $0x91,%ax
    jne vbe_n
    movb MODEI+0x19,%al        /* bpp */
    movb MODEI+0x1B,%ah        /* memory model */
    cmpb $8,%al
    jne 1f
    cmpb $4,%ah                /* packed pixel */
    jne vbe_n
    jmp 2f
1:  cmpb $6,%ah                /* direct color */
    jne vbe_n
    cmpb $16,%al
    jne 5f
    movb MODEI+0x21,%ah        /* 16bpp: need green=6 (5:6:5) */
    testb %ah,%ah
    jz 2f                      /* masks unfilled: trust bpp */
    cmpb $6,%ah
    je 2f
    jmp vbe_n
5:  cmpb $24,%al
    je 6f
    cmpb $32,%al
    jne vbe_n
6:  movb MODEI+0x1F,%ah        /* 24/32bpp: expect red @16 (XRGB) */
    testb %ah,%ah
    jz 2f
    cmpb $16,MODEI+0x20
    jne vbe_n
2:  movzwl MODEI+0x12,%eax     /* X */
    cmpl $320,%eax
    jb vbe_n
    movzwl MODEI+0x14,%edx     /* Y */
    cmpl $200,%edx
    jb vbe_n
    imull %edx,%eax            /* score = area*4 + bytespp */
    shll $2,%eax
    movzbl MODEI+0x19,%edx
    shrl $3,%edx
    orl %edx,%eax
    cmpl A(bestlim),%eax       /* skip tiers that failed to set */
    jae vbe_n
    cmpl A(bestsc),%eax
    jbe vbe_n
    movl %eax,A(bestsc)
    movw A(curmd),%dx
    movw %dx,A(bestmd)
vbe_n:
    decw A(mcnt)
    jnz vbe_l
vbe_sel:
    movw A(bestmd),%cx
    testw %cx,%cx
    jz vbe_fb
    movw $0x4F01,%ax           /* refetch info for best mode */
    movw $MODEI,%di
    int $0x10
    cmpw $0x004F,%ax
    jne vbe_bad
    movw $0x4F02,%ax
    movw A(bestmd),%bx
    orw $0x4000,%bx            /* LFB */
    int $0x10
    cmpw $0x004F,%ax
    jne vbe_bad
    movl MODEI+0x28,%eax
    movl %eax,A(fbphys)
    movzwl MODEI+0x10,%eax
    movl %eax,A(fbpitch)
    movzwl MODEI+0x12,%eax
    movl %eax,A(fbw)
    movzwl MODEI+0x14,%eax
    movl %eax,A(fbh)
    movzbl MODEI+0x19,%eax
    movl %eax,A(fbbpp)
    jmp vbe_ok
vbe_bad:
    movl A(bestsc),%eax        /* exclude this tier, retry next best */
    movl %eax,A(bestlim)
    jmp vbe_scan
vbe_fb:
    movw $0x0013,%ax           /* VGA 320x200x8 fallback */
    int $0x10
    movl $0xA0000,A(fbphys)
    movl $320,A(fbpitch)
    movl $320,A(fbw)
    movl $200,A(fbh)
    movl $8,A(fbbpp)
vbe_ok:
    cli
    lgdtl A(gdtdesc)
    movl %cr0,%eax
    orb $1,%al
    movl %eax,%cr0
    ljmpl $0x18,$A(pm32)

/* ---------------- 32-bit trampoline ---------------- */
    .code32
pm32:
    movw $0x10,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    movw %ax,%fs
    movw %ax,%gs
    movl $LOAD,%esp
    xorl %eax,%eax             /* bootstrap identity map: 4 GiB */
    movl $BPML4,%edi
    movl $0x1800,%ecx
    rep stosl
    movl $BPDPT+3,BPML4
    movl $BPD+0x0003,BPDPT
    movl $BPD+0x1003,BPDPT+8
    movl $BPD+0x2003,BPDPT+16
    movl $BPD+0x3003,BPDPT+24
    movl $BPD,%edi
    xorl %esi,%esi
1:  movl %esi,%eax
    shll $21,%eax
    orl $0x83,%eax             /* present|rw|2MiB */
    movl %eax,(%edi)
    movl $0,4(%edi)
    addl $8,%edi
    incl %esi
    cmpl $2048,%esi
    jb 1b
    movl $BPML4,%eax
    movl %eax,%cr3
    movl %cr4,%eax
    orl $0x20,%eax             /* PAE */
    movl %eax,%cr4
    movl $0xC0000080,%ecx      /* EFER.LME (no NXE: no protection) */
    rdmsr
    orl $0x100,%eax
    wrmsr
    movl %cr0,%eax
    andl $0xFFFAFFF3,%eax      /* clear WP,AM,EM,TS */
    orl $0x80000003,%eax       /* PG|MP|PE */
    movl %eax,%cr0
    ljmpl $0x08,$A(lm64)

    .p2align 3
gdt:
    .quad 0
    .quad 0x00209A0000000000   /* 0x08 64-bit code */
    .quad 0x00CF92000000FFFF   /* 0x10 data */
    .quad 0x00CF9A000000FFFF   /* 0x18 32-bit code */
gdt_end:
gdtdesc:
    .word gdt_end-gdt-1
    .long A(gdt)

/* ---------------- 64-bit ---------------- */
    .code64
lm64:
    movw $0x10,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    movw %ax,%fs
    movw %ax,%gs
    movq $STK64,%rsp
    cld
    fninit                     /* x87 to build the sine table */
    xorl %ecx,%ecx
1:  movw %cx,tmpw(%rip)
    filds tmpw(%rip)
    fmull c_ang(%rip)
    fsin
    fmull c_amp(%rip)
    leaq sintab(%rip),%rdx
    fistps (%rdx,%rcx,2)
    incl %ecx
    cmpl $256,%ecx
    jb 1b

    /* topaddr = highest usable E820 end, >=4GiB, <=16TiB */
    movq $0x100000000,%rax
    movq %rax,topaddr(%rip)
    movzwl E820AT,%ecx
    movl $E820AT+0x10,%esi
tp_l:
    testl %ecx,%ecx
    jz tp_d
    cmpl $1,16(%rsi)
    jne tp_n
    movq (%rsi),%rax
    addq 8(%rsi),%rax
    cmpq topaddr(%rip),%rax
    jbe tp_n
    movq %rax,topaddr(%rip)
tp_n:
    addq $24,%rsi
    decl %ecx
    jmp tp_l
tp_d:
    movabsq $0x100000000000,%rax
    cmpq %rax,topaddr(%rip)
    jbe 1f
    movq %rax,topaddr(%rip)
1:
    /* rebuild identity map covering all of topaddr at TBL */
    movl $0x80000000,%eax
    cpuid
    cmpl $0x80000001,%eax
    jb pg2m
    movl $0x80000001,%eax
    cpuid
    btl $26,%edx               /* pdpe1gb? */
    jnc pg2m
pg1g:
    movq topaddr(%rip),%rax
    addq $0x3FFFFFFF,%rax
    shrq $30,%rax
    movq %rax,%r12             /* n 1GiB pages */
    leaq 511(%rax),%rbx
    shrq $9,%rbx               /* n PDPT pages = PML4 entries */
    leaq 1(%rbx),%rcx
    shlq $9,%rcx
    movl $TBL,%edi
    xorl %eax,%eax
    rep stosq
    xorl %ecx,%ecx
1:  movq %rcx,%rax
    shlq $12,%rax
    leaq TBL+0x1003(%rax),%rax
    movq %rax,TBL(,%rcx,8)
    incq %rcx
    cmpq %rbx,%rcx
    jb 1b
    xorl %ecx,%ecx
2:  movq %rcx,%rax
    shlq $30,%rax
    orq $0x83,%rax
    movq %rax,TBL+0x1000(,%rcx,8)
    incq %rcx
    cmpq %r12,%rcx
    jb 2b
    leaq 1(%rbx),%rax
    shlq $12,%rax
    addq $TBL,%rax
    movq %rax,tblend(%rip)
    jmp tbl_ok
pg2m:
    movq topaddr(%rip),%rax
    addq $0x1FFFFF,%rax
    shrq $21,%rax
    movq %rax,%r12             /* n 2MiB pages */
    leaq 511(%rax),%r13
    shrq $9,%r13               /* n PD pages */
    leaq 511(%r13),%r14
    shrq $9,%r14               /* n PDPT pages */
    leaq 1(%r14),%rcx
    addq %r13,%rcx
    shlq $9,%rcx
    movl $TBL,%edi
    xorl %eax,%eax
    rep stosq
    xorl %ecx,%ecx
1:  movq %rcx,%rax
    shlq $12,%rax
    leaq TBL+0x1003(%rax),%rax
    movq %rax,TBL(,%rcx,8)
    incq %rcx
    cmpq %r14,%rcx
    jb 1b
    movq %r14,%r15             /* PD base = TBL+0x1000+npdpt<<12 */
    shlq $12,%r15
    leaq TBL+0x1000(%r15),%r15
    xorl %ecx,%ecx
2:  movq %rcx,%rax
    shlq $12,%rax
    leaq 3(%r15,%rax),%rax
    movq %rax,TBL+0x1000(,%rcx,8)
    incq %rcx
    cmpq %r13,%rcx
    jb 2b
    xorl %ecx,%ecx
3:  movq %rcx,%rax
    shlq $21,%rax
    orq $0x83,%rax
    movq %rax,(%r15,%rcx,8)
    incq %rcx
    cmpq %r12,%rcx
    jb 3b
    movq %r13,%rax
    shlq $12,%rax
    addq %r15,%rax
    movq %rax,tblend(%rip)
tbl_ok:
    movl $TBL,%eax
    movq %rax,%cr3

    /* maze region: largest usable region above tables, below map */
    movq tblend(%rip),%rax
    addq $0x1FFFFF,%rax
    movabsq $0xFFFFFFFFFFE00000,%rdx
    andq %rdx,%rax
    cmpq $0x400000,%rax
    jae 1f
    movl $0x400000,%eax
1:  movq %rax,mazemin(%rip)
    xorl %r14d,%r14d
    xorl %r15d,%r15d
    movzwl E820AT,%ecx
    movl $E820AT+0x10,%esi
rg_l:
    testl %ecx,%ecx
    jz rg_d
    cmpl $1,16(%rsi)
    jne rg_n
    movq (%rsi),%r8
    movq (%rsi),%rax
    addq 8(%rsi),%rax
    cmpq topaddr(%rip),%rax
    jbe 1f
    movq topaddr(%rip),%rax
1:  cmpq mazemin(%rip),%r8
    jae 2f
    movq mazemin(%rip),%r8
2:  cmpq %r8,%rax
    jbe rg_n
    subq %r8,%rax
    cmpq %r14,%rax
    jbe rg_n
    movq %rax,%r14
    movq %r8,%r15
rg_n:
    addq $24,%rsi
    decl %ecx
    jmp rg_l
rg_d:
    movq %r14,mazesz(%rip)
    movq %r15,mazeb(%rip)
    cmpq $1300,%r14
    jae 1f
    jmp panic_noram
1:  movl $2,%ebx               /* maxN: largest n<=2000, n^4<=size */
2:  leal 1(%rbx),%eax
    cmpl $2000,%eax
    ja 3f
    movq %rax,%rcx
    imulq %rcx,%rcx
    imulq %rcx,%rcx
    cmpq mazesz(%rip),%rcx
    ja 3f
    incl %ebx
    jmp 2b
3:  movl %ebx,maxN(%rip)

    /* video helpers */
    movl fbbpp(%rip),%eax
    shrl $3,%eax
    movl %eax,bytespp(%rip)
    movl fbw(%rip),%edx
    movl fbh(%rip),%esi        /* ts needs width AND height */
    movl $1,%eax
    cmpl $1280,%edx
    jb 1f
    cmpl $720,%esi
    jb 1f
    movl $2,%eax
    cmpl $2560,%edx
    jb 1f
    cmpl $1440,%esi
    jb 1f
    movl $3,%eax
1:  movl %eax,ts(%rip)
    movl %eax,%ecx             /* tsl = max(1,ts-1): legend/labels */
    decl %ecx
    jnz 4f
    movl $1,%ecx
4:  movl %ecx,tsl(%rip)
    movl $8,%eax
    cmpl $640,%edx
    jae 2f
    movl $4,%eax
2:  movl %eax,gap(%rip)
    xorl %ecx,%ecx             /* RGB565 table */
c16l:
    leaq rgb32(%rip),%rsi
    movl (%rsi,%rcx,4),%eax
    movl %eax,%edx
    shrl $19,%edx
    andl $0x1F,%edx
    shll $11,%edx
    movl %eax,%edi
    shrl $10,%edi
    andl $0x3F,%edi
    shll $5,%edi
    orl %edi,%edx
    andl $0xFF,%eax
    shrl $3,%eax
    orl %eax,%edx
    leaq col16(%rip),%rdi
    movw %dx,(%rdi,%rcx,2)
    incl %ecx
    cmpl $NCOL,%ecx
    jb c16l
    cmpl $8,fbbpp(%rip)        /* program DAC palette for 8bpp */
    jne dac_d
    xorl %ecx,%ecx
dacl:
    movl %ecx,%eax
    movw $0x3C8,%dx
    outb %al,%dx
    leaq rgb32(%rip),%rsi
    movl (%rsi,%rcx,4),%edi
    movw $0x3C9,%dx
    movl %edi,%eax
    shrl $18,%eax
    outb %al,%dx
    movl %edi,%eax
    shrl $10,%eax
    andl $0x3F,%eax
    outb %al,%dx
    movl %edi,%eax
    shrl $2,%eax
    andl $0x3F,%eax
    outb %al,%dx
    incl %ecx
    cmpl $NCOL,%ecx
    jb dacl
dac_d:
    /* layout: HUD/legend bands; 2x2 3D grid; 3x2 2D grid */
    movl tsl(%rip),%eax
    imull $10,%eax,%ecx
    movl %ecx,lab(%rip)        /* label band = 10*tsl */
    imull $30,%eax,%esi
    addl $6,%esi               /* legh = 30*tsl+6 */
    movl ts(%rip),%eax
    imull $20,%eax,%edx
    addl $6,%edx
    movl %edx,hudh(%rip)
    movl fbh(%rip),%edi
    subl %esi,%edi
    subl %edx,%edi
    movl %ecx,%eax
    shll $1,%eax
    subl %eax,%edi
    movl gap(%rip),%eax
    leal (%rax,%rax,2),%edx
    subl %edx,%edi
    shrl $1,%edi               /* availh/2 */
    movl fbw(%rip),%eax
    movl gap(%rip),%edx
    leal (%rdx,%rdx,2),%edx
    subl %edx,%eax
    shrl $1,%eax
    cmpl %edi,%eax
    jbe 1f
    movl %edi,%eax
1:  movl %eax,qside(%rip)
    movl fbw(%rip),%edx
    movl %eax,%ecx
    shll $1,%ecx
    addl gap(%rip),%ecx
    subl %ecx,%edx
    shrl $1,%edx
    movl %edx,vx0g(%rip)
    addl %eax,%edx
    addl gap(%rip),%edx
    movl %edx,vx1g(%rip)
    movl hudh(%rip),%edx
    addl gap(%rip),%edx
    movl %edx,yl0(%rip)
    addl lab(%rip),%edx
    movl %edx,vy0(%rip)
    addl %eax,%edx
    addl gap(%rip),%edx
    movl %edx,yl1(%rip)
    addl lab(%rip),%edx
    movl %edx,vy1(%rip)
    /* 2D grid: s2side = min((fbw-4gap)/3, availh/2) ; edi=availh/2 */
    movl fbw(%rip),%eax
    movl gap(%rip),%edx
    shll $2,%edx
    subl %edx,%eax
    xorl %edx,%edx
    movl $3,%ecx
    divl %ecx
    cmpl %edi,%eax
    jbe 4f
    movl %edi,%eax
4:  movl %eax,s2side(%rip)
    movl fbw(%rip),%edx        /* v2x0 = (fbw-3*s2-2gap)/2 */
    leal (%rax,%rax,2),%ecx
    subl %ecx,%edx
    movl gap(%rip),%ecx
    subl %ecx,%edx
    subl %ecx,%edx
    shrl $1,%edx
    movl %edx,v2x0(%rip)
    addl %eax,%edx
    addl %ecx,%edx
    movl %edx,v2x1(%rip)
    addl %eax,%edx
    addl %ecx,%edx
    movl %edx,v2x2(%rip)
    movl hudh(%rip),%edx
    addl %ecx,%edx
    movl %edx,y2l0(%rip)
    addl lab(%rip),%edx
    movl %edx,v2y0(%rip)
    addl %eax,%edx
    addl %ecx,%edx
    movl %edx,y2l1(%rip)
    addl lab(%rip),%edx
    movl %edx,v2y1(%rip)
    movl tsl(%rip),%eax
    imull $30,%eax,%esi
    addl $6,%esi
    movl fbh(%rip),%edx
    subl %esi,%edx
    addl $2,%edx
    movl %edx,legy(%rip)
    movl $15,%eax              /* default window: 15 (11 if tiny) */
    cmpl $160,qside(%rip)
    jae 3f
    movl $11,%eax
3:  movl %eax,defwin(%rip)
    call seed_rng
    jmp menu

panic_noram:
    call clear_fb
    movl $16,curx(%rip)
    movl $16,cury(%rip)
    movl $ID_ERR,colr(%rip)
    leaq s_noram(%rip),%rsi
    call draw_str
1:  hlt
    jmp 1b

/* ---------------- menu ----------------
 * Screen flow: menu (enter N) -> menu_type (1 perfect / 2 sparse) ->
 * [menu_walls (how many walls to remove)] -> setup_n -> game.
 * Digit input into inbuf/inlen, backspace edits, ESC returns here. */
menu:
    movl $0,inlen(%rip)
    movq $0,errstr(%rip)
menu_draw:
    call clear_fb
    movl $16,curx(%rip)
    movl $12,cury(%rip)
    movl $ID_ACC,colr(%rip)
    leaq s_t1(%rip),%rsi
    call draw_str
    call menu_nl
    movl $ID_DIM,colr(%rip)
    leaq s_t2(%rip),%rsi
    call draw_str
    call menu_nl
    call menu_nl
    movl $ID_TXT,colr(%rip)
    leaq s_ram(%rip),%rsi
    call draw_str
    movq mazesz(%rip),%rax
    shrq $20,%rax
    call draw_dec
    leaq s_mib(%rip),%rsi
    call draw_str
    call menu_nl
    leaq s_vid(%rip),%rsi
    call draw_str
    movl fbw(%rip),%eax
    call draw_dec
    movb $'X',%al
    call draw_char
    movl fbh(%rip),%eax
    call draw_dec
    movb $'X',%al
    call draw_char
    movl fbbpp(%rip),%eax
    call draw_dec
    call menu_nl
    leaq s_maxn(%rip),%rsi
    call draw_str
    movl maxN(%rip),%eax
    call draw_dec
    call menu_nl
    call menu_nl
    leaq s_pr1(%rip),%rsi
    call draw_str
    movl maxN(%rip),%eax
    call draw_dec
    leaq s_pr2(%rip),%rsi
    call draw_str
    call menu_nl
    movl $ID_ACC,colr(%rip)
    leaq s_cur(%rip),%rsi
    call draw_str
    xorl %ebx,%ebx
mi_l:
    cmpl inlen(%rip),%ebx
    jae mi_d
    leaq inbuf(%rip),%rax
    movb (%rax,%rbx),%al
    call draw_char
    incl %ebx
    jmp mi_l
mi_d:
    movb $'_',%al
    call draw_char
    call menu_nl
    movq errstr(%rip),%rsi
    testq %rsi,%rsi
    jz 1f
    movl $ID_ERR,colr(%rip)
    call draw_str
1:  call menu_nl
    call menu_nl
    movl $ID_DIM,colr(%rip)
    leaq s_goal(%rip),%rsi
    call draw_str
    call menu_nl
    leaq s_l1(%rip),%rsi
    call draw_str
    call menu_nl
    leaq s_l2(%rip),%rsi
    call draw_str
    call menu_nl
    leaq s_l3(%rip),%rsi
    call draw_str
menu_key:
    call getkey
    cmpb $0x1C,%al             /* enter */
    je menu_go
    cmpb $0x0E,%al             /* backspace */
    je menu_bs
    cmpb $0x02,%al
    jb menu_key
    cmpb $0x0B,%al
    ja menu_key
    movzbl %al,%eax
    leaq scan2dig-2(%rip),%rdx
    movb (%rdx,%rax),%dl
    movl inlen(%rip),%ecx
    cmpl $4,%ecx
    jae menu_key
    leaq inbuf(%rip),%rax
    movb %dl,(%rax,%rcx)
    incl %ecx
    movl %ecx,inlen(%rip)
    jmp menu_draw
menu_bs:
    movl inlen(%rip),%ecx
    testl %ecx,%ecx
    jz menu_key
    decl %ecx
    movl %ecx,inlen(%rip)
    jmp menu_draw
menu_go:
    movl inlen(%rip),%ecx
    testl %ecx,%ecx
    jz menu_epos
    xorl %eax,%eax
    xorl %ebx,%ebx
mg_l:
    cmpl %ecx,%ebx
    jae mg_d
    imull $10,%eax
    leaq inbuf(%rip),%rdx
    movzbl (%rdx,%rbx),%edx
    subl $'0',%edx
    addl %edx,%eax
    incl %ebx
    jmp mg_l
mg_d:
    testl %eax,%eax
    jz menu_epos
    cmpl $2,%eax
    jae 1f
    movl $2,%eax               /* clamp tiny N up to 2 (see header) */
1:  cmpl maxN(%rip),%eax
    jbe 2f
    movl maxN(%rip),%eax
2:  movl %eax,N(%rip)
    jmp menu_type
menu_epos:
    leaq s_epos(%rip),%rax
    movq %rax,errstr(%rip)
    movl $0,inlen(%rip)
    jmp menu_draw

/* ---------------- maze type menu ---------------- */
menu_type:
    call clear_fb
    movl $16,curx(%rip)
    movl $12,cury(%rip)
    movl $ID_ACC,colr(%rip)
    leaq s_ty0(%rip),%rsi
    call draw_str
    movl N(%rip),%eax
    call draw_dec
    call menu_nl
    call menu_nl
    movl $ID_TXT,colr(%rip)
    leaq s_ty1(%rip),%rsi
    call draw_str
    call menu_nl
    leaq s_ty2(%rip),%rsi
    call draw_str
    call menu_nl
    call menu_nl
    movl $ID_DIM,colr(%rip)
    leaq s_ty3(%rip),%rsi
    call draw_str
mt_key:
    call getkey
    cmpb $0x01,%al             /* ESC: back to size menu */
    je menu
    cmpb $0x1C,%al             /* Enter = perfect */
    je mt_perf
    cmpb $0x02,%al             /* 1 = perfect */
    je mt_perf
    cmpb $0x03,%al             /* 2 = sparse */
    je menu_walls
    jmp mt_key
mt_perf:
    movq $0,rmwalls(%rip)
    jmp setup_n

/* ---------------- sparse: how many walls to remove ----------------
 * After perfect-maze carving of m^4 cells (m cells per axis) there are
 * 4*m^3*(m-1) walls between adjacent cell pairs, of which m^4-1 were
 * carved, leaving  maxrm = m^3*(3m-4)+1  removable walls. */
menu_walls:
    /* X = removable walls = ALL full voxels of the perfect maze:
     * N^4 - (2m^4 - 1) - (4 if N even), m = ceil(N/2) rooms per axis
     * (frees = m^4 rooms + m^4-1 carved passages + 4 exit-corridor
     * voxels when N is even).  R = X empties the grid completely. */
    movl N(%rip),%eax
    movq %rax,%rcx
    imulq %rax,%rcx
    imulq %rcx,%rcx            /* N^4 */
    incl %eax
    shrl $1,%eax               /* m */
    movq %rax,%rdx
    imulq %rax,%rdx
    imulq %rdx,%rdx            /* m^4 */
    addq %rdx,%rdx
    decq %rdx                  /* free voxels (odd N) */
    subq %rdx,%rcx
    testl $1,N(%rip)
    jnz 1f
    subq $4,%rcx               /* even N: exit corridor frees 4 more */
1:  movq %rcx,maxrm(%rip)
    movl $0,inlen(%rip)
mw_draw:
    call clear_fb
    movl $16,curx(%rip)
    movl $12,cury(%rip)
    movl $ID_ACC,colr(%rip)
    leaq s_wl0(%rip),%rsi
    call draw_str
    movl N(%rip),%eax
    call draw_dec
    call menu_nl
    call menu_nl
    movl $ID_TXT,colr(%rip)
    leaq s_wl1(%rip),%rsi
    call draw_str
    movq maxrm(%rip),%rax
    call draw_dec
    call menu_nl
    leaq s_wl2(%rip),%rsi
    call draw_str
    call menu_nl
    movl $ID_ACC,colr(%rip)
    leaq s_cur(%rip),%rsi
    call draw_str
    xorl %ebx,%ebx
mw_il:
    cmpl inlen(%rip),%ebx
    jae mw_id
    leaq inbuf(%rip),%rax
    movb (%rax,%rbx),%al
    call draw_char
    incl %ebx
    jmp mw_il
mw_id:
    movb $'_',%al
    call draw_char
    call menu_nl
    call menu_nl
    movl $ID_DIM,colr(%rip)
    leaq s_wl3(%rip),%rsi
    call draw_str
mw_key:
    call getkey
    cmpb $0x01,%al             /* ESC: back */
    je menu
    cmpb $0x1C,%al             /* enter */
    je mw_go
    cmpb $0x0E,%al             /* backspace */
    je mw_bs
    cmpb $0x02,%al
    jb mw_key
    cmpb $0x0B,%al
    ja mw_key
    movzbl %al,%eax
    leaq scan2dig-2(%rip),%rdx
    movb (%rdx,%rax),%dl
    movl inlen(%rip),%ecx
    cmpl $13,%ecx              /* 13 digits < 2^63, plenty */
    jae mw_key
    leaq inbuf(%rip),%rax
    movb %dl,(%rax,%rcx)
    incl %ecx
    movl %ecx,inlen(%rip)
    jmp mw_draw
mw_bs:
    movl inlen(%rip),%ecx
    testl %ecx,%ecx
    jz mw_key
    decl %ecx
    movl %ecx,inlen(%rip)
    jmp mw_draw
mw_go:
    xorl %eax,%eax             /* parse 64-bit, empty = 0 */
    xorl %ebx,%ebx
    movl inlen(%rip),%ecx
1:  cmpl %ecx,%ebx
    jae 2f
    imulq $10,%rax,%rax
    leaq inbuf(%rip),%rdx
    movzbl (%rdx,%rbx),%edx
    subl $'0',%edx
    addq %rdx,%rax
    incl %ebx
    jmp 1b
2:  cmpq maxrm(%rip),%rax      /* clamp to removable count */
    jbe 3f
    movq maxrm(%rip),%rax
3:  movq %rax,rmwalls(%rip)
    jmp setup_n

/* ---------------- per-N setup ----------------
 * Computes everything derived from N: strides (1,N,N^2,N^3), total voxel
 * count, maxc (largest even room coordinate), cells = m^4, the sdtab
 * single-voxel offsets for the 8 directions, start/exit positions,
 * default view windows/rotations for the 3D and 2D modes, then generates
 * the maze and enters the game loop. */
setup_n:
    movl N(%rip),%eax
    movq %rax,Nq(%rip)
    movq $1,stride(%rip)
    movq %rax,stride+8(%rip)
    movq %rax,%rdx
    imulq %rax,%rdx
    movq %rdx,stride+16(%rip)
    imulq %rax,%rdx
    movq %rdx,stride+24(%rip)
    imulq %rax,%rdx
    movq %rdx,total(%rip)
    movl N(%rip),%eax
    incl %eax
    shrl $1,%eax               /* Mc = rooms per axis = ceil(N/2) */
    movl %eax,%edx
    leal -2(%rax,%rax),%eax
    movl %eax,maxc(%rip)       /* last room coord = 2*(Mc-1) */
    movl %edx,%eax
    movq %rax,%rcx
    imulq %rcx,%rcx
    imulq %rcx,%rcx
    movq %rcx,cells(%rip)
    xorl %ecx,%ecx
sdl:
    leaq stride(%rip),%rax
    movq (%rax,%rcx,8),%rdx
    leaq sdtab(%rip),%rax
    movq %rcx,%rdi
    shlq $4,%rdi
    movq %rdx,(%rax,%rdi)
    negq %rdx
    movq %rdx,8(%rax,%rdi)
    incl %ecx
    cmpl $4,%ecx
    jb sdl
    movl $0,pcoord(%rip)       /* start at the origin corner */
    movl $0,pcoord+4(%rip)
    movl $0,pcoord+8(%rip)
    movl $0,pcoord+12(%rip)
    movl N(%rip),%eax          /* exit at the far corner (N-1,...) */
    decl %eax
    movl %eax,ecoord(%rip)
    movl %eax,ecoord+4(%rip)
    movl %eax,ecoord+8(%rip)
    movl %eax,ecoord+12(%rip)
    movq $0,moves(%rip)
    movl defwin(%rip),%eax     /* per-view windows */
    cmpl N(%rip),%eax
    jbe 1f
    movl N(%rip),%eax
1:  testl $1,%eax
    jnz 2f
    decl %eax
2:  movl %eax,defwinN(%rip)
    movl %eax,vwin(%rip)
    movl %eax,vwin+4(%rip)
    movl %eax,vwin+8(%rip)
    movl %eax,vwin+12(%rip)
    movl $29,%eax
    cmpl N(%rip),%eax
    jbe 3f
    movl N(%rip),%eax
3:  testl $1,%eax
    jnz 4f
    decl %eax
4:  movl %eax,maxwinN(%rip)
    movl N(%rip),%eax          /* 2D window: max = odd(2N-1) cap 401 */
    leal -1(%rax,%rax),%eax
    cmpl $401,%eax
    jbe 5f
    movl $401,%eax
5:  movl %eax,w2max(%rip)
    cmpl $41,%eax              /* default = min(41, w2max) */
    jbe 6f
    movl $41,%eax
6:  movl %eax,w2def(%rip)
    movl %eax,w2win(%rip)
    movb $21,vyaw(%rip)
    movb $21,vyaw+1(%rip)
    movb $21,vyaw+2(%rip)
    movb $21,vyaw+3(%rip)
    movb $242,vpit(%rip)
    movb $242,vpit+1(%rip)
    movb $242,vpit+2(%rip)
    movb $242,vpit+3(%rip)
    movl $0,actv(%rip)
    call gen_maze
    jmp game_redraw

/* ---------------- maze generator (iterative DFS) ----------------
 * Fill the volume with walls, then carve a PERFECT maze over the rooms at
 * all-even coordinates with a depth-first backtracker.  The DFS stack is
 * the maze itself: entering a room stores 0x40|(came_from<<1) in its voxel
 * byte (start room = 0x50 sentinel), backtracking reads the mark, clears
 * it, and returns; carving opens the wall voxel between the two rooms.
 * A progress bar tracks gdone/cells.  Afterwards: for even N a staircase
 * corridor connects the last room to the exit corner, and an optional
 * sparse pass (rmwalls > 0) removes random walls - see gdon below. */
gen_maze:
    pushq %rbx
    pushq %rbp
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    call clear_fb
    movl $16,curx(%rip)
    movl $16,cury(%rip)
    movl $ID_ACC,colr(%rip)
    leaq s_gen(%rip),%rsi
    call draw_str
    movl N(%rip),%eax
    call draw_dec
    movl $16,barx(%rip)
    movl fbw(%rip),%eax
    subl $32,%eax
    movl %eax,barw(%rip)
    movl fbh(%rip),%eax
    shrl $1,%eax
    movl %eax,bary(%rip)
    movl $8,barh(%rip)
    movl barx(%rip),%edi
    subl $2,%edi
    movl bary(%rip),%esi
    subl $2,%esi
    movl barw(%rip),%edx
    addl $4,%edx
    movl barh(%rip),%ecx
    addl $4,%ecx
    movl $ID_BORD,%r8d
    call fill_rect
    movl barx(%rip),%edi
    movl bary(%rip),%esi
    movl barw(%rip),%edx
    movl barh(%rip),%ecx
    movl $ID_BG,%r8d
    call fill_rect
    movq mazeb(%rip),%rdi      /* fill all with walls */
    movq total(%rip),%rcx
    movq %rcx,%rdx
    shrq $3,%rcx
    movabsq $0x0101010101010101,%rax
    rep stosq
    movq %rdx,%rcx
    andl $7,%ecx
    rep stosb
    movl $0,gcur(%rip)
    movl $0,gcur+4(%rip)
    movl $0,gcur+8(%rip)
    movl $0,gcur+12(%rip)
    leaq gcur(%rip),%rsi
    call vox_addr_v
    movq %rax,%rbx
    movb $0x50,(%rbx)          /* start sentinel (bit4) */
    movq $1,gdone(%rip)
genl:
    xorl %r15d,%r15d           /* candidate count */
    xorl %r13d,%r13d           /* dir */
gcand:
    movl %r13d,%eax
    shrl $1,%eax
    leaq gcur(%rip),%rdx
    movl (%rdx,%rax,4),%edx
    movl %r13d,%eax
    andl $1,%eax
    leaq dsgn2(%rip),%rcx
    addl (%rcx,%rax,4),%edx
    testl %edx,%edx
    js gskip
    cmpl maxc(%rip),%edx
    jg gskip
    leaq sdtab(%rip),%rax
    movq (%rax,%r13,8),%rax
    leaq (%rbx,%rax,2),%rcx
    cmpb $1,(%rcx)             /* unvisited cell? */
    jne gskip
    leaq cand(%rip),%rax
    movb %r13b,(%rax,%r15)
    incl %r15d
gskip:
    incl %r13d
    cmpl $8,%r13d
    jb gcand
    testl %r15d,%r15d
    jz gback
    movl %r15d,%edi
    call rng_below
    leaq cand(%rip),%rcx
    movzbl (%rcx,%rax),%r13d
    leaq sdtab(%rip),%rax      /* carve wall, step to neighbor */
    movq (%rax,%r13,8),%rdx
    movb $0,(%rbx,%rdx)
    leaq (%rbx,%rdx,2),%rbx
    movl %r13d,%eax
    xorl $1,%eax
    addl %eax,%eax
    orl $0x40,%eax             /* came-from dir in bits 1-3 */
    movb %al,(%rbx)
    movl %r13d,%eax
    andl $1,%eax
    leaq dsgn2(%rip),%rcx
    movl (%rcx,%rax,4),%edx
    movl %r13d,%eax
    shrl $1,%eax
    leaq gcur(%rip),%rcx
    addl %edx,(%rcx,%rax,4)
    incq gdone(%rip)
    movq gdone(%rip),%rax
    testl $0xFFF,%eax
    jnz genl
    movslq barw(%rip),%rcx     /* progress bar */
    mulq %rcx
    divq cells(%rip)
    movl %eax,%edx
    movl barx(%rip),%edi
    movl bary(%rip),%esi
    movl barh(%rip),%ecx
    movl $ID_BAR,%r8d
    call fill_rect
    jmp genl
gback:
    movzbl (%rbx),%eax
    movb $0,(%rbx)             /* leave cell open */
    testb $0x10,%al
    jnz gdon
    shrl $1,%eax
    andl $7,%eax
    movl %eax,%r13d
    movl %r13d,%eax
    andl $1,%eax
    leaq dsgn2(%rip),%rcx
    movl (%rcx,%rax,4),%edx
    movl %r13d,%eax
    shrl $1,%eax
    leaq gcur(%rip),%rcx
    addl %edx,(%rcx,%rax,4)
    leaq sdtab(%rip),%rax
    movq (%rax,%r13,8),%rdx
    leaq (%rbx,%rdx,2),%rbx
    jmp genl
gdon:
    /* Even N: the exit corner (N-1,...) lies one voxel beyond the last
     * room layer (maxc = N-2).  Carve a staircase corridor from room
     * (maxc,maxc,maxc,maxc) to the exit, bumping one axis at a time to
     * N-1 and opening the voxel after each step.  Still a perfect maze:
     * a tree plus one attached dead-end path.  (Odd N: maxc = N-1, the
     * exit corner already is a room - nothing to do.) */
    movl maxc(%rip),%eax
    incl %eax
    cmpl N(%rip),%eax
    je gnost
    movl maxc(%rip),%eax
    movl %eax,gcur(%rip)
    movl %eax,gcur+4(%rip)
    movl %eax,gcur+8(%rip)
    movl %eax,gcur+12(%rip)
    xorl %r13d,%r13d
gst_l:
    leaq gcur(%rip),%rax
    incl (%rax,%r13,4)         /* coord[axis] = N-1 */
    leaq gcur(%rip),%rsi
    call vox_addr_v
    movb $0,(%rax)
    incl %r13d
    cmpl $4,%r13d
    jb gst_l
gnost:
    movq rmwalls(%rip),%r14    /* sparse: remove R random walls */
    testq %r14,%r14
    jz grt
    movl $16,curx(%rip)        /* status line under the bar */
    movl bary(%rip),%eax
    addl $20,%eax
    movl %eax,cury(%rip)
    movl $ID_TXT,colr(%rip)
    leaq s_rmw(%rip),%rsi
    call draw_str
    movl barx(%rip),%edi       /* reset the bar for removal progress */
    movl bary(%rip),%esi
    movl barw(%rip),%edx
    movl barh(%rip),%ecx
    movl $ID_BG,%r8d
    call fill_rect
/* Sequential random sampling over a single linear scan of all N^4 voxel
 * bytes: every still-full voxel (byte==1) is a candidate; rem starts at
 * maxrm (the exact number of full voxels, see menu_walls) and an unbroken
 * wall is removed with probability need/rem, which picks every possible
 * subset of `need` walls with equal probability.  The bar refills with
 * scan progress (updated every ~1M voxels). */
    movq maxrm(%rip),%r15      /* rem = full voxels left to consider */
    testq %r15,%r15
    jz grt
    cmpq %r15,%r14             /* safety clamp: need <= rem */
    jbe 1f
    movq %r15,%r14
1:  movq mazeb(%rip),%rbx
    movq total(%rip),%rbp
rml:
    cmpb $1,(%rbx)             /* still a wall? */
    jne rmn
    call rng_next              /* 64-bit random % rem */
    movl %eax,%r9d
    call rng_next
    shlq $32,%r9
    movl %eax,%eax
    orq %r9,%rax
    xorl %edx,%edx
    divq %r15
    cmpq %r14,%rdx             /* rdx < need: remove this wall */
    jae rmk
    movb $0,(%rbx)
    decq %r14
    jz grt                     /* removed all requested */
rmk:
    decq %r15                  /* one fewer candidate left */
rmn:
    incq %rbx
    decq %rbp
    jz grt
    testl $0xFFFFF,%ebp        /* progress bar every ~1M voxels */
    jnz rml
    movq total(%rip),%rax
    subq %rbp,%rax             /* voxels scanned so far */
    movslq barw(%rip),%rcx
    mulq %rcx
    divq total(%rip)
    movl %eax,%edx
    movl barx(%rip),%edi
    movl bary(%rip),%esi
    movl barh(%rip),%ecx
    movl $ID_BAR,%r8d
    call fill_rect
    jmp rml
grt:
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbp
    popq %rbx
    ret

/* ---------------- game loop ----------------
 * getkey scancodes -> actions:
 *   ESC menu | arrows +-X/+-Y | W/S +-Z | A/K +-W | TAB 3D/2D mode
 *   1-4 active 3D view | J/L yaw | I/M pitch | U/O zoom | R reset views
 *   X random move | H hint move (find_opt) | B best move (find_best) */
game_redraw:
    call draw_all
game_key:
    call getkey
    cmpb $0x01,%al             /* ESC */
    je menu
    xorl %edi,%edi
    cmpb $0x4D,%al             /* right: +x */
    je domv
    movl $1,%edi
    cmpb $0x4B,%al             /* left: -x */
    je domv
    movl $2,%edi
    cmpb $0x50,%al             /* down: +y */
    je domv
    movl $3,%edi
    cmpb $0x48,%al             /* up: -y */
    je domv
    movl $4,%edi
    cmpb $0x11,%al             /* W: +z */
    je domv
    movl $5,%edi
    cmpb $0x1F,%al             /* S: -z */
    je domv
    movl $6,%edi
    cmpb $0x1E,%al             /* A: +w ata */
    je domv
    movl $7,%edi
    cmpb $0x25,%al             /* K: -w kata */
    je domv
    cmpb $0x0F,%al             /* TAB: toggle 3D/2D projections */
    jne 0f
    xorl $1,viewmode(%rip)
    jmp game_redraw
0:  cmpb $0x02,%al             /* 1-4: select view */
    jb 1f
    cmpb $0x05,%al
    ja 1f
    movzbl %al,%eax
    subl $2,%eax
    movl %eax,actv(%rip)
    jmp game_redraw
1:  movl actv(%rip),%ecx
    cmpb $0x24,%al             /* J: yaw- */
    jne 2f
    leaq vyaw(%rip),%rdx
    subb $8,(%rdx,%rcx)
    jmp game_redraw
2:  cmpb $0x26,%al             /* L: yaw+ */
    jne 3f
    leaq vyaw(%rip),%rdx
    addb $8,(%rdx,%rcx)
    jmp game_redraw
3:  cmpb $0x17,%al             /* I: pitch- */
    jne 4f
    leaq vpit(%rip),%rdx
    subb $8,(%rdx,%rcx)
    jmp game_redraw
4:  cmpb $0x32,%al             /* M: pitch+ */
    jne 5f
    leaq vpit(%rip),%rdx
    addb $8,(%rdx,%rcx)
    jmp game_redraw
5:  cmpb $0x16,%al             /* U: zoom in */
    jne 6f
    cmpl $0,viewmode(%rip)
    jne 51f
    leaq vwin(%rip),%rdx
    movl (%rdx,%rcx,4),%eax
    subl $2,%eax
    cmpl $3,%eax
    jge 55f
    movl $3,%eax
55: movl %eax,(%rdx,%rcx,4)
    jmp game_redraw
51: movl w2win(%rip),%eax      /* 2D zoom in */
    subl $2,%eax
    cmpl $3,%eax
    jge 52f
    movl $3,%eax
52: movl %eax,w2win(%rip)
    jmp game_redraw
6:  cmpb $0x18,%al             /* O: zoom out */
    jne 7f
    cmpl $0,viewmode(%rip)
    jne 61f
    leaq vwin(%rip),%rdx
    movl (%rdx,%rcx,4),%eax
    addl $2,%eax
    cmpl maxwinN(%rip),%eax
    jle 66f
    movl maxwinN(%rip),%eax
66: movl %eax,(%rdx,%rcx,4)
    jmp game_redraw
61: movl w2win(%rip),%eax      /* 2D zoom out */
    addl $2,%eax
    cmpl w2max(%rip),%eax
    jle 62f
    movl w2max(%rip),%eax
62: movl %eax,w2win(%rip)
    jmp game_redraw
7:  cmpb $0x13,%al             /* R: reset views */
    jne 8f
    movl defwinN(%rip),%eax
    movl %eax,vwin(%rip)
    movl %eax,vwin+4(%rip)
    movl %eax,vwin+8(%rip)
    movl %eax,vwin+12(%rip)
    movl w2def(%rip),%eax
    movl %eax,w2win(%rip)
    movb $21,vyaw(%rip)
    movb $21,vyaw+1(%rip)
    movb $21,vyaw+2(%rip)
    movb $21,vyaw+3(%rip)
    movb $242,vpit(%rip)
    movb $242,vpit+1(%rip)
    movb $242,vpit+2(%rip)
    movb $242,vpit+3(%rip)
    jmp game_redraw
8:  cmpb $0x2D,%al             /* X: random move */
    je rnd_move
    cmpb $0x23,%al             /* H: assisted move (DFS path) */
    jne 9f
    call find_opt
    jmp doassist
9:  cmpb $0x30,%al             /* B: best move (true shortest, BFS) */
    jne game_key
    call find_best
doassist:
    testl %eax,%eax
    js game_redraw
    movl %eax,%edi
domv:
    call try_move
    jmp game_redraw

/* try_move: edi = dir 0..7.  Bounds-check the destination (unsigned cmp
 * catches -1), reject walls, commit the move, count it, and jump to the
 * win screen (dropping our return address) when the exit is reached. */
try_move:
    movl %edi,%eax
    shrl $1,%eax               /* axis */
    movl %edi,%ecx
    andl $1,%ecx
    leaq dsgn1(%rip),%rdx
    movl (%rdx,%rcx,4),%ecx    /* delta */
    movq pcoord(%rip),%rdx
    movq %rdx,tvec(%rip)
    movq pcoord+8(%rip),%rdx
    movq %rdx,tvec+8(%rip)
    leaq tvec(%rip),%rdx
    addl (%rdx,%rax,4),%ecx
    cmpl N(%rip),%ecx          /* unsigned: catches -1 too */
    jae tm_no
    movl %ecx,(%rdx,%rax,4)
    movq %rdx,%rsi
    call vox_addr_v
    testb $1,(%rax)
    jnz tm_no
    movq tvec(%rip),%rdx
    movq %rdx,pcoord(%rip)
    movq tvec+8(%rip),%rdx
    movq %rdx,pcoord+8(%rip)
    incq moves(%rip)
    movq pcoord(%rip),%rdx
    cmpq ecoord(%rip),%rdx
    jne tm_no
    movq pcoord+8(%rip),%rdx
    cmpq ecoord+8(%rip),%rdx
    jne tm_no
    addq $8,%rsp               /* drop return: we won */
    jmp win_scr
tm_no:
    ret

/* random move: pick uniformly among the open neighbor voxels */
rnd_move:
    leaq pcoord(%rip),%rsi
    call vox_addr_v
    movq %rax,%rbp             /* player voxel addr */
    xorl %ebx,%ebx             /* candidate count */
    xorl %r13d,%r13d           /* dir */
rm_c:
    movl %r13d,%eax
    shrl $1,%eax               /* axis */
    movl %r13d,%ecx
    andl $1,%ecx
    leaq dsgn1(%rip),%rdx
    movl (%rdx,%rcx,4),%ecx
    leaq pcoord(%rip),%rdx
    addl (%rdx,%rax,4),%ecx
    cmpl N(%rip),%ecx          /* unsigned: catches -1 too */
    jae rm_s
    leaq sdtab(%rip),%rdx
    movq (%rdx,%r13,8),%rdx
    testb $1,(%rbp,%rdx)       /* wall? */
    jnz rm_s
    leaq cand(%rip),%rax
    movb %r13b,(%rax,%rbx)
    incl %ebx
rm_s:
    incl %r13d
    cmpl $8,%r13d
    jb rm_c
    testl %ebx,%ebx
    jz game_redraw
    movl %ebx,%edi
    call rng_below
    leaq cand(%rip),%rcx
    movzbl (%rcx,%rax),%edi
    jmp domv

/* assisted move: DFS from exit to player over open voxels.
 * Visited voxels keep 0x40|(camefrom<<1) permanently during the search, so
 * each voxel is entered at most once and the run time is linear even when
 * the maze has cycles (sparse mazes).  The came-from chain of the first
 * discovery is a simple path to the exit: on a perfect maze it is THE unique
 * (shortest) path; on a sparse maze it is a valid, converging (depth in the
 * fixed DFS spanning tree strictly decreases every press) but possibly
 * sub-optimal path.  All marks are wiped by sweep_marks before returning.
 * Returns eax = dir 0..7 for the player, -1 if unreachable (impossible). */
find_opt:
    pushq %rbx
    pushq %rbp
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    movq ecoord(%rip),%rax     /* hvec = exit */
    movq %rax,hvec(%rip)
    movq ecoord+8(%rip),%rax
    movq %rax,hvec+8(%rip)
    leaq pcoord(%rip),%rsi
    call vox_addr_v
    movq %rax,%r15             /* player voxel addr */
    leaq hvec(%rip),%rsi
    call vox_addr_v
    movq %rax,%rbp             /* cur voxel addr */
    cmpq %r15,%rbp
    je fo_fail                 /* already at exit */
    movb $0x50,(%rbp)          /* exit sentinel (bit4) */
    xorl %r13d,%r13d           /* dir scan index */
fo_scan:
    cmpl $8,%r13d
    jae fo_back
    movl %r13d,%eax
    shrl $1,%eax               /* axis */
    movl %r13d,%ecx
    andl $1,%ecx
    leaq dsgn1(%rip),%rdx
    movl (%rdx,%rcx,4),%ebx    /* delta */
    leaq hvec(%rip),%rdx
    movl (%rdx,%rax,4),%ecx
    addl %ebx,%ecx
    cmpl N(%rip),%ecx          /* unsigned bounds */
    jae fo_next
    leaq sdtab(%rip),%rdx
    movq (%rdx,%r13,8),%r12
    cmpb $0,(%rbp,%r12)        /* open and unvisited? */
    jne fo_next
    leaq hvec(%rip),%rdx       /* step forward */
    movl %ecx,(%rdx,%rax,4)
    addq %r12,%rbp
    movl %r13d,%ecx            /* mark: came-from = dir^1 */
    xorl $1,%ecx
    addl %ecx,%ecx
    orl $0x40,%ecx
    movb %cl,(%rbp)
    cmpq %r15,%rbp
    je fo_found
    xorl %r13d,%r13d           /* fresh voxel: scan from 0 */
    jmp fo_scan
fo_next:
    incl %r13d
    jmp fo_scan
fo_back:
    movzbl (%rbp),%eax
    testb $0x10,%al            /* back at exit: exhausted */
    jnz fo_fail
    shrl $1,%eax               /* mark stays (visited forever) */
    andl $7,%eax
    movl %eax,%r13d            /* d = came-from (cur -> parent) */
    movl %eax,%ecx
    andl $1,%ecx
    leaq dsgn1(%rip),%rdx
    movl (%rdx,%rcx,4),%ebx
    movl %r13d,%eax
    shrl $1,%eax
    leaq hvec(%rip),%rdx
    addl %ebx,(%rdx,%rax,4)
    leaq sdtab(%rip),%rdx
    movq (%rdx,%r13,8),%r12
    addq %r12,%rbp             /* cur = parent */
    movl %r13d,%eax            /* resume past the dir we came down */
    xorl $1,%eax
    leal 1(%rax),%r13d
    jmp fo_scan
fo_found:
    movzbl (%rbp),%eax         /* answer = player's came-from dir */
    shrl $1,%eax
    andl $7,%eax
    movl %eax,%r14d
    call sweep_marks           /* restore maze to walls/open only */
    jmp fo_ret
fo_fail:
    call sweep_marks
    movl $-1,%r14d
fo_ret:
    movl %r14d,%eax
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbp
    popq %rbx
    ret

/* clear every non-wall bit in the whole maze volume (removes all search
 * marks left by find_opt / find_best).  8 bytes at a time. */
sweep_marks:
    movq mazeb(%rip),%rdi
    movq total(%rip),%rcx
    movq %rcx,%rdx
    shrq $3,%rcx
    movabsq $0x0101010101010101,%rax
    testq %rcx,%rcx
    jz 2f
1:  andq %rax,(%rdi)
    addq $8,%rdi
    decq %rcx
    jnz 1b
2:  andl $7,%edx
    jz 4f
3:  andb $1,(%rdi)
    incq %rdi
    decl %edx
    jnz 3b
4:  ret

/* best move: true shortest next step via breadth-first search from the exit.
 * The BFS wave queues live in the spare memory of the maze's E820 region
 * (after the N^4 maze bytes): entry = voxel addr (8) + 4 packed u16 coords
 * (8).  Parent directions are stored in the voxel bytes exactly like
 * find_opt, so the player's mark is the next hop of a genuine shortest path.
 * If the spare memory is too small (or a wave overflows it), falls back to
 * find_opt.  All marks are swept before returning.
 * Returns eax = dir 0..7, -1 if unreachable (impossible). */
find_best:
    pushq %rbx
    pushq %rbp
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    movq mazeb(%rip),%rax      /* wave buffers = region slack */
    addq total(%rip),%rax
    addq $15,%rax
    andq $-16,%rax
    movq %rax,wvA(%rip)
    movq mazeb(%rip),%rdx
    addq mazesz(%rip),%rdx     /* region end */
    subq %rax,%rdx             /* slack bytes */
    jle fb_nobuf
    shrq $1,%rdx
    andq $-16,%rdx             /* bytes per half */
    cmpq $64,%rdx
    jb fb_nobuf
    movq %rdx,wvcap(%rip)
    addq wvA(%rip),%rdx
    movq %rdx,wvB(%rip)
    leaq pcoord(%rip),%rsi
    call vox_addr_v
    movq %rax,%r15             /* player voxel addr */
    leaq ecoord(%rip),%rsi
    call vox_addr_v
    cmpq %r15,%rax
    je fb_fail
    movb $0x50,(%rax)          /* exit sentinel */
    movq wvA(%rip),%rdi        /* seed wave = exit */
    movq %rax,(%rdi)
    movl N(%rip),%eax
    decl %eax                  /* exit coords = N-1 on every axis */
    movw %ax,8(%rdi)
    movw %ax,10(%rdi)
    movw %ax,12(%rdi)
    movw %ax,14(%rdi)
    movq $1,wcur(%rip)
    movq $0,wnxt(%rip)
fb_wave:
    xorl %r13d,%r13d           /* entry index in current wave */
fb_ent:
    cmpq wcur(%rip),%r13
    jae fb_wdone
    movq %r13,%rdx
    shlq $4,%rdx
    addq wvA(%rip),%rdx
    movq (%rdx),%rbp           /* voxel addr */
    movq 8(%rdx),%r12          /* packed coords 4 x u16 */
    xorl %ebx,%ebx             /* dir */
fb_dir:
    cmpl $8,%ebx
    jae fb_edone
    movl %ebx,%ecx
    shrl $1,%ecx               /* axis */
    shll $4,%ecx               /* field shift */
    movq %r12,%rdx
    shrq %cl,%rdx
    movzwl %dx,%edx            /* coord on that axis */
    movl %ebx,%eax
    andl $1,%eax
    leaq dsgn1(%rip),%rsi
    addl (%rsi,%rax,4),%edx    /* new coord */
    cmpl N(%rip),%edx
    jae fb_nd                  /* out of bounds (unsigned) */
    leaq sdtab(%rip),%rax
    movq (%rax,%rbx,8),%rdi
    addq %rbp,%rdi             /* neighbor addr */
    cmpb $0,(%rdi)
    jne fb_nd                  /* wall or already visited */
    movl %ebx,%eax             /* mark: came-from = dir^1 */
    xorl $1,%eax
    leal (%rax,%rax),%eax
    orl $0x40,%eax
    movb %al,(%rdi)
    cmpq %r15,%rdi
    je fb_found
    movq wnxt(%rip),%rax       /* push to next wave */
    leaq 1(%rax),%rsi
    shlq $4,%rsi
    cmpq wvcap(%rip),%rsi
    ja fb_overflow
    shlq $4,%rax
    addq wvB(%rip),%rax
    movq %rdi,(%rax)
    movq $0xFFFF,%r9           /* replace the axis field in coords */
    shlq %cl,%r9
    notq %r9
    movq %r12,%r10
    andq %r9,%r10
    movq %rdx,%r9
    shlq %cl,%r9
    orq %r9,%r10
    movq %r10,8(%rax)
    incq wnxt(%rip)
fb_nd:
    incl %ebx
    jmp fb_dir
fb_edone:
    incq %r13
    jmp fb_ent
fb_wdone:
    movq wnxt(%rip),%rax
    testq %rax,%rax
    jz fb_fail                 /* frontier died: unreachable */
    movq %rax,wcur(%rip)
    movq $0,wnxt(%rip)
    movq wvA(%rip),%rax        /* swap wave buffers */
    movq wvB(%rip),%rdx
    movq %rdx,wvA(%rip)
    movq %rax,wvB(%rip)
    jmp fb_wave
fb_found:
    movzbl (%rdi),%eax         /* answer = player's came-from dir */
    shrl $1,%eax
    andl $7,%eax
    movl %eax,%r14d
    call sweep_marks
    movl %r14d,%eax
    jmp fb_ret
fb_fail:
    call sweep_marks
    movl $-1,%eax
fb_ret:
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbp
    popq %rbx
    ret
fb_overflow:
    call sweep_marks           /* wave didn't fit: clean up, use DFS */
fb_nobuf:
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbp
    popq %rbx
    jmp find_opt

/* win screen: reached by try_move when pcoord == ecoord.  Shows the move
 * count (the score) and returns to the menu on any key. */
win_scr:
    call clear_fb
    movl $16,curx(%rip)
    movl fbh(%rip),%eax
    shrl $2,%eax
    movl %eax,cury(%rip)
    movl $ID_ACC,colr(%rip)
    leaq s_w1(%rip),%rsi
    call draw_str
    call menu_nl
    call menu_nl
    movl $ID_TXT,colr(%rip)
    leaq s_w2(%rip),%rsi
    call draw_str
    movq moves(%rip),%rax
    call draw_dec
    call menu_nl
    leaq s_wn(%rip),%rsi
    call draw_str
    movl N(%rip),%eax
    call draw_dec
    call menu_nl
    call menu_nl
    movl $ID_DIM,colr(%rip)
    leaq s_w3(%rip),%rsi
    call draw_str
    call getkey
    jmp menu

/* ---------------- renderer ---------------- */
draw_all:
    pushq %rbx
    call clear_fb
    movl $16,curx(%rip)
    movl $4,cury(%rip)
    movl $ID_TXT,colr(%rip)
    leaq s_hmov(%rip),%rsi
    call draw_str
    movq moves(%rip),%rax
    call draw_dec
    leaq s_hn(%rip),%rsi
    call draw_str
    movl N(%rip),%eax
    call draw_dec
    leaq s_hv(%rip),%rsi
    call draw_str
    movl actv(%rip),%eax
    incl %eax
    call draw_dec
    call menu_nl
    leaq s_hpos(%rip),%rsi
    call draw_str
    leaq pcoord(%rip),%rsi
    call draw_vec4
    leaq s_hend(%rip),%rsi
    call draw_str
    leaq ecoord(%rip),%rsi
    call draw_vec4
    movl ts(%rip),%eax         /* legend+labels at small scale */
    movl %eax,tsav(%rip)
    movl tsl(%rip),%eax
    movl %eax,ts(%rip)
    movl legy(%rip),%eax
    movl %eax,cury(%rip)
    movl $16,curx(%rip)
    movl $ID_DIM,colr(%rip)
    leaq s_l1(%rip),%rsi
    call draw_str
    call menu_nl
    leaq s_l2(%rip),%rsi
    call draw_str
    call menu_nl
    leaq s_l3(%rip),%rsi
    call draw_str
    movl $0,cvi(%rip)
    cmpl $0,viewmode(%rip)
    jne d2_v
da_v:
    movl cvi(%rip),%ebx
    movl vx0g(%rip),%eax
    testl $1,%ebx
    jz 1f
    movl vx1g(%rip),%eax
1:  movl %eax,m_x0(%rip)
    movl vy0(%rip),%eax
    movl yl0(%rip),%edx
    cmpl $2,%ebx
    jb 2f
    movl vy1(%rip),%eax
    movl yl1(%rip),%edx
2:  movl %eax,m_y0(%rip)
    movl m_x0(%rip),%eax
    movl %eax,curx(%rip)
    movl %edx,cury(%rip)
    movl $ID_DIM,colr(%rip)
    cmpl actv(%rip),%ebx
    jne 3f
    movl $ID_ACC,colr(%rip)
3:  leaq s_vlab(%rip),%rsi
    movl %ebx,%eax
    shll $2,%eax
    addq %rax,%rsi
    call draw_str
    cmpl actv(%rip),%ebx
    jne 4f
    leaq s_act(%rip),%rsi
    call draw_str
4:  movl $ID_BORD,%eax
    cmpl actv(%rip),%ebx
    jne 5f
    movl $ID_ACC,%eax
5:  movl %eax,m_bc(%rip)
    movl qside(%rip),%eax
    movl %eax,brd(%rip)
    call draw_border
    call draw_view
    incl cvi(%rip)
    cmpl $4,cvi(%rip)
    jb da_v
da_done:
    movl tsav(%rip),%eax       /* restore big text scale */
    movl %eax,ts(%rip)
    popq %rbx
    ret

/* 2D mode: 6 panels XY XZ XW YZ YW ZW in 3x2 grid */
d2_v:
    movl cvi(%rip),%ebx
    movl %ebx,%ecx             /* col = cvi%3, row = cvi/3 */
    xorl %edx,%edx
    cmpl $3,%ecx
    jb 1f
    subl $3,%ecx
    movl $1,%edx
1:  leaq v2x0(%rip),%rax
    movl (%rax,%rcx,4),%eax
    movl %eax,m_x0(%rip)
    movl v2y0(%rip),%eax
    movl y2l0(%rip),%ecx
    testl %edx,%edx
    jz 2f
    movl v2y1(%rip),%eax
    movl y2l1(%rip),%ecx
2:  movl %eax,m_y0(%rip)
    movl m_x0(%rip),%eax
    movl %eax,curx(%rip)
    movl %ecx,cury(%rip)
    movl $ID_DIM,colr(%rip)
    leaq s_vlab2(%rip),%rsi
    leal (%rbx,%rbx,2),%eax
    addq %rax,%rsi
    call draw_str
    movl $ID_BORD,%eax
    movl %eax,m_bc(%rip)
    movl s2side(%rip),%eax
    movl %eax,brd(%rip)
    call draw_border
    call draw_view2
    incl cvi(%rip)
    cmpl $6,cvi(%rip)
    jb d2_v
    jmp da_done

/* frame around (m_x0-2,m_y0-2), inner side brd, thickness 2, color m_bc */
draw_border:
    movl m_x0(%rip),%edi
    subl $2,%edi
    movl m_y0(%rip),%esi
    subl $2,%esi
    movl brd(%rip),%edx
    addl $4,%edx
    movl $2,%ecx
    movl m_bc(%rip),%r8d
    call fill_rect
    movl m_x0(%rip),%edi
    subl $2,%edi
    movl m_y0(%rip),%esi
    addl brd(%rip),%esi
    movl brd(%rip),%edx
    addl $4,%edx
    movl $2,%ecx
    movl m_bc(%rip),%r8d
    call fill_rect
    movl m_x0(%rip),%edi
    subl $2,%edi
    movl m_y0(%rip),%esi
    movl $2,%edx
    movl brd(%rip),%ecx
    movl m_bc(%rip),%r8d
    call fill_rect
    movl m_x0(%rip),%edi
    addl brd(%rip),%edi
    movl m_y0(%rip),%esi
    movl $2,%edx
    movl brd(%rip),%ecx
    movl m_bc(%rip),%r8d
    jmp fill_rect

/* one 3D view: axes from axtab, angles/window per view */
draw_view:
    pushq %rbx
    pushq %rbp
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    movl cvi(%rip),%eax
    leaq axtab(%rip),%rcx
    movzbl (%rcx,%rax,4),%edx
    movl %edx,m_ax(%rip)
    movzbl 1(%rcx,%rax,4),%edx
    movl %edx,m_ax+4(%rip)
    movzbl 2(%rcx,%rax,4),%edx
    movl %edx,m_ax+8(%rip)
    movzbl 3(%rcx,%rax,4),%edx
    movl %edx,m_ax+12(%rip)
    leaq vyaw(%rip),%rcx
    movzbl (%rcx,%rax),%edi
    movl %edi,%r12d
    call sinv
    movl %eax,m_sy(%rip)
    leal 64(%r12d),%edi
    call sinv
    movl %eax,m_cy(%rip)
    movl cvi(%rip),%eax
    leaq vpit(%rip),%rcx
    movzbl (%rcx,%rax),%edi
    movl %edi,%r12d
    call sinv
    movl %eax,m_sp(%rip)
    leal 64(%r12d),%edi
    call sinv
    movl %eax,m_cp(%rip)
    movl cvi(%rip),%eax
    leaq vwin(%rip),%rcx
    movl (%rcx,%rax,4),%eax
    movl %eax,m_v(%rip)
    shrl $1,%eax
    movl %eax,m_h(%rip)
    movl qside(%rip),%eax      /* pp = Q*45/(64*V) */
    imull $45,%eax
    movl m_v(%rip),%ecx
    shll $6,%ecx
    xorl %edx,%edx
    divl %ecx
    testl %eax,%eax
    jnz 1f
    movl $1,%eax
1:  movl %eax,m_pp(%rip)
    movl qside(%rip),%edx
    shrl $1,%edx
    movl m_x0(%rip),%eax
    addl %edx,%eax
    movl %eax,m_cx(%rip)
    movl m_y0(%rip),%eax
    addl %edx,%eax
    movl %eax,m_cy2(%rip)
    movl m_h(%rip),%eax        /* depth band scale */
    imull $28400,%eax
    movslq %eax,%rax
    movq %rax,m_zbias(%rip)
    leaq 1(%rax,%rax),%rax
    movq %rax,m_zdiv(%rip)
    movl m_pp(%rip),%eax       /* dot sizes per band */
    shrl $1,%eax
    xorl %ecx,%ecx
2:  movl %eax,%edx
    subl %ecx,%edx
    cmpl $1,%edx
    jge 3f
    movl $1,%edx
3:  leaq m_dsz(%rip),%rdi
    movb %dl,(%rdi,%rcx)
    incl %ecx
    cmpl $4,%ecx
    jb 2b
    movl m_pp(%rip),%eax
    xorl %edx,%edx
    movl $3,%ecx
    divl %ecx
    testl %eax,%eax
    jnz 4f
    movl $1,%eax
4:  movl %eax,m_asz(%rip)
    movl m_pp(%rip),%eax
    incl %eax
    cmpl $3,%eax
    jge 5f
    movl $3,%eax
5:  movl %eax,m_msz(%rip)
    movl m_ax(%rip),%eax       /* strides for the 3 view axes */
    leaq stride(%rip),%rcx
    movq (%rcx,%rax,8),%rdx
    movq %rdx,m_sA(%rip)
    movl m_ax+4(%rip),%eax
    movq (%rcx,%rax,8),%rdx
    movq %rdx,m_sB(%rip)
    movl m_ax+8(%rip),%eax
    movq (%rcx,%rax,8),%rdx
    movq %rdx,m_sC(%rip)
    xorl %ecx,%ecx             /* clip ranges per view axis */
rg2:
    leaq m_ax(%rip),%rax
    movl (%rax,%rcx,4),%eax
    leaq pcoord(%rip),%rdx
    movl (%rdx,%rax,4),%edx
    movl m_h(%rip),%eax
    movl %eax,%edi
    negl %edi
    movl %edx,%esi
    negl %esi
    cmpl %esi,%edi
    jge 1f
    movl %esi,%edi
1:  leaq m_lo(%rip),%rsi
    movl %edi,(%rsi,%rcx,4)
    movl N(%rip),%edi
    decl %edi
    subl %edx,%edi
    cmpl %eax,%edi
    jle 2f
    movl %eax,%edi
2:  leaq m_hi(%rip),%rsi
    movl %edi,(%rsi,%rcx,4)
    incl %ecx
    cmpl $3,%ecx
    jb rg2
    leaq pcoord(%rip),%rsi
    call vox_addr_v
    movq %rax,m_pa(%rip)
    xorl %r12d,%r12d           /* axis gizmo */
gz_k:
    movl $1,%r13d
gz_t:
    cmpl m_h(%rip),%r13d
    jg gz_n
    xorl %ecx,%ecx
    xorl %edx,%edx
    xorl %ebx,%ebx
    movslq %r13d,%rax
    testl %r12d,%r12d
    jnz 1f
    movq %rax,%rcx
    jmp 3f
1:  cmpl $1,%r12d
    jne 2f
    movq %rax,%rdx
    jmp 3f
2:  movq %rax,%rbx
3:  call xform
    leaq m_ax(%rip),%rdx
    movl (%rdx,%r12,4),%edx
    leal ID_AX(%rdx),%r8d
    movl m_asz(%rip),%edx
    call dot_draw
    incl %r13d
    jmp gz_t
gz_n:
    incl %r12d
    cmpl $3,%r12d
    jb gz_k
    movl m_lo(%rip),%r12d      /* voxel dots */
vlA:
    cmpl m_hi(%rip),%r12d
    jg vmark
    movslq %r12d,%rax
    imulq m_sA(%rip),%rax
    addq m_pa(%rip),%rax
    movq %rax,m_aA(%rip)
    movl m_lo+4(%rip),%r13d
vlB:
    cmpl m_hi+4(%rip),%r13d
    jg vBe
    movslq %r13d,%rax
    imulq m_sB(%rip),%rax
    addq m_aA(%rip),%rax
    movq %rax,%r15
    movl m_lo+8(%rip),%r14d
    movslq %r14d,%rax
    imulq m_sC(%rip),%rax
    leaq (%r15,%rax),%rbp
vlC:
    cmpl m_hi+8(%rip),%r14d
    jg vCe
    movzbl 0(%rbp),%eax
    testb $1,%al
    jnz vsk
    movslq %r12d,%rcx
    movslq %r13d,%rdx
    movslq %r14d,%rbx
    call xform
    movl %edi,%r8d
    addl $ID_G0,%r8d
    leaq m_dsz(%rip),%rdx
    movzbl (%rdx,%rdi),%edx
    call dot_draw
vsk:
    addq m_sC(%rip),%rbp
    incl %r14d
    jmp vlC
vCe:
    incl %r13d
    jmp vlB
vBe:
    incl %r12d
    jmp vlA
vmark:
    leaq ecoord(%rip),%rsi
    movl $ID_EXIT,%r8d
    call mark_draw
    leaq svec(%rip),%rsi
    movl $ID_START,%r8d
    call mark_draw
    xorl %ecx,%ecx
    xorl %edx,%edx
    xorl %ebx,%ebx
    call xform
    movl m_msz(%rip),%edx
    movl $ID_PLY,%r8d
    call dot_draw
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbp
    popq %rbx
    ret

mark_draw:                     /* rsi=coords, r8d=color id */
    movl %r8d,m_mid(%rip)
    movq %rsi,m_mt(%rip)
    movl m_ax+12(%rip),%eax    /* fixed axis must match player */
    leaq pcoord(%rip),%rcx
    movl (%rcx,%rax,4),%edx
    movq m_mt(%rip),%rsi
    cmpl (%rsi,%rax,4),%edx
    jne md_no
    xorl %ecx,%ecx
1:  leaq m_ax(%rip),%rax
    movl (%rax,%rcx,4),%eax
    movq m_mt(%rip),%rsi
    movl (%rsi,%rax,4),%edx
    leaq pcoord(%rip),%rsi
    subl (%rsi,%rax,4),%edx
    movl m_h(%rip),%eax
    cmpl %eax,%edx
    jg md_no
    negl %eax
    cmpl %eax,%edx
    jl md_no
    leaq m_rel(%rip),%rax
    movl %edx,(%rax,%rcx,4)
    incl %ecx
    cmpl $3,%ecx
    jb 1b
    pushq %rbx
    movslq m_rel(%rip),%rcx
    movslq m_rel+4(%rip),%rdx
    movslq m_rel+8(%rip),%rbx
    call xform
    movl m_msz(%rip),%edx
    movl m_mid(%rip),%r8d
    call dot_draw
    popq %rbx
md_no:
    ret

/* one 2D panel: plane m_ax[0],m_ax[1]; other axes fixed at player */
draw_view2:
    pushq %rbx
    pushq %rbp
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    movl cvi(%rip),%eax
    leaq ax2tab(%rip),%rcx
    movzbl (%rcx,%rax,4),%edx
    movl %edx,m_ax(%rip)
    movzbl 1(%rcx,%rax,4),%edx
    movl %edx,m_ax+4(%rip)
    movzbl 2(%rcx,%rax,4),%edx
    movl %edx,m_ax+8(%rip)
    movzbl 3(%rcx,%rax,4),%edx
    movl %edx,m_ax+12(%rip)
    movl w2win(%rip),%eax      /* effective window: fit panel */
    movl s2side(%rip),%ecx
    testl $1,%ecx
    jnz 1f
    decl %ecx
1:  cmpl %ecx,%eax
    jbe 2f
    movl %ecx,%eax
2:  movl %eax,m2_w(%rip)
    movl %eax,%ecx
    shrl $1,%ecx
    movl %ecx,m_h(%rip)
    movl m_ax(%rip),%eax       /* strides */
    leaq stride(%rip),%rcx
    movq (%rcx,%rax,8),%rdx
    movq %rdx,m_sA(%rip)
    movl m_ax+4(%rip),%eax
    movq (%rcx,%rax,8),%rdx
    movq %rdx,m_sB(%rip)
    xorl %ecx,%ecx             /* clip ranges both axes */
rg22:
    leaq m_ax(%rip),%rax
    movl (%rax,%rcx,4),%eax
    leaq pcoord(%rip),%rdx
    movl (%rdx,%rax,4),%edx
    movl m_h(%rip),%eax
    movl %eax,%edi
    negl %edi
    movl %edx,%esi
    negl %esi
    cmpl %esi,%edi
    jge 1f
    movl %esi,%edi
1:  leaq m_lo(%rip),%rsi
    movl %edi,(%rsi,%rcx,4)
    movl N(%rip),%edi
    decl %edi
    subl %edx,%edi
    cmpl %eax,%edi
    jle 2f
    movl %eax,%edi
2:  leaq m_hi(%rip),%rsi
    movl %edi,(%rsi,%rcx,4)
    incl %ecx
    cmpl $2,%ecx
    jb rg22
    leaq pcoord(%rip),%rsi
    call vox_addr_v
    movq %rax,m_pa(%rip)
    movl m_hi(%rip),%eax       /* auto-fit: cp from visible extent */
    subl m_lo(%rip),%eax
    incl %eax                  /* vis0 = cols */
    movl m_hi+4(%rip),%edx
    subl m_lo+4(%rip),%edx
    incl %edx                  /* vis1 = rows */
    movl %eax,%ecx
    cmpl %edx,%ecx
    jge 6f
    movl %edx,%ecx             /* vismax */
6:  pushq %rax
    pushq %rdx
    movl s2side(%rip),%eax
    xorl %edx,%edx
    divl %ecx
    testl %eax,%eax
    jnz 7f
    movl $1,%eax
7:  movl %eax,m2_cp(%rip)
    movl %eax,%edx             /* cell fill size = max(1,cp-1) */
    decl %edx
    jnz 8f
    movl $1,%edx
8:  movl %edx,m2_sz(%rip)
    popq %rdx
    popq %rcx                  /* rcx=vis0, rdx=vis1 */
    movl m2_cp(%rip),%eax      /* gx = x0+(s2-vis0*cp)/2-lo0*cp */
    imull %eax,%ecx
    movl s2side(%rip),%edi
    subl %ecx,%edi
    shrl $1,%edi
    addl m_x0(%rip),%edi
    movl m_lo(%rip),%ecx
    imull %eax,%ecx
    subl %ecx,%edi
    movl %edi,m2_gx(%rip)
    imull %eax,%edx            /* gy likewise */
    movl s2side(%rip),%edi
    subl %edx,%edi
    shrl $1,%edi
    addl m_y0(%rip),%edi
    movl m_lo+4(%rip),%ecx
    imull %eax,%ecx
    subl %ecx,%edi
    movl %edi,m2_gy(%rip)
    movl m_lo(%rip),%r12d      /* cell loop */
v2A:
    cmpl m_hi(%rip),%r12d
    jg v2mk
    movslq %r12d,%rax
    imulq m_sA(%rip),%rax
    addq m_pa(%rip),%rax
    movq %rax,m_aA(%rip)
    movl %r12d,%eax            /* px for this column */
    imull m2_cp(%rip),%eax
    addl m2_gx(%rip),%eax
    movl %eax,m2_px(%rip)
    movl m_lo+4(%rip),%r13d
    movslq %r13d,%rax
    imulq m_sB(%rip),%rax
    addq m_aA(%rip),%rax
    movq %rax,%rbp             /* voxel address */
    movl %r13d,%r14d           /* py */
    imull m2_cp(%rip),%r14d
    addl m2_gy(%rip),%r14d
v2B:
    cmpl m_hi+4(%rip),%r13d
    jg v2Be
    movzbl 0(%rbp),%eax
    movl $(ID_G0+3),%r8d       /* wall: dark */
    testb $1,%al
    jnz 5f
    movl $(ID_G0+1),%r8d       /* open: light */
5:  movl m2_px(%rip),%edi
    movl %r14d,%esi
    movl m2_sz(%rip),%edx
    movl %edx,%ecx
    call fill_rect
    addq m_sB(%rip),%rbp
    addl m2_cp(%rip),%r14d
    incl %r13d
    jmp v2B
v2Be:
    incl %r12d
    jmp v2A
v2mk:
    leaq ecoord(%rip),%rsi
    movl $ID_EXIT,%r8d
    call mark2
    leaq svec(%rip),%rsi
    movl $ID_START,%r8d
    call mark2
    movl m2_gx(%rip),%edi      /* player at rel (0,0) */
    movl m2_gy(%rip),%esi
    movl m2_sz(%rip),%edx
    movl %edx,%ecx
    movl $ID_PLY,%r8d
    call fill_rect
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbp
    popq %rbx
    ret

mark2:                         /* rsi=coords, r8d=color: 2D marker */
    movl %r8d,m_mid(%rip)
    movq %rsi,m_mt(%rip)
    movl m_ax+8(%rip),%eax     /* both fixed axes must match */
    leaq pcoord(%rip),%rcx
    movl (%rcx,%rax,4),%edx
    cmpl (%rsi,%rax,4),%edx
    jne mk2_no
    movl m_ax+12(%rip),%eax
    movl (%rcx,%rax,4),%edx
    cmpl (%rsi,%rax,4),%edx
    jne mk2_no
    movl m_ax(%rip),%eax       /* rel on plane axes, clipped */
    movl (%rsi,%rax,4),%edx
    subl (%rcx,%rax,4),%edx
    cmpl m_lo(%rip),%edx
    jl mk2_no
    cmpl m_hi(%rip),%edx
    jg mk2_no
    movl %edx,m_rel(%rip)
    movl m_ax+4(%rip),%eax
    movl (%rsi,%rax,4),%edx
    subl (%rcx,%rax,4),%edx
    cmpl m_lo+4(%rip),%edx
    jl mk2_no
    cmpl m_hi+4(%rip),%edx
    jg mk2_no
    movl m_rel(%rip),%eax
    imull m2_cp(%rip),%eax
    addl m2_gx(%rip),%eax
    movl %eax,%edi
    imull m2_cp(%rip),%edx
    addl m2_gy(%rip),%edx
    movl %edx,%esi
    movl m2_sz(%rip),%edx
    movl %edx,%ecx
    movl m_mid(%rip),%r8d
    jmp fill_rect
mk2_no:
    ret

/* rotate+project cell offset: in rcx=dx rdx=dy rbx=dz
 * out eax=sx esi=sy edi=depth band 0-3; clobbers rdx,r8-r11 */
xform:
    movslq m_cy(%rip),%rax
    imulq %rcx,%rax
    movslq m_sy(%rip),%rsi
    imulq %rbx,%rsi
    addq %rsi,%rax
    movq %rax,%r10             /* x1<<14 */
    movslq m_cy(%rip),%rsi
    imulq %rbx,%rsi
    movslq m_sy(%rip),%r8
    imulq %rcx,%r8
    subq %r8,%rsi              /* z1<<14 */
    movslq m_cp(%rip),%r9
    imulq %rdx,%r9
    movq %rsi,%r8
    movslq m_sp(%rip),%r11
    imulq %r11,%r8
    sarq $14,%r8
    subq %r8,%r9               /* y2<<14 */
    movslq m_cp(%rip),%r8
    imulq %rsi,%r8
    sarq $14,%r8
    movslq m_sp(%rip),%r11
    imulq %rdx,%r11
    addq %r11,%r8              /* z2<<14 */
    addq m_zbias(%rip),%r8
    jns 1f
    xorl %r8d,%r8d
1:  shlq $2,%r8
    movq %r8,%rax
    xorl %edx,%edx
    divq m_zdiv(%rip)
    cmpq $3,%rax
    jbe 2f
    movl $3,%eax
2:  movl %eax,%edi
    movslq m_pp(%rip),%r11
    movq %r10,%rax
    imulq %r11,%rax
    sarq $14,%rax
    addl m_cx(%rip),%eax
    imulq %r11,%r9
    sarq $14,%r9
    movl %r9d,%esi
    addl m_cy2(%rip),%esi
    ret

/* centered square dot, clipped to view box
 * eax=sx esi=sy edx=size r8d=color */
dot_draw:
    movl %edx,%r9d
    shrl $1,%r9d
    subl %r9d,%eax
    subl %r9d,%esi
    movl m_x0(%rip),%r9d
    cmpl %r9d,%eax
    jl 9f
    movl m_y0(%rip),%r10d
    cmpl %r10d,%esi
    jl 9f
    addl qside(%rip),%r9d
    movl %eax,%r11d
    addl %edx,%r11d
    cmpl %r9d,%r11d
    jg 9f
    addl qside(%rip),%r10d
    movl %esi,%r11d
    addl %edx,%r11d
    cmpl %r10d,%r11d
    jg 9f
    movl %eax,%edi
    movl %edx,%ecx
    jmp fill_rect
9:  ret

/* ---------------- primitives ---------------- */
/* edi=x esi=y edx=w ecx=h r8d=color id; preserves rbx,rbp,r12-r15
 * clips to the framebuffer, safe for any mode geometry */
fill_rect:
    testl %edi,%edi            /* x<0: shrink w, clamp x */
    jns 1f
    addl %edi,%edx
    xorl %edi,%edi
1:  testl %esi,%esi            /* y<0 */
    jns 2f
    addl %esi,%ecx
    xorl %esi,%esi
2:  movl fbw(%rip),%eax        /* right edge */
    subl %edi,%eax
    cmpl %eax,%edx
    jle 3f
    movl %eax,%edx
3:  movl fbh(%rip),%eax        /* bottom edge */
    subl %esi,%eax
    cmpl %eax,%ecx
    jle 4f
    movl %eax,%ecx
4:  testl %edx,%edx
    jle fr_ret
    testl %ecx,%ecx
    jle fr_ret
    movl %esi,%eax
    imull fbpitch(%rip),%eax
    movl bytespp(%rip),%r9d
    imull %r9d,%edi
    addl %edi,%eax
    movl fbphys(%rip),%edi
    addq %rdi,%rax
    movq %rax,%r10
    movl %edx,%r11d
    cmpl $4,%r9d
    je fr32
    cmpl $2,%r9d
    je fr16
    cmpl $3,%r9d
    je fr24
    movl %ecx,%r9d             /* 8 bpp */
    movl %r8d,%eax
1:  movq %r10,%rdi
    movl %r11d,%ecx
    rep stosb
    movl fbpitch(%rip),%ecx
    addq %rcx,%r10
    decl %r9d
    jnz 1b
    ret
fr16:
    movl %ecx,%r9d
    leaq col16(%rip),%rax
    movzwl (%rax,%r8,2),%eax
1:  movq %r10,%rdi
    movl %r11d,%ecx
    rep stosw
    movl fbpitch(%rip),%ecx
    addq %rcx,%r10
    decl %r9d
    jnz 1b
    ret
fr32:
    movl %ecx,%r9d
    leaq rgb32(%rip),%rax
    movl (%rax,%r8,4),%eax
1:  movq %r10,%rdi
    movl %r11d,%ecx
    rep stosl
    movl fbpitch(%rip),%ecx
    addq %rcx,%r10
    decl %r9d
    jnz 1b
    ret
fr24:
    movl %ecx,%r9d
    leaq rgb32(%rip),%rax
    movl (%rax,%r8,4),%esi
1:  movq %r10,%rdi
    movl %r11d,%ecx
2:  movw %si,(%rdi)
    movl %esi,%eax
    shrl $16,%eax
    movb %al,2(%rdi)
    addq $3,%rdi
    decl %ecx
    jnz 2b
    movl fbpitch(%rip),%eax
    addq %rax,%r10
    decl %r9d
    jnz 1b
fr_ret:
    ret

clear_fb:
    xorl %edi,%edi
    xorl %esi,%esi
    movl fbw(%rip),%edx
    movl fbh(%rip),%ecx
    movl $ID_BG,%r8d
    jmp fill_rect

/* al=char at (curx,cury), color colr, advances curx; keeps rsi */
draw_char:
    pushq %rbx
    pushq %rbp
    pushq %rsi
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    movzbl %al,%eax
    andl $0x7F,%eax
    movl $FONT,%ebx
    leaq (%rbx,%rax,8),%rbx
    movl curx(%rip),%r13d
    movl cury(%rip),%r14d
    xorl %ebp,%ebp
dc_r:
    movzbl (%rbx,%rbp),%r12d
    xorl %r15d,%r15d
dc_c:
    movl $0x80,%eax
    movl %r15d,%ecx
    shrl %cl,%eax
    testl %r12d,%eax
    jz dc_s
    movl ts(%rip),%edx
    movl %r15d,%edi
    imull %edx,%edi
    addl %r13d,%edi
    movl %ebp,%esi
    imull %edx,%esi
    addl %r14d,%esi
    movl %edx,%ecx
    movl colr(%rip),%r8d
    call fill_rect
dc_s:
    incl %r15d
    cmpl $8,%r15d
    jb dc_c
    incq %rbp
    cmpq $8,%rbp
    jb dc_r
    movl ts(%rip),%eax
    shll $3,%eax
    addl %eax,curx(%rip)
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rsi
    popq %rbp
    popq %rbx
    ret

draw_str:                      /* rsi = asciz */
1:  lodsb
    testb %al,%al
    jz 2f
    call draw_char
    jmp 1b
2:  ret

draw_dec:                      /* rax = value */
    call itoa
    jmp draw_str

draw_vec4:                     /* rsi -> 4 dwords "a,b,c,d" */
    pushq %rbx
    pushq %r12
    movq %rsi,%rbx
    xorl %r12d,%r12d
1:  movl (%rbx,%r12,4),%eax
    call draw_dec
    cmpl $3,%r12d
    jae 2f
    movb $',',%al
    call draw_char
2:  incl %r12d
    cmpl $4,%r12d
    jb 1b
    popq %r12
    popq %rbx
    ret

menu_nl:
    movl ts(%rip),%eax
    leal (%rax,%rax,4),%eax
    addl %eax,%eax
    addl %eax,cury(%rip)
    movl $16,curx(%rip)
    ret

itoa:                          /* rax -> rsi=asciz in numbuf */
    leaq numbuf+23(%rip),%rsi
    movb $0,(%rsi)
    movl $10,%ecx
1:  xorl %edx,%edx
    divq %rcx
    addb $'0',%dl
    decq %rsi
    movb %dl,(%rsi)
    testq %rax,%rax
    jnz 1b
    ret

getkey:                        /* poll PS/2, return make scancode */
1:  inb $0x64,%al
    testb $1,%al
    jz 1b
    testb $0x20,%al            /* mouse byte: discard */
    jz 2f
    inb $0x60,%al
    jmp 1b
2:  inb $0x60,%al
    cmpb $0xE0,%al
    je 1b
    cmpb $0xE1,%al
    je 1b
    testb $0x80,%al            /* ignore break codes */
    jnz 1b
    ret

seed_rng:
    rdtsc
    movl %eax,%ecx
    xorl %edx,%ecx
    xorb %al,%al
    outb %al,$0x43             /* latch PIT ch0 */
    inb $0x40,%al
    movb %al,%dl
    inb $0x40,%al
    movb %al,%dh
    movzwl %dx,%edx
    xorl %edx,%ecx
    movb $0,%al
    outb %al,$0x70             /* RTC seconds */
    inb $0x71,%al
    movzbl %al,%eax
    xorl %eax,%ecx
    testl %ecx,%ecx
    jnz 1f
    movl $0x12345678,%ecx
1:  movl %ecx,rngs(%rip)
    ret

rng_next:                      /* xorshift32 -> eax */
    movl rngs(%rip),%eax
    movl %eax,%ecx
    shll $13,%ecx
    xorl %ecx,%eax
    movl %eax,%ecx
    shrl $17,%ecx
    xorl %ecx,%eax
    movl %eax,%ecx
    shll $5,%ecx
    xorl %ecx,%eax
    movl %eax,rngs(%rip)
    ret

rng_below:                     /* eax = rng % edi */
    call rng_next
    xorl %edx,%edx
    divl %edi
    movl %edx,%eax
    ret

vox_addr_v:                    /* rsi -> x,y,z,w dwords; rax = addr */
    movslq 12(%rsi),%rax
    imulq Nq(%rip),%rax
    movslq 8(%rsi),%rdx
    addq %rdx,%rax
    imulq Nq(%rip),%rax
    movslq 4(%rsi),%rdx
    addq %rdx,%rax
    imulq Nq(%rip),%rax
    movslq 0(%rsi),%rdx
    addq %rdx,%rax
    addq mazeb(%rip),%rax
    ret

sinv:                          /* edi=angle 0-255 -> eax=sin*16383 */
    andl $255,%edi
    leaq sintab(%rip),%rax
    movswl (%rax,%rdi,2),%eax
    ret

/* ---------------- data ---------------- */
axtab:  .byte 0,1,2,3, 0,1,3,2, 0,2,3,1, 1,2,3,0
ax2tab: .byte 0,1,2,3, 0,2,1,3, 0,3,1,2, 1,2,0,3, 1,3,0,2, 2,3,0,1
dsgn2:  .long 2,-2
dsgn1:  .long 1,-1
scan2dig: .ascii "1234567890"
s_vlab: .asciz "XYZ"
        .asciz "XYW"
        .asciz "XZW"
        .asciz "YZW"
s_vlab2:.asciz "XY"
        .asciz "XZ"
        .asciz "XW"
        .asciz "YZ"
        .asciz "YW"
        .asciz "ZW"
s_act:  .asciz " *"
s_t1:   .asciz "4D MAZE - AMD64 LONG MODE OS"
s_t2:   .asciz "FLAT IDENTITY MAP - NO PROTECTION"
s_ram:  .asciz "RAM FOR MAZE: "
s_mib:  .asciz " MIB"
s_vid:  .asciz "VIDEO: "
s_maxn: .asciz "MAX N: "
s_pr1:  .asciz "ENTER N (2-"
s_pr2:  .asciz "), MAZE = N^4 VOXELS"
s_cur:  .asciz "> "
s_epos: .asciz "ENTER A POSITIVE NUMBER"
s_ty0:  .asciz "MAZE TYPE, N="
s_ty1:  .asciz "1 = PERFECT: EXACTLY ONE PATH BETWEEN ANY TWO CELLS (DEFAULT)"
s_ty2:  .asciz "2 = SPARSE: PERFECT + RANDOMLY REMOVED WALLS (EASIER, HAS LOOPS)"
s_ty3:  .asciz "PRESS 1 / 2 (ENTER = PERFECT, ESC = BACK)"
s_wl0:  .asciz "SPARSE MAZE, N="
s_wl1:  .asciz "REMOVABLE WALLS: "
s_wl2:  .asciz "HOW MANY TO REMOVE? (0 - MAX ABOVE, EMPTY = 0)"
s_wl3:  .asciz "ENTER = GENERATE, ESC = BACK"
s_rmw:  .asciz "REMOVING RANDOM WALLS..."
s_goal: .asciz "GOAL: FROM 0,0,0,0 TO GREEN EXIT"
s_l1:   .asciz "DOTS:OPEN YEL:YOU GRN:EXIT BLU:START"
s_l2:   .asciz "ARROWS:XY W/S:Z A/K:W(4D) ESC:MENU X:RND H:HINT B:BEST"
s_l3:   .asciz "TAB:2D/3D 1-4:VIEW J/L I/M:ROT U/O:ZOOM R:RST"
s_gen:  .asciz "GENERATING 4D MAZE, N="
s_hmov: .asciz "MOVES:"
s_hn:   .asciz "  N:"
s_hv:   .asciz "  VIEW:"
s_hpos: .asciz "POS:"
s_hend: .asciz "  EXIT:"
s_w1:   .asciz "YOU ESCAPED THE 4D MAZE!"
s_w2:   .asciz "MOVES: "
s_wn:   .asciz "N: "
s_w3:   .asciz "PRESS ANY KEY FOR MENU"
s_noram:.asciz "NO USABLE RAM FOUND"

    .p2align 3
c_ang:  .double 0.02454369260617026
c_amp:  .double 16383.0
rgb32:
    .long 0x000000
    .long 0xF8F8F8, 0xB8B8B8, 0x808080, 0x505050
    .long 0xFFE000, 0x00E000, 0x4080FF
    .long 0xFF8000, 0x00C8C8, 0xC048FF, 0xFFFFFF
    .long 0xE8E8E8, 0x909090, 0xFFD000, 0xFF4040
    .long 0x505050, 0x00C0FF

    .p2align 3
topaddr: .quad 0
tblend:  .quad 0
mazemin: .quad 0
mazeb:   .quad 0
mazesz:  .quad 0
Nq:      .quad 0
total:   .quad 0
cells:   .quad 0
moves:   .quad 0
gdone:   .quad 0
rmwalls: .quad 0
maxrm:   .quad 0
wvA:     .quad 0
wvB:     .quad 0
wvcap:   .quad 0
wcur:    .quad 0
wnxt:    .quad 0
stride:  .quad 0,0,0,0
sdtab:   .quad 0,0,0,0,0,0,0,0
m_pa:    .quad 0
m_aA:    .quad 0
m_sA:    .quad 0
m_sB:    .quad 0
m_sC:    .quad 0
m_zbias: .quad 0
m_zdiv:  .quad 0
m_mt:    .quad 0
errstr:  .quad 0
fbphys:  .long 0
fbpitch: .long 0
fbw:     .long 0
fbh:     .long 0
fbbpp:   .long 0
bestsc:  .long 0
bestlim: .long 0
bestmd:  .word 0
curmd:   .word 0
mcnt:    .word 0
         .word 0
N:       .long 0
maxc:    .long 0
maxN:    .long 0
ts:      .long 1
tsl:     .long 1
tsav:    .long 1
gap:     .long 8
bytespp: .long 4
qside:   .long 0
vx0g:    .long 0
vx1g:    .long 0
vy0:     .long 0
vy1:     .long 0
yl0:     .long 0
yl1:     .long 0
legy:    .long 0
lab:     .long 0
hudh:    .long 0
s2side:  .long 0
v2x0:    .long 0
v2x1:    .long 0
v2x2:    .long 0
y2l0:    .long 0
y2l1:    .long 0
v2y0:    .long 0
v2y1:    .long 0
viewmode:.long 0
w2win:   .long 41
w2max:   .long 41
w2def:   .long 41
m2_w:    .long 0
m2_cp:   .long 0
m2_sz:   .long 0
m2_gx:   .long 0
m2_gy:   .long 0
m2_px:   .long 0
brd:     .long 0
defwin:  .long 15
defwinN: .long 15
maxwinN: .long 29
actv:    .long 0
cvi:     .long 0
curx:    .long 0
cury:    .long 0
colr:    .long 12
inlen:   .long 0
rngs:    .long 0x12345
pcoord:  .long 0,0,0,0
ecoord:  .long 0,0,0,0
tvec:    .long 0,0,0,0
hvec:    .long 0,0,0,0
gcur:    .long 0,0,0,0
svec:    .long 0,0,0,0
vwin:    .long 15,15,15,15
m_ax:    .long 0,0,0,0
m_lo:    .long 0,0,0
m_hi:    .long 0,0,0
m_rel:   .long 0,0,0
m_v:     .long 0
m_h:     .long 0
m_pp:    .long 0
m_cx:    .long 0
m_cy2:   .long 0
m_x0:    .long 0
m_y0:    .long 0
m_sy:    .long 0
m_cy:    .long 0
m_sp:    .long 0
m_cp:    .long 0
m_asz:   .long 0
m_msz:   .long 0
m_mid:   .long 0
m_bc:    .long 0
barx:    .long 0
bary:    .long 0
barw:    .long 0
barh:    .long 0
vyaw:    .byte 21,21,21,21
vpit:    .byte 242,242,242,242
m_dsz:   .byte 0,0,0,0
cand:    .byte 0,0,0,0,0,0,0,0
inbuf:   .byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
tmpw:    .word 0
numbuf:  .skip 24
sintab:  .skip 512
col16:   .skip 36
imgend:
