#import "ConfigStore.h"

#import "AppSettings.h"

/* 旧 JSON 没有 mutations 时返回空数组；字段补默认值只为 GUI 可编辑性，
 * 最终的严格合法性仍由编辑页和引擎各自校验。 */
static NSMutableArray *mutableMutations(id raw) {
    NSMutableArray *result = [NSMutableArray array];
    if (![raw isKindOfClass:[NSArray class]]) return result;
    for (NSDictionary *entry in raw) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSMutableDictionary *copy = [entry mutableCopy];
        if (copy[@"enabled"] == nil) copy[@"enabled"] = @YES;
        if (copy[@"reg"] == nil) copy[@"reg"] = @"x0";
        if (copy[@"width"] == nil) copy[@"width"] = @64;
        if (copy[@"apply"] == nil) copy[@"apply"] = @"once";
        for (NSString *key in @[ @"offset", @"value" ]) {
            if ([copy[key] isKindOfClass:[NSNumber class]]) {
                copy[key] = [NSString stringWithFormat:@"0x%llx",
                             [copy[key] unsignedLongLongValue]];
            }
        }
        [result addObject:copy];
    }
    return result;
}

@implementation ConfigStore

+ (instancetype)shared {
    static ConfigStore *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [ConfigStore new];
        [s load];
    });
    return s;
}

/* 配置目录:rootless 优先 /var/jb,否则经典路径。与引擎 config_path() 保持一致。 */
- (NSString *)configDir {
    return QBDIConfigDir();
}

- (NSString *)configPath {
    return [[self configDir] stringByAppendingPathComponent:@"config.json"];
}

- (void)load {
    self.items = [NSMutableArray array];

    NSData *data = [NSData dataWithContentsOfFile:[self configPath]];
    if (data == nil) {
        return;
    }
    NSDictionary *cfg =
        [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![cfg isKindOfClass:[NSDictionary class]]) {
        return;
    }
    /* cfg[@"enabled"] 是旧版总开关,已由 AppSettings 迁到 settings.json,这里忽略。 */
    NSArray *items = cfg[@"items"];
    if ([items isKindOfClass:[NSArray class]]) {
        for (NSDictionary *it in items) {
            if ([it isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *m = [it mutableCopy];
                /* watches 深拷成可变 */
                NSArray *w = it[@"watches"];
                NSMutableArray *mw = [NSMutableArray array];
                if ([w isKindOfClass:[NSArray class]]) {
                    for (NSDictionary *e in w) {
                        if ([e isKindOfClass:[NSDictionary class]]) {
                            [mw addObject:[e mutableCopy]];
                        }
                    }
                }
                m[@"watches"] = mw;
                m[@"mutations"] = mutableMutations(it[@"mutations"]);
                /* triggers 深拷；旧版扁平触发字段迁移成一条，未配置则保持空数组。 */
                NSMutableArray *mt = [NSMutableArray array];
                NSArray *triggers = it[@"triggers"];
                if ([triggers isKindOfClass:[NSArray class]]) {
                    for (NSDictionary *e in triggers) {
                        if ([e isKindOfClass:[NSDictionary class]]) {
                            NSMutableDictionary *copy = [e mutableCopy];
                            id address = copy[@"triggerAddress"];
                            if ([address isKindOfClass:[NSNumber class]]) {
                                copy[@"triggerAddress"] = [NSString stringWithFormat:
                                    @"0x%llx", [address unsignedLongLongValue]];
                            }
                            if (copy[@"triggerLimit"] == nil) copy[@"triggerLimit"] = @1;
                            [mt addObject:copy];
                        }
                    }
                } else if ([it[@"triggerExpr"] isKindOfClass:[NSString class]] &&
                           [it[@"triggerExpr"] length] > 0) {
                    NSMutableDictionary *legacy = [NSMutableDictionary dictionary];
                    for (NSString *key in @[ @"triggerExpr", @"triggerAddress",
                                             @"triggerMatch", @"triggerValue",
                                             @"triggerWhere", @"triggerScan" ]) {
                        if (it[key] != nil) legacy[key] = it[key];
                    }
                    id address = legacy[@"triggerAddress"];
                    if ([address isKindOfClass:[NSNumber class]]) {
                        legacy[@"triggerAddress"] = [NSString stringWithFormat:
                            @"0x%llx", [address unsignedLongLongValue]];
                    }
                    legacy[@"triggerLimit"] = @1;
                    [mt addObject:legacy];
                }
                m[@"triggers"] = mt;
                if (m[@"triggerConsume"] == nil) m[@"triggerConsume"] = @"repeat";
                for (NSString *key in @[ @"triggerExpr", @"triggerAddress",
                                         @"triggerMatch", @"triggerValue",
                                         @"triggerWhere", @"triggerScan" ]) {
                    [m removeObjectForKey:key];
                }
                [self.items addObject:m];
            }
        }
    }
}

- (BOOL)save {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *err = nil;
    [fm createDirectoryAtPath:[self configDir]
  withIntermediateDirectories:YES
                   attributes:nil
                        error:&err];

    NSDictionary *cfg = @{ @"items": self.items ?: @[] };
    if (![NSJSONSerialization isValidJSONObject:cfg]) {
        return NO;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:cfg
                                                  options:NSJSONWritingPrettyPrinted
                                                    error:&err];
    if (data == nil) {
        return NO;
    }
    return [data writeToFile:[self configPath] atomically:YES];
}

- (NSMutableDictionary *)newItem {
    return [@{
        @"id": [[NSUUID UUID] UUIDString],
        @"addedAt": QBDINewAddedAt(),
        @"enabled": @YES,
        @"traceName": @"",       /* 可选的用户自定义名称 */
        @"bundleId": @"",
        @"appName": @"",
        @"module": @"",
        @"start": @"0x0",
        @"end": @"0x0",
        @"count": @1,
        @"moduleOnly": @YES,
        @"delaySecs": @0,
        @"logMask": @17,         /* LOG_INST | LOG_VREG(界面已不再让用户选) */
        @"maxInstructions": @0,  /* 0=精确跑到 end，不按指令数截断 */
        @"triggerConsume": @"repeat",
        @"triggers": [NSMutableArray array],
        @"mutations": [NSMutableArray array],
        @"watches": [NSMutableArray array],
    } mutableCopy];
}

#pragma mark - 导出 / 导入

static NSError *cfgError(NSString *msg) {
    return [NSError errorWithDomain:@"ConfigStore"
                               code:1
                           userInfo:@{ NSLocalizedDescriptionKey: msg }];
}

- (NSString *)exportDir {
    return [[AppSettings shared] traceExportDir];
}

/* 文件名净化:去掉路径分隔符和空白,保证是合法文件名 */
static NSString *sanitizeName(NSString *s) {
    if (s.length == 0) return @"App";
    NSCharacterSet *bad = [NSCharacterSet
        characterSetWithCharactersInString:@"/\\:*?\"<>| \t\n"];
    NSArray *parts = [s componentsSeparatedByCharactersInSet:bad];
    NSString *out = [parts componentsJoinedByString:@""];
    return out.length ? out : @"App";
}

- (NSString *)exportItem:(NSDictionary *)item error:(NSError **)err {
    if (![item isKindOfClass:[NSDictionary class]]) {
        if (err) *err = cfgError(@"条目无效");
        return nil;
    }
    NSDictionary *wrapper = @{ @"version": @1, @"item": item };
    if (![NSJSONSerialization isValidJSONObject:wrapper]) {
        if (err) *err = cfgError(@"条目无法序列化");
        return nil;
    }
    NSError *e = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:wrapper
                                                  options:NSJSONWritingPrettyPrinted
                                                    error:&e];
    if (data == nil) {
        if (err) *err = e ?: cfgError(@"序列化失败");
        return nil;
    }

    NSString *appName = [item[@"appName"] length] ? item[@"appName"]
                                                  : item[@"bundleId"];
    NSDateFormatter *df = [NSDateFormatter new];
    df.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    df.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    df.dateFormat = @"yyyyMMddHHmmss";
    NSString *ts = [df stringFromDate:[NSDate date]];
    NSString *fname = [NSString stringWithFormat:@"trace_%@%@.json",
                       sanitizeName(appName), ts];
    NSString *path = [[self exportDir] stringByAppendingPathComponent:fname];

    if (![data writeToFile:path atomically:YES]) {
        if (err) *err = cfgError(@"写文件失败(检查权限)");
        return nil;
    }
    return path;
}

- (NSArray<NSString *> *)listImportableFiles {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *paths = [NSMutableArray array];
    /* 旧版把导出文件直接堆在 Documents 根下。升级后仍然列出来,否则用户会以为
     * 以前导出的配置丢了。同名文件以新目录为准。 */
    NSMutableArray<NSString *> *dirs = [NSMutableArray arrayWithObject:[self exportDir]];
    NSString *legacy = QBDIDocumentsDir();
    if (legacy.length && ![dirs containsObject:legacy]) [dirs addObject:legacy];

    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *dir in dirs) {
        for (NSString *n in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            if (![n.pathExtension.lowercaseString isEqualToString:@"json"]) continue;
            if ([seen containsObject:n]) continue;
            [seen addObject:n];
            [paths addObject:[dir stringByAppendingPathComponent:n]];
        }
    }
    return QBDISortedFilePaths(paths, QBDIListSortNewestFirst);
}

/* 校验并规整一条 item:必须能解析 + 有 module/start/end。通过则重生 id、enabled=YES。 */
- (NSMutableDictionary *)normalizeImported:(id)raw error:(NSError **)err {
    NSDictionary *item = nil;
    if ([raw isKindOfClass:[NSDictionary class]]) {
        /* 支持两种:{version,item:{}} 包装,或直接就是 item */
        if ([raw[@"item"] isKindOfClass:[NSDictionary class]]) {
            item = raw[@"item"];
        } else if (raw[@"module"] != nil) {
            item = raw;
        }
    }
    if (item == nil) {
        if (err) *err = cfgError(@"配置格式无效");
        return nil;
    }
    /* 必要字段 */
    if (![item[@"module"] isKindOfClass:[NSString class]] ||
        [item[@"module"] length] == 0 ||
        item[@"start"] == nil || item[@"end"] == nil) {
        if (err) *err = cfgError(@"配置格式无效(缺 module/start/end)");
        return nil;
    }

    /* 以 newItem 为模板补齐缺省字段,再覆盖已有值 */
    NSMutableDictionary *out = [self newItem];
    /* 加字段记得加进这个白名单,否则导出再导入会把它丢掉 */
    for (NSString *k in @[ @"enabled", @"traceName", @"bundleId", @"appName", @"module",
                           @"start", @"end", @"count", @"moduleOnly",
                           @"delaySecs", @"logMask", @"maxInstructions",
                           @"triggerConsume",
                           @"triggerExpr", @"triggerAddress",
                           @"triggerMatch", @"triggerValue",
                           @"triggerWhere", @"triggerScan" ]) {
        if (item[k] != nil) out[k] = item[k];
    }
    /* watches 深拷成可变 */
    NSMutableArray *mw = [NSMutableArray array];
    if ([item[@"watches"] isKindOfClass:[NSArray class]]) {
        for (NSDictionary *w in item[@"watches"]) {
            if ([w isKindOfClass:[NSDictionary class]]) {
                [mw addObject:[w mutableCopy]];
            }
        }
    }
    out[@"watches"] = mw;
    out[@"mutations"] = mutableMutations(item[@"mutations"]);
    NSMutableArray *mt = [NSMutableArray array];
    if ([item[@"triggers"] isKindOfClass:[NSArray class]]) {
        for (NSDictionary *tr in item[@"triggers"]) {
            if ([tr isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *copy = [tr mutableCopy];
                id address = copy[@"triggerAddress"];
                if ([address isKindOfClass:[NSNumber class]]) {
                    copy[@"triggerAddress"] = [NSString stringWithFormat:
                        @"0x%llx", [address unsignedLongLongValue]];
                }
                if (copy[@"triggerLimit"] == nil) copy[@"triggerLimit"] = @1;
                [mt addObject:copy];
            }
        }
    } else if ([item[@"triggerExpr"] isKindOfClass:[NSString class]] &&
               [item[@"triggerExpr"] length] > 0) {
        NSMutableDictionary *legacy = [NSMutableDictionary dictionary];
        for (NSString *key in @[ @"triggerExpr", @"triggerAddress",
                                 @"triggerMatch", @"triggerValue",
                                 @"triggerWhere", @"triggerScan" ]) {
            if (item[key] != nil) legacy[key] = item[key];
        }
        id address = legacy[@"triggerAddress"];
        if ([address isKindOfClass:[NSNumber class]]) {
            legacy[@"triggerAddress"] = [NSString stringWithFormat:
                @"0x%llx", [address unsignedLongLongValue]];
        }
        legacy[@"triggerLimit"] = @1;
        [mt addObject:legacy];
    }
    out[@"triggers"] = mt;
    for (NSString *key in @[ @"triggerExpr", @"triggerAddress",
                             @"triggerMatch", @"triggerValue",
                             @"triggerWhere", @"triggerScan" ]) {
        [out removeObjectForKey:key];
    }
    /* 重生 id、默认启用,避免与现有条目冲突 */
    out[@"id"] = [[NSUUID UUID] UUIDString];
    out[@"enabled"] = @YES;
    return out;
}

- (NSMutableDictionary *)importItemFromData:(NSData *)data error:(NSError **)err {
    if (data == nil) {
        if (err) *err = cfgError(@"配置格式无效(空内容)");
        return nil;
    }
    id raw = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (raw == nil) {
        if (err) *err = cfgError(@"配置格式无效(不是合法 JSON)");
        return nil;
    }
    return [self normalizeImported:raw error:err];
}

- (NSMutableDictionary *)importItemFromString:(NSString *)json error:(NSError **)err {
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    return [self importItemFromData:data error:err];
}

@end
