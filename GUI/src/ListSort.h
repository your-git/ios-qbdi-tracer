#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, QBDIListSortMode) {
    QBDIListSortNameAscending = 0,
    QBDIListSortNameDescending,
    QBDIListSortNewestFirst,
    QBDIListSortOldestFirst,
};

QBDIListSortMode QBDIValidatedSortMode(id value);
QBDIListSortMode QBDIValidatedSortModeWithDefault(id value, QBDIListSortMode fallback);
NSString *QBDIListSortTitle(QBDIListSortMode mode);
NSNumber *QBDINewAddedAt(void);
/* 返回原条目对象的排序视图，不修改源数组 / 引擎的加载次序。 */
NSArray<NSMutableDictionary *> *QBDISortedEntries(NSArray<NSMutableDictionary *> *entries,
                                                NSString *nameKey, QBDIListSortMode mode);
/* 文件名按拼音 / 自然顺序比较，时间使用文件修改时间；不修改路径列表。 */
NSArray<NSString *> *QBDISortedFilePaths(NSArray<NSString *> *paths, QBDIListSortMode mode);
