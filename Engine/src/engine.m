#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <mach-o/dyld.h>
#import <string.h>

#import <dobby.h>

#import "config.h"
#import "engine.h"

/* ---- 运行期配置表(config.h 中 extern) ---- */
TraceSpec  g_traces[TRACE_MAX_TARGETS];
int        g_trace_count = 0;
TraceWatch g_watches[TRACE_MAX_WATCHES];
int        g_watch_count = 0;

/* 已成功安装的 Dobby 补丁绝对地址。配置中的模块名是子串，两个不同字符串
 * 也可能匹配到同一镜像，所以装 Hook 前还要用绝对地址再挡一道。 */
static uint64_t g_installed_hook_targets[TRACE_MAX_TARGETS * 2];
static int g_installed_hook_count;

/* 控制 App 自己的 bundleId:引擎注入到它时要跳过(不自钩) */
#define GUI_BUNDLE_ID @"com.snk.qbditracer"

bool find_module(const char *name, uint64_t *runtime_base) {
    if (name == NULL || runtime_base == NULL) {
        return false;
    }
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *img = _dyld_get_image_name(i);
        if (img && strstr(img, name)) {
            *runtime_base = (uint64_t)(uintptr_t)_dyld_get_image_header(i);
            return true;
        }
    }
    return false;
}

/* 配置文件路径:优先 rootless 前缀 /var/jb,回退经典路径 */
static NSString *config_path(void) {
    NSArray *bases = @[ @"/var/jb/var/mobile/Documents/QBDITracer",
                        @"/var/mobile/Documents/QBDITracer" ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *b in bases) {
        NSString *p = [b stringByAppendingPathComponent:@"config.json"];
        if ([fm fileExistsAtPath:p]) {
            return p;
        }
    }
    /* 默认返回经典路径(供日志说明) */
    return [bases.lastObject stringByAppendingPathComponent:@"config.json"];
}

/* "0x1234" / "1234"(hex) → uint64。空/非法返回 0 */
static uint64_t parse_hex(id v) {
    if ([v isKindOfClass:[NSNumber class]]) {
        return (uint64_t)[v unsignedLongLongValue];
    }
    if (![v isKindOfClass:[NSString class]]) {
        return 0;
    }
    const char *s = [v UTF8String];
    if (s == NULL) {
        return 0;
    }
    return (uint64_t)strtoull(s, NULL, 16);
}

/* 地址字段的严格解析：不允许把 "12zz" 静默当成 0x12。 */
static bool parse_hex_strict(id v, uint64_t *out) {
    if (out == NULL) return false;
    if ([v isKindOfClass:[NSNumber class]]) {
        *out = (uint64_t)[v unsignedLongLongValue];
        return true;
    }
    if (![v isKindOfClass:[NSString class]]) return false;
    const char *s = [v UTF8String];
    if (s == NULL) return false;
    while (*s == ' ' || *s == '\t') s++;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) s += 2;
    if (*s == '\0') return false;
    char *end = NULL;
    unsigned long long n = strtoull(s, &end, 16);
    if (end == s) return false;
    while (*end == ' ' || *end == '\t') end++;
    if (*end != '\0') return false;
    *out = (uint64_t)n;
    return true;
}

/* size 字段专用:带 "0x" 前缀按十六进制,不带按十进制。
 * 旧配置里 size 是裸十进制数字(NSNumber),新 App 写出来一律是 "0x..." 字符串,
 * 两者靠前缀区分,不用迁移。 */
static uint64_t parse_size(id v) {
    if ([v isKindOfClass:[NSNumber class]]) {
        return (uint64_t)[v unsignedLongLongValue];
    }
    if (![v isKindOfClass:[NSString class]]) {
        return 0;
    }
    const char *s = [v UTF8String];
    if (s == NULL) {
        return 0;
    }
    while (*s == ' ' || *s == '\t') {
        s++;
    }
    bool hex = (s[0] == '0' && (s[1] == 'x' || s[1] == 'X'));
    return (uint64_t)strtoull(hex ? s + 2 : s, NULL, hex ? 16 : 10);
}

static int parse_int(id v, int dflt) {
    if ([v isKindOfClass:[NSNumber class]]) {
        return [v intValue];
    }
    if ([v isKindOfClass:[NSString class]]) {
        return (int)strtol([v UTF8String], NULL, 0);
    }
    return dflt;
}

static bool parse_bool(id v, bool dflt) {
    if ([v isKindOfClass:[NSNumber class]]) {
        return [v boolValue];
    }
    return dflt;
}

/* strdup 一个 NSString(生命周期=进程);nil → NULL */
static const char *dup_str(id v) {
    if (![v isKindOfClass:[NSString class]] || [v length] == 0) {
        return NULL;
    }
    const char *s = [v UTF8String];
    return s ? strdup(s) : NULL;
}

/* 解析触发条件。返回 false = 配置有问题(调用方应拒绝整条 trace,而不是退化成无条件 ——
 * 过滤静默失效会给一堆本该被滤掉的日志,比不 trace 更误导)。err 写人可读原因。 */
static bool load_trigger(NSDictionary *it, TraceSpec *t, char *err, size_t errcap) {
    t->trigger_match = TRIG_NONE;
    t->trigger_where = TRIG_AT_PREFIX;
    t->trigger_scan  = TRIG_DEF_SCAN;
    t->trigger_expr  = NULL;
    t->want_nbytes   = 0;
    t->want_u64      = 0;
    t->trigger_address = t->static_start;
    memset(&t->trigger_cexpr, 0, sizeof(t->trigger_cexpr));

    const char *expr = dup_str(it[@"triggerExpr"]);
    if (expr == NULL) {
        return true; /* 没配条件:无条件 trace,和以前一样 */
    }

    if (!wexpr_compile(expr, &t->trigger_cexpr, err, errcap)) {
        return false;
    }
    t->trigger_expr = expr;

    id address = it[@"triggerAddress"];
    if ([address isKindOfClass:[NSString class]] && [address length] == 0) {
        address = nil; /* App 里留空 = 起始地址 */
    }
    if (address != nil && !parse_hex_strict(address, &t->trigger_address)) {
        snprintf(err, errcap, "triggerAddress is not a valid hex address");
        return false;
    }
    /* 等于 start 沿用原 hook；其余地址必须在数值区间外。
     * 低于 start 时还要避免两个 0x10 字节的 Dobby 补丁重叠。 */
    if (t->trigger_address > t->static_start &&
        t->trigger_address < t->static_end) {
        snprintf(err, errcap,
                 "triggerAddress 0x%llx is inside trace range (0x%llx, 0x%llx)",
                 (unsigned long long)t->trigger_address,
                 (unsigned long long)t->static_start,
                 (unsigned long long)t->static_end);
        return false;
    }
    if (t->trigger_address < t->static_start &&
        t->static_start - t->trigger_address < QBDI_PATCH_SIZE) {
        snprintf(err, errcap,
                 "triggerAddress 0x%llx is too close to start 0x%llx; "
                 "Dobby hooks need at least 0x%x bytes",
                 (unsigned long long)t->trigger_address,
                 (unsigned long long)t->static_start, QBDI_PATCH_SIZE);
        return false;
    }

    NSString *m = [it[@"triggerMatch"] isKindOfClass:[NSString class]]
                      ? it[@"triggerMatch"] : @"notnull";
    NSString *v = [it[@"triggerValue"] isKindOfClass:[NSString class]]
                      ? it[@"triggerValue"] : @"";

    /* 期望值出现在哪儿。缺省按直觉给:字符串=包含,字节=开头 */
    NSString *w = it[@"triggerWhere"];
    if ([w isKindOfClass:[NSString class]] && [w length] > 0) {
        if ([w isEqualToString:@"contains"]) {
            t->trigger_where = TRIG_AT_CONTAINS;
        } else if ([w isEqualToString:@"prefix"]) {
            t->trigger_where = TRIG_AT_PREFIX;
        } else {
            snprintf(err, errcap, "unknown triggerWhere \"%s\"", [w UTF8String]);
            return false;
        }
    } else {
        t->trigger_where =
            [m isEqualToString:@"cstr"] ? TRIG_AT_CONTAINS : TRIG_AT_PREFIX;
    }

    /* 「包含」的读取上限(与 size 同规则:带 0x = 十六进制,不带 = 十进制) */
    if (it[@"triggerScan"] != nil) {
        uint64_t sc = parse_size(it[@"triggerScan"]);
        if (sc == 0) {
            sc = TRIG_DEF_SCAN;
        }
        if (sc > TRIG_MAX_SCAN) {
            snprintf(err, errcap, "triggerScan 0x%llx exceeds max 0x%x",
                     (unsigned long long)sc, TRIG_MAX_SCAN);
            return false;
        }
        t->trigger_scan = (uint32_t)sc;
    }

    if ([m isEqualToString:@"notnull"]) {
        t->trigger_match = TRIG_NOTNULL;
        return true;
    }
    if ([m isEqualToString:@"u64"]) {
        t->trigger_match = TRIG_U64;
        t->want_u64 = parse_hex(v); /* 一律十六进制,与 offset 同规则 */
        return true;
    }
    if ([m isEqualToString:@"cstr"]) {
        const char *s = [v UTF8String];
        size_t n = s ? strlen(s) : 0;
        if (n == 0 || n > TRIG_MAX_BYTES) {
            snprintf(err, errcap, "cstr value must be 1..%d bytes", TRIG_MAX_BYTES);
            return false;
        }
        memcpy(t->want_bytes, s, n);
        t->want_nbytes = (int)n;
        t->trigger_match = TRIG_CSTR;
        if (t->trigger_where == TRIG_AT_CONTAINS && t->trigger_scan < n) {
            snprintf(err, errcap,
                     "triggerScan 0x%x is smaller than the %zu-byte needle",
                     t->trigger_scan, n);
            return false;
        }
        return true;
    }
    if ([m isEqualToString:@"bytes"]) {
        /* "08a48c90" / "08 a4 8c 90":忽略空白,按内存顺序存 */
        const char *s = [v UTF8String];
        if (s == NULL) {
            snprintf(err, errcap, "bytes value missing");
            return false;
        }
        int hi = -1, n = 0;
        for (; *s; s++) {
            if (*s == ' ' || *s == '\t' || *s == ':' || *s == ',') {
                continue;
            }
            int d;
            char c = (*s >= 'A' && *s <= 'Z') ? (char)(*s - 'A' + 'a') : *s;
            if (c >= '0' && c <= '9') {
                d = c - '0';
            } else if (c >= 'a' && c <= 'f') {
                d = c - 'a' + 10;
            } else {
                snprintf(err, errcap, "bytes value has non-hex char '%c'", *s);
                return false;
            }
            if (hi < 0) {
                hi = d;
            } else {
                if (n >= TRIG_MAX_BYTES) {
                    snprintf(err, errcap, "bytes value longer than %d bytes",
                             TRIG_MAX_BYTES);
                    return false;
                }
                t->want_bytes[n++] = (uint8_t)((hi << 4) | d);
                hi = -1;
            }
        }
        if (hi >= 0) {
            snprintf(err, errcap, "bytes value needs an even number of hex digits");
            return false;
        }
        if (n == 0) {
            snprintf(err, errcap, "bytes value is empty");
            return false;
        }
        t->want_nbytes = n;
        t->trigger_match = TRIG_BYTES;
        /* 窗口比要找的东西还短,那永远搜不到 —— 拦下来,别让它静默不匹配 */
        if (t->trigger_where == TRIG_AT_CONTAINS && (int)t->trigger_scan < n) {
            snprintf(err, errcap,
                     "triggerScan 0x%x is smaller than the %d-byte needle",
                     t->trigger_scan, n);
            return false;
        }
        return true;
    }

    snprintf(err, errcap, "unknown triggerMatch \"%s\"", [m UTF8String]);
    return false;
}

static bool hook_patches_overlap(uint64_t a, uint64_t b) {
    uint64_t hi = a > b ? a : b;
    uint64_t lo = a > b ? b : a;
    return hi - lo < QBDI_PATCH_SIZE;
}

static bool installed_hook_conflict(uint64_t target, uint64_t *existing) {
    for (int i = 0; i < g_installed_hook_count; i++) {
        if (hook_patches_overlap(target, g_installed_hook_targets[i])) {
            if (existing) *existing = g_installed_hook_targets[i];
            return true;
        }
    }
    return false;
}

static void remember_installed_hook(uint64_t target) {
    int cap = (int)(sizeof(g_installed_hook_targets) /
                    sizeof(g_installed_hook_targets[0]));
    if (g_installed_hook_count < cap) {
        g_installed_hook_targets[g_installed_hook_count++] = target;
    }
}

/* Dobby 在每个目标地址覆盖 0x10 字节。既要防本条的 trigger/start
 * 互相覆盖，也要防不同条目的 start/trigger 重叠。 */
static bool find_hook_conflict(const TraceSpec *t, int *other_slot,
                               uint64_t *this_address,
                               uint64_t *other_address) {
    uint64_t mine[2] = { t->static_start, t->trigger_address };
    int mine_count = (t->trigger_match != TRIG_NONE &&
                      t->trigger_address != t->static_start) ? 2 : 1;
    for (int i = 0; i < g_trace_count; i++) {
        const TraceSpec *other = &g_traces[i];
        if (other->module == NULL || strcmp(t->module, other->module) != 0) {
            continue;
        }
        uint64_t theirs[2] = { other->static_start, other->trigger_address };
        int their_count = (other->trigger_match != TRIG_NONE &&
                           other->trigger_address != other->static_start) ? 2 : 1;
        for (int m = 0; m < mine_count; m++) {
            for (int n = 0; n < their_count; n++) {
                if (hook_patches_overlap(mine[m], theirs[n])) {
                    if (other_slot) *other_slot = i;
                    if (this_address) *this_address = mine[m];
                    if (other_address) *other_address = theirs[n];
                    return true;
                }
            }
        }
    }
    return false;
}

/* 把一条 item 的 watches 填进全局 g_watches */
static void load_watches(NSArray *warr) {
    if (![warr isKindOfClass:[NSArray class]]) {
        return;
    }
    for (NSDictionary *w in warr) {
        if (![w isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        if (g_watch_count >= TRACE_MAX_WATCHES) {
            break;
        }
        TraceWatch *dst = &g_watches[g_watch_count];
        memset(dst, 0, sizeof(*dst));
        dst->module = dup_str(w[@"module"]);
        dst->offset = parse_hex(w[@"offset"]);
        dst->reg    = dup_str(w[@"reg"]);
        dst->expr   = dup_str(w[@"expr"]);
        dst->action = dup_str(w[@"action"]);
        dst->size   = (uint32_t)parse_size(w[@"size"]);
        dst->label  = dup_str(w[@"label"]);
        if (dst->expr != NULL) {
            /* 加载期就编译:语法错误此刻进日志,不会表现成"watch 没有任何输出" */
            char err[96];
            if (!wexpr_compile(dst->expr, &dst->cexpr, err, sizeof(err))) {
                qbdi_trace_logf("[watch] bad expr \"%s\": %s (falling back to reg %s)\n",
                                dst->expr, err, dst->reg ? dst->reg : "(none)");
                dst->cexpr.nops = 0;
                dst->expr       = NULL;
            }
        }
        if (dst->module == NULL || (dst->reg == NULL && dst->expr == NULL)) {
            qbdi_trace_logf("[watch] skipped invalid entry: module=%s reg=%s expr=%s\n",
                            dst->module ? dst->module : "(null)",
                            dst->reg ? dst->reg : "(null)",
                            dst->expr ? dst->expr : "(null)");
            continue; /* 丢弃无效行,不递增 count */
        }
        g_watch_count++;
    }
}

/* 对一个槽位装 Dobby hook(在该条目的延迟到点后调用) */
static void install_slot(int slot) {
    TraceSpec *t = &g_traces[slot];
    qbdi_trace_logf("[engine] installing hook: slot=%d name=%s target=%s+0x%llx\n",
                    slot, t->trace_name ? t->trace_name : "(unnamed)",
                    t->module ? t->module : "(null)",
                    (unsigned long long)t->static_start);
    uint64_t base = 0;
    if (!find_module(t->module, &base)) {
        qbdi_trace_logf("[engine] module not found: %s (slot %d)\n", t->module, slot);
        return;
    }
    uint64_t start_abs = base + t->static_start;
    uint64_t trigger_abs = base + t->trigger_address;
    uint64_t conflict = 0;
    if (installed_hook_conflict(start_abs, &conflict) ||
        (t->trigger_match != TRIG_NONE &&
         t->trigger_address != t->static_start &&
         installed_hook_conflict(trigger_abs, &conflict))) {
        qbdi_trace_logf(
            "[engine] hook install rejected: %s slot %d target near existing "
            "absolute hook 0x%llx\n",
            t->module, slot, (unsigned long long)conflict);
        return;
    }
    /* trigger hook 先装时也能安全透传；只有 start origin 就绪后才允许授权。 */
    g_module_base[slot] = base;
    /* 自定义触发点必须先装好。若它失败，不再装 start hook，
     * 避免表面上 hook 成功但永远等不到触发的半失效状态。 */
    if (t->trigger_match != TRIG_NONE &&
        t->trigger_address != t->static_start) {
        void *trigger_target =
            (void *)(uintptr_t)(base + t->trigger_address);
        void *trigger_origin = NULL;
        qbdi_trace_logf(
            "[engine] installing trigger hook: slot=%d target=%s+0x%llx\n",
            slot, t->module, (unsigned long long)t->trigger_address);
        int trc = DobbyHook(trigger_target, (void *)g_trigger_tramps[slot],
                            &trigger_origin);
        if (trc != 0 || trigger_origin == NULL) {
            qbdi_trace_logf(
                "[engine] trigger DobbyHook failed(%d): %s+0x%llx "
                "(slot %d); start hook not installed\n",
                trc, t->module, (unsigned long long)t->trigger_address, slot);
            return;
        }
        g_trigger_origin[slot] = trigger_origin;
        remember_installed_hook(trigger_abs);
        qbdi_trace_logf(
            "[engine] trigger hooked %s+0x%llx @ %p (slot %d, origin=%p)\n",
            t->module, (unsigned long long)t->trigger_address,
            trigger_target, slot, trigger_origin);
    }
    void *target = (void *)(uintptr_t)(base + t->static_start);
    void *origin = NULL;
    int rc = DobbyHook(target, (void *)g_tramps[slot], &origin);
    if (rc == 0 && origin != NULL) {
        /* 基址在这里存好:trace_ctx_entry 每次命中都要用,不能让它自己去
         * find_module(遍历 dyld 镜像 + 抢 dyld 锁,热点上会拖死整个进程) */
        g_module_base[slot] = base;
        g_origin[slot] = origin;
        remember_installed_hook(start_abs);
        qbdi_trace_logf("[engine] hooked %s+0x%llx @ %p (slot %d, origin=%p)\n",
                        t->module, (unsigned long long)t->static_start, target,
                        slot, origin);
    } else {
        qbdi_trace_logf("[engine] DobbyHook failed(%d): %s+0x%llx (slot %d)\n",
                        rc, t->module, (unsigned long long)t->static_start, slot);
    }
}

void engine_start(void) {
    @autoreleasepool {
        NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
        /* 控制 App 自己不 hook */
        if (bundleId != nil && [bundleId isEqualToString:GUI_BUNDLE_ID]) {
            return;
        }

        NSString *processName = [[NSProcessInfo processInfo] processName];
        qbdi_console_logf("engine loaded: app=%s bundle=%s pid=%d",
                          processName.UTF8String ?: "(unknown)",
                          bundleId.UTF8String ?: "(unknown)",
                          [[NSProcessInfo processInfo] processIdentifier]);

        NSString *path = config_path();
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data == nil) {
            return; /* 无配置:空转返回(全量注入的其它 app 走这里) */
        }
        NSError *jsonError = nil;
        NSDictionary *cfg =
            [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (![cfg isKindOfClass:[NSDictionary class]]) {
            qbdi_console_logf("config load failed: path=%s error=%s",
                              path.UTF8String,
                              jsonError.localizedDescription.UTF8String ?: "invalid root object");
            return;
        }
        if (!parse_bool(cfg[@"enabled"], true)) {
            return; /* 总开关关闭 */
        }
        NSArray *items = cfg[@"items"];
        if (![items isKindOfClass:[NSArray class]] || items.count == 0) {
            return;
        }

        /* 收集匹配当前 bundleId 且启用的条目。
         * 去重:同一 (module, start) 只保留最后一条 —— 同地址二重 hook 会让
         * 先装的槽位(=列表靠前的条目)支配,导致"停用第1条、启用第2条"却仍是
         * 第1条生效。用户后创建/后启用的条目在列表更靠后,故"后者覆盖前者"。 */
        NSMutableArray *matched = [NSMutableArray array];
        NSMutableDictionary *seen = [NSMutableDictionary dictionary]; /* key -> matched 下标 */
        for (NSDictionary *it in items) {
            if (![it isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            id bid = it[@"bundleId"];
            if (![bid isKindOfClass:[NSString class]] || bundleId == nil ||
                ![bid isEqualToString:bundleId]) {
                continue;
            }
            if (!parse_bool(it[@"enabled"], true)) {
                id namev = it[@"traceName"];
                id modv = it[@"module"];
                qbdi_console_logf(
                    "trace disabled, skip: name=%s target=%s+0x%llx",
                    [namev isKindOfClass:[NSString class]] && [namev length]
                        ? [namev UTF8String] : "(unnamed)",
                    [modv isKindOfClass:[NSString class]]
                        ? [modv UTF8String] : "(unknown)",
                    (unsigned long long)parse_hex(it[@"start"]));
                continue;
            }
            /* 去重键:模块名 + 起始偏移(归一化成数值,兼容 "0x100"/"256" 混写) */
            id modv = it[@"module"];
            NSString *mod = [modv isKindOfClass:[NSString class]] ? modv : @"";
            NSString *key = [NSString stringWithFormat:@"%@|0x%llx", mod,
                             (unsigned long long)parse_hex(it[@"start"])];
            NSNumber *idx = seen[key];
            if (idx != nil) {
                /* 同地址已存在:后者覆盖前者(原地替换,保持顺序) */
                qbdi_trace_logf("[engine] dup target %s overrides earlier entry\n",
                                [key UTF8String]);
                matched[idx.unsignedIntegerValue] = it;
            } else {
                seen[key] = @(matched.count);
                [matched addObject:it];
            }
        }
        if (matched.count == 0) {
            return; /* 当前 app 无匹配条目:空转返回 */
        }

        /* 崩溃捕获立即装(延迟期间崩溃也留档) */
        qbdi_trace_crash_diag_init();
        qbdi_trace_logf("[engine] app started, begin injection: %s, %lu matched item(s)\n",
                        [bundleId UTF8String], (unsigned long)matched.count);

        for (NSDictionary *it in matched) {
            if (g_trace_count >= TRACE_MAX_TARGETS) {
                qbdi_trace_logf("[engine] too many traces, cap=%d\n",
                                TRACE_MAX_TARGETS);
                break;
            }
            int slot = g_trace_count;
            TraceSpec *t = &g_traces[slot];
            t->trace_name   = dup_str(it[@"traceName"]);
            t->module       = dup_str(it[@"module"]);
            t->static_start = parse_hex(it[@"start"]);
            t->static_end   = parse_hex(it[@"end"]);
            t->module_only  = parse_bool(it[@"moduleOnly"], true) ? 1 : 0;
            t->count        = parse_int(it[@"count"], 1);
            t->delay_secs   = parse_int(it[@"delaySecs"], 0);
            t->log_mask     = (uint64_t)parse_int(it[@"logMask"], LOG_INST);
            /* 旧版固定在 1000 万条时静默截断，即使还没到 end。
             * 精确 trace 的默认语义应是“跑到 end”；需要保护时可在 JSON
             * 显式设 maxInstructions，0/缺省表示不限制。 */
            t->max_instructions = parse_size(it[@"maxInstructions"]);
            if (t->module == NULL || t->static_end <= t->static_start) {
                qbdi_trace_logf("[engine] skip invalid item (slot %d)\n", slot);
                memset(t, 0, sizeof(*t));
                continue;
            }
            /* 区间短于 Dobby 补丁长度时,end 落在 [start, start+0x10) 里 —— 那几条指令
             * 在真实内存里已被补丁覆盖,QBDI 跑的是 origin 里的副本,PC 永远不会等于 end,
             * 于是停不下来、一路执行到崩。这种配置必须拒掉,不能让它跑。 */
            if (t->static_end - t->static_start < QBDI_PATCH_SIZE) {
                qbdi_trace_logf("[engine] skip item (slot %d): range 0x%llx too short, "
                                "end must be >= start + 0x%x (Dobby patch covers "
                                "[start, start+0x%x))\n",
                                slot,
                                (unsigned long long)(t->static_end - t->static_start),
                                QBDI_PATCH_SIZE, QBDI_PATCH_SIZE);
                memset(t, 0, sizeof(*t));
                continue;
            }
            char terr[96];
            if (!load_trigger(it, t, terr, sizeof(terr))) {
                /* 条件配错就拒整条:否则过滤静默失效,日志里全是本该被滤掉的内容 */
                qbdi_trace_logf("[engine] skip item (slot %d): bad trigger: %s\n",
                                slot, terr);
                memset(t, 0, sizeof(*t));
                continue;
            }
            int conflict_slot = -1;
            uint64_t this_hook = 0, other_hook = 0;
            if (find_hook_conflict(t, &conflict_slot, &this_hook, &other_hook)) {
                qbdi_trace_logf(
                    "[engine] skip item (slot %d): Dobby hook %s+0x%llx "
                    "overlaps slot %d hook at 0x%llx (patch size 0x%x)\n",
                    slot, t->module, (unsigned long long)this_hook,
                    conflict_slot, (unsigned long long)other_hook,
                    QBDI_PATCH_SIZE);
                memset(t, 0, sizeof(*t));
                continue;
            }
            if (t->trigger_match != TRIG_NONE) {
                qbdi_trace_logf("[%s] trigger: %s (%s) at 0x%llx\n", t->module,
                                t->trigger_expr,
                                t->trigger_match == TRIG_NOTNULL ? "notnull"
                                : t->trigger_match == TRIG_BYTES ? "bytes"
                                : t->trigger_match == TRIG_CSTR  ? "cstr"
                                                                 : "u64",
                                (unsigned long long)t->trigger_address);
            }
            load_watches(it[@"watches"]);
            g_trace_count++;
        }

        if (g_trace_count == 0) {
            qbdi_trace_logf("[engine] injection aborted: no valid trace items for %s\n",
                            [bundleId UTF8String]);
            return;
        }
        qbdi_trace_init_state(); /* 按 g_trace_count 重置 origin/remaining */

        /* 每条目各自延迟装 hook */
        for (int slot = 0; slot < g_trace_count; slot++) {
            int delay = g_traces[slot].delay_secs;
            if (delay <= 0) {
                install_slot(slot);
            } else {
                int captured = slot;
                dispatch_after(
                    dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay * NSEC_PER_SEC),
                    dispatch_get_main_queue(), ^{
                        install_slot(captured);
                    });
                qbdi_trace_logf("[engine] slot %d will install after %ds\n",
                                slot, delay);
            }
        }
    }
}
