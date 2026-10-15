#import <Foundation/Foundation.h>
#import "ListSort.h"
#import "ConfigStore.h"
#import "HookStore.h"
#import "AppSettings.h"
#import "GUIFeatures.h"
#include <assert.h>

static NSArray *ids(NSArray *entries) { return [entries valueForKey:@"id"]; }
static NSMutableDictionary *entry(NSString *ident, NSString *name, NSString *app, NSNumber *time) {
    NSMutableDictionary *row = [@{ @"id": ident, @"traceName": name, @"hookName": name,
                                   @"appName": app } mutableCopy];
    if (time) row[@"addedAt"] = time;
    return row;
}

int main(void) { @autoreleasepool {
    NSArray *rows = @[ entry(@"zhang", @"张三", @"Ignored", @30),
                       entry(@"li", @"李四", @"Ignored", @10),
                       entry(@"apple", @"  ", @"Apple", @20),
                       entry(@"banana", @"banana", @"Ignored", @40) ];
    NSArray *original = ids(rows);
    for (NSString *nameKey in @[ @"traceName", @"hookName" ]) {
        assert(([ids(QBDISortedEntries(rows, nameKey, QBDIListSortNameAscending))
            isEqual:@[ @"apple", @"banana", @"li", @"zhang" ]]));
        assert(([ids(QBDISortedEntries(rows, nameKey, QBDIListSortNameDescending))
            isEqual:@[ @"zhang", @"li", @"banana", @"apple" ]]));
        assert(([ids(QBDISortedEntries(rows, nameKey, QBDIListSortNewestFirst))
            isEqual:@[ @"banana", @"zhang", @"apple", @"li" ]]));
        assert(([ids(QBDISortedEntries(rows, nameKey, QBDIListSortOldestFirst))
            isEqual:@[ @"li", @"apple", @"zhang", @"banana" ]]));
    }
    assert(([ids(rows) isEqual:original])); // sorting never changes engine load order
    NSArray *sorted = QBDISortedEntries(rows, @"traceName", QBDIListSortNameAscending);
    assert((sorted[0] == rows[2])); // row actions must keep the original dictionary identity
    rows[2][@"traceName"] = @"Zulu";
    assert(([ids(QBDISortedEntries(rows, @"traceName", QBDIListSortNameAscending)).lastObject isEqual:@"apple"]));
    assert(([rows[2][@"addedAt"] isEqual:@20])); // rename / edits do not reset addition time

    NSArray *legacy = @[ entry(@"old1", @"Same", @"", nil), entry(@"old2", @"same", @"", nil),
                         entry(@"new", @"same", @"", @100) ];
    assert(([ids(QBDISortedEntries(legacy, @"traceName", QBDIListSortNewestFirst))
        isEqual:@[ @"new", @"old2", @"old1" ]]));
    assert(([ids(QBDISortedEntries(legacy, @"traceName", QBDIListSortOldestFirst))
        isEqual:@[ @"old1", @"old2", @"new" ]]));
    assert(([ids(QBDISortedEntries(legacy, @"traceName", QBDIListSortNameDescending))
        isEqual:@[ @"old1", @"old2", @"new" ]]));
    assert((QBDISortedEntries(@[], @"traceName", QBDIListSortNewestFirst).count == 0));
    assert((QBDIValidatedSortMode(nil) == QBDIListSortOldestFirst));
    assert((QBDIValidatedSortMode(@"name") == QBDIListSortOldestFirst));
    assert((QBDIValidatedSortMode(@(-1)) == QBDIListSortOldestFirst));
    assert((QBDIValidatedSortMode(@1.5) == QBDIListSortOldestFirst));
    NSArray *natural = @[ entry(@"ten", @"条目10", @"", @1), entry(@"two", @"条目2", @"", @2) ];
    assert(([ids(QBDISortedEntries(natural, @"traceName", QBDIListSortNameAscending))
        isEqual:@[ @"two", @"ten" ]]));

    NSString *fileDir = [QBDIConfigDir() stringByAppendingPathComponent:@"file-sort-test"];
    NSFileManager *fm = [NSFileManager defaultManager];
    assert(([fm createDirectoryAtPath:fileDir withIntermediateDirectories:YES attributes:nil error:nil]));
    NSArray *names = @[ @"张三.json", @"Apple.json", @"李四.json" ];
    NSArray *times = @[ @30, @10, @20 ];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSUInteger i = 0; i < names.count; i++) {
        NSString *path = [fileDir stringByAppendingPathComponent:names[i]];
        assert(([@"{}" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]));
        assert(([fm setAttributes:@{ NSFileModificationDate: [NSDate dateWithTimeIntervalSince1970:[times[i] doubleValue]] }
            ofItemAtPath:path error:nil]));
        [paths addObject:path];
    }
    assert(([QBDISortedFilePaths(paths, QBDIListSortNameAscending)
        isEqual:@[ paths[1], paths[2], paths[0] ]]));
    assert(([QBDISortedFilePaths(paths, QBDIListSortNameDescending)
        isEqual:@[ paths[0], paths[2], paths[1] ]]));
    assert(([QBDISortedFilePaths(paths, QBDIListSortNewestFirst)
        isEqual:@[ paths[0], paths[2], paths[1] ]]));
    assert(([QBDISortedFilePaths(paths, QBDIListSortOldestFirst)
        isEqual:@[ paths[1], paths[2], paths[0] ]]));
    assert(([paths[0].lastPathComponent isEqual:@"张三.json"]));
    NSString *missing = [fileDir stringByAppendingPathComponent:@"missing.json"];
    assert(([QBDISortedFilePaths(@[ missing, paths[0] ], QBDIListSortNewestFirst).lastObject isEqual:missing]));
    assert((QBDISortedFilePaths(@[], QBDIListSortNewestFirst).count == 0));
    assert((QBDIValidatedSortModeWithDefault(@"invalid", QBDIListSortNewestFirst) == QBDIListSortNewestFirst));

    AppSettings *settings = [AppSettings shared];
    assert((settings.traceSortMode == QBDIListSortOldestFirst));
    assert((settings.hookSortMode == QBDIListSortOldestFirst));
    assert((settings.traceImportSortMode == QBDIListSortNewestFirst));
    assert((settings.hookImportSortMode == QBDIListSortNewestFirst));
    settings.exportRoot = [QBDIConfigDir() stringByAppendingPathComponent:@"exports"];
    settings.traceSortMode = QBDIListSortNameDescending;
    settings.hookSortMode = QBDIListSortNewestFirst;
    settings.traceImportSortMode = QBDIListSortNameAscending;
    settings.hookImportSortMode = QBDIListSortOldestFirst;
    settings.enabled = NO;
    assert(([settings save]));
    AppSettings *reloaded = [AppSettings new];
    [reloaded load];
    assert((reloaded.traceSortMode == QBDIListSortNameDescending));
    assert((reloaded.hookSortMode == QBDIListSortNewestFirst));
    assert((reloaded.traceImportSortMode == QBDIListSortNameAscending));
    assert((reloaded.hookImportSortMode == QBDIListSortOldestFirst));
    assert((!reloaded.enabled));

    ConfigStore *traces = [ConfigStore shared];
    NSMutableDictionary *trace = [traces newItem];
    trace[@"addedAt"] = @123;
    trace[@"bundleId"] = @"com.example.test";
    trace[@"module"] = @"Test";
    trace[@"end"] = @"0x20";
    trace[@"mutations"] = [@[ [@{ @"enabled": @YES, @"offset": @"0x4", @"reg": @"x8",
                                     @"width": @64, @"value": @"0x2", @"apply": @"once" } mutableCopy] ] mutableCopy];
    [traces.items addObject:trace];
    assert(([traces save]));
    [traces load];
    assert(([traces.items[0][@"addedAt"] isEqual:@123]));
    assert(([traces.items[0][@"mutations"] count] == 1)); // hiding UI must not drop stored rules
    NSError *error = nil;
    NSData *traceJSON = [NSJSONSerialization dataWithJSONObject:@{ @"version": @1, @"item": trace }
        options:0 error:&error];
    NSMutableDictionary *importedTrace = [traces importItemFromData:traceJSON error:&error];
    assert((importedTrace && !error));
    assert(([importedTrace[@"addedAt"] doubleValue] > 123));
    assert((![importedTrace[@"id"] isEqual:trace[@"id"]]));
    assert(([importedTrace[@"mutations"] count] == 1));

    HookStore *hooks = [HookStore shared];
    NSMutableDictionary *hook = [hooks newHook];
    hook[@"addedAt"] = @456;
    hook[@"bundleId"] = @"com.example.test";
    hook[@"module"] = @"Test";
    hook[@"mods"] = [@[ [hooks newMod] ] mutableCopy];
    [hooks.hooks addObject:hook];
    assert(([hooks save]));
    [hooks load];
    assert(([hooks.hooks[0][@"addedAt"] isEqual:@456]));
    NSData *hookJSON = [NSJSONSerialization dataWithJSONObject:@{ @"version": @1, @"type": @"hook", @"hook": hook }
        options:0 error:&error];
    NSMutableDictionary *importedHook = [hooks importHookFromData:hookJSON error:&error];
    assert((importedHook && !error));
    assert(([importedHook[@"addedAt"] doubleValue] > 456));
    assert((![importedHook[@"id"] isEqual:hook[@"id"]]));
    assert(([importedHook[@"mods"] count] == 1));
    trace[@"appName"] = @"TikTok";
    hook[@"appName"] = @"TikTok";
    NSString *tracePath = [traces exportItem:trace error:&error];
    NSString *hookPath = [hooks exportHook:hook error:&error];
    assert((tracePath && hookPath && !error));
    for (NSString *path in @[ tracePath, hookPath ]) {
        NSString *prefix = [path isEqual:tracePath] ? @"trace" : @"hook";
        NSString *pattern = [NSString stringWithFormat:@"^%@_TikTok[0-9]{14}\\.json$", prefix];
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
        NSString *name = path.lastPathComponent;
        assert(([regex numberOfMatchesInString:name options:0 range:NSMakeRange(0, name.length)] == 1));
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0 error:nil];
        BOOL isTrace = [prefix isEqual:@"trace"];
        assert(([json[isTrace ? @"item" : @"hook"][@"id"] isEqual:(isTrace ? trace[@"id"] : hook[@"id"])]));
    }
    assert((!QBDI_SHOW_TRACE_MUTATIONS));
    NSLog(@"PASS: pinyin / four orders / file names and dates / stable identity / legacy entries / settings persistence / import times / retained mutations / export seconds");
} return 0; }
