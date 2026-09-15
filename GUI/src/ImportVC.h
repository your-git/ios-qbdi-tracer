#import <UIKit/UIKit.h>

/* 从文件导入:列出导出目录里的 .json,点选一个导入 */
@interface ImportVC : UITableViewController
/* 导入成功回调(已加入 ConfigStore.items 并保存);调用方刷新主列表 */
@property (nonatomic, copy) void (^onImported)(void);
@end
