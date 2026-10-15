#import <UIKit/UIKit.h>

/* Trace / Hook 只维护排序后的显示快照，所有行操作仍使用原条目的对象身份。 */
@interface SortedListVC : UITableViewController
@property (nonatomic, copy) NSArray<NSMutableDictionary *> *displayedEntries;
- (NSArray<NSMutableDictionary *> *)sourceEntries;
- (BOOL)isHookList;
- (void)installSortButton;
- (void)reloadEntries;
@end
