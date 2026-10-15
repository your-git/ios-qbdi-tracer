#import "AppSettings.h"

NSString *QBDIConfigDir(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:@"/var/jb" isDirectory:&isDir] && isDir) {
        return @"/var/jb/var/mobile/Documents/QBDITracer";
    }
    return @"/var/mobile/Documents/QBDITracer";
}

NSString *QBDIDocumentsDir(void) {
    /* 系统级 app 上 NSHomeDirectory 可能不是标准沙盒,逐级回退,最后兜死路径。 */
    NSArray *paths = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject;
    if (dir.length == 0) {
        NSString *home = NSHomeDirectory();
        if (home.length) {
            dir = [home stringByAppendingPathComponent:@"Documents"];
        }
    }
    return dir.length ? dir : @"/var/mobile/Documents";
}

NSString *QBDIDefaultLogRoot(void) {
    return @"/tmp/ios-qbdi-tracer";
}

NSString *QBDIDefaultExportRoot(void) {
    return [QBDIDocumentsDir()
        stringByAppendingPathComponent:@"ios-qbdi-tracer-config-json"];
}

/* 去掉首尾空白;空串一律当成"没填",由调用方回落默认值。 */
static NSString *trimmed(id value) {
    if (![value isKindOfClass:[NSString class]]) return @"";
    return [value stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

@implementation AppSettings

+ (instancetype)shared {
    static AppSettings *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [AppSettings new];
        [s load];
    });
    return s;
}

- (NSString *)settingsPath {
    return [QBDIConfigDir() stringByAppendingPathComponent:@"settings.json"];
}

/* 旧版总开关的所在地。只在 settings.json 还不存在时读一次。 */
- (NSString *)legacyConfigPath {
    return [QBDIConfigDir() stringByAppendingPathComponent:@"config.json"];
}

- (void)load {
    self.enabled = YES;
    self.logRoot = QBDIDefaultLogRoot();
    self.exportRoot = QBDIDefaultExportRoot();
    self.traceSortMode = QBDIListSortOldestFirst;
    self.hookSortMode = QBDIListSortOldestFirst;
    self.traceImportSortMode = QBDIListSortNewestFirst;
    self.hookImportSortMode = QBDIListSortNewestFirst;

    NSData *data = [NSData dataWithContentsOfFile:[self settingsPath]];
    if (data != nil) {
        NSDictionary *cfg =
            [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([cfg isKindOfClass:[NSDictionary class]]) {
            id en = cfg[@"enabled"];
            if ([en isKindOfClass:[NSNumber class]]) self.enabled = [en boolValue];
            NSString *log = trimmed(cfg[@"logRoot"]);
            if (log.length) self.logRoot = log;
            NSString *exp = trimmed(cfg[@"exportRoot"]);
            if (exp.length) self.exportRoot = exp;
            self.traceSortMode = QBDIValidatedSortMode(cfg[@"traceSortMode"]);
            self.hookSortMode = QBDIValidatedSortMode(cfg[@"hookSortMode"]);
            self.traceImportSortMode = QBDIValidatedSortModeWithDefault(cfg[@"traceImportSortMode"], QBDIListSortNewestFirst);
            self.hookImportSortMode = QBDIValidatedSortModeWithDefault(cfg[@"hookImportSortMode"], QBDIListSortNewestFirst);
        }
        return;
    }

    /* settings.json 不存在 = 刚从旧版升级(或全新安装)。把旧 config.json 里的
     * 总开关搬过来再落盘,否则用户原本关掉的插件会变成开启。全新安装时旧文件
     * 也不存在,默认值 YES 正是期望行为。 */
    NSData *legacy = [NSData dataWithContentsOfFile:[self legacyConfigPath]];
    if (legacy != nil) {
        NSDictionary *cfg =
            [NSJSONSerialization JSONObjectWithData:legacy options:0 error:nil];
        if ([cfg isKindOfClass:[NSDictionary class]] &&
            [cfg[@"enabled"] isKindOfClass:[NSNumber class]]) {
            self.enabled = [cfg[@"enabled"] boolValue];
        }
    }
    [self save];
}

- (BOOL)save {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:QBDIConfigDir()
  withIntermediateDirectories:YES
                   attributes:nil
                        error:nil];

    NSDictionary *cfg = @{
        @"enabled": @(self.enabled),
        @"logRoot": self.logRoot ?: QBDIDefaultLogRoot(),
        @"exportRoot": self.exportRoot ?: QBDIDefaultExportRoot(),
        @"traceSortMode": @(self.traceSortMode),
        @"hookSortMode": @(self.hookSortMode),
        @"traceImportSortMode": @(self.traceImportSortMode),
        @"hookImportSortMode": @(self.hookImportSortMode),
    };
    if (![NSJSONSerialization isValidJSONObject:cfg]) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:cfg
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    if (data == nil) return NO;
    return [data writeToFile:[self settingsPath] atomically:YES];
}

/* 子目录按需创建。创建失败不在这里报错 —— 调用方写文件时自然会失败并提示,
 * 比在取路径时弹框更贴近用户的实际操作。 */
- (NSString *)ensureDir:(NSString *)parent sub:(NSString *)sub {
    NSString *dir = [parent stringByAppendingPathComponent:sub];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return dir;
}

- (NSString *)traceLogDir {
    return [self ensureDir:self.logRoot sub:QBDI_TRACE_LOG_SUBDIR];
}
- (NSString *)hookLogDir {
    return [self ensureDir:self.logRoot sub:QBDI_HOOK_LOG_SUBDIR];
}
- (NSString *)traceExportDir {
    return [self ensureDir:self.exportRoot sub:QBDI_TRACE_EXPORT_SUBDIR];
}
- (NSString *)hookExportDir {
    return [self ensureDir:self.exportRoot sub:QBDI_HOOK_EXPORT_SUBDIR];
}

+ (BOOL)directoryUsable:(NSString *)path {
    if (path.length == 0 || ![path hasPrefix:@"/"]) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm createDirectoryAtPath:path
       withIntermediateDirectories:YES
                        attributes:nil
                             error:nil]) {
        return NO;
    }
    /* 目录建出来了不等于能写(只读挂载、权限不足都可能)。真写一个探针文件,
     * 这是唯一靠得住的判断。 */
    NSString *probe = [path stringByAppendingPathComponent:@".qbdi_write_test"];
    if (![[NSData data] writeToFile:probe atomically:YES]) return NO;
    [fm removeItemAtPath:probe error:nil];
    return YES;
}

@end
