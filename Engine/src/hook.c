#include "hook.h"

#include <errno.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "watch_expr.h"

/* Hook 与 Trace 完全独立:自己的日志文件、自己的锁、自己的运行期状态数组。 */

#define HOOK_LOG_SUBDIR "hook-logs"
#define HOOK_LOG_PREFIX "hook_"
#define HOOK_FAIL_LIMIT 20 /* 连续这么多次命中一条修改都没成功 → 停掉该 Hook */

/* ---- 运行期状态(config.h 中 extern) ---- */
HookSpec g_hooks[HOOK_MAX_TARGETS];
int      g_hook_count = 0;

void    *g_hook_origin[HOOK_MAX_TARGETS];
uint64_t g_hook_module_base[HOOK_MAX_TARGETS];

static uint64_t g_hook_hits[HOOK_MAX_TARGETS];       /* 命中次数(max_hits 用) */
static uint64_t g_hook_applied[HOOK_MAX_TARGETS];    /* 应用次数(日志退避用) */
static uint32_t g_hook_fail_streak[HOOK_MAX_TARGETS];/* 连续失败次数 */
static int      g_hook_disabled[HOOK_MAX_TARGETS];   /* 自动停用标志 */

void hook_init_state(void) {
    for (int i = 0; i < HOOK_MAX_TARGETS; i++) {
        g_hook_origin[i] = NULL;
        g_hook_module_base[i] = 0;
        g_hook_hits[i] = 0;
        g_hook_applied[i] = 0;
        g_hook_fail_streak[i] = 0;
        g_hook_disabled[i] = 0;
    }
}

/* ---- 日志 ---- */

static pthread_mutex_t g_hook_lock;
static FILE *g_hook_log = NULL;

static void hook_lock_init(void) {
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&g_hook_lock, &attr);
    pthread_mutexattr_destroy(&attr);
}
static pthread_once_t g_hook_lock_once = PTHREAD_ONCE_INIT;

static FILE *hook_log_open(void) {
    if (g_hook_log == NULL) {
        char path[640];
        qbdi_log_build_path(path, sizeof(path), HOOK_LOG_SUBDIR, HOOK_LOG_PREFIX);
        g_hook_log = fopen(path, "a");
        if (g_hook_log != NULL) {
            qbdi_console_logf("hook log opened: %s", path);
        } else {
            qbdi_console_logf("hook log open FAILED: %s (errno=%d)", path, errno);
        }
    }
    return g_hook_log;
}

void qbdi_hook_logf(const char *fmt, ...) {
    char msg[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);

    pthread_once(&g_hook_lock_once, hook_lock_init);
    pthread_mutex_lock(&g_hook_lock);
    FILE *f = hook_log_open();
    if (f != NULL) {
        fputs(msg, f);
        fflush(f);
    }
    pthread_mutex_unlock(&g_hook_lock);
    qbdi_console_logf("%s", msg); /* 生命周期/错误也进系统控制台 */
}

/* ---- 内存读写 ---- */

/* 安全读:读不进返回 0,不崩(供 wexpr_eval 解引用与"记旧值") */
static size_t hook_read(uint64_t addr, void *buf, size_t n) {
    if (n == 0) return 0;
    vm_size_t outsz = n;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)addr,
                                         (vm_size_t)n, (vm_address_t)buf, &outsz);
    return kr == KERN_SUCCESS ? (size_t)outsz : 0;
}

/* 往 addr 写 n 字节。目标只读时先 vm_protect 提权、写完恢复原保护位。
 * 地址未映射、跨区、或提权失败都返回 false(不崩)。 */
static bool hook_write_mem(uint64_t addr, const uint8_t *buf, int n) {
    if (n <= 0) return false;
    mach_port_t task = mach_task_self();

    /* 先弄清 addr 落在哪个区、可不可写、够不够 n 字节。 */
    vm_address_t region = (vm_address_t)addr;
    vm_size_t rsize = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj = MACH_PORT_NULL;
    kern_return_t kr = vm_region_64(task, &region, &rsize, VM_REGION_BASIC_INFO_64,
                                    (vm_region_info_t)&info, &cnt, &obj);
    if (kr != KERN_SUCCESS) return false;
    /* vm_region_64 返回 >= 入参地址的第一个区。addr 落在空洞里时 region>addr。 */
    if ((uint64_t)region > addr) return false;
    if (addr + (uint64_t)n > (uint64_t)region + (uint64_t)rsize) return false;

    bool need_prot = (info.protection & VM_PROT_WRITE) == 0;
    vm_address_t pstart = 0;
    vm_size_t plen = 0;
    if (need_prot) {
        uint64_t pg = (uint64_t)vm_page_size ? (uint64_t)vm_page_size : 0x4000;
        uint64_t start = addr & ~(pg - 1);
        uint64_t end = (addr + (uint64_t)n + pg - 1) & ~(pg - 1);
        pstart = (vm_address_t)start;
        plen = (vm_size_t)(end - start);
        /* VM_PROT_COPY:对私有 copy-on-write 页也能改,不影响其它进程。 */
        kr = vm_protect(task, pstart, plen, FALSE,
                        VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
        if (kr != KERN_SUCCESS) return false;
    }

    memcpy((void *)(uintptr_t)addr, buf, (size_t)n); /* 同进程,直接写 */

    if (need_prot) {
        vm_protect(task, pstart, plen, FALSE, info.protection); /* 恢复原保护位 */
    }
    return true;
}

/* ---- 加载期:值编码 ---- */

static int hex_digit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* 整串十六进制 → u64(可带 0x 前缀,首尾空白允许)。非法返回 false。 */
static bool parse_hex_u64(const char *s, uint64_t *out) {
    if (s == NULL) return false;
    while (*s == ' ' || *s == '\t') s++;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) s += 2;
    if (*s == '\0') return false;
    uint64_t v = 0;
    int digits = 0;
    for (; *s && *s != ' ' && *s != '\t'; s++) {
        int d = hex_digit(*s);
        if (d < 0) return false;
        if (++digits > 16) return false; /* 超过 64 位 */
        v = (v << 4) | (uint64_t)d;
    }
    while (*s == ' ' || *s == '\t') s++;
    if (*s != '\0' || digits == 0) return false;
    *out = v;
    return true;
}

bool hook_encode_value(HookMod *mod, HookValType type, uint8_t width,
                       const char *value, char *err, size_t errcap) {
    mod->type = type;
    mod->width = width;
    mod->number = 0;
    mod->nbytes = 0;

    if (type == HOOK_VAL_NUMBER) {
        if (width != 8 && width != 16 && width != 32 && width != 64) {
            snprintf(err, errcap, "数值位宽必须是 8/16/32/64");
            return false;
        }
        uint64_t num = 0;
        if (!parse_hex_u64(value, &num)) {
            snprintf(err, errcap, "数值不是合法的十六进制");
            return false;
        }
        if (width < 64 && (num >> width) != 0) {
            snprintf(err, errcap, "数值超出 %u 位范围", width);
            return false;
        }
        mod->number = num;
        int n = width / 8;
        for (int i = 0; i < n; i++) {
            mod->payload[i] = (uint8_t)(num >> (8 * i)); /* 小端 */
        }
        mod->nbytes = n;
        return true;
    }

    if (type == HOOK_VAL_BYTES) {
        int n = 0, hi = -1;
        for (const char *s = value; s && *s; s++) {
            if (*s == ' ' || *s == '\t' || *s == ':' || *s == ',') continue;
            int d = hex_digit(*s);
            if (d < 0) {
                snprintf(err, errcap, "字节含非十六进制字符 '%c'", *s);
                return false;
            }
            if (hi < 0) {
                hi = d;
            } else {
                if (n >= HOOK_VAL_MAX) {
                    snprintf(err, errcap, "字节超过 %d 上限", HOOK_VAL_MAX);
                    return false;
                }
                mod->payload[n++] = (uint8_t)((hi << 4) | d);
                hi = -1;
            }
        }
        if (hi >= 0) {
            snprintf(err, errcap, "字节需要偶数个十六进制位");
            return false;
        }
        if (n == 0) {
            snprintf(err, errcap, "字节内容为空");
            return false;
        }
        mod->nbytes = n;
        return true;
    }

    if (type == HOOK_VAL_STRING) {
        size_t len = value ? strlen(value) : 0;
        if (len + 1 > HOOK_VAL_MAX) { /* +1 是结尾 0 */
            snprintf(err, errcap, "字符串超过 %d 字节(含结尾 0)", HOOK_VAL_MAX);
            return false;
        }
        if (len > 0) memcpy(mod->payload, value, len);
        mod->payload[len] = 0;
        mod->nbytes = (int)len + 1;
        return true;
    }

    snprintf(err, errcap, "未知修改类型");
    return false;
}

/* ---- 加载期:写入目标分类(那张不对称语义表) ---- */

/* 单个裸寄存器?是则回填下标(0..28=x0..x28,29=fp,30=lr)。
 * 排除 x17(Dobby 跳板临时寄存器)、sp、pc:寄存器写这些没有意义。 */
static bool bare_register(const char *expr, uint8_t *index) {
    char buf[16];
    size_t n = 0;
    for (const char *s = expr; *s; s++) {
        if (*s == ' ' || *s == '\t') continue;
        if (n >= sizeof(buf) - 1) return false;
        char c = *s;
        if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
        buf[n++] = c;
    }
    buf[n] = '\0';
    if (strcmp(buf, "fp") == 0) { *index = 29; return true; }
    if (strcmp(buf, "lr") == 0) { *index = 30; return true; }
    if (buf[0] != 'x' || buf[1] == '\0') return false;
    int v = 0;
    for (size_t i = 1; buf[i]; i++) {
        if (buf[i] < '0' || buf[i] > '9') return false;
        v = v * 10 + (buf[i] - '0');
    }
    if (v == 29) { *index = 29; return true; }
    if (v == 30) { *index = 30; return true; }
    if (v < 0 || v > 28 || v == 17) return false;
    *index = (uint8_t)v;
    return true;
}

/* 整个表达式是否被一对最外层 [] 包住?是则把内部拷进 inner。
 * 例:"[x0+0x10]" → "x0+0x10";"[x0]+[x1]" 不算(第一个]之后深度已归 0)。 */
static bool outer_bracket(const char *expr, char *inner, size_t cap) {
    const char *s = expr;
    while (*s == ' ' || *s == '\t') s++;
    if (*s != '[') return false;
    const char *end = expr + strlen(expr);
    while (end > s && (end[-1] == ' ' || end[-1] == '\t')) end--;
    if (end <= s || end[-1] != ']') return false;
    /* 确认首 [ 与末 ] 是配对的最外层 */
    int depth = 0;
    for (const char *p = s; p < end; p++) {
        if (*p == '[') depth++;
        else if (*p == ']') {
            depth--;
            if (depth == 0 && p != end - 1) return false; /* 提前归零 */
        }
    }
    if (depth != 0) return false;
    size_t len = (size_t)(end - 1 - (s + 1));
    if (len == 0 || len >= cap) return false;
    memcpy(inner, s + 1, len);
    inner[len] = '\0';
    return true;
}

bool hook_classify_target(HookMod *mod, const char *expr, char *err,
                          size_t errcap) {
    memset(&mod->cexpr, 0, sizeof(mod->cexpr));
    mod->expr = NULL;

    if (expr == NULL || expr[0] == '\0') {
        snprintf(err, errcap, "取址表达式为空");
        return false;
    }

    char inner[128];
    if (outer_bracket(expr, inner, sizeof(inner))) {
        /* [表达式] → 写内存,地址 = 方括号内部求值 */
        if (!wexpr_compile(inner, &mod->cexpr, err, errcap)) return false;
        mod->dst = HOOK_DST_MEM;
        return true;
    }

    uint8_t reg = 0;
    if (bare_register(expr, &reg)) {
        if (mod->type == HOOK_VAL_NUMBER) {
            mod->dst = HOOK_DST_REG; /* 数值 + 裸寄存器 = 改寄存器本身 */
            mod->reg_index = reg;
            return true;
        }
        if (mod->type == HOOK_VAL_STRING) {
            /* 字符串 + 裸寄存器 = 把寄存器的值当 char* 首地址,写内存 */
            if (!wexpr_compile(expr, &mod->cexpr, err, errcap)) return false;
            mod->dst = HOOK_DST_MEM;
            return true;
        }
        /* 字节 + 裸寄存器 = 非法 */
        snprintf(err, errcap,
                 "字节修改必须用 [ ] 指定内存地址,裸寄存器写不了字节");
        return false;
    }

    snprintf(err, errcap,
             "表达式无法识别:改内存请用 [地址],改寄存器请填单个寄存器名");
    return false;
}

/* ---- 运行期 ---- */

static void hook_fill_regs(const TraceRegFile *rf, uint64_t pc,
                           uint64_t regs[WEXPR_NREGS]) {
    for (int i = 0; i < 29; i++) regs[i] = rf->x[i];
    regs[WEXPR_REG_FP] = rf->fp;
    regs[WEXPR_REG_LR] = rf->lr;
    regs[WEXPR_REG_SP] = rf->sp;
    regs[WEXPR_REG_PC] = pc;
}

/* 写寄存器修改到保存的现场;跳板恢复时这些值会进真实寄存器。 */
static uint64_t *reg_slot(TraceRegFile *rf, uint8_t index) {
    if (index <= 28) return &rf->x[index];
    if (index == 29) return &rf->fp;
    if (index == 30) return &rf->lr;
    return NULL;
}

/* seq 是不是 1/10/100/1000…(指数退避打日志) */
static bool is_backoff_point(uint64_t seq) {
    uint64_t t = 1;
    while (t < seq) t *= 10;
    return t == seq;
}

uint64_t hook_ctx_entry(TraceRegFile *rf, int idx) {
    if (idx < 0 || idx >= g_hook_count) return 0; /* 跳板会退到现场 LR */
    uint64_t origin = (uint64_t)(uintptr_t)g_hook_origin[idx];
    HookSpec *h = &g_hooks[idx];

    if (__atomic_load_n(&g_hook_disabled[idx], __ATOMIC_RELAXED)) return origin;

    if (h->max_hits > 0) {
        uint64_t n = __atomic_add_fetch(&g_hook_hits[idx], 1, __ATOMIC_RELAXED);
        if (n > h->max_hits) return origin; /* 次数用完,透传 */
    }

    uint64_t base = g_hook_module_base[idx];
    uint64_t regs[WEXPR_NREGS];
    hook_fill_regs(rf, base + h->target, regs);

    uint64_t seq = __atomic_add_fetch(&g_hook_applied[idx], 1, __ATOMIC_RELAXED);
    bool should_log = is_backoff_point(seq);

    FILE *out = NULL;
    if (should_log) {
        pthread_once(&g_hook_lock_once, hook_lock_init);
        pthread_mutex_lock(&g_hook_lock);
        out = hook_log_open();
        if (out != NULL) {
            fprintf(out, "[hook %s+0x%llx] #%llu%s%s\n",
                    h->module ? h->module : "(null)",
                    (unsigned long long)h->target, (unsigned long long)seq,
                    h->hook_name ? " " : "", h->hook_name ? h->hook_name : "");
        }
    }

    int ok = 0, fail = 0;
    for (int i = 0; i < h->mod_count; i++) {
        HookMod *m = &h->mods[i];
        if (m->dst == HOOK_DST_REG) {
            uint64_t *slot = reg_slot(rf, m->reg_index);
            if (slot == NULL) { fail++; continue; }
            uint64_t old = *slot;
            uint64_t v = m->number;
            if (m->width == 32) v &= 0xFFFFFFFFULL; /* wN 清高 32 位 */
            *slot = v;
            ok++;
            if (out != NULL) {
                fprintf(out, "   reg[%d] %s = 0x%llx -> 0x%llx\n", i + 1,
                        m->expr ? m->expr : "?", (unsigned long long)old,
                        (unsigned long long)v);
            }
            continue;
        }

        /* HOOK_DST_MEM:先算地址 */
        uint64_t addr = 0;
        if (!wexpr_eval(&m->cexpr, regs, hook_read, &addr, NULL)) {
            fail++;
            if (out != NULL) {
                fprintf(out, "   mem[%d] %s = <地址求值失败>\n", i + 1,
                        m->expr ? m->expr : "?");
            }
            continue;
        }
        /* 旧值只在要打日志的这几次才读,省热路径上的 mach 调用 */
        uint8_t oldbuf[HOOK_VAL_MAX];
        size_t got = 0;
        if (out != NULL) got = hook_read(addr, oldbuf, (size_t)m->nbytes);

        if (hook_write_mem(addr, m->payload, m->nbytes)) {
            ok++;
            if (out != NULL) {
                fprintf(out, "   mem[%d] %s @ 0x%llx (%d bytes)\n", i + 1,
                        m->expr ? m->expr : "?", (unsigned long long)addr,
                        m->nbytes);
                if (got == (size_t)m->nbytes) {
                    fprintf(out, "        old:");
                    for (int b = 0; b < m->nbytes; b++)
                        fprintf(out, " %02x", oldbuf[b]);
                    fprintf(out, "\n");
                }
                fprintf(out, "        new:");
                for (int b = 0; b < m->nbytes; b++)
                    fprintf(out, " %02x", m->payload[b]);
                fprintf(out, "\n");
            }
        } else {
            fail++;
            if (out != NULL) {
                fprintf(out, "   mem[%d] %s @ 0x%llx 写入失败(不可写/跨区/未映射)\n",
                        i + 1, m->expr ? m->expr : "?", (unsigned long long)addr);
            }
        }
    }

    if (out != NULL) {
        fflush(out);
        pthread_mutex_unlock(&g_hook_lock);
    }

    /* 连续失败(一次命中没有任何一条修改成功)累计到上限就停掉这条 Hook。
     * 只要成功一次就清零,避免偶发失败误停。 */
    if (ok > 0) {
        __atomic_store_n(&g_hook_fail_streak[idx], 0, __ATOMIC_RELAXED);
    } else if (fail > 0) {
        uint32_t s = __atomic_add_fetch(&g_hook_fail_streak[idx], 1, __ATOMIC_RELAXED);
        if (s >= HOOK_FAIL_LIMIT &&
            __atomic_exchange_n(&g_hook_disabled[idx], 1, __ATOMIC_RELAXED) == 0) {
            qbdi_hook_logf("[hook %s+0x%llx] 连续 %d 次修改失败,已自动停用该 Hook\n",
                           h->module ? h->module : "(null)",
                           (unsigned long long)h->target, HOOK_FAIL_LIMIT);
        }
    }

    return origin;
}
