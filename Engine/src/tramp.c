#include <stdint.h>

#include "config.h"
#include "qbdi_trace.h"

/*
 * 固定 32 个 naked arm64 trampoline(槽位 0..31)。
 * 与编译期 X-macro 版不同:数量固定,运行期由 engine.m 决定 hook 哪几个槽位。
 * 每个 trampoline 只差 `mov x1, #slot`(asm 要求字面量,故必须逐个展开)。
 *
 * 流程(与真机验证过的一致):
 *   保存 x0-x28/fp/lr/真实sp → bl trace_ctx_entry(rf, slot)
 *   → 恢复全部寄存器(sp 用真实 sp)→ br 续跑地址
 */
#define TRAMP(slot)                                                             \
    __attribute__((naked)) static void tramp_##slot(void) {                     \
        __asm__ volatile(                                                        \
            "sub sp, sp, #0x100\n"                                               \
            "stp x0, x1, [sp, #0x00]\n"                                          \
            "stp x2, x3, [sp, #0x10]\n"                                          \
            "stp x4, x5, [sp, #0x20]\n"                                          \
            "stp x6, x7, [sp, #0x30]\n"                                          \
            "stp x8, x9, [sp, #0x40]\n"                                          \
            "stp x10, x11, [sp, #0x50]\n"                                        \
            "stp x12, x13, [sp, #0x60]\n"                                        \
            "stp x14, x15, [sp, #0x70]\n"                                        \
            "stp x16, x17, [sp, #0x80]\n"                                        \
            "stp x18, x19, [sp, #0x90]\n"                                        \
            "stp x20, x21, [sp, #0xa0]\n"                                        \
            "stp x22, x23, [sp, #0xb0]\n"                                        \
            "stp x24, x25, [sp, #0xc0]\n"                                        \
            "stp x26, x27, [sp, #0xd0]\n"                                        \
            "stp x28, x29, [sp, #0xe0]\n"                                        \
            "str x30, [sp, #0xf0]\n"                                             \
            "add x9, sp, #0x100\n"                                               \
            "str x9, [sp, #0xf8]\n"                                              \
            "mov x0, sp\n"                                                       \
            "mov x1, #" #slot "\n"                                               \
            "bl _trace_ctx_entry\n"                                              \
            "mov x16, x0\n"                                                      \
            "ldp x0, x1, [sp, #0x00]\n"                                          \
            "ldp x2, x3, [sp, #0x10]\n"                                          \
            "ldp x4, x5, [sp, #0x20]\n"                                          \
            "ldp x6, x7, [sp, #0x30]\n"                                          \
            "ldp x8, x9, [sp, #0x40]\n"                                          \
            "ldp x10, x11, [sp, #0x50]\n"                                        \
            "ldp x12, x13, [sp, #0x60]\n"                                        \
            "ldp x14, x15, [sp, #0x70]\n"                                        \
            "ldp x16, x17, [sp, #0x80]\n"                                        \
            "ldp x18, x19, [sp, #0x90]\n"                                        \
            "ldp x20, x21, [sp, #0xa0]\n"                                        \
            "ldp x22, x23, [sp, #0xb0]\n"                                        \
            "ldp x24, x25, [sp, #0xc0]\n"                                        \
            "ldp x26, x27, [sp, #0xd0]\n"                                        \
            "ldp x28, x29, [sp, #0xe0]\n"                                        \
            "ldr x30, [sp, #0xf0]\n"                                             \
            "ldr x9, [sp, #0xf8]\n"                                              \
            "mov sp, x9\n"                                                       \
            "br x16\n"                                                           \
        );                                                                       \
    }

TRAMP(0)  TRAMP(1)  TRAMP(2)  TRAMP(3)  TRAMP(4)  TRAMP(5)  TRAMP(6)  TRAMP(7)
TRAMP(8)  TRAMP(9)  TRAMP(10) TRAMP(11) TRAMP(12) TRAMP(13) TRAMP(14) TRAMP(15)
TRAMP(16) TRAMP(17) TRAMP(18) TRAMP(19) TRAMP(20) TRAMP(21) TRAMP(22) TRAMP(23)
TRAMP(24) TRAMP(25) TRAMP(26) TRAMP(27) TRAMP(28) TRAMP(29) TRAMP(30) TRAMP(31)
#undef TRAMP

/* 槽位 → trampoline 函数指针(engine.m 装 hook 时按 slot 取) */
const void *g_tramps[TRACE_MAX_TARGETS] = {
#define T(slot) (const void *)tramp_##slot,
    T(0)  T(1)  T(2)  T(3)  T(4)  T(5)  T(6)  T(7)
    T(8)  T(9)  T(10) T(11) T(12) T(13) T(14) T(15)
    T(16) T(17) T(18) T(19) T(20) T(21) T(22) T(23)
    T(24) T(25) T(26) T(27) T(28) T(29) T(30) T(31)
#undef T
};
