#import "HookStore.h"

#import "AppSettings.h"

/* mods 深拷成可变,并补上 GUI 可编辑所需的默认值(最终合法性仍由编辑页 + 引擎校验)。 */
static NSMutableArray *mutableMods(id raw) {
    NSMutableArray *result = [NSMutableArray array];
    if (![raw isKindOfClass:[NSArray class]]) return result;
    for (NSDictionary *entry in raw) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSMutableDictionary *copy = [entry mutableCopy];
        if (copy[@"enabled"] == nil) copy[@"enabled"] = @YES;
        if (copy[@"kind"] == nil) copy[@"kind"] = @"modify";
        if (copy[@"type"] == nil) copy[@"type"] = @"number";
        if (copy[@"width"] == nil) copy[@"width"] = @64;
        if (copy[@"expr"] == nil) copy[@"expr"] = @"";
        if (copy[@"value"] == nil) copy[@"value"] = @"";
        [result addObject:copy];
    }
    return result;
}

@implementation HookStore

+ (instancetype)shared {
    static HookStore *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [HookStore new];
        [s load];
    });
    return s;
}

- (NSString *)configPath {
    return [QBDIConfigDir() stringByAppendingPathComponent:@"hooks.json"];
}

- (void)load {
    self.hooks = [NSMutableArray array];
    NSData *data = [NSData dataWithContentsOfFile:[self configPath]];
    if (data == nil) return;
    NSDictionary *cfg =
        [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![cfg isKindOfClass:[NSDictionary class]]) return;
    NSArray *hooks = cfg[@"hooks"];
    if (![hooks isKindOfClass:[NSArray class]]) return;
    for (NSDictionary *h in hooks) {
        if (![h isKindOfClass:[NSDictionary class]]) continue;
        NSMutableDictionary *m = [h mutableCopy];
        m[@"mods"] = mutableMods(h[@"mods"]);
        [self.hooks addObject:m];
    }
}

- (BOOL)save {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:QBDIConfigDir()
  withIntermediateDirectories:YES
                   attributes:nil
                        error:nil];
    NSDictionary *cfg = @{ @"hooks": self.hooks ?: @[] };
    if (![NSJSONSerialization isValidJSONObject:cfg]) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:cfg
                                                  options:NSJSONWritingPrettyPrinted
                                                    error:nil];
    if (data == nil) return NO;
    return [data writeToFile:[self configPath] atomically:YES];
}

- (NSMutableDictionary *)newHook {
    return [@{
        @"id": [[NSUUID UUID] UUIDString],
        @"addedAt": QBDINewAddedAt(),
        @"enabled": @YES,
        @"hookName": @"",
        @"bundleId": @"",
        @"appName": @"",
        @"module": @"",
        @"target": @"0x0",
        @"delaySecs": @0,
        @"maxHits": @0,        /* 0 = 每次命中都执行 */
        @"mods": [NSMutableArray array],
    } mutableCopy];
}

- (NSMutableDictionary *)newMod {
    return [@{
        @"enabled": @YES,
        @"kind": @"modify",
        @"type": @"number",
        @"width": @64,
        @"expr": @"",
        @"value": @"",
    } mutableCopy];
}

#pragma mark - 导出 / 导入

static NSError *hookError(NSString *msg) {
    return [NSError errorWithDomain:@"HookStore"
                               code:1
                           userInfo:@{ NSLocalizedDescriptionKey: msg }];
}

static NSString *sanitizeName(NSString *s) {
    if (s.length == 0) return @"App";
    NSCharacterSet *bad = [NSCharacterSet
        characterSetWithCharactersInString:@"/\\:*?\"<>| \t\n"];
    NSArray *parts = [s componentsSeparatedByCharactersInSet:bad];
    NSString *out = [parts componentsJoinedByString:@""];
    return out.length ? out : @"App";
}

- (NSString *)exportDir {
    return [[AppSettings shared] hookExportDir];
}

- (NSString *)exportHook:(NSDictionary *)hook error:(NSError **)err {
    if (![hook isKindOfClass:[NSDictionary class]]) {
        if (err) *err = hookError(@"条目无效");
        return nil;
    }
    NSDictionary *wrapper = @{ @"version": @1, @"type": @"hook", @"hook": hook };
    if (![NSJSONSerialization isValidJSONObject:wrapper]) {
        if (err) *err = hookError(@"条目无法序列化");
        return nil;
    }
    NSError *e = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:wrapper
                                                  options:NSJSONWritingPrettyPrinted
                                                    error:&e];
    if (data == nil) {
        if (err) *err = e ?: hookError(@"序列化失败");
        return nil;
    }
    NSString *appName = [hook[@"appName"] length] ? hook[@"appName"]
                                                  : hook[@"bundleId"];
    NSDateFormatter *df = [NSDateFormatter new];
    df.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    df.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    df.dateFormat = @"yyyyMMddHHmmss";
    NSString *ts = [df stringFromDate:[NSDate date]];
    NSString *fname = [NSString stringWithFormat:@"hook_%@%@.json",
                       sanitizeName(appName), ts];
    NSString *path = [[self exportDir] stringByAppendingPathComponent:fname];
    if (![data writeToFile:path atomically:YES]) {
        if (err) *err = hookError(@"写文件失败(检查权限)");
        return nil;
    }
    return path;
}

- (NSArray<NSString *> *)listImportableFiles {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *paths = [NSMutableArray array];
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

/* 从一份导出里取出 hook 字典(支持 {version,type,hook} 包装或裸 hook)。 */
static NSDictionary *unwrapHook(id raw) {
    if (![raw isKindOfClass:[NSDictionary class]]) return nil;
    if ([raw[@"hook"] isKindOfClass:[NSDictionary class]]) return raw[@"hook"];
    /* 裸 hook:靠 target + mods 认。 */
    if (raw[@"target"] != nil && [raw[@"mods"] isKindOfClass:[NSArray class]]) {
        return raw;
    }
    return nil;
}

- (NSMutableDictionary *)importHookFromData:(NSData *)data error:(NSError **)err {
    if (data == nil) {
        if (err) *err = hookError(@"配置格式无效(空内容)");
        return nil;
    }
    id raw = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSDictionary *hook = unwrapHook(raw);
    if (hook == nil) {
        if (err) *err = hookError(@"配置格式无效(不是 Hook 配置)");
        return nil;
    }
    if (![hook[@"module"] isKindOfClass:[NSString class]] ||
        [hook[@"module"] length] == 0 || hook[@"target"] == nil) {
        if (err) *err = hookError(@"配置格式无效(缺 module/target)");
        return nil;
    }
    /* 以 newHook 为模板补齐,再覆盖已有值。加字段记得加进白名单。 */
    NSMutableDictionary *out = [self newHook];
    for (NSString *k in @[ @"hookName", @"bundleId", @"appName", @"module",
                           @"target", @"delaySecs", @"maxHits" ]) {
        if (hook[k] != nil) out[k] = hook[k];
    }
    out[@"mods"] = mutableMods(hook[@"mods"]);
    out[@"id"] = [[NSUUID UUID] UUIDString];
    out[@"enabled"] = @YES;
    return out;
}

+ (NSString *)detectType:(NSData *)data {
    if (data == nil) return nil;
    id raw = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![raw isKindOfClass:[NSDictionary class]]) return nil;
    /* 显式 type 最可靠;其次看包装 key;最后看裸对象的特征字段。 */
    id type = raw[@"type"];
    if ([type isKindOfClass:[NSString class]]) {
        if ([type isEqualToString:@"hook"]) return @"hook";
        if ([type isEqualToString:@"trace"]) return @"trace";
    }
    if ([raw[@"hook"] isKindOfClass:[NSDictionary class]]) return @"hook";
    if ([raw[@"item"] isKindOfClass:[NSDictionary class]]) return @"trace";
    /* 裸对象:hook 有 target+mods;trace 有 start+end。 */
    if (raw[@"target"] != nil && [raw[@"mods"] isKindOfClass:[NSArray class]]) {
        return @"hook";
    }
    if (raw[@"start"] != nil && raw[@"end"] != nil) return @"trace";
    return nil;
}

@end
