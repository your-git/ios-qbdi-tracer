#include <stdint.h>

#include <dobby.h>

#include "config.h"
#include "qbdi_trace.h"

/* trampoline 的最终间接跳转必须占用一个通用寄存器。Dobby 在 arm64 上明确把
 * x17 保留为跳板临时寄存器，因此只能牺牲 x17；x16 仍属于 hook 点原始状态，
 * 必须恢复。若将来升级 Dobby 后契约变化，宁可编译失败，也不能静默跳错地址。 */
#ifndef ARM64_TMP_REG_NDX_0
#error "Dobby arm64 temporary-register contract is unavailable"
#endif
#if ARM64_TMP_REG_NDX_0 != 17
#error "Tracer trampoline requires Dobby ARM64_TMP_REG_NDX_0 to be x17"
#endif

/*
 * 固定 32 个 naked arm64 trampoline(槽位 0..31)。
 * 与编译期 X-macro 版不同:数量固定,运行期由 engine.m 决定 hook 哪几个槽位。
 * 每个 trampoline 只差 `mov x1, #slot`(asm 要求字面量,故必须逐个展开)。
 *
 * ---- 为什么要保存这么多东西 ----
 *
 * DobbyHook 是**纯跳转** hook,不替我们保存任何 CPU 状态;而 hook 点通常落在
 * **函数中间**,不是函数调用边界 —— 也就是说这里没有任何 ABI 保护可言,原代码
 * 此刻持有的一切都得原样还回去。唯一例外是 Dobby 已声明为跳板临时寄存器的
 * x17：入口补丁本身就可能改写它，返回时继续用它承载 origin。除此之外还必须保存:
 *
 *   NZCV  —— 条件标志位。trace_ctx_entry 里的 C 代码(表达式求值、memcmp、
 *            字符串搜索)一定会改写它。不恢复的话,原代码紧跟着的 b.eq/cbz 之类
 *            会基于被污染的标志位跳转 —— 如果那正好是循环的退出判断,
 *            程序就会永远出不来(真机上出现过:同一个函数被反复执行上百万次)。
 *   q0-q31 —— 向量寄存器。C 里的 memcpy/memcmp/字符串操作大量用 NEON。
 *            ABI 只保证 v8-v15 的**低 64 位**由 callee 保护,而原代码在指令中间
 *            可能正拿着任意 v 寄存器存中间值。
 *   FPCR/FPSR —— 浮点控制/状态。改动概率低,但既然要"原样还回去"就一起存。
 *
 * ---- 栈布局(共 0x320 字节)----
 *   sp+0x000..0x0FF  TraceRegFile:x0..x28 / fp / lr / 真实sp(结构别动)
 *   sp+0x100         NZCV
 *   sp+0x108         FPCR
 *   sp+0x110         FPSR
 *   sp+0x120..0x31F  q0..q31
 *
 * 恢复顺序有讲究:`msr nzcv` 必须排在恢复通用寄存器**之前**(借 x9 当临时寄存器),
 * 因为之后的 ldp/ldr/mov sp/br 都不会碰标志位,而 x9 随后会被还原成原值。
 * `trace_ctx_entry` 的返回值必须留在 x17 直到最后 `br x17`；绝不能先放进 x16
 * 又用保存值覆盖 x16，否则会跳到 hook 入口时的旧 x16，造成重复进入同一现场。
 */
#define TRAMP(slot)                                                             \
    __attribute__((naked)) static void tramp_##slot(void) {                     \
        __asm__ volatile(                                                        \
            "sub sp, sp, #0x320\n"                                               \
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
            "add x9, sp, #0x320\n"                                               \
            "str x9, [sp, #0xf8]\n"                                              \
            /* x9 的原值已在 0x48 存好,这里可以拿它当临时寄存器 */                \
            "mrs x9, nzcv\n"                                                     \
            "str x9, [sp, #0x100]\n"                                             \
            "mrs x9, fpcr\n"                                                     \
            "str x9, [sp, #0x108]\n"                                             \
            "mrs x9, fpsr\n"                                                     \
            "str x9, [sp, #0x110]\n"                                             \
            "stp q0, q1, [sp, #0x120]\n"                                         \
            "stp q2, q3, [sp, #0x140]\n"                                         \
            "stp q4, q5, [sp, #0x160]\n"                                         \
            "stp q6, q7, [sp, #0x180]\n"                                         \
            "stp q8, q9, [sp, #0x1a0]\n"                                         \
            "stp q10, q11, [sp, #0x1c0]\n"                                       \
            "stp q12, q13, [sp, #0x1e0]\n"                                       \
            "stp q14, q15, [sp, #0x200]\n"                                       \
            "stp q16, q17, [sp, #0x220]\n"                                       \
            "stp q18, q19, [sp, #0x240]\n"                                       \
            "stp q20, q21, [sp, #0x260]\n"                                       \
            "stp q22, q23, [sp, #0x280]\n"                                       \
            "stp q24, q25, [sp, #0x2a0]\n"                                       \
            "stp q26, q27, [sp, #0x2c0]\n"                                       \
            "stp q28, q29, [sp, #0x2e0]\n"                                       \
            "stp q30, q31, [sp, #0x300]\n"                                       \
            "mov x0, sp\n"                                                       \
            "mov x1, #" #slot "\n"                                               \
            "bl _trace_ctx_entry\n"                                              \
            /* x17 是 Dobby 的 arm64 跳板临时寄存器。若 C 层意外返回 0，退到 */    \
            /* hook 现场保存的 LR，至少避免 br 0 立即崩溃。 */                     \
            "mov x17, x0\n"                                                      \
            "cbnz x17, 1f\n"                                                     \
            "ldr x17, [sp, #0xf0]\n"                                             \
            "1:\n"                                                               \
            "ldp q0, q1, [sp, #0x120]\n"                                         \
            "ldp q2, q3, [sp, #0x140]\n"                                         \
            "ldp q4, q5, [sp, #0x160]\n"                                         \
            "ldp q6, q7, [sp, #0x180]\n"                                         \
            "ldp q8, q9, [sp, #0x1a0]\n"                                         \
            "ldp q10, q11, [sp, #0x1c0]\n"                                       \
            "ldp q12, q13, [sp, #0x1e0]\n"                                       \
            "ldp q14, q15, [sp, #0x200]\n"                                       \
            "ldp q16, q17, [sp, #0x220]\n"                                       \
            "ldp q18, q19, [sp, #0x240]\n"                                       \
            "ldp q20, q21, [sp, #0x260]\n"                                       \
            "ldp q22, q23, [sp, #0x280]\n"                                       \
            "ldp q24, q25, [sp, #0x2a0]\n"                                       \
            "ldp q26, q27, [sp, #0x2c0]\n"                                       \
            "ldp q28, q29, [sp, #0x2e0]\n"                                       \
            "ldp q30, q31, [sp, #0x300]\n"                                       \
            "ldr x9, [sp, #0x110]\n"                                             \
            "msr fpsr, x9\n"                                                     \
            "ldr x9, [sp, #0x108]\n"                                             \
            "msr fpcr, x9\n"                                                     \
            "ldr x9, [sp, #0x100]\n"                                             \
            "msr nzcv, x9\n"                                                     \
            /* 以下 ldp/ldr/mov sp/br 都不改标志位,所以 nzcv 可以先恢复 */        \
            "ldp x0, x1, [sp, #0x00]\n"                                          \
            "ldp x2, x3, [sp, #0x10]\n"                                          \
            "ldp x4, x5, [sp, #0x20]\n"                                          \
            "ldp x6, x7, [sp, #0x30]\n"                                          \
            "ldp x8, x9, [sp, #0x40]\n"                                          \
            "ldp x10, x11, [sp, #0x50]\n"                                        \
            "ldp x12, x13, [sp, #0x60]\n"                                        \
            "ldp x14, x15, [sp, #0x70]\n"                                        \
            /* x16 必须恢复；x17 保留 trace_ctx_entry 返回的续跑地址。 */           \
            "ldr x16, [sp, #0x80]\n"                                             \
            "ldp x18, x19, [sp, #0x90]\n"                                        \
            "ldp x20, x21, [sp, #0xa0]\n"                                        \
            "ldp x22, x23, [sp, #0xb0]\n"                                        \
            "ldp x24, x25, [sp, #0xc0]\n"                                        \
            "ldp x26, x27, [sp, #0xd0]\n"                                        \
            "ldp x28, x29, [sp, #0xe0]\n"                                        \
            "ldr x30, [sp, #0xf0]\n"                                             \
            "ldr x9, [sp, #0xf8]\n"                                              \
            "mov sp, x9\n"                                                       \
            "br x17\n"                                                           \
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
