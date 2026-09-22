#import <UIKit/UIKit.h>

#import "MoreMenu.h"

/* Hook 列表页(用 Dobby 真实修改目标进程数据,区别于 QBDI Trace 的只读记录)。 */
@interface HookListVC : UITableViewController <QBDIListPage>
@end
