/* maze4d_poc.c - portable proof-of-concept of the maze4d.S algorithm.
 *
 * Same maze representation and generator as the assembly OS:
 *   - N*N*N*N voxels, 1 byte each; bit0 = wall, bit0 clear = open
 *   - cells at all-odd coordinates, DFS backtracker carves walls,
 *     visited marker 0x40 | (came_from_dir << 1), start sentinel bit4
 *   - xorshift32 RNG
 * Adds a BFS check (every cell reachable => perfect maze) and an
 * interactive text walker on the 4 hyperplane slices.
 *
 * build: cc -O2 -o maze4d_poc maze4d_poc.c
 * usage: ./maze4d_poc N [seed]        (N >= 5)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

static uint8_t *mz;
static long long N, S[4], total;
static int maxc;

static uint32_t rngs = 0x12345;
static uint32_t rng_next(void) {
    rngs ^= rngs << 13; rngs ^= rngs >> 17; rngs ^= rngs << 5;
    return rngs;
}
static uint32_t rng_below(uint32_t n) { return rng_next() % n; }

static long long vaddr(const int c[4]) {
    return ((((long long)c[3] * N + c[2]) * N + c[1]) * N + c[0]);
}

static const int sgn1[2] = {1, -1};

static void gen(void) {
    long long sd[8];
    int cur[4] = {1, 1, 1, 1}, d;
    for (d = 0; d < 8; d++) sd[d] = S[d >> 1] * sgn1[d & 1];
    memset(mz, 0x01, total);
    long long p = vaddr(cur);
    mz[p] = 0x50;                          /* start: visited + bit4 */
    for (;;) {
        int cand[8], nc = 0;
        for (d = 0; d < 8; d++) {          /* unvisited neighbors */
            int ax = d >> 1, v = cur[ax] + 2 * sgn1[d & 1];
            if (v < 1 || v > maxc) continue;
            if (mz[p + 2 * sd[d]] == 0x01) cand[nc++] = d;
        }
        if (nc) {                          /* carve forward */
            d = cand[rng_below(nc)];
            mz[p + sd[d]] = 0x00;
            p += 2 * sd[d];
            cur[d >> 1] += 2 * sgn1[d & 1];
            mz[p] = 0x40 | (uint8_t)((d ^ 1) << 1);
        } else {                           /* backtrack */
            uint8_t b = mz[p];
            mz[p] = 0x00;
            if (b & 0x10) break;           /* start reached: done */
            d = (b >> 1) & 7;
            cur[d >> 1] += 2 * sgn1[d & 1];
            p += 2 * sd[d];
        }
    }
}

static int bfs_all_reachable(void) {
    long long cells = 0, seen = 0, head = 0, tail = 0, qcap, i;
    long long c1 = (maxc + 1) / 2;         /* cells per axis */
    qcap = c1 * c1 * c1 * c1;
    long long *q = malloc(qcap * sizeof *q);
    uint8_t *vis = calloc(total, 1);
    if (!q || !vis) { fprintf(stderr, "poc oom\n"); exit(1); }
    cells = qcap;
    int st[4] = {1, 1, 1, 1};
    q[tail++] = vaddr(st); vis[q[0]] = 1; seen = 1;
    while (head < tail) {
        long long p = q[head++];
        for (int d = 0; d < 8; d++) {
            long long sd = S[d >> 1] * sgn1[d & 1];
            /* recover coord on that axis to bounds-check */
            long long rem = p, co;
            for (i = 3; i > (d >> 1); i--) rem %= S[i];
            co = rem / S[d >> 1];
            if (co + 2 * sgn1[d & 1] < 1 || co + 2 * sgn1[d & 1] > maxc) continue;
            if (mz[p + sd] & 1) continue;  /* wall not carved */
            long long np = p + 2 * sd;
            if (!vis[np]) { vis[np] = 1; q[tail++] = np; seen++; }
        }
    }
    free(q); free(vis);
    printf("BFS: reached %lld of %lld cells -> %s\n", seen, cells,
           seen == cells ? "PERFECT MAZE" : "BROKEN!");
    return seen == cells;
}

static void slice(const int p[4], int a0, int a1, const char *t) {
    int c[4], i, j;
    printf("%s (through your position):\n", t);
    memcpy(c, p, sizeof c);
    for (j = 0; j < N && j < 39; j++) {
        for (i = 0; i < N && i < 39; i++) {
            c[a0] = i; c[a1] = j;
            char g = (mz[vaddr(c)] & 1) ? '#' : '.';
            if (i == p[a0] && j == p[a1]) g = '@';
            putchar(g); putchar(g == '#' ? '#' : ' ');
        }
        putchar('\n');
    }
}

int main(int argc, char **argv) {
    int p[4] = {1, 1, 1, 1}, e[4], moves = 0, i;
    if (argc < 2 || (N = atoll(argv[1])) < 5) {
        fprintf(stderr, "usage: %s N [seed]  (N >= 5)\n", argv[0]);
        return 1;
    }
    if (argc > 2) rngs = (uint32_t)strtoul(argv[2], 0, 0);
    if (!rngs) rngs = 0x12345;
    maxc = 2 * (int)((N - 1) / 2) - 1;
    S[0] = 1; S[1] = N; S[2] = N * N; S[3] = N * N * N;
    total = N * N * N * N;
    mz = malloc(total);
    if (!mz) { fprintf(stderr, "need %lld bytes\n", total); return 1; }
    printf("generating %lldx%lldx%lldx%lld maze...\n", N, N, N, N);
    gen();
    if (!bfs_all_reachable()) return 1;
    for (i = 0; i < 4; i++) e[i] = maxc;
    printf("start (1,1,1,1) -> exit (%d,%d,%d,%d)\n", e[0], e[1], e[2], e[3]);
    printf("keys: d/a=+-x  s/w=+-y  e/q=+-z  k/j=+-w  p=print slices  x=quit\n");
    for (;;) {
        if (!memcmp(p, e, sizeof p)) {
            printf("YOU ESCAPED THE 4D MAZE! moves=%d\n", moves);
            return 0;
        }
        printf("pos=(%d,%d,%d,%d) moves=%d > ", p[0], p[1], p[2], p[3], moves);
        int ch = getchar();
        if (ch == EOF || ch == 'x') return 0;
        int d = -1;
        switch (ch) {
        case 'd': d = 0; break; case 'a': d = 1; break;
        case 's': d = 2; break; case 'w': d = 3; break;
        case 'e': d = 4; break; case 'q': d = 5; break;
        case 'k': d = 6; break; case 'j': d = 7; break;
        case 'p':
            slice(p, 0, 1, "XY"); slice(p, 0, 2, "XZ");
            slice(p, 0, 3, "XW"); slice(p, 2, 3, "ZW");
            continue;
        default: continue;
        }
        int t[4]; memcpy(t, p, sizeof t);
        t[d >> 1] += sgn1[d & 1];
        if (t[d >> 1] < 0 || t[d >> 1] >= N) { printf("edge\n"); continue; }
        if (mz[vaddr(t)] & 1) { printf("wall\n"); continue; }
        memcpy(p, t, sizeof p); moves++;
    }
}
