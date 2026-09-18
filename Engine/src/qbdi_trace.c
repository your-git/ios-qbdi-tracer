/* Darwin 的 ucontext.h 需要 _XOPEN_SOURCE 才暴露(已废弃的)ucontext 接口 */
#define _XOPEN_SOURCE 700

#include "qbdi_trace.h"

#include <mach/mach.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <os/log.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <ucontext.h>

#include "QBDI.h"

#include "config.h" /* find_module / g_traces / g_watches */

/* 日志文件:/tmp/qbdi_trace_<年月日时分>.log
 * 文件名在进程首次写日志时按当前时间生成一次(配置靠"重开 app"生效,
 * 所以每次 app 启动 = 一个新的带时间戳日志)。 */
#define TRACE_LOG_DIR    "/tmp"
#define TRACE_LOG_PREFIX "qbdi_trace_"
#define TRACE_STACK_SIZE 0x100000
/* hexdump 的硬上限:size 配大了(hex 输入很容易多打一个 0)也不会把日志写爆 */
#define WATCH_HEXDUMP_MAX 0x10000
/* Dobby 搬走的原函数序言代码范围:覆盖 origin trampoline 里被搬迁的那几条指令 */
#define ORIGIN_SPAN 0x40
/* 不设指令上限时的稀疏进度诊断，不会停止 trace。 */
#define TRACE_PROGRESS_INTERVAL 10000000ULL
#define CONSOLE_PREFIX "[ios-qbdi-tracer]"

/* 手动路径的入参(线程局部) */
__thread uint64_t g_enter_args[8];
__thread void *g_enter_origin;

/* 自动 hook 每目标的运行时状态 */
void *g_origin[TRACE_MAX_TARGETS];
void *g_trigger_origin[TRACE_MAX_TARGETS];
int g_remaining[TRACE_MAX_TARGETS];
uint64_t g_module_base[TRACE_MAX_TARGETS];

/* 自定义触发只授权“同一线程的下一次 start”，绝不能用全局布尔值，
 * 否则 A 线程命中会错误触发 B 线程。32 个槽位正好用一个 bitmask。 */
static __thread uint32_t g_trigger_armed_mask;
/* QBDI 动态路径可能又走到外部触发 hook；此时只透传，不能反过来授权
 * 嵌套 trace。这是重入保护，不代表可以忽略 Hook 地址选择。 */
static __thread unsigned int g_inside_qbdi_trace;

typedef struct {
    const char *module;
    uint64_t mask;
    uint64_t module_base;
    uint64_t static_start;
    uint64_t origin;
    FILE *out;
    uint64_t inst_count;
    uint64_t max_instructions;
    uint64_t end;
    uint64_t next_progress;
    uint64_t stop_pc; /* 被指令上限拦下的下一条指令 */
    bool instruction_limit_reached;
    uint64_t prev[32]; /* x0..x28, fp, lr, sp 寄存器增量对比 */
    __uint128_t prev_v[32]; /* v0..v31 向量寄存器增量对比(仅 LOG_VREG 时用) */
    int has_prev;
} TraceCtx;

static const char *const g_reg_names[32] = {
    "x0",  "x1",  "x2",  "x3",  "x4",  "x5",  "x6",  "x7",
    "x8",  "x9",  "x10", "x11", "x12", "x13", "x14", "x15",
    "x16", "x17", "x18", "x19", "x20", "x21", "x22", "x23",
    "x24", "x25", "x26", "x27", "x28", "fp",  "lr",  "sp",
};

static const char *const g_vreg_names[32] = {
    "v0",  "v1",  "v2",  "v3",  "v4",  "v5",  "v6",  "v7",
    "v8",  "v9",  "v10", "v11", "v12", "v13", "v14", "v15",
    "v16", "v17", "v18", "v19", "v20", "v21", "v22", "v23",
    "v24", "v25", "v26", "v27", "v28", "v29", "v30", "v31",
};

/* 把 128 位向量寄存器格式化成 "0x<高64><低64>" 写进日志 */
static void print_vreg(FILE *out, const char *name, __uint128_t v) {
    uint64_t hi = (uint64_t)(v >> 64);
    uint64_t lo = (uint64_t)v;
    fprintf(out, "\"%s\": \"0x%016llx%016llx\"", name,
            (unsigned long long)hi, (unsigned long long)lo);
}

/* 递归锁:qbdi_trace_logf 内部也会上锁,允许在 trace() 持锁期间调用 */
static pthread_mutex_t g_trace_lock;
static FILE *g_log = NULL;

static void trace_lock_init(void) {
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&g_trace_lock, &attr);
    pthread_mutexattr_destroy(&attr);
}
static pthread_once_t g_trace_lock_once = PTHREAD_ONCE_INIT;
#define trace_lock_ensure() pthread_once(&g_trace_lock_once, trace_lock_init)

/* 系统控制台只承载运行状态和故障诊断，不镜像逐指令输出，避免把 Console 刷爆。 */
static void console_vlogf(const char *fmt, va_list ap) {
    char msg[2048];
    vsnprintf(msg, sizeof(msg), fmt, ap);
    size_t n = strlen(msg);
    while (n > 0 && (msg[n - 1] == '\n' || msg[n - 1] == '\r')) {
        msg[--n] = '\0';
    }
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "%{public}s %{public}s",
                     CONSOLE_PREFIX, msg);
}

void qbdi_console_logf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    console_vlogf(fmt, ap);
    va_end(ap);
}

static FILE *trace_log_open(void) {
    if (g_log == NULL) {
        char path[256];
        time_t now = time(NULL);
        struct tm tm;
        localtime_r(&now, &tm);
        char ts[16];
        /* 年月日时分:YYYYMMDDHHMM */
        strftime(ts, sizeof(ts), "%Y%m%d%H%M", &tm);
        snprintf(path, sizeof(path), "%s/%s%s.log", TRACE_LOG_DIR,
                 TRACE_LOG_PREFIX, ts);
        g_log = fopen(path, "a");
        if (g_log != NULL) {
            qbdi_console_logf("trace log opened: %s", path);
        } else {
            qbdi_console_logf("trace log open FAILED: %s", path);
        }
    }
    return g_log;
}

/* ---- watch:地址触发的寄存器解引用 ---- */

/* 安全读 n 字节;返回实际读到的字节数(读不进返回 0,不崩) */
static size_t safe_read(uint64_t addr, void *buf, size_t n) {
    if (n == 0) {
        return 0;
    }
    vm_size_t outsz = n;
    kern_return_t kr = vm_read_overwrite(
        mach_task_self(), (vm_address_t)addr, (vm_size_t)n,
        (vm_address_t)(uintptr_t)buf, &outsz);
    return kr == KERN_SUCCESS ? (size_t)outsz : 0;
}

/* 寄存器名 → 值;不认识的返回 false(打印 <absent>) */
static bool watch_reg_value(const GPRState *gpr, const char *name, uint64_t *out) {
    if (name == NULL) {
        return false;
    }
    if (name[0] == 'x' && name[1] >= '0' && name[1] <= '9') {
        char *end = NULL;
        long n = strtol(name + 1, &end, 10);
        if (end != NULL && *end == '\0' && n >= 0 && n <= 28) {
            *out = ((const uint64_t *)gpr)[n];
            return true;
        }
    }
    if (strcmp(name, "fp") == 0) {
        *out = gpr->x29;
        return true;
    }
    if (strcmp(name, "lr") == 0) {
        *out = gpr->lr;
        return true;
    }
    if (strcmp(name, "sp") == 0) {
        *out = gpr->sp;
        return true;
    }
    return false;
}

/* 打印一段字节(转义不可打印字符) */
static void watch_print_buf(FILE *out, const unsigned char *s, size_t n) {
    fputc('"', out);
    for (size_t i = 0; i < n; i++) {
        unsigned char ch = s[i];
        if (ch == '"' || ch == '\\') {
            fputc('\\', out);
            fputc(ch, out);
        } else if (ch == '\n') {
            fputs("\\n", out);
        } else if (ch == '\t') {
            fputs("\\t", out);
        } else if (ch == '\r') {
            fputs("\\r", out);
        } else if (ch >= 0x20 && ch < 0x7f) {
            fputc(ch, out);
        } else {
            fprintf(out, "\\x%02x", ch);
        }
    }
    fputc('"', out);
}

/* 从 addr 读到第一个 \0(不截断),cap 是硬上限防失控 */
static size_t watch_read_string(uint64_t addr, unsigned char *buf, size_t cap) {
    size_t len = 0;
    unsigned char tmp[64];
    while (len < cap) {
        size_t want = sizeof(tmp);
        if (want > cap - len) {
            want = cap - len;
        }
        size_t got = safe_read(addr + len, tmp, want);
        if (got == 0) {
            break;
        }
        size_t i = 0;
        while (i < got && len < cap) {
            if (tmp[i] == '\0') {
                return len;
            }
            buf[len++] = tmp[i++];
        }
        if (got < want) {
            break;
        }
    }
    return len;
}

static bool watch_dump_hex(FILE *out, uint64_t addr, uint32_t size) {
    unsigned char buf[256];
    size_t total = size ? size : 64;
    bool truncated = false;
    if (total > WATCH_HEXDUMP_MAX) {
        total = WATCH_HEXDUMP_MAX;
        truncated = true;
    }
    size_t off = 0;
    while (off < total) {
        size_t want = sizeof(buf);
        if (want > total - off) {
            want = total - off;
        }
        size_t got = safe_read(addr + off, buf, want);
        if (got == 0) {
            if (off == 0) {
                fprintf(out, "(not a pointer)");
            }
            fputc('\n', out);
            return false;
        }
        /* 行首打绝对地址:起点可能是 x0-0x110 这种,相对偏移看不出自己在哪 */
        for (size_t i = 0; i < got; i += 16) {
            fprintf(out, "    %016llx  ",
                    (unsigned long long)(addr + off + i));
            for (size_t j = 0; j < 16; j++) {
                if (i + j < got) {
                    fprintf(out, "%02x ", buf[i + j]);
                } else {
                    fputs("   ", out);
                }
            }
            fputs(" |", out);
            for (size_t j = 0; j < 16 && i + j < got; j++) {
                unsigned char ch = buf[i + j];
                fputc(ch >= 0x20 && ch < 0x7f ? ch : '.', out);
            }
            fputs("|\n", out);
        }
        off += got;
        if (got < want) {
            break;
        }
    }
    if (truncated) {
        fprintf(out, "    ... (truncated at 0x%x bytes)\n", WATCH_HEXDUMP_MAX);
    }
    return true;
}

/* objc/po:把 val 当 ObjC 对象解析。先粗校验 isa 降低野指针风险。 */
static bool watch_handle_objc(FILE *out, uint64_t val) {
    uint64_t isa = 0;
    if (safe_read(val, &isa, sizeof(isa)) != sizeof(isa)) {
        fprintf(out, " (not an ObjC object)\n");
        return false;
    }
    uint64_t probe = 0;
    if (safe_read(isa, &probe, sizeof(probe)) != sizeof(probe)) {
        fprintf(out, " (not an ObjC object)\n");
        return false;
    }
    id obj = (id)(uintptr_t)val;
    Class cls = object_getClass(obj);
    if (cls == NULL) {
        fprintf(out, " (not an ObjC object)\n");
        return false;
    }

    SEL isKind = sel_registerName("isKindOfClass:");
    if (objc_getClass("NSString") &&
        ((BOOL (*)(id, SEL, Class))objc_msgSend)(obj, isKind, objc_getClass("NSString"))) {
        const char *s = (const char *)((const char *(*)(id, SEL))objc_msgSend)(
            obj, sel_registerName("UTF8String"));
        fprintf(out, " %s\n", s ? s : "(nil)");
    } else if (objc_getClass("NSData") &&
               ((BOOL (*)(id, SEL, Class))objc_msgSend)(obj, isKind, objc_getClass("NSData"))) {
        uint64_t len = (uint64_t)((uint64_t (*)(id, SEL))objc_msgSend)(
            obj, sel_registerName("length"));
        const void *bytes = (const void *)((const void *(*)(id, SEL))objc_msgSend)(
            obj, sel_registerName("bytes"));
        fprintf(out, " NSData len=%llu", (unsigned long long)len);
        if (bytes != NULL && len > 0) {
            size_t show = len < 64 ? (size_t)len : 64;
            const unsigned char *p = (const unsigned char *)bytes;
            fputs(" hex=", out);
            for (size_t i = 0; i < show; i++) {
                fprintf(out, "%02x", p[i]);
            }
            if (len > 64) {
                fputs("...", out);
            }
        }
        fputc('\n', out);
    } else {
        id desc = ((id (*)(id, SEL))objc_msgSend)(obj, sel_registerName("description"));
        const char *s = desc ? (const char *)((const char *(*)(id, SEL))objc_msgSend)(
                                  desc, sel_registerName("UTF8String"))
                             : NULL;
        fprintf(out, " %s\n", s ? s : "(nil)");
    }
    return true;
}

/* 把 QBDI 的 GPRState 摊成 watch 表达式用的寄存器数组(下标见 watch_expr.h) */
static void watch_fill_regs(const GPRState *gpr, uint64_t regs[WEXPR_NREGS]) {
    const uint64_t *raw = (const uint64_t *)gpr; /* 前 29 项就是 x0..x28 */
    for (int i = 0; i < 29; i++) {
        regs[i] = raw[i];
    }
    regs[WEXPR_REG_FP] = gpr->x29;
    regs[WEXPR_REG_LR] = gpr->lr;
    regs[WEXPR_REG_SP] = gpr->sp;
    regs[WEXPR_REG_PC] = gpr->pc;
}

/* 在 inst_cb 里按 rel 匹配 watch;返回命中的个数(用于决定是否 flush) */
static int watch_handle(FILE *out, const GPRState *gpr, const char *module,
                        uint64_t rel) {
    int fired = 0;
    for (int i = 0; i < g_watch_count; i++) {
        const TraceWatch *w = &g_watches[i];
        if (w->offset != rel || strstr(module, w->module) == NULL) {
            continue;
        }
        fired++;
        uint64_t val = 0;
        /* 显示名:有表达式就显示表达式原文,否则显示寄存器名 */
        const char *disp = (w->cexpr.nops > 0 && w->expr != NULL) ? w->expr : w->reg;
        fprintf(out, "[watch %s+0x%llx] ", module, (unsigned long long)w->offset);
        if (w->label != NULL && w->label[0]) {
            fprintf(out, "%s ", w->label);
        }
        if (w->cexpr.nops > 0) {
            uint64_t regs[WEXPR_NREGS];
            watch_fill_regs(gpr, regs);
            WatchExprTrace tr;
            if (!wexpr_eval(&w->cexpr, regs, safe_read, &val, &tr)) {
                /* 多级指针配错时,光说"读不出来"没法排查 —— 把每一级都列出来 */
                fprintf(out, "%s = <unreadable>\n", disp);
                wexpr_print_trace(out, &tr);
                qbdi_console_logf("watch failed: %s+0x%llx %s unreadable",
                                  module, (unsigned long long)w->offset, disp);
                continue;
            }
        } else if (!watch_reg_value(gpr, w->reg, &val)) {
            fprintf(out, "%s = <absent>\n", disp ? disp : "(none)");
            qbdi_console_logf("watch failed: %s+0x%llx register %s absent",
                              module, (unsigned long long)w->offset,
                              disp ? disp : "(none)");
            continue;
        }
        fprintf(out, "%s=0x%llx", disp, (unsigned long long)val);
        if (val == 0) {
            fprintf(out, " (null)\n");
            qbdi_console_logf("watch returned null: %s+0x%llx %s",
                              module, (unsigned long long)w->offset, disp);
            continue;
        }

        const char *a = w->action != NULL ? w->action : "";
        if (strcmp(a, "cstr") == 0 || strcmp(a, "utf8") == 0) {
            unsigned char sbuf[4096];
            size_t cap = w->size ? w->size : sizeof(sbuf);
            if (cap > sizeof(sbuf)) {
                cap = sizeof(sbuf);
            }
            size_t len = watch_read_string(val, sbuf, cap);
            if (len == 0) {
                unsigned char c = 0;
                if (safe_read(val, &c, 1) == 1) {
                    fputs(" \"\"\n", out);
                } else {
                    fputs(" (not a pointer)\n", out);
                    qbdi_console_logf(
                        "watch failed: %s+0x%llx %s=0x%llx is not readable",
                        module, (unsigned long long)w->offset, disp,
                        (unsigned long long)val);
                }
            } else {
                fputc(' ', out);
                watch_print_buf(out, sbuf, len);
                fputc('\n', out);
            }
        } else if (strcmp(a, "u32") == 0) {
            uint32_t v = 0;
            if (safe_read(val, &v, sizeof(v)) == sizeof(v)) {
                fprintf(out, " = 0x%08x\n", v);
            } else {
                fputs(" (not a pointer)\n", out);
                qbdi_console_logf(
                    "watch failed: %s+0x%llx %s=0x%llx cannot read u32",
                    module, (unsigned long long)w->offset, disp,
                    (unsigned long long)val);
            }
        } else if (strcmp(a, "u64") == 0) {
            uint64_t v = 0;
            if (safe_read(val, &v, sizeof(v)) == sizeof(v)) {
                fprintf(out, " = 0x%llx\n", (unsigned long long)v);
            } else {
                fputs(" (not a pointer)\n", out);
                qbdi_console_logf(
                    "watch failed: %s+0x%llx %s=0x%llx cannot read u64",
                    module, (unsigned long long)w->offset, disp,
                    (unsigned long long)val);
            }
        } else if (strcmp(a, "hexdump") == 0) {
            fputc('\n', out);
            if (!watch_dump_hex(out, val, w->size)) {
                qbdi_console_logf(
                    "watch failed: %s+0x%llx %s=0x%llx cannot hexdump",
                    module, (unsigned long long)w->offset, disp,
                    (unsigned long long)val);
            }
        } else if (strcmp(a, "objc") == 0 || strcmp(a, "po") == 0) {
            if (!watch_handle_objc(out, val)) {
                qbdi_console_logf(
                    "watch failed: %s+0x%llx %s=0x%llx is not an ObjC object",
                    module, (unsigned long long)w->offset, disp,
                    (unsigned long long)val);
            }
        } else {
            /* 未知 action:只打印寄存器值 */
            fputc('\n', out);
        }
    }
    return fired;
}

/* ---- 触发条件 ---- */

/* 每目标被条件挡掉的次数,以及下次该在第几次打诊断(指数退避:1/10/100/1000/...) */
static uint64_t g_filtered[TRACE_MAX_TARGETS];
static uint64_t g_trig_next_log[TRACE_MAX_TARGETS];

/* 把 hook 点的寄存器快照摊成表达式用的数组。
 * TraceRegFile 里没有 pc,填 hook 点地址(那一刻唯一合理的值)。 */
static void trig_fill_regs(const TraceRegFile *rf, uint64_t hook_pc,
                           uint64_t regs[WEXPR_NREGS]) {
    for (int i = 0; i < 29; i++) {
        regs[i] = rf->x[i];
    }
    regs[WEXPR_REG_FP] = rf->fp;
    regs[WEXPR_REG_LR] = rf->lr;
    regs[WEXPR_REG_SP] = rf->sp;
    regs[WEXPR_REG_PC] = hook_pc;
}

/* 朴素子串搜索(窗口最多 4KB、needle 最多 32 字节,不值得上 KMP) */
static bool mem_contains(const unsigned char *hay, size_t hn,
                         const unsigned char *needle, size_t nn) {
    if (nn == 0 || hn < nn) {
        return false;
    }
    for (size_t i = 0; i + nn <= hn; i++) {
        if (memcmp(hay + i, needle, nn) == 0) {
            return true;
        }
    }
    return false;
}

/* 纯比较:data 是已经读到的 n 字节,判断是否满足条件。
 * 不碰内存、不依赖 mach,所以能在 mac 上单独提取出来测(见 tests/trigger_test.m)。 */
static bool trig_compare(const TraceSpec *spec, const unsigned char *data,
                         size_t n) {
    int want = spec->want_nbytes;
    if (want <= 0 || want > TRIG_MAX_BYTES) {
        return false;
    }
    if (spec->trigger_where == TRIG_AT_CONTAINS) {
        return mem_contains(data, n, spec->want_bytes, (size_t)want);
    }
    /* 开头:长度不够就谈不上相等 */
    if (n < (size_t)want) {
        return false;
    }
    return memcmp(data, spec->want_bytes, (size_t)want) == 0;
}

/* 尽量读 want 字节。vm_read_overwrite 一旦范围末尾跨到未映射页会**整块失败**,
 * 所以整块读不到时退一步:只读到本页末尾。返回实际读到的字节数。 */
static size_t trigger_read(uint64_t addr, unsigned char *buf, size_t want) {
    if (want == 0) {
        return 0;
    }
    size_t got = safe_read(addr, buf, want);
    if (got > 0) {
        return got;
    }
    size_t pg = (size_t)vm_page_size ? (size_t)vm_page_size : 0x4000;
    size_t to_page_end = pg - (size_t)(addr & (pg - 1));
    if (to_page_end < want) {
        return safe_read(addr, buf, to_page_end);
    }
    return 0;
}

/* 一次条件求值的全过程,失败时用来打诊断 */
typedef struct {
    bool           addr_ok;   /* 表达式是否求出了地址 */
    uint64_t       addr;
    WatchExprTrace tr;        /* 取址失败时的逐级链 */
    bool           read_ok;   /* 是否读到了数据 */
    bool           truncated; /* cstr:读满窗口都没遇到 \0(字符串比窗口长) */
    size_t         got_len;   /* 实际读到多少字节(cstr 已按 \0 截断) */
    unsigned char  got[TRIG_MAX_SCAN];
} TrigProbe;

/* 条件是否满足。无条件恒为 true;地址求不出来/读不到一律算不满足。
 * probe 必传(内部直接用它的缓冲读数据),调用方按需拿去打诊断。 */
static bool trigger_hit(const TraceSpec *spec, const TraceRegFile *rf,
                        uint64_t hook_pc, TrigProbe *probe) {
    probe->addr_ok = false;
    probe->addr    = 0;
    probe->read_ok   = false;
    probe->truncated = false;
    probe->got_len   = 0;
    memset(&probe->tr, 0, sizeof(probe->tr));

    if (spec->trigger_match == TRIG_NONE) {
        return true;
    }
    uint64_t regs[WEXPR_NREGS];
    trig_fill_regs(rf, hook_pc, regs);
    if (!wexpr_eval(&spec->trigger_cexpr, regs, safe_read, &probe->addr,
                    &probe->tr)) {
        return false;
    }
    probe->addr_ok = true;
    if (probe->addr == 0) {
        return false; /* 这一步就把 "(null)" 那些调用全挡掉了 */
    }

    if (spec->trigger_match == TRIG_NOTNULL) {
        probe->got_len = trigger_read(probe->addr, probe->got, 1);
        probe->read_ok = probe->got_len == 1;
        return probe->read_ok;
    }
    if (spec->trigger_match == TRIG_U64) {
        probe->got_len = trigger_read(probe->addr, probe->got, sizeof(uint64_t));
        if (probe->got_len != sizeof(uint64_t)) {
            return false;
        }
        probe->read_ok = true;
        uint64_t v = 0;
        memcpy(&v, probe->got, sizeof(v));
        return v == spec->want_u64;
    }

    /* 「开头」只需读期望值那么长;「包含」要读一个窗口 */
    size_t want = spec->trigger_where == TRIG_AT_CONTAINS
                      ? (size_t)spec->trigger_scan
                      : (size_t)spec->want_nbytes;
    if (want == 0 || want > TRIG_MAX_SCAN) {
        want = TRIG_DEF_SCAN;
    }
    /* 一次读满,不要像 watch_read_string 那样每 64 字节一趟 mach trap ——
     * 这段代码在每次 hook 命中都跑,trap 次数才是成本所在 */
    probe->got_len = trigger_read(probe->addr, probe->got, want);
    if (probe->got_len == 0) {
        return false;
    }
    probe->read_ok = true;
    /* 字符串:读到的窗口按第一个 \0 截断,免得搜到字符串之后的无关数据上去 */
    if (spec->trigger_match == TRIG_CSTR) {
        unsigned char *nul = memchr(probe->got, '\0', probe->got_len);
        if (nul != NULL) {
            probe->got_len = (size_t)(nul - probe->got);
        } else {
            probe->truncated = true; /* 窗口内没有结尾,后面还有内容没看到 */
        }
    }
    return trig_compare(spec, probe->got, probe->got_len);
}

static const char *trig_match_name(TrigMatch m) {
    switch (m) {
        case TRIG_NOTNULL: return "notnull";
        case TRIG_BYTES:   return "bytes";
        case TRIG_CSTR:    return "cstr";
        case TRIG_U64:     return "u64";
        case TRIG_NONE:    break;
    }
    return "none";
}

/* 不匹配时的诊断:地址 + 实际读到的数据 + 期望值 + 调用现场。
 * 按指数退避调用(第 1/10/100/1000... 次),所以可以打得详细些。
 * 带上 lr/sp/线程是为了分辨"同一个循环在正常推进"和"真的卡住不动":
 * sp 与 lr 两次之间完全一样,说明还在同一次函数调用的同一个循环里。 */
static void trigger_log_miss(const TraceSpec *spec, const TrigProbe *probe,
                             uint64_t nth, const TraceRegFile *rf) {
    const char *where =
        spec->trigger_where == TRIG_AT_CONTAINS ? "contains" : "prefix";

    if (!probe->addr_ok) {
        qbdi_console_logf("[%s] trigger miss #%llu: %s unreadable",
                          spec->module, (unsigned long long)nth,
                          spec->trigger_expr);
    } else if (probe->addr == 0) {
        qbdi_console_logf("[%s] trigger miss #%llu: %s returned null",
                          spec->module, (unsigned long long)nth,
                          spec->trigger_expr);
    } else if (!probe->read_ok) {
        qbdi_console_logf("[%s] trigger miss #%llu: read failed at 0x%llx",
                          spec->module, (unsigned long long)nth,
                          (unsigned long long)probe->addr);
    } else {
        qbdi_console_logf("[%s] trigger miss #%llu: content did not match (%s)",
                          spec->module, (unsigned long long)nth, where);
    }

    /* 整段在一次加锁里写完:多线程同时命中时,want/got 这几行不能被别人插进来。
     * (递归锁,内部再调 qbdi_trace_logf 也安全) */
    trace_lock_ensure();
    pthread_mutex_lock(&g_trace_lock);
    FILE *out = trace_log_open();
    if (out == NULL) {
        pthread_mutex_unlock(&g_trace_lock);
        return;
    }

    if (!probe->addr_ok) {
        fprintf(out, "[%s] trigger miss #%llu: %s = <unreadable>\n",
                spec->module, (unsigned long long)nth, spec->trigger_expr);
        wexpr_print_trace(out, &probe->tr);
        fflush(out);
        pthread_mutex_unlock(&g_trace_lock);
        return;
    }
    if (probe->addr == 0) {
        fprintf(out, "[%s] trigger miss #%llu: %s = 0x0 (null)\n", spec->module,
                (unsigned long long)nth, spec->trigger_expr);
        fflush(out);
        pthread_mutex_unlock(&g_trace_lock);
        return;
    }

    fprintf(out, "[%s] trigger miss #%llu: %s = 0x%llx\n", spec->module,
            (unsigned long long)nth, spec->trigger_expr,
            (unsigned long long)probe->addr);
    fprintf(out, "    at  : lr=0x%llx sp=0x%llx thread=%p\n",
            (unsigned long long)rf->lr, (unsigned long long)rf->sp,
            (void *)pthread_self());

    if (spec->trigger_match == TRIG_NOTNULL) {
        fprintf(out, "    want: notnull (readable and non-zero)\n");
        fprintf(out, "    got : unreadable at 0x%llx\n",
                (unsigned long long)probe->addr);
        fflush(out);
        pthread_mutex_unlock(&g_trace_lock);
        return;
    }
    if (spec->trigger_match == TRIG_U64) {
        fprintf(out, "    want: u64 = 0x%016llx\n",
                (unsigned long long)spec->want_u64);
        if (probe->read_ok) {
            uint64_t v = 0;
            memcpy(&v, probe->got, sizeof(v));
            fprintf(out, "    got : u64 = 0x%016llx\n", (unsigned long long)v);
        } else {
            fprintf(out, "    got : read failed\n");
        }
        fflush(out);
        pthread_mutex_unlock(&g_trace_lock);
        return;
    }
    if (spec->trigger_match == TRIG_CSTR) {
        fprintf(out, "    want: cstr %s ", where);
        watch_print_buf(out, spec->want_bytes, (size_t)spec->want_nbytes);
        fputc('\n', out);
        fprintf(out, "    got : ");
        if (probe->read_ok) {
            /* 太长就截断,日志里不需要完整的几 KB */
            size_t show = probe->got_len < 96 ? probe->got_len : 96;
            watch_print_buf(out, probe->got, show);
            fprintf(out, " (len 0x%zx)\n", probe->got_len);
            /* 读满窗口还没遇到 \0 = 字符串被截断了,要找的东西很可能在后面。
             * 不明说的话,日志上只表现为一个"恰好等于窗口大小"的 len,看不出来。 */
            if (probe->truncated) {
                fprintf(out,
                        "    note: no NUL within 0x%x bytes - string is longer "
                        "than the window, raise triggerScan\n",
                        spec->trigger_scan);
            }
        } else {
            fprintf(out, "read failed\n");
        }
        fflush(out);
        pthread_mutex_unlock(&g_trace_lock);
        return;
    }
    /* TRIG_BYTES */
    fprintf(out, "    want: bytes %s ", where);
    for (int i = 0; i < spec->want_nbytes; i++) {
        fprintf(out, "%02x", spec->want_bytes[i]);
    }
    fputc('\n', out);
    fprintf(out, "    got : ");
    if (probe->read_ok) {
        size_t show = probe->got_len < 32 ? probe->got_len : 32;
        for (size_t i = 0; i < show; i++) {
            fprintf(out, "%02x", probe->got[i]);
        }
        if (show < probe->got_len) {
            fprintf(out, "...");
        }
        fprintf(out, " (read 0x%zx bytes)\n", probe->got_len);
    } else {
        fprintf(out, "read failed\n");
    }
    fflush(out);
    pthread_mutex_unlock(&g_trace_lock);
}

/* 外部触发 hook 和 start hook 共用同一套指数退避诊断。 */
static void trigger_record_miss(const TraceSpec *spec, int idx,
                                const TrigProbe *probe,
                                const TraceRegFile *rf) {
    uint64_t n = __atomic_add_fetch(&g_filtered[idx], 1, __ATOMIC_RELAXED);
    uint64_t next = __atomic_load_n(&g_trig_next_log[idx], __ATOMIC_RELAXED);
    if (next == 0) next = 1;
    if (n < next) return;
    if (__atomic_compare_exchange_n(&g_trig_next_log[idx], &next, next * 10,
                                    false, __ATOMIC_RELAXED,
                                    __ATOMIC_RELAXED)) {
        trigger_log_miss(spec, probe, n, rf);
    }
}

/* 指令级回调:PREINST,每条指令执行前触发 */
static VMAction inst_cb(VMInstanceRef vm, GPRState *gpr, FPRState *fpr,
                        void *data) {
    TraceCtx *c = (TraceCtx *)data;

    const InstAnalysis *ia =
        qbdi_getInstAnalysis(vm,
                             QBDI_ANALYSIS_INSTRUCTION | QBDI_ANALYSIS_DISASSEMBLY);
    if (ia == NULL) {
        return QBDI_CONTINUE;
    }
    /* 0 表示严格跑到 qbdi_run 的 stop address。上限检查放在计数前，
     * 这样日志中的 inst 始终是实际执行过的指令数，不再出现
     * “上限 + 1”。 */
    if (c->max_instructions != 0 &&
        c->inst_count >= c->max_instructions) {
        c->instruction_limit_reached = true;
        c->stop_pc = ia->address;
        return QBDI_STOP;
    }
    c->inst_count++;
    if (c->max_instructions == 0 && c->inst_count == c->next_progress) {
        qbdi_console_logf(
            "[%s] trace still running: inst=%llu pc=0x%llx end=0x%llx",
            c->module, (unsigned long long)c->inst_count,
            (unsigned long long)ia->address, (unsigned long long)c->end);
        if (UINT64_MAX - c->next_progress >= TRACE_PROGRESS_INTERVAL) {
            c->next_progress += TRACE_PROGRESS_INTERVAL;
        }
    }

    /* 相对模块偏移:Dobby origin 序言映射回模块偏移,其余直接减模块基址 */
    uint64_t rel;
    if (c->origin && ia->address >= c->origin &&
        ia->address < c->origin + ORIGIN_SPAN) {
        rel = c->static_start + (ia->address - c->origin);
    } else {
        rel = ia->address - c->module_base;
    }

    if (c->mask & LOG_INST) {
        /* 当前寄存器快照(x0..x28, fp, lr, sp) */
        uint64_t cur[32];
        if (gpr != NULL) {
            memcpy(cur, gpr, 29 * sizeof(uint64_t)); /* x0..x28 */
            cur[29] = gpr->x29;
            cur[30] = gpr->lr;
            cur[31] = gpr->sp;
        } else {
            memset(cur, 0, sizeof(cur));
        }

        /* 0x<绝对地址> (<模块>!0x<偏移>): <反汇编> */
        fprintf(c->out, "0x%llx (%s!0x%llx): %s",
                (unsigned long long)ia->address, c->module,
                (unsigned long long)rel, ia->disassembly);

        if (!c->has_prev) {
            /* 第一条指令:打印全部寄存器 */
            fprintf(c->out, "   {");
            for (int i = 0; i < 32; i++) {
                if (i) fprintf(c->out, ", ");
                fprintf(c->out, "\"%s\": \"0x%016llx\"", g_reg_names[i],
                        (unsigned long long)cur[i]);
            }
            fprintf(c->out, "}\n");
        } else {
            /* 后续:只打印变化的寄存器 */
            int first = 1;
            for (int i = 0; i < 32; i++) {
                if (cur[i] != c->prev[i]) {
                    if (first) {
                        fprintf(c->out, "   {");
                        first = 0;
                    } else {
                        fprintf(c->out, ", ");
                    }
                    fprintf(c->out, "\"%s\": \"0x%016llx\"", g_reg_names[i],
                            (unsigned long long)cur[i]);
                }
            }
            if (!first) fprintf(c->out, "}\n");
            else fprintf(c->out, "\n");
        }

        /* 向量寄存器 v0-v31:单独一行,同样只打变化的(首条打全部)。
         * 放在通用寄存器之后、更新 prev 之前,复用 has_prev 判断首条。 */
        if ((c->mask & LOG_VREG) && fpr != NULL) {
            __uint128_t vcur[32];
            memcpy(vcur, fpr, 32 * sizeof(__uint128_t)); /* FPRState 前 32 项即 v0..v31 */
            if (!c->has_prev) {
                fprintf(c->out, "   V{");
                for (int i = 0; i < 32; i++) {
                    if (i) fprintf(c->out, ", ");
                    print_vreg(c->out, g_vreg_names[i], vcur[i]);
                }
                fprintf(c->out, "}\n");
            } else {
                int vfirst = 1;
                for (int i = 0; i < 32; i++) {
                    if (vcur[i] != c->prev_v[i]) {
                        if (vfirst) { fprintf(c->out, "   V{"); vfirst = 0; }
                        else fprintf(c->out, ", ");
                        print_vreg(c->out, g_vreg_names[i], vcur[i]);
                    }
                }
                if (!vfirst) fprintf(c->out, "}\n");
            }
            memcpy(c->prev_v, vcur, sizeof(vcur));
        }

        memcpy(c->prev, cur, sizeof(cur));
        c->has_prev = 1;
    }

    /* watch:按相对偏移匹配,命中就读取寄存器并解引用(watch 数据要紧,立即 flush) */
    if (watch_handle(c->out, gpr, c->module, rel) > 0) {
        fflush(c->out);
    }

    if ((c->mask & LOG_MEM) && (ia->mayLoad || ia->mayStore)) {
        size_t n = 0;
        MemoryAccess *ma = qbdi_getInstMemoryAccess(vm, &n);
        for (size_t i = 0; i < n; i++) {
            char rw[3] = { '-', '-', '\0' };
            if (ma[i].type & QBDI_MEMORY_READ) {
                rw[0] = 'R';
            }
            if (ma[i].type & QBDI_MEMORY_WRITE) {
                rw[1] = 'W';
            }
            fprintf(c->out, "    MEM %s 0x%llx +%u = 0x%llx\n", rw,
                    (unsigned long long)ma[i].accessAddress, ma[i].size,
                    (unsigned long long)ma[i].value);
        }
    }

    return QBDI_CONTINUE;
}

void qbdi_trace_logf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    va_list console_ap;
    va_copy(console_ap, ap);
    console_vlogf(fmt, console_ap);
    va_end(console_ap);

    trace_lock_ensure();
    pthread_mutex_lock(&g_trace_lock);
    FILE *out = trace_log_open();
    if (out != NULL) {
        vfprintf(out, fmt, ap);
        fflush(out);
    }
    pthread_mutex_unlock(&g_trace_lock);
    va_end(ap);
}

/* ---- 崩溃诊断:捕获 SIGSEGV/BUS/ILL/ABRT,记录 PC/寄存器后重抛 ----
 * 越狱机常不生成 .ips 崩溃日志,有了这个至少能拿到崩溃 PC。 */
static void crash_diag_handler(int sig, siginfo_t *info, void *uctx_v) {
    ucontext_t *uc = (ucontext_t *)uctx_v;
    uint64_t pc = 0, lr = 0, sp = 0;
    if (uc != NULL) {
        pc = (uint64_t)uc->uc_mcontext->__ss.__pc;
        lr = (uint64_t)uc->uc_mcontext->__ss.__lr;
        sp = (uint64_t)uc->uc_mcontext->__ss.__sp;
    }
    uint64_t fault = (uint64_t)(uintptr_t)(info ? info->si_addr : NULL);
    qbdi_trace_logf("[crash] signal=%d(%s) pc=0x%llx lr=0x%llx sp=0x%llx fault=0x%llx\n",
                    sig, strsignal(sig), (unsigned long long)pc,
                    (unsigned long long)lr, (unsigned long long)sp,
                    (unsigned long long)fault);
    signal(sig, SIG_DFL);
    raise(sig);
}

void qbdi_trace_crash_diag_init(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = crash_diag_handler;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    qbdi_trace_logf("[QBDITracer] crash diag handlers installed\n");
}

void qbdi_trace_init_state(void) {
    g_trigger_armed_mask = 0;
    g_inside_qbdi_trace = 0;
    for (int i = 0; i < g_trace_count && i < TRACE_MAX_TARGETS; i++) {
        g_origin[i] = NULL;
        g_trigger_origin[i] = NULL;
        g_module_base[i] = 0;
        g_remaining[i] = g_traces[i].count;
        g_filtered[i] = 0;
        g_trig_next_log[i] = 1;
    }
}

/* 核心:用 rf 里的寄存器做一次 QBDI trace,rf 更新为停止时的寄存器状态。
 * 返回续跑地址(end)。 */
static uint64_t run_trace(const TraceSpec *spec, uint64_t base, void *origin,
                          TraceRegFile *rf, int no) {
    uint64_t start = base + spec->static_start;
    uint64_t end = base + spec->static_end;
    uint64_t entry = origin != NULL ? (uint64_t)(uintptr_t)origin : start;

    trace_lock_ensure();
    pthread_mutex_lock(&g_trace_lock);

    FILE *out = trace_log_open();
    if (out == NULL) {
        pthread_mutex_unlock(&g_trace_lock);
        return end;
    }

    qbdi_trace_logf("[%s] trace#%d step: initVM\n", spec->module, no);
    VMInstanceRef vm = NULL;
    qbdi_initVM(&vm, NULL, NULL, 0);
    if (vm == NULL) {
        qbdi_trace_logf("[%s] trace#%d step: initVM FAILED\n", spec->module, no);
        pthread_mutex_unlock(&g_trace_lock);
        return end;
    }

    qbdi_trace_logf("[%s] trace#%d step: alloc stack\n", spec->module, no);
    GPRState *state = qbdi_getGPRState(vm);
    if (state == NULL) {
        qbdi_trace_logf("[%s] trace#%d step: getGPRState FAILED\n", spec->module, no);
        qbdi_terminateVM(vm);
        pthread_mutex_unlock(&g_trace_lock);
        return end;
    }
    uint8_t *fakestack = NULL;
    /* 一律用 QBDI 虚拟栈:QBDI 引擎需要独立栈稳定执行(用真实栈会 abort)。
     * 自动 hook 场景记录完由 trace_ctx_entry 恢复输入寄存器并跳回 origin 原生续跑,
     * 所以这里不需要沿用真实栈。 */
    qbdi_allocateVirtualStack(state, TRACE_STACK_SIZE, &fakestack);
    if (fakestack == NULL) {
        qbdi_trace_logf("[%s] trace#%d step: alloc stack FAILED\n", spec->module, no);
        qbdi_terminateVM(vm);
        pthread_mutex_unlock(&g_trace_lock);
        return end;
    }

    uint64_t mask = spec->log_mask ? spec->log_mask : TRACE_DEFAULT_MASK;
    qbdi_trace_logf("[%s] trace#%d step: instrument\n", spec->module, no);
    if (mask & LOG_MEM) {
        qbdi_recordMemoryAccess(vm, QBDI_MEMORY_READ | QBDI_MEMORY_WRITE);
    }
    if (spec->module_only) {
        qbdi_addInstrumentedModuleFromAddr(vm, start);
    } else {
        qbdi_instrumentAllExecutableMaps(vm);
    }
    if (origin != NULL) {
        qbdi_addInstrumentedRange(vm, (rword)(uintptr_t)origin,
                                  (rword)(uintptr_t)origin + ORIGIN_SPAN);
    }

    TraceCtx ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.module       = spec->module;
    ctx.mask         = mask;
    ctx.module_base  = base;
    ctx.static_start = spec->static_start;
    ctx.origin       = (uint64_t)(uintptr_t)origin;
    ctx.out          = out;
    ctx.max_instructions = spec->max_instructions;
    ctx.end = end;
    ctx.next_progress = TRACE_PROGRESS_INTERVAL;
    qbdi_addCodeCB(vm, QBDI_PREINST, inst_cb, &ctx, 0);

    qbdi_trace_logf("[%s] trace#%d step: set regs, entry=%p end=0x%llx\n",
                    spec->module, no, (void *)(uintptr_t)entry,
                    (unsigned long long)end);

    /* 全部通用寄存器从 rf 载入(x0..x28, fp);SP 用虚拟栈;LR=end(提前 ret 跳回 end 停止) */
    memcpy(state, rf->x, 29 * sizeof(uint64_t));
    state->x29 = rf->fp;
    state->lr = end;

    if (spec->max_instructions == 0) {
        qbdi_trace_logf(
            "[%s] ==== trace#%d enter %s+0x%llx -> %s+0x%llx entry=%p "
            "scope=%s maxInst=unlimited ====\n",
            spec->module, no, spec->module,
            (unsigned long long)spec->static_start, spec->module,
            (unsigned long long)spec->static_end, (void *)(uintptr_t)entry,
            spec->module_only ? "module" : "all");
    } else {
        qbdi_trace_logf(
            "[%s] ==== trace#%d enter %s+0x%llx -> %s+0x%llx entry=%p "
            "scope=%s maxInst=%llu ====\n",
            spec->module, no, spec->module,
            (unsigned long long)spec->static_start, spec->module,
            (unsigned long long)spec->static_end, (void *)(uintptr_t)entry,
            spec->module_only ? "module" : "all",
            (unsigned long long)spec->max_instructions);
    }

    qbdi_trace_logf("[%s] trace#%d step: qbdi_run\n", spec->module, no);
    g_inside_qbdi_trace++;
    bool ok = qbdi_run(vm, entry, end);
    g_inside_qbdi_trace--;

    /* 回写输出寄存器(除 sp:真实 sp 保留);LR 若在 origin 洞里则映射回模块地址 */
    memcpy(rf->x, state, 29 * sizeof(uint64_t));
    rf->fp = state->x29;
    rf->lr = state->lr;
    if (origin != NULL && rf->lr >= (uint64_t)(uintptr_t)origin &&
        rf->lr < (uint64_t)(uintptr_t)origin + ORIGIN_SPAN) {
        rf->lr = start + (rf->lr - (uint64_t)(uintptr_t)origin);
    }
    uint64_t ret = state->x0;

    /* qbdi_run=true 只表示至少执行了一个 block，不等于已命中
     * stop address。必须再核对 PC，否则其他异常停止仍会被误报成 end。 */
    const char *reason = !ok ? "qbdi-failed"
                             : (ctx.instruction_limit_reached
                                    ? "instruction-limit"
                                    : (state->pc == end ? "end"
                                                        : "unexpected-stop"));
    qbdi_trace_logf(
        "[%s] ==== trace#%d exit ret=0x%llx inst=%llu ok=%d reason=%s "
        "pc=0x%llx ====\n",
        spec->module, no, (unsigned long long)ret,
        (unsigned long long)ctx.inst_count, ok, reason,
        (unsigned long long)state->pc);
    if (ctx.instruction_limit_reached) {
        qbdi_console_logf(
            "[%s] trace#%d TRUNCATED: instruction limit %llu reached before "
            "end, next pc=0x%llx",
            spec->module, no, (unsigned long long)spec->max_instructions,
            (unsigned long long)ctx.stop_pc);
        qbdi_trace_logf(
            "[%s] trace#%d truncated before end=0x%llx, next pc=0x%llx; "
            "raise maxInstructions or set it to 0\n",
            spec->module, no, (unsigned long long)end,
            (unsigned long long)ctx.stop_pc);
    } else if (!ok) {
        qbdi_console_logf("[%s] trace#%d FAILED: qbdi_run returned false",
                          spec->module, no);
    } else if (state->pc != end) {
        qbdi_console_logf(
            "[%s] trace#%d FAILED: QBDI stopped before end, pc=0x%llx "
            "end=0x%llx",
            spec->module, no, (unsigned long long)state->pc,
            (unsigned long long)end);
    }

    if (fakestack != NULL) {
        qbdi_alignedFree(fakestack);
    }
    qbdi_terminateVM(vm);

    pthread_mutex_unlock(&g_trace_lock);
    return end;
}

uint64_t trace_ctx_entry(TraceRegFile *rf, int idx) {
    /* 这个函数在**每次 hook 命中**都会跑,可能是每秒几十万次。
     * 除了必要的判断,别在这里做任何"看起来无害"的重活 —— 尤其不要
     * find_module(遍历 dyld 镜像 + strstr + 抢 dyld 锁,曾经把进程拖死)。 */
    void *origin = idx >= 0 && idx < TRACE_MAX_TARGETS ? g_origin[idx] : NULL;

    /* 出任何意外都不能返回 0:trampoline 会 br 到它,0 = 跳 NULL 直接崩。
     * 没有 origin 可跳时,退回"补丁之后"继续执行原函数。 */
    if (idx < 0 || idx >= g_trace_count) {
        qbdi_trace_logf("[engine] return failed: invalid slot %d (trace count %d, origin=%p)\n",
                        idx, g_trace_count, origin);
        return origin != NULL ? (uint64_t)(uintptr_t)origin
                              : (rf != NULL ? rf->lr : 0);
    }
    const TraceSpec *spec = &g_traces[idx];
    uint64_t base = g_module_base[idx]; /* 装 hook 时算好的,不变 */
    if (spec->module == NULL || base == 0) {
        qbdi_trace_logf("[engine] return failed: slot %d has module=%s base=0x%llx origin=%p\n",
                        idx, spec->module ? spec->module : "(null)",
                        (unsigned long long)base, origin);
        return origin != NULL ? (uint64_t)(uintptr_t)origin
                              : (rf != NULL ? rf->lr : 0);
    }
    if (origin == NULL) {
        qbdi_trace_logf("[engine] return fallback: slot %d origin missing, continue at %s+0x%llx\n",
                        idx, spec->module,
                        (unsigned long long)(spec->static_start + QBDI_PATCH_SIZE));
        return base + spec->static_start + QBDI_PATCH_SIZE;
    }

    /* 次数用完就直接透传:不必再求值条件(否则 trace 早就结束了,
     * 过滤统计还会一直往日志里长) */
    if (__atomic_load_n(&g_remaining[idx], __ATOMIC_RELAXED) <= 0) {
        return (uint64_t)(uintptr_t)origin;
    }

    /* 默认地址在 start 当场判断；自定义地址则只消费本线程之前的授权。 */
    if (spec->trigger_match != TRIG_NONE) {
        if (spec->trigger_address == spec->static_start) {
            TrigProbe probe;
            if (!trigger_hit(spec, rf, base + spec->static_start, &probe)) {
                trigger_record_miss(spec, idx, &probe, rf);
                return (uint64_t)(uintptr_t)origin;
            }
        } else {
            uint32_t bit = (uint32_t)1u << (unsigned int)idx;
            if ((g_trigger_armed_mask & bit) == 0) {
                return (uint64_t)(uintptr_t)origin;
            }
            /* 一次性授权：在占用 trace 次数前就消费，防止重入 start 复用。 */
            g_trigger_armed_mask &= ~bit;
        }
    }

    /* 真要 trace 了才占用次数。非原子递减的话,两个线程可能同时通过上面的
     * "还有次数"检查,把 count=1 用成两次。 */
    if (__atomic_sub_fetch(&g_remaining[idx], 1, __ATOMIC_SEQ_CST) < 0) {
        __atomic_add_fetch(&g_remaining[idx], 1, __ATOMIC_SEQ_CST); /* 还回去 */
        return (uint64_t)(uintptr_t)origin;
    }

    if (spec->trigger_match != TRIG_NONE) {
        if (spec->trigger_address == spec->static_start) {
            qbdi_trace_logf(
                "[%s] trigger matched (%s %s) after %llu filtered calls\n",
                spec->module, trig_match_name(spec->trigger_match),
                spec->trigger_where == TRIG_AT_CONTAINS ? "contains"
                                                        : "prefix",
                (unsigned long long)__atomic_load_n(&g_filtered[idx],
                                                    __ATOMIC_RELAXED));
        } else {
            qbdi_trace_logf(
                "[%s] trigger authorization consumed at start 0x%llx "
                "(thread=%p)\n",
                spec->module, (unsigned long long)spec->static_start,
                (void *)pthread_self());
        }
    }
    /* QBDI 在虚拟栈上只做「记录」;输出寄存器丢弃,恢复 hook 点输入寄存器,
     * 然后跳回 origin 让区域代码原生执行一遍,保证 app 状态正确。
     * 代价:首调区域代码(含 blr 调用子树)执行两遍,对纯计算函数无害。 */
    {
        TraceRegFile in = *rf;
        run_trace(spec, base, origin, rf, idx);
        *rf = in;
    }

    /* 续跑地址 = origin:跑原区域的搬迁代码,再跳回 start+PATCH_SIZE 继续原函数 */
    return (uint64_t)(uintptr_t)origin;
}

uint64_t trigger_ctx_entry(TraceRegFile *rf, int idx) {
    void *origin = idx >= 0 && idx < TRACE_MAX_TARGETS
                       ? g_trigger_origin[idx]
                       : NULL;
    if (idx < 0 || idx >= g_trace_count || rf == NULL) {
        qbdi_trace_logf(
            "[engine] trigger return failed: invalid slot %d "
            "(trace count %d, origin=%p)\n",
            idx, g_trace_count, origin);
        return origin != NULL ? (uint64_t)(uintptr_t)origin
                              : (rf != NULL ? rf->lr : 0);
    }
    const TraceSpec *spec = &g_traces[idx];
    uint64_t base = g_module_base[idx];
    if (origin == NULL || spec->module == NULL || base == 0) {
        qbdi_trace_logf(
            "[engine] trigger return fallback: slot %d module=%s base=0x%llx "
            "origin=%p\n",
            idx, spec->module ? spec->module : "(null)",
            (unsigned long long)base, origin);
        return origin != NULL
                   ? (uint64_t)(uintptr_t)origin
                   : base + spec->trigger_address + QBDI_PATCH_SIZE;
    }
    /* QBDI 动态路径再命中这个 Dobby hook 时只透传，避免嵌套授权。 */
    if (g_origin[idx] == NULL || g_inside_qbdi_trace != 0 ||
        __atomic_load_n(&g_remaining[idx], __ATOMIC_RELAXED) <= 0) {
        return (uint64_t)(uintptr_t)origin;
    }

    TrigProbe probe;
    if (!trigger_hit(spec, rf, base + spec->trigger_address, &probe)) {
        trigger_record_miss(spec, idx, &probe, rf);
        return (uint64_t)(uintptr_t)origin;
    }

    uint32_t bit = (uint32_t)1u << (unsigned int)idx;
    bool was_armed = (g_trigger_armed_mask & bit) != 0;
    g_trigger_armed_mask |= bit;
    if (!was_armed) {
        uint64_t filtered =
            __atomic_load_n(&g_filtered[idx], __ATOMIC_RELAXED);
        qbdi_trace_logf(
            "[%s] trigger matched at 0x%llx; armed next start 0x%llx "
            "on thread=%p after %llu filtered calls\n",
            spec->module, (unsigned long long)spec->trigger_address,
            (unsigned long long)spec->static_start, (void *)pthread_self(),
            (unsigned long long)filtered);
    }
    return (uint64_t)(uintptr_t)origin;
}

uint64_t trace(const char *module, uint64_t static_start, uint64_t static_end,
               int module_only, int count) {
    if (module == NULL || static_end <= static_start) {
        qbdi_trace_logf("[%s] invalid range: end 0x%llx <= start 0x%llx\n",
                        module ? module : "(null)",
                        (unsigned long long)static_end,
                        (unsigned long long)static_start);
        return 0;
    }
    /* 同 engine.m:区间短于补丁长度时 end 落在补丁区内,QBDI 永远跑不到它 */
    if (static_end - static_start < QBDI_PATCH_SIZE) {
        qbdi_trace_logf("[%s] invalid range: 0x%llx too short, end must be >= "
                        "start + 0x%x (Dobby patch covers [start, start+0x%x))\n",
                        module, (unsigned long long)(static_end - static_start),
                        QBDI_PATCH_SIZE, QBDI_PATCH_SIZE);
        return 0;
    }
    uint64_t base = 0;
    if (!find_module(module, &base)) {
        qbdi_trace_logf("[%s] module not found\n", module);
        return 0;
    }

    TraceSpec spec = {
        .trace_name = NULL,
        .module = module,
        .static_start = static_start,
        .static_end = static_end,
        .module_only = module_only,
        .count = count,
        .delay_secs = 0,
        .log_mask = TRACE_DEFAULT_MASK,
        .max_instructions = 0,
    };
    TraceRegFile rf;
    memset(&rf, 0, sizeof(rf));
    for (int i = 0; i < 8; i++) {
        rf.x[i] = g_enter_args[i];
    }

    run_trace(&spec, base, g_enter_origin, &rf, count);
    return rf.x[0];
}
