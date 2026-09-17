/* 宿主机自测:只验证 watch_expr.c 的编译/求值,不依赖 QBDI */
#include "watch_expr.h"

#include <stdio.h>
#include <string.h>

/* 模拟内存:一段 64 字节的假对象图 */
static unsigned char g_mem[0x200];
#define MEM_BASE 0x100000ULL

static size_t fake_read(uint64_t addr, void *buf, size_t n) {
    if (addr < MEM_BASE || addr + n > MEM_BASE + sizeof(g_mem)) {
        return 0; /* 越界 = 读不进,模拟野指针 */
    }
    memcpy(buf, g_mem + (addr - MEM_BASE), n);
    return n;
}

static void put64(uint64_t at, uint64_t v) {
    memcpy(g_mem + (at - MEM_BASE), &v, 8);
}

static int g_fail = 0;

static void ok_case(const char *src, const uint64_t *regs, uint64_t want) {
    WatchExpr e;
    char err[96];
    if (!wexpr_compile(src, &e, err, sizeof(err))) {
        printf("FAIL compile \"%s\": %s\n", src, err);
        g_fail++;
        return;
    }
    uint64_t got = 0;
    WatchExprTrace tr;
    if (!wexpr_eval(&e, regs, fake_read, &got, &tr)) {
        printf("FAIL eval \"%s\" (nops=%d)\n", src, e.nops);
        wexpr_print_trace(stdout, &tr);
        g_fail++;
        return;
    }
    if (got != want) {
        printf("FAIL \"%s\": got 0x%llx want 0x%llx\n", src,
               (unsigned long long)got, (unsigned long long)want);
        g_fail++;
        return;
    }
    printf("ok   \"%s\" = 0x%llx (nops=%d, base=%s)\n", src,
           (unsigned long long)got, e.nops,
           wexpr_base_reg(&e) ? wexpr_base_reg(&e) : "-");
}

static void bad_case(const char *src) {
    WatchExpr e;
    char err[96];
    if (wexpr_compile(src, &e, err, sizeof(err))) {
        printf("FAIL \"%s\" should not compile (nops=%d)\n", src, e.nops);
        g_fail++;
        return;
    }
    printf("ok   reject \"%s\": %s\n", src, err);
}

static void unreadable_case(const char *src, const uint64_t *regs,
                            int want_deref) {
    WatchExpr e;
    char err[96];
    if (!wexpr_compile(src, &e, err, sizeof(err))) {
        printf("FAIL compile \"%s\": %s\n", src, err);
        g_fail++;
        return;
    }
    uint64_t got = 0;
    WatchExprTrace tr;
    if (wexpr_eval(&e, regs, fake_read, &got, &tr)) {
        printf("FAIL \"%s\" should be unreadable, got 0x%llx\n", src,
               (unsigned long long)got);
        g_fail++;
        return;
    }
    if (tr.nderef != want_deref || tr.deref_ok[want_deref - 1]) {
        printf("FAIL \"%s\" diag: nderef=%d want %d\n", src, tr.nderef,
               want_deref);
        g_fail++;
        return;
    }
    printf("ok   unreadable \"%s\" (failed at deref#%d)\n", src, tr.nderef);
    wexpr_print_trace(stdout, &tr);
}

int main(void) {
    uint64_t regs[WEXPR_NREGS];
    memset(regs, 0, sizeof(regs));
    regs[0]              = MEM_BASE + 0x100; /* x0 = 对象指针 */
    regs[1]              = 0x10;
    regs[WEXPR_REG_SP]   = MEM_BASE + 0x180;
    regs[WEXPR_REG_FP]   = MEM_BASE + 0x190;
    regs[WEXPR_REG_LR]   = 0xdeadbeef;
    regs[WEXPR_REG_PC]   = 0xcafe;
    regs[28]             = 0x28;

    /* 对象图:[x0+8] -> 0x100040, [0x100040+0x10] -> 0x100080 */
    put64(MEM_BASE + 0x108, MEM_BASE + 0x40);
    put64(MEM_BASE + 0x50, MEM_BASE + 0x80);
    put64(MEM_BASE + 0x180, 0x1122334455667788ULL);

    puts("-- 基本 --");
    ok_case("x0", regs, MEM_BASE + 0x100);
    ok_case("X0", regs, MEM_BASE + 0x100);
    ok_case("x28", regs, 0x28);
    ok_case("sp", regs, MEM_BASE + 0x180);
    ok_case("fp", regs, MEM_BASE + 0x190);
    ok_case("x29", regs, MEM_BASE + 0x190); /* x29 = fp 别名 */
    ok_case("x30", regs, 0xdeadbeef);       /* x30 = lr 别名 */
    ok_case("pc", regs, 0xcafe);

    puts("-- 加减(一律十六进制) --");
    ok_case("x0-0x110", regs, MEM_BASE + 0x100 - 0x110);
    ok_case("x0-110", regs, MEM_BASE + 0x100 - 0x110); /* 省 0x 也按 hex */
    ok_case("x0+10", regs, MEM_BASE + 0x110);
    ok_case(" x0 + 0x10 ", regs, MEM_BASE + 0x110);
    ok_case("x0+x1", regs, MEM_BASE + 0x110);
    ok_case("x0+-8", regs, MEM_BASE + 0xf8);
    ok_case("x0+8-8", regs, MEM_BASE + 0x100);

    puts("-- 解引用 --");
    ok_case("[sp]", regs, 0x1122334455667788ULL);
    ok_case("[x0+8]", regs, MEM_BASE + 0x40);
    ok_case("[[x0+8]+0x10]", regs, MEM_BASE + 0x80);
    ok_case("[[x0+8]+0x10]-4", regs, MEM_BASE + 0x7c);
    ok_case("[ [ x0 + 8 ] + 10 ] - 4", regs, MEM_BASE + 0x7c);

    puts("-- 能读到 0 与真读不出来是两回事 --");
    ok_case("[x0]", regs, 0);          /* 那一格确实是 0,算读成功 */
    ok_case("[[x0+8]+0x18]", regs, 0); /* 第二级读到 0(合法) */

    puts("-- 读不出来时的诊断 --");
    put64(MEM_BASE + 0x110, 0xdeadbeef000ULL); /* 埋一个野指针 */
    unreadable_case("[x0-0x200]", regs, 1);    /* 第一级就越界 */
    unreadable_case("[[x0+0x10]]", regs, 2);   /* 第一级成功,第二级踩野指针 */
    unreadable_case("[[[x0+0x10]]]", regs, 2); /* 第二级就断了,不会有第三级 */

    puts("-- 应当拒绝 --");
    bad_case("");
    bad_case("[[x0+8");
    bad_case("x0+");
    bad_case("x0++8");
    bad_case("]x0[");
    bad_case("x31");
    bad_case("x1a");
    bad_case("w0");
    bad_case("-x0");
    bad_case("x0 8");
    bad_case("[[[[[[[[[x0]]]]]]]]]");                 /* 超过 8 级 */
    bad_case("x0+1+2+3+4+5+6+7+8+9+a+b+c+d+e+f+1+2"); /* 超过 op 上限 */
    bad_case("$x0");
    bad_case("x0*2");
    bad_case("0x");

    printf("\n%s\n", g_fail == 0 ? "ALL PASS" : "SOME FAILED");
    return g_fail != 0;
}
