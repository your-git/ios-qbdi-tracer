#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "qbdi_trace.h"  /* LOG_* */
#include "watch_expr.h"  /* WatchExpr */

/* 触发条件的匹配方式 */
typedef enum {
    TRIG_NONE = 0, /* 无条件(默认):每次命中都 trace */
    TRIG_NOTNULL,  /* 地址可读且非 0 */
    TRIG_BYTES,    /* 字节序列(按内存顺序,与 hexdump 所见一致) */
    TRIG_CSTR,     /* C 字符串(读到 \0 为止) */
    TRIG_U64,      /* 读 8 字节(小端)等于 want_u64 */
} TrigMatch;

/* 期望值出现在哪儿(只对 TRIG_BYTES / TRIG_CSTR 有意义) */
typedef enum {
    TRIG_AT_PREFIX = 0, /* 开头:只读期望值那么长,逐字节比 */
    TRIG_AT_CONTAINS,   /* 包含:读最多 scan 字节(cstr 读到 \0),在里面搜 */
} TrigWhere;

#define TRIG_MAX_BYTES 32     /* 期望值最长 32 字节 */
#define TRIG_MAX_SCAN  0x1000 /* 「包含」的搜索窗口硬上限 4KB */
#define TRIG_DEF_SCAN  0x100  /* 默认窗口 256 字节 */

/* 一条触发条件。条件数组按 JSON 顺序保存；相同 address 共享一个 Dobby hook。 */
typedef struct {
    uint64_t    address;                        /* 模块相对偏移；缺省=trace start */
    const char *expr;                           /* 表达式原文(仅用于日志) */
    WatchExpr   cexpr;                          /* 编译后的取址表达式 */
    TrigMatch   match;
    TrigWhere   where;
    uint32_t    scan;
    uint8_t     want_bytes[TRIG_MAX_BYTES];
    int         want_nbytes;
    uint64_t    want_u64;
    int         consume_state;                  /* 原子状态:0 可用,1 占用中,2 已消耗 */
    uint64_t    filtered;                       /* 不匹配次数(指数退避日志) */
    uint64_t    next_log;
} TraceTrigger;

/* 一条 trace 区间(运行期由 engine.m 从 JSON 填充) */
typedef struct {
    const char *trace_name;   /* 用户自定义名称,仅用于诊断日志,可为 NULL */
    const char *module;       /* dyld 镜像名子串,如 "ModuleName" */
    uint64_t    static_start; /* 相对模块基址的偏移(与 Frida module_base.add(x) 一致) */
    uint64_t    static_end;   /* 执行到该地址即停,该地址本身不执行 */
    int         module_only;  /* 1 = 只记录模块内指令;0 = 记录所有可执行映射 */
    int         count;        /* trace 次数:前 count 次执行 trace,之后透传 */
    int         delay_secs;   /* 本条目启动后延迟多少秒装 hook(0 = 立即) */
    uint64_t    log_mask;     /* LOG_INST|LOG_MEM|LOG_REGS|LOG_BRANCH */
    uint64_t    max_instructions; /* 0=不截断,否则到上限后停止本次 QBDI */

    TraceTrigger *triggers;                      /* 0 条 = 无条件 */
    int           trigger_count;                 /* 条件数量不设产品层上限 */
    int           trigger_once;                  /* 1=成功后各条件只生效一次 */
} TraceSpec;

typedef struct {
    const char *module;   /* dyld 镜像名子串 */
    uint64_t    offset;   /* 静态偏移(相对模块基址) */
    const char *reg;      /* x0..x28, fp, lr, sp —— 无 expr 时的取址来源 */
    const char *expr;     /* 取址表达式原文(可为 NULL),如 "[[x0+8]+0x10]-4" */
    WatchExpr   cexpr;    /* expr 的编译结果;nops > 0 时优先于 reg */
    const char *action;   /* cstr|utf8|u32|u64|hexdump|objc|po|其它=仅打印值 */
    uint32_t    size;     /* cstr/utf8 读取上限、hexdump 长度(十六进制);0=不截断 */
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
