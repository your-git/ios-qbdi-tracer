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
        dst->module = dup_str(w[@"module"]);
        dst->offset = parse_hex(w[@"offset"]);
        dst->reg    = dup_str(w[@"reg"]);
        dst->action = dup_str(w[@"action"]);
        dst->size   = (uint32_t)parse_int(w[@"size"], 0);
        dst->label  = dup_str(w[@"label"]);
        if (dst->module == NULL || dst->reg == NULL) {
            continue; /* 丢弃无效行,不递增 count */
        }
        g_watch_count++;
    }
}

/* 对一个槽位装 Dobby hook(在该条目的延迟到点后调用) */
static void install_slot(int slot) {
    TraceSpec *t = &g_traces[slot];
    uint64_t base = 0;
    if (!find_module(t->module, &base)) {
        qbdi_trace_logf("[engine] module not found: %s (slot %d)\n", t->module, slot);
        return;
    }
    void *target = (void *)(uintptr_t)(base + t->static_start);
    void *origin = NULL;
    int rc = DobbyHook(target, (void *)g_tramps[slot], &origin);
    if (rc == 0 && origin != NULL) {
        g_origin[slot] = origin;
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

        NSString *path = config_path();
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data == nil) {
            return; /* 无配置:空转返回(全量注入的其它 app 走这里) */
        }
        NSDictionary *cfg =
            [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![cfg isKindOfClass:[NSDictionary class]]) {
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
            if (!parse_bool(it[@"enabled"], true)) {
                continue;
            }
            id bid = it[@"bundleId"];
            if (![bid isKindOfClass:[NSString class]] || bundleId == nil ||
                ![bid isEqualToString:bundleId]) {
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
        qbdi_trace_logf("[engine] %s: %lu matched item(s)\n",
                        [bundleId UTF8String], (unsigned long)matched.count);

        for (NSDictionary *it in matched) {
            if (g_trace_count >= TRACE_MAX_TARGETS) {
                qbdi_trace_logf("[engine] too many traces, cap=%d\n",
                                TRACE_MAX_TARGETS);
                break;
            }
            int slot = g_trace_count;
            TraceSpec *t = &g_traces[slot];
            t->module       = dup_str(it[@"module"]);
            t->static_start = parse_hex(it[@"start"]);
            t->static_end   = parse_hex(it[@"end"]);
            t->module_only  = parse_bool(it[@"moduleOnly"], true) ? 1 : 0;
            t->count        = parse_int(it[@"count"], 1);
            t->delay_secs   = parse_int(it[@"delaySecs"], 0);
            t->log_mask     = (uint64_t)parse_int(it[@"logMask"], LOG_INST);
            if (t->module == NULL || t->static_end <= t->static_start) {
                qbdi_trace_logf("[engine] skip invalid item (slot %d)\n", slot);
                memset(t, 0, sizeof(*t));
                continue;
            }
            load_watches(it[@"watches"]);
            g_trace_count++;
        }

        if (g_trace_count == 0) {
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
