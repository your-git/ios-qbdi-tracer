#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

/* watch 的取址表达式:寄存器 + 常量加减 + [] 多级解引用。
 *
 *   x0-0x110          x0 往前 0x110 字节
 *   sp+0x40           栈帧里的某个槽
 *   [x0+0x10]         读 x0+0x10 处的 8 字节指针
 *   [[x0+8]+0x10]-4   两级解引用后再减 4
 *
 * 语义:表达式算出的是一个"地址",最后那次解引用由 watch 的 action 负责
 * (cstr 从这个地址读字符串、hexdump 从这里开始 dump)。所以 expr="x0"
 * 与旧配置 reg="x0" 行为完全一致,老配置不用迁移。
 *
 * 数字一律按十六进制解析(与配置里的 offset 字段一致),"0x" 前缀可省。
 * 寄存器名大小写不敏感,x29/x30 是 fp/lr 的别名。
 */

#define WEXPR_MAX_OPS   24 /* 编译后的 op 数上限 */
#define WEXPR_MAX_DEPTH 8  /* [] 嵌套层数上限 */
#define WEXPR_NREGS     33 /* x0..x28, fp, lr, sp, pc */
#define WEXPR_MAX_TRACE 8  /* 诊断里最多记几个寄存器/几次解引用 */

/* 寄存器在 regs[] 里的下标:0..28 = x0..x28 */
enum {
    WEXPR_REG_FP = 29,
    WEXPR_REG_LR = 30,
    WEXPR_REG_SP = 31,
    WEXPR_REG_PC = 32,
};

/* 编译结果(后缀式)。nops == 0 表示没有可用表达式,调用方应回落到 reg。 */
typedef struct {
    uint8_t ops[WEXPR_MAX_OPS];
    int64_t imms[WEXPR_MAX_OPS]; /* REG:寄存器下标  IMM:常量值  其余:未用 */
    int     nops;
} WatchExpr;

/* 求值过程记录:多级指针配错时,用来指出到底是哪一级读不出来 */
typedef struct {
    int      nregs;
    uint8_t  reg_ids[WEXPR_MAX_TRACE];
    uint64_t reg_vals[WEXPR_MAX_TRACE];
    int      nderef;
    uint64_t deref_addr[WEXPR_MAX_TRACE];
    uint64_t deref_val[WEXPR_MAX_TRACE];
    bool     deref_ok[WEXPR_MAX_TRACE];
} WatchExprTrace;

/* 安全读内存回调:读不进返回 0(不得崩) */
typedef size_t (*wexpr_read_fn)(uint64_t addr, void *buf, size_t n);

/* 编译表达式。失败返回 false,并把人可读的原因写进 err(err 可为 NULL)。
 * 编译放在配置加载期做,好处是语法错误在 app 启动时就能报进日志,
 * 而不是表现成"watch 没有任何输出"。 */
bool wexpr_compile(const char *src, WatchExpr *out, char *err, size_t errcap);

/* 求值。regs 按上面的下标约定填满 WEXPR_NREGS 项;tr 可为 NULL。
 * 返回 false = 某一级解引用读不出来(*out 不可信,细节看 tr)。 */
bool wexpr_eval(const WatchExpr *e, const uint64_t *regs, wexpr_read_fn rd,
                uint64_t *out, WatchExprTrace *tr);

/* 从表达式里取第一个寄存器名(写回配置的 reg 字段用);取不到返回 NULL */
const char *wexpr_base_reg(const WatchExpr *e);

/* 下标 → 寄存器名;越界返回 "?" */
const char *wexpr_reg_name(int id);

/* 把求值过程写进 out(每行一条,4 空格缩进),供失败时排查 */
void wexpr_print_trace(FILE *out, const WatchExprTrace *tr);
