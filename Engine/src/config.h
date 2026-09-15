#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "qbdi_trace.h" /* LOG_* */

/* 一条 trace 区间(运行期由 engine.m 从 JSON 填充) */
typedef struct {
    const char *module;       /* dyld 镜像名子串,如 "ModuleName" */
    uint64_t    static_start; /* 相对模块基址的偏移(与 Frida module_base.add(x) 一致) */
    uint64_t    static_end;   /* 执行到该地址即停,该地址本身不执行 */
    int         module_only;  /* 1 = 只记录模块内指令;0 = 记录所有可执行映射 */
    int         count;        /* trace 次数:前 count 次执行 trace,之后透传 */
    int         delay_secs;   /* 本条目启动后延迟多少秒装 hook(0 = 立即) */
    uint64_t    log_mask;     /* LOG_INST|LOG_MEM|LOG_REGS|LOG_BRANCH */
} TraceSpec;

typedef struct {
    const char *module;   /* dyld 镜像名子串 */
    uint64_t    offset;   /* 静态偏移(相对模块基址) */
    const char *reg;      /* x0..x28, fp, lr, sp */
    const char *action;   /* cstr|utf8|u32|u64|hexdump|objc|po|其它=仅打印值 */
    uint32_t    size;     /* cstr/utf8 读取上限、hexdump 长度;0=不截断 */
    const char *label;    /* 可选标签 */
} TraceWatch;

/* 运行期填充的表(engine.m 负责填,tramp.c/qbdi_trace.c 只读)。
 * g_traces 与 32 个固定 trampoline 槽位一一对应;g_trace_count 是已启用条数。 */
extern TraceSpec  g_traces[TRACE_MAX_TARGETS];
extern int        g_trace_count;
extern TraceWatch g_watches[TRACE_MAX_WATCHES];
extern int        g_watch_count;

/* 按名字找模块运行时基址(= _dyld_get_image_header,已含 slide)。
 * name 用子串匹配镜像路径。返回 true 表示找到。 */
bool find_module(const char *name, uint64_t *runtime_base);
