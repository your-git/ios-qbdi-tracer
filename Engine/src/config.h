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

typedef enum {
    TRIG_CONSUME_REPEAT = 0,
    TRIG_CONSUME_ONCE,
    TRIG_CONSUME_CUSTOM,
} TrigConsumePolicy;

/* 只作用于一次 QBDI 执行的寄存器覆盖规则。Trace 结束后寄存器现场会恢复。 */
typedef struct {
    uint64_t offset;      /* 当前 trace 模块的静态偏移，命中指令执行前生效 */
    uint64_t value;
    uint8_t  reg_index;   /* 0..28=x0..x28, 29=fp, 30=lr；x17 禁止配置 */
    uint8_t  width;       /* 32=按 wN 写入并清零高位，64=按 xN 写入 */
    uint8_t  every_hit;   /* 0=每次 Trace 仅第一次命中生效，1=每次命中 */
} TraceMutation;

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
    int         max_traces;                     /* custom 策略下允许成功触发 1..16 次 */
    uint32_t    consume_state;                  /* 原子状态:低16位成功数,高16位预占数 */
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
    TrigConsumePolicy trigger_policy;

    TraceMutation *mutations;                    /* 仅改变 QBDI 寄存器状态 */
    int            mutation_count;
} TraceSpec;

/* ===== Hook(用 Dobby 真实修改数据,与 QBDI Trace 无关) ===== *
 *
 * Trace 的 mutations 只改 QBDI 虚拟寄存器、不写回真实 App;Hook 则在目标地址
 * 装 Dobby hook,命中时**真的**改写目标进程的寄存器或内存,续跑后生效。
 * 配置来自 hooks.json(与 config.json/settings.json 平行),由 engine.m 解析。 */

/* 修改内容的类型 */
typedef enum {
    HOOK_VAL_BYTES = 0, /* 十六进制字节序列,按内存顺序写 */
    HOOK_VAL_STRING,    /* UTF-8 字符串,自动补一个 0 结尾 */
    HOOK_VAL_NUMBER,    /* 数值,按 width 小端写 */
} HookValType;

/* 写到哪儿 —— 由"修改类型 + 表达式形态"共同决定(不对称语义,见 hook.c):
 *   数值 + 裸寄存器 x0        → 改寄存器本身(REG)
 *   数值 + [表达式]           → 改内存(MEM),地址 = 表达式求值
 *   字节 + 裸寄存器           → 非法(加载期拒)
 *   字节 + [表达式]           → 改内存
 *   字符串 + 裸寄存器 x0      → 改内存,地址 = x0 的值(当 char* 指针)
 *   字符串 + [表达式]         → 改内存 */
typedef enum {
    HOOK_DST_REG = 0, /* 写寄存器本身(仅 数值 + 裸寄存器) */
    HOOK_DST_MEM,     /* 写内存,地址由 cexpr 求出 */
} HookDstKind;

#define HOOK_VAL_MAX     256 /* 字节/字符串写入上限 */
#define HOOK_MAX_TARGETS 32  /* Hook 条目上限(对应 tramp.c 的 32 个 hook 跳板) */
#define HOOK_MAX_MODS    16  /* 单条 Hook 最多挂多少条修改数据 */

/* 一条"修改数据"功能。 */
typedef struct {
    HookValType type;
    HookDstKind dst;

    /* dst == HOOK_DST_REG:直接写 GPR。0..28=x0..x28, 29=fp, 30=lr。 */
    uint8_t reg_index;

    /* dst == HOOK_DST_MEM:地址表达式。字符串+裸寄存器时 cexpr 就是那个裸寄存器
     * (求值得到 char* 的值);[表达式] 时 cexpr 是方括号内部。 */
    WatchExpr   cexpr;
    const char *expr; /* 表达式原文,仅用于日志 */

    /* 载荷。number/reg 写入用 number;bytes/string/number 内存写入用 payload。 */
    uint8_t  width;                 /* 数值位宽 8/16/32/64;reg 仅 32/64 */
    uint64_t number;                /* 数值原值(REG 写入直接用它) */
    uint8_t  payload[HOOK_VAL_MAX]; /* 要写入内存的字节(number 已按 width 小端) */
    int      nbytes;                /* payload 有效长度 */
} HookMod;

/* 一条 Hook 条目。 */
typedef struct {
    const char *hook_name; /* 用户自定义名称,可为 NULL,仅日志 */
    const char *module;    /* dyld 镜像名子串 */
    uint64_t    target;    /* 目标地址:相对模块基址的偏移 */
    int         delay_secs;/* 延迟多少秒装 hook */
    uint64_t    max_hits;  /* 应用修改的次数上限;0 = 不限 */

    HookMod *mods;
    int      mod_count;
} HookSpec;

extern HookSpec g_hooks[HOOK_MAX_TARGETS];
extern int      g_hook_count;

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
