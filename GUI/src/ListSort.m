#import "ListSort.h"
#import <CoreFoundation/CoreFoundation.h>
#include <math.h>

QBDIListSortMode QBDIValidatedSortMode(id value) {
    return QBDIValidatedSortModeWithDefault(value, QBDIListSortOldestFirst);
}

QBDIListSortMode QBDIValidatedSortModeWithDefault(id value, QBDIListSortMode fallback) {
    if (![value isKindOfClass:[NSNumber class]]) return fallback;
    double n = [value doubleValue];
    if (!isfinite(n) || n != floor(n) || n < QBDIListSortNameAscending || n > QBDIListSortOldestFirst)
        return fallback;
    return (QBDIListSortMode)n;
}

NSString *QBDIListSortTitle(QBDIListSortMode mode) {
    return @[ @"名称：A–Z", @"名称：Z–A", @"加入时间：新到旧", @"加入时间：旧到新" ]
        [QBDIValidatedSortMode(@(mode))];
}

NSNumber *QBDINewAddedAt(void) { return @([[NSDate date] timeIntervalSince1970]); }

static NSString *trimName(id value) {
    return [value isKindOfClass:[NSString class]]
        ? [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
}

static NSString *sortKey(NSDictionary *entry, NSString *nameKey) {
    NSString *name = trimName(entry[nameKey]);
    if (!name.length) name = trimName(entry[@"appName"]);
    if (!name.length) name = trimName(entry[@"bundleId"]);
    NSMutableString *key = [name mutableCopy];
    CFStringTransform((__bridge CFMutableStringRef)key, NULL, kCFStringTransformMandarinLatin, false);
    CFStringTransform((__bridge CFMutableStringRef)key, NULL, kCFStringTransformStripCombiningMarks, false);
    NSString *collapsed = [[key componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
        componentsJoinedByString:@""];
    return collapsed.lowercaseString;
}

static double addedAt(NSDictionary *entry) {
    id raw = entry[@"addedAt"];
    if (![raw isKindOfClass:[NSNumber class]]) return 0;
    double n = [raw doubleValue];
    return isfinite(n) && n > 0 ? n : 0;
}

NSArray<NSMutableDictionary *> *QBDISortedEntries(NSArray<NSMutableDictionary *> *entries,
                                                NSString *nameKey, QBDIListSortMode mode) {
    mode = QBDIValidatedSortMode(@(mode));
    BOOL byName = mode == QBDIListSortNameAscending || mode == QBDIListSortNameDescending;
    BOOL descending = mode == QBDIListSortNameDescending || mode == QBDIListSortNewestFirst;
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:entries.count];
    [entries enumerateObjectsUsingBlock:^(NSMutableDictionary *entry, NSUInteger index, BOOL *stop) {
        (void)stop;
        [rows addObject:@{ @"entry": entry, @"index": @(index),
                          @"key": byName ? sortKey(entry, nameKey) : @"" }];
    }];
    NSLocale *locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult result = NSOrderedSame;
        if (byName) {
            NSString *left = a[@"key"], *right = b[@"key"];
            result = [left compare:right options:NSCaseInsensitiveSearch | NSNumericSearch
                range:NSMakeRange(0, left.length) locale:locale];
        } else {
            double left = addedAt(a[@"entry"]), right = addedAt(b[@"entry"]);
            result = left < right ? NSOrderedAscending : left > right ? NSOrderedDescending : NSOrderedSame;
        }
        if (result != NSOrderedSame) return descending ? -result : result;
        /* 旧条目无法还原真实时间，以原数组位置作先后依据。名称相同则保持原次序。 */
        result = [a[@"index"] compare:b[@"index"]];
        return !byName && descending ? -result : result;
    }];
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:rows.count];
    for (NSDictionary *row in rows) [result addObject:row[@"entry"]];
    return result;
}

NSArray<NSString *> *QBDISortedFilePaths(NSArray<NSString *> *paths, QBDIListSortMode mode) {
    NSMutableArray *entries = [NSMutableArray arrayWithCapacity:paths.count];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in paths) {
        NSDate *date = [fm attributesOfItemAtPath:path error:nil].fileModificationDate;
        [entries addObject:[@{ @"path": path, @"fileName": path.lastPathComponent,
                               @"addedAt": @(date ? date.timeIntervalSince1970 : 0) } mutableCopy]];
    }
    NSArray *sorted = QBDISortedEntries(entries, @"fileName", mode);
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:sorted.count];
    for (NSDictionary *entry in sorted) [result addObject:entry[@"path"]];
    return result;
}
