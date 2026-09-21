#pragma once

#include <stddef.h> /* size_t:qbdi_log_build_path */
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

#define TRACE_MAX_TARGETS 32
#define TRACE_MAX_WATCHES 128
/* 条件数量不设上限；只有“不同的外部触发地址”需要独立机器码 trampoline。
 * 相同地址的任意多条条件共用一个槽位。 */
#define TRACE_MAX_TRIGGER_HOOKS 128
/* Dobby 在 arm64 上的补丁长度:补丁覆盖 [start, start+16),原代码从 start+16 继续 */
#define QBDI_PATCH_SIZE 16

/* hook 点的完整 GPR 上下文(asm trampoline 捕获/恢复) */
typedef struct {
    uint64_t x[29]; /* x0..x28；x17 可能已被 Dobby 入口跳板占用，不能视为可靠原值 */
    uint64_t fp;    /* x29 */
    uint64_t lr;    /* x30 */
    uint64_t sp;    /* 真实 sp(asm 在入栈前记下) */
} TraceRegFile;

/* 自动 hook 每目标的运行时状态(次数用完透传) */
extern void *g_origin[TRACE_MAX_TARGETS];
/* 自定义触发地址的 Dobby origin；触发地址=起始地址时为 NULL。 */
extern void *g_trigger_origin[TRACE_MAX_TRIGGER_HOOKS];
extern int g_trigger_trace_slot[TRACE_MAX_TRIGGER_HOOKS];
extern uint64_t g_trigger_address[TRACE_MAX_TRIGGER_HOOKS];
extern int g_remaining[TRACE_MAX_TARGETS];
/* 装 hook 时算好的模块运行时基址。**别在命中时重新 find_module** ——
 * 那会遍历所有 dyld 镜像做 strstr 并抢 dyld 锁,热点上足以把整个进程拖死。 */
extern uint64_t g_module_base[TRACE_MAX_TARGETS];
void qbdi_trace_init_state(void);

/* asm trampoline 调用的入口:对第 idx 个目标做一次 trace 或透传。
 * QBDI 只负责记录;rf 出入参都是 hook 点输入寄存器(输出状态丢弃)。
 * 返回续跑地址 = Dobby origin,让区域代码原生执行一遍,app 状态才正确。 */
uint64_t trace_ctx_entry(TraceRegFile *rf, int idx);

/* 自定义触发 hook 入口：只判断条件并授权同线程下一次 trace，
 * 不在这个 hook 上直接启动 QBDI。返回值是该 hook 的 Dobby origin。 */
uint64_t trigger_ctx_entry(TraceRegFile *rf, int hook_idx);

/* 手动区间 trace:从 模块基址+static_start 跑到 模块基址+static_end,返回停止时 x0。
 * 手动调用前可设 g_enter_args[8] 作参数;g_enter_origin 为 NULL 时从真实模块地址起跑。 */
uint64_t trace(const char *module, uint64_t static_start, uint64_t static_end,
               int module_only, int count);

/* trampoline → trace 的入参通道(手动路径用,线程局部) */
extern __thread uint64_t g_enter_args[8];
extern __thread void *g_enter_origin;

/* ---- 日志落地位置 ----
 *
 * 目录结构:<logRoot>/trace-logs/trace_<年月日时分>.log
 *           <logRoot>/hook-logs/hook_<年月日时分>.log(阶段② Hook 用)
 *
 * logRoot 来自 settings.json(用户可在 App 设置页改)。engine_start 必须在
 * **第一次写文件日志之前**调用 qbdi_trace_set_log_root,否则日志会落到默认
 * 的 /tmp/ios-qbdi-tracer 而不是用户配的位置。非绝对路径会被忽略。 */
void qbdi_trace_set_log_root(const char *root);

/* 全进程共享的日志时间戳(%y%m%d%H%M)。首次调用时生成,之后恒定 ——
 * Trace 和 Hook 日志靠它保证同一次运行的文件名后缀一致。 */
const char *qbdi_log_timestamp(void);

/* 拼 <logRoot>/<subdir>/<prefix><时间戳>.log 并按需创建目录。 */
void qbdi_log_build_path(char *out, size_t cap, const char *subdir,
                         const char *prefix);

/* 追加日志(自动 hook 的安装/报错信息) */
void qbdi_trace_logf(const char *fmt, ...);

/* 只写 iPhone 系统日志控制台，自动加 [ios-qbdi-tracer] 前缀。 */
void qbdi_console_logf(const char *fmt, ...);

/* 安装崩溃信号捕获(SIGSEGV/SIGBUS/SIGILL/SIGABRT),把崩溃 PC 写进日志后重抛 */
void qbdi_trace_crash_diag_init(void);
