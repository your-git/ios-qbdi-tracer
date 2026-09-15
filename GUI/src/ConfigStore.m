#import "ConfigStore.h"

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
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:@"/var/jb" isDirectory:&isDir] && isDir) {
        return @"/var/jb/var/mobile/Documents/QBDITracer";
    }
    return @"/var/mobile/Documents/QBDITracer";
}

- (NSString *)configPath {
    return [[self configDir] stringByAppendingPathComponent:@"config.json"];
}

- (void)load {
    self.enabled = YES;
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
    id en = cfg[@"enabled"];
    self.enabled = [en isKindOfClass:[NSNumber class]] ? [en boolValue] : YES;

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

    NSDictionary *cfg = @{ @"enabled": @(self.enabled),
                           @"items": self.items ?: @[] };
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
        @"enabled": @YES,
        @"bundleId": @"",
        @"appName": @"",
        @"module": @"",
        @"start": @"0x0",
        @"end": @"0x0",
        @"count": @1,
        @"moduleOnly": @YES,
        @"delaySecs": @0,
        @"logMask": @1,          /* LOG_INST */
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
    /* App 沙盒 Documents;系统级 app 上 NSHomeDirectory 可能非标准沙盒,
     * 探测失败则回退到 Finder/文件 App 可见的固定位置。 */
    NSString *dir = nil;
    NSArray *paths = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES);
    if (paths.count > 0) {
        dir = paths.firstObject;
    }
    if (dir.length == 0) {
        NSString *home = NSHomeDirectory();
        if (home.length) {
            dir = [home stringByAppendingPathComponent:@"Documents"];
        }
    }
    if (dir.length == 0) {
        dir = @"/var/mobile/Documents"; /* 最后兜底 */
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return dir;
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
    df.dateFormat = @"yyyyMMddHHmm";
    NSString *ts = [df stringFromDate:[NSDate date]];
    NSString *fname = [NSString stringWithFormat:@"%@%@.json",
                       sanitizeName(appName), ts];
    NSString *path = [[self exportDir] stringByAppendingPathComponent:fname];

    if (![data writeToFile:path atomically:YES]) {
        if (err) *err = cfgError(@"写文件失败(检查权限)");
        return nil;
    }
    return path;
}

- (NSArray<NSString *> *)listImportableFiles {
    NSString *dir = [self exportDir];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *names = [fm contentsOfDirectoryAtPath:dir error:nil];
    NSMutableArray *paths = [NSMutableArray array];
    for (NSString *n in names) {
        if ([n.pathExtension.lowercaseString isEqualToString:@"json"]) {
            [paths addObject:[dir stringByAppendingPathComponent:n]];
        }
    }
    [paths sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSDate *da = [fm attributesOfItemAtPath:a error:nil].fileModificationDate;
        NSDate *db = [fm attributesOfItemAtPath:b error:nil].fileModificationDate;
        return [db compare:da]; /* 倒序:新的在前 */
    }];
    return paths;
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
    for (NSString *k in @[ @"enabled", @"bundleId", @"appName", @"module",
                           @"start", @"end", @"count", @"moduleOnly",
                           @"delaySecs", @"logMask" ]) {
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
