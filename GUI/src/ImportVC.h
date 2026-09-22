#import <UIKit/UIKit.h>

/* 从文件导入:底部分页 Trace|Hook,列出各自导出目录(+旧版 Documents 根)里的 .json,
 * 点选一个导入。若选中的文件其实是另一类配置,会自动导到正确的一类并提示。 */
@interface ImportVC : UITableViewController
/* 默认进哪一页:NO=Trace(默认),YES=Hook。 */
@property (nonatomic, assign) BOOL initialHookPage;
/* 导入成功回调;调用方刷新自己的列表。 */
@property (nonatomic, copy) void (^onImported)(void);
@end
