/* Darwin 的 ucontext.h 需要 _XOPEN_SOURCE 才暴露(已废弃的)ucontext 接口 */
#define _XOPEN_SOURCE 700

#include "qbdi_trace.h"

#include <mach/mach.h>
#include <objc/message.h>
#include <objc/runtime.h>
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
/* Dobby 搬走的原函数序言代码范围:覆盖 origin trampoline 里被搬迁的那几条指令 */
#define ORIGIN_SPAN 0x40

/* 手动路径的入参(线程局部) */
__thread uint64_t g_enter_args[8];
__thread void *g_enter_origin;

/* 自动 hook 每目标的运行时状态 */
void *g_origin[TRACE_MAX_TARGETS];
int g_remaining[TRACE_MAX_TARGETS];

typedef struct {
    const char *module;
    uint64_t mask;
    uint64_t module_base;
    uint64_t static_start;
    uint64_t origin;
    FILE *out;
    uint64_t inst_count;
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

static void watch_dump_hex(FILE *out, uint64_t addr, uint32_t size) {
    unsigned char buf[256];
    size_t total = size ? size : 64;
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
            return;
        }
        for (size_t i = 0; i < got; i += 16) {
            fprintf(out, "    %04zx  ", off + i);
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
}

/* objc/po:把 val 当 ObjC 对象解析。先粗校验 isa 降低野指针风险。 */
static void watch_handle_objc(FILE *out, uint64_t val) {
    uint64_t isa = 0;
    if (safe_read(val, &isa, sizeof(isa)) != sizeof(isa)) {
        fprintf(out, " (not an ObjC object)\n");
        return;
    }
    uint64_t probe = 0;
    if (safe_read(isa, &probe, sizeof(probe)) != sizeof(probe)) {
        fprintf(out, " (not an ObjC object)\n");
        return;
    }
    id obj = (id)(uintptr_t)val;
    Class cls = object_getClass(obj);
    if (cls == NULL) {
        fprintf(out, " (not an ObjC object)\n");
        return;
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
        fprintf(out, "[watch %s+0x%llx] ", module, (unsigned long long)w->offset);
        if (w->label != NULL && w->label[0]) {
            fprintf(out, "%s ", w->label);
        }
        if (!watch_reg_value(gpr, w->reg, &val)) {
            fprintf(out, "%s = <absent>\n", w->reg);
            continue;
        }
        fprintf(out, "%s=0x%llx", w->reg, (unsigned long long)val);
        if (val == 0) {
            fprintf(out, " (null)\n");
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
            }
        } else if (strcmp(a, "u64") == 0) {
            uint64_t v = 0;
            if (safe_read(val, &v, sizeof(v)) == sizeof(v)) {
                fprintf(out, " = 0x%llx\n", (unsigned long long)v);
            } else {
                fputs(" (not a pointer)\n", out);
            }
        } else if (strcmp(a, "hexdump") == 0) {
            fputc('\n', out);
            watch_dump_hex(out, val, w->size);
        } else if (strcmp(a, "objc") == 0 || strcmp(a, "po") == 0) {
            watch_handle_objc(out, val);
        } else {
            /* 未知 action:只打印寄存器值 */
            fputc('\n', out);
        }
    }
    return fired;
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
    if (++c->inst_count > TRACE_MAX_INST) {
        return QBDI_STOP;
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
    trace_lock_ensure();
    pthread_mutex_lock(&g_trace_lock);
    FILE *out = trace_log_open();
    if (out != NULL) {
        va_list ap;
        va_start(ap, fmt);
        vfprintf(out, fmt, ap);
        va_end(ap);
        fflush(out);
    }
    pthread_mutex_unlock(&g_trace_lock);
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
    for (int i = 0; i < g_trace_count && i < TRACE_MAX_TARGETS; i++) {
        g_origin[i] = NULL;
        g_remaining[i] = g_traces[i].count;
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
    qbdi_addCodeCB(vm, QBDI_PREINST, inst_cb, &ctx, 0);

    qbdi_trace_logf("[%s] trace#%d step: set regs, entry=%p end=0x%llx\n",
                    spec->module, no, (void *)(uintptr_t)entry,
                    (unsigned long long)end);

    /* 全部通用寄存器从 rf 载入(x0..x28, fp);SP 用虚拟栈;LR=end(提前 ret 跳回 end 停止) */
    memcpy(state, rf->x, 29 * sizeof(uint64_t));
    state->x29 = rf->fp;
    state->lr = end;

    fprintf(out,
            "[%s] ==== trace#%d enter %s+0x%llx -> %s+0x%llx entry=%p scope=%s ====\n",
            spec->module, no, spec->module, (unsigned long long)spec->static_start,
            spec->module, (unsigned long long)spec->static_end,
            (void *)(uintptr_t)entry, spec->module_only ? "module" : "all");
    fflush(out);

    qbdi_trace_logf("[%s] trace#%d step: qbdi_run\n", spec->module, no);
    bool ok = qbdi_run(vm, entry, end);

    /* 回写输出寄存器(除 sp:真实 sp 保留);LR 若在 origin 洞里则映射回模块地址 */
    memcpy(rf->x, state, 29 * sizeof(uint64_t));
    rf->fp = state->x29;
    rf->lr = state->lr;
    if (origin != NULL && rf->lr >= (uint64_t)(uintptr_t)origin &&
        rf->lr < (uint64_t)(uintptr_t)origin + ORIGIN_SPAN) {
        rf->lr = start + (rf->lr - (uint64_t)(uintptr_t)origin);
    }
    uint64_t ret = state->x0;

    fprintf(out, "[%s] ==== trace#%d exit ret=0x%llx inst=%llu ok=%d ====\n",
            spec->module, no, (unsigned long long)ret,
            (unsigned long long)ctx.inst_count, ok);
    fflush(out);

    if (fakestack != NULL) {
        qbdi_alignedFree(fakestack);
    }
    qbdi_terminateVM(vm);

    pthread_mutex_unlock(&g_trace_lock);
    return end;
}

uint64_t trace_ctx_entry(TraceRegFile *rf, int idx) {
    if (idx < 0 || idx >= g_trace_count) {
        return 0;
    }
    const TraceSpec *spec = &g_traces[idx];
    if (spec->module == NULL) {
        return 0;
    }
    uint64_t base = 0;
    if (!find_module(spec->module, &base)) {
        qbdi_trace_logf("[%s] module not found (ctx#%d)\n", spec->module, idx);
        return 0;
    }
    void *origin = g_origin[idx];
    if (origin == NULL) {
        return base + spec->static_start + QBDI_PATCH_SIZE;
    }

    if (g_remaining[idx] > 0) {
        g_remaining[idx]--;
        /* QBDI 在虚拟栈上只做「记录」;输出寄存器丢弃,恢复 hook 点输入寄存器,
         * 然后跳回 origin 让区域代码原生执行一遍,保证 app 状态正确。
         * 代价:首调区域代码(含 blr 调用子树)执行两遍,对纯计算函数无害。 */
        TraceRegFile in = *rf;
        run_trace(spec, base, origin, rf, idx);
        *rf = in;
    }

    /* 续跑地址 = origin:跑原区域的搬迁代码,再跳回 start+PATCH_SIZE 继续原函数 */
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
    uint64_t base = 0;
    if (!find_module(module, &base)) {
        qbdi_trace_logf("[%s] module not found\n", module);
        return 0;
    }

    TraceSpec spec = { module, static_start, static_end, module_only, count, 0,
                       TRACE_DEFAULT_MASK };
    TraceRegFile rf;
    memset(&rf, 0, sizeof(rf));
    for (int i = 0; i < 8; i++) {
        rf.x[i] = g_enter_args[i];
    }

    run_trace(&spec, base, g_enter_origin, &rf, count);
    return rf.x[0];
}
