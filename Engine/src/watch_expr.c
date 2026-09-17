#include "watch_expr.h"

#include <stdarg.h>
#include <string.h>

/* 后缀式操作码 */
enum {
    WOP_REG = 1, /* push regs[imm] */
    WOP_IMM,     /* push imm */
    WOP_ADD,     /* b=pop a=pop push a+b */
    WOP_SUB,     /* b=pop a=pop push a-b */
    WOP_DEREF,   /* a=pop push *(uint64_t *)a */
};

static const char *const g_reg_names[WEXPR_NREGS] = {
    "x0",  "x1",  "x2",  "x3",  "x4",  "x5",  "x6",  "x7",
    "x8",  "x9",  "x10", "x11", "x12", "x13", "x14", "x15",
    "x16", "x17", "x18", "x19", "x20", "x21", "x22", "x23",
    "x24", "x25", "x26", "x27", "x28", "fp",  "lr",  "sp",
    "pc",
};

const char *wexpr_reg_name(int id) {
    return (id >= 0 && id < WEXPR_NREGS) ? g_reg_names[id] : "?";
}

/* ---- 词法辅助 ---- */

static char wlower(char c) {
    return (c >= 'A' && c <= 'Z') ? (char)(c - 'A' + 'a') : c;
}

/* hex 数字 → 值;不是 hex 返回 -1 */
static int whex(char c) {
    c = wlower(c);
    if (c >= '0' && c <= '9') {
        return c - '0';
    }
    if (c >= 'a' && c <= 'f') {
        return c - 'a' + 10;
    }
    return -1;
}

static bool wis_alnum(char c) {
    c = wlower(c);
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z');
}

/* ---- 递归下降解析,直接 emit 后缀式 ----
 * expr := term (('+' | '-') term)*
 * term := ['-'] number | reg | '[' expr ']'
 */

typedef struct {
    const char *s;
    size_t      i;
    WatchExpr  *e;
    char       *err;
    size_t      errcap;
    bool        failed;
} WPars;

static void wp_fail(WPars *p, const char *fmt, ...) {
    if (p->failed) {
        return; /* 只保留第一个错误,它最接近真正的写错位置 */
    }
    p->failed = true;
    if (p->err != NULL && p->errcap > 0) {
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(p->err, p->errcap, fmt, ap);
        va_end(ap);
    }
}

static void wp_skip_ws(WPars *p) {
    while (p->s[p->i] == ' ' || p->s[p->i] == '\t') {
        p->i++;
    }
}

static void wp_emit(WPars *p, uint8_t op, int64_t imm) {
    if (p->failed) {
        return;
    }
    if (p->e->nops >= WEXPR_MAX_OPS) {
        wp_fail(p, "expression too long (max %d ops)", WEXPR_MAX_OPS);
        return;
    }
    p->e->ops[p->e->nops]  = op;
    p->e->imms[p->e->nops] = imm;
    p->e->nops++;
}

/* 尝试吃一个寄存器名;成功返回下标并前进,失败返回 -1 且不前进 */
static int wp_reg(WPars *p) {
    const char *s = p->s + p->i;
    char c0 = wlower(s[0]);

    if (c0 == 'x') {
        if (s[1] < '0' || s[1] > '9') {
            return -1;
        }
        int    n   = s[1] - '0';
        size_t len = 2;
        if (s[2] >= '0' && s[2] <= '9') {
            n   = n * 10 + (s[2] - '0');
            len = 3;
        }
        if (n > 30 || wis_alnum(s[len])) {
            return -1; /* x31/x123/x1a 都算写错 */
        }
        p->i += len;
        return n; /* x29 → 29(fp), x30 → 30(lr) */
    }

    char c1 = wlower(s[1]);
    int  id = -1;
    if (c0 == 'f' && c1 == 'p') {
        id = WEXPR_REG_FP;
    } else if (c0 == 'l' && c1 == 'r') {
        id = WEXPR_REG_LR;
    } else if (c0 == 's' && c1 == 'p') {
        id = WEXPR_REG_SP;
    } else if (c0 == 'p' && c1 == 'c') {
        id = WEXPR_REG_PC;
    }
    if (id < 0 || wis_alnum(s[2])) {
        return -1;
    }
    p->i += 2;
    return id;
}

/* 尝试吃一个十六进制常量("0x" 可省) */
static bool wp_number(WPars *p, uint64_t *out) {
    const char *s = p->s + p->i;
    size_t      j = 0;
    if (s[0] == '0' && wlower(s[1]) == 'x') {
        j = 2;
    }
    if (whex(s[j]) < 0) {
        return false;
    }
    uint64_t v     = 0;
    size_t   start = j;
    while (whex(s[j]) >= 0) {
        if (j - start >= 16) {
            wp_fail(p, "constant too long at col %zu", p->i + 1);
            return false;
        }
        v = (v << 4) | (uint64_t)whex(s[j]);
        j++;
    }
    p->i += j;
    *out = v;
    return true;
}

static void wp_expr(WPars *p, int depth);

static void wp_term(WPars *p, int depth) {
    wp_skip_ws(p);
    char c = p->s[p->i];
    if (c == '\0') {
        wp_fail(p, "unexpected end of expression at col %zu", p->i + 1);
        return;
    }

    if (c == '[') {
        if (depth + 1 > WEXPR_MAX_DEPTH) {
            wp_fail(p, "deref nested deeper than %d levels", WEXPR_MAX_DEPTH);
            return;
        }
        p->i++;
        wp_expr(p, depth + 1);
        if (p->failed) {
            return;
        }
        wp_skip_ws(p);
        if (p->s[p->i] != ']') {
            wp_fail(p, "missing ']' at col %zu", p->i + 1);
            return;
        }
        p->i++;
        wp_emit(p, WOP_DEREF, 0);
        return;
    }

    /* 一元负号只对常量有意义(-x0 没有意义,当写错处理) */
    bool neg = false;
    if (c == '-') {
        p->i++;
        wp_skip_ws(p);
        neg = true;
    }

    size_t at = p->i;
    if (!neg) {
        int r = wp_reg(p);
        if (r >= 0) {
            wp_emit(p, WOP_REG, r);
            return;
        }
    }

    uint64_t v = 0;
    if (wp_number(p, &v)) {
        wp_emit(p, WOP_IMM, neg ? -(int64_t)v : (int64_t)v);
        return;
    }
    if (!p->failed) {
        wp_fail(p, "cannot parse register or constant at col %zu", at + 1);
    }
}

static void wp_expr(WPars *p, int depth) {
    wp_term(p, depth);
    for (;;) {
        if (p->failed) {
            return;
        }
        wp_skip_ws(p);
        char c = p->s[p->i];
        if (c != '+' && c != '-') {
            return;
        }
        p->i++;
        wp_term(p, depth);
        wp_emit(p, c == '+' ? WOP_ADD : WOP_SUB, 0);
    }
}

bool wexpr_compile(const char *src, WatchExpr *out, char *err, size_t errcap) {
    if (out == NULL) {
        return false;
    }
    memset(out, 0, sizeof(*out));
    if (err != NULL && errcap > 0) {
        err[0] = '\0';
    }
    if (src == NULL || src[0] == '\0') {
        if (err != NULL && errcap > 0) {
            snprintf(err, errcap, "empty expression");
        }
        return false;
    }

    WPars p = {
        .s = src, .i = 0, .e = out, .err = err, .errcap = errcap, .failed = false
    };
    wp_expr(&p, 0);
    if (!p.failed) {
        wp_skip_ws(&p);
        if (p.s[p.i] != '\0') {
            wp_fail(&p, "unexpected '%c' at col %zu", p.s[p.i], p.i + 1);
        }
    }
    if (p.failed) {
        out->nops = 0;
        return false;
    }

    /* 栈平衡自检:按文法必然平衡,错了说明 emit 写漏,宁可拒绝也别在热路径上出事 */
    int depth = 0;
    for (int i = 0; i < out->nops; i++) {
        switch (out->ops[i]) {
        case WOP_REG:
        case WOP_IMM:
            depth++;
            break;
        case WOP_ADD:
        case WOP_SUB:
            depth--;
            break;
        default:
            break;
        }
        if (depth < 1 || depth > WEXPR_MAX_OPS) {
            out->nops = 0;
            if (err != NULL && errcap > 0) {
                snprintf(err, errcap, "internal: unbalanced expression");
            }
            return false;
        }
    }
    if (depth != 1 || out->nops == 0) {
        out->nops = 0;
        if (err != NULL && errcap > 0) {
            snprintf(err, errcap, "internal: unbalanced expression");
        }
        return false;
    }
    return true;
}

/* ---- 求值 ---- */

static void tr_reg(WatchExprTrace *tr, int id, uint64_t v) {
    if (tr == NULL) {
        return;
    }
    for (int i = 0; i < tr->nregs; i++) {
        if (tr->reg_ids[i] == (uint8_t)id) {
            return; /* 同一个寄存器只记一次 */
        }
    }
    if (tr->nregs < WEXPR_MAX_TRACE) {
        tr->reg_ids[tr->nregs]  = (uint8_t)id;
        tr->reg_vals[tr->nregs] = v;
        tr->nregs++;
    }
}

static void tr_deref(WatchExprTrace *tr, uint64_t addr, uint64_t v, bool ok) {
    if (tr == NULL || tr->nderef >= WEXPR_MAX_TRACE) {
        return;
    }
    tr->deref_addr[tr->nderef] = addr;
    tr->deref_val[tr->nderef]  = v;
    tr->deref_ok[tr->nderef]   = ok;
    tr->nderef++;
}

bool wexpr_eval(const WatchExpr *e, const uint64_t *regs, wexpr_read_fn rd,
                uint64_t *out, WatchExprTrace *tr) {
    if (tr != NULL) {
        memset(tr, 0, sizeof(*tr));
    }
    if (e == NULL || e->nops <= 0 || e->nops > WEXPR_MAX_OPS || regs == NULL ||
        rd == NULL) {
        return false;
    }

    uint64_t st[WEXPR_MAX_OPS];
    int      sp = 0;

    for (int i = 0; i < e->nops; i++) {
        switch (e->ops[i]) {
        case WOP_REG: {
            int id = (int)e->imms[i];
            if (id < 0 || id >= WEXPR_NREGS || sp >= WEXPR_MAX_OPS) {
                return false;
            }
            tr_reg(tr, id, regs[id]);
            st[sp++] = regs[id];
            break;
        }
        case WOP_IMM:
            if (sp >= WEXPR_MAX_OPS) {
                return false;
            }
            st[sp++] = (uint64_t)e->imms[i];
            break;
        case WOP_ADD:
            if (sp < 2) {
                return false;
            }
            st[sp - 2] += st[sp - 1];
            sp--;
            break;
        case WOP_SUB:
            if (sp < 2) {
                return false;
            }
            st[sp - 2] -= st[sp - 1];
            sp--;
            break;
        case WOP_DEREF: {
            if (sp < 1) {
                return false;
            }
            uint64_t addr = st[sp - 1];
            uint64_t v    = 0;
            bool     ok   = rd(addr, &v, sizeof(v)) == sizeof(v);
            tr_deref(tr, addr, v, ok);
            if (!ok) {
                return false;
            }
            st[sp - 1] = v;
            break;
        }
        default:
            return false;
        }
    }
    if (sp != 1) {
        return false;
    }
    if (out != NULL) {
        *out = st[0];
    }
    return true;
}

const char *wexpr_base_reg(const WatchExpr *e) {
    if (e == NULL) {
        return NULL;
    }
    for (int i = 0; i < e->nops; i++) {
        if (e->ops[i] == WOP_REG) {
            return wexpr_reg_name((int)e->imms[i]);
        }
    }
    return NULL;
}

void wexpr_print_trace(FILE *out, const WatchExprTrace *tr) {
    if (out == NULL || tr == NULL) {
        return;
    }
    for (int i = 0; i < tr->nregs; i++) {
        fprintf(out, "    %-4s      = 0x%016llx\n",
                wexpr_reg_name(tr->reg_ids[i]),
                (unsigned long long)tr->reg_vals[i]);
    }
    for (int i = 0; i < tr->nderef; i++) {
        if (tr->deref_ok[i]) {
            fprintf(out, "    deref#%d @0x%llx = 0x%016llx\n", i + 1,
                    (unsigned long long)tr->deref_addr[i],
                    (unsigned long long)tr->deref_val[i]);
        } else {
            fprintf(out, "    deref#%d @0x%llx = read failed\n", i + 1,
                    (unsigned long long)tr->deref_addr[i]);
        }
    }
}
