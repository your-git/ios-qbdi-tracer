#pragma once

#include <stdint.h>

/* 日志位 */
enum {
    LOG_INST   = 1 << 0, /* 打印每条指令(地址 + 反汇编)+ 变化的通用寄存器 */
    LOG_MEM    = 1 << 1, /* 打印内存读写地址/大小/值 */
    LOG_REGS   = 1 << 2, /* 每条指令前打印 x0-x7, sp, lr, pc */
    LOG_BRANCH = 1 << 3, /* 只保留分支/调用/返回指令 */
    LOG_VREG   = 1 << 4, /* 额外打印变化的向量寄存器 v0-v31(输出量大,默认关) */
};

/* 无配置时的兜底 mask(正常都由每条目 log_mask 覆盖) */
#define TRACE_DEFAULT_MASK (LOG_INST)

/* 单次 trace 最多记录指令数,防止死循环把设备拖垮 */
#define TRACE_MAX_INST 10000000

#define TRACE_MAX_TARGETS 32
#define TRACE_MAX_WATCHES 128
/* Dobby 在 arm64 上的补丁长度:补丁覆盖 [start, start+16),原代码从 start+16 继续 */
#define QBDI_PATCH_SIZE 16

/* hook 点的完整 GPR 上下文(asm trampoline 捕获/恢复) */
typedef struct {
    uint64_t x[29]; /* x0..x28 */
    uint64_t fp;    /* x29 */
    uint64_t lr;    /* x30 */
    uint64_t sp;    /* 真实 sp(asm 在入栈前记下) */
} TraceRegFile;

/* 自动 hook 每目标的运行时状态(次数用完透传) */
extern void *g_origin[TRACE_MAX_TARGETS];
extern int g_remaining[TRACE_MAX_TARGETS];
void qbdi_trace_init_state(void);

/* asm trampoline 调用的入口:对第 idx 个目标做一次 trace 或透传。
 * QBDI 只负责记录;rf 出入参都是 hook 点输入寄存器(输出状态丢弃)。
 * 返回续跑地址 = Dobby origin,让区域代码原生执行一遍,app 状态才正确。 */
uint64_t trace_ctx_entry(TraceRegFile *rf, int idx);

/* 手动区间 trace:从 模块基址+static_start 跑到 模块基址+static_end,返回停止时 x0。
 * 手动调用前可设 g_enter_args[8] 作参数;g_enter_origin 为 NULL 时从真实模块地址起跑。 */
uint64_t trace(const char *module, uint64_t static_start, uint64_t static_end,
               int module_only, int count);

/* trampoline → trace 的入参通道(手动路径用,线程局部) */
extern __thread uint64_t g_enter_args[8];
extern __thread void *g_enter_origin;

/* 追加日志(自动 hook 的安装/报错信息) */
void qbdi_trace_logf(const char *fmt, ...);

/* 安装崩溃信号捕获(SIGSEGV/SIGBUS/SIGILL/SIGABRT),把崩溃 PC 写进日志后重抛 */
void qbdi_trace_crash_diag_init(void);
