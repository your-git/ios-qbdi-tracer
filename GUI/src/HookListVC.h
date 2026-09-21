#import <UIKit/UIKit.h>

/* Hook 列表页(用 Dobby 真实修改目标进程数据,区别于 QBDI Trace 的只读记录)。
 *
 * 阶段①只立骨架:页面、标签、更多菜单都到位,列表内容和「创建/导入 Hook」
 * 在阶段③补齐。先把主页结构一次改到位,免得后面再动一遍导航层。 */
@interface HookListVC : UITableViewController
@end
