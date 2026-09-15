#import <UIKit/UIKit.h>

@interface AppPickerVC : UITableViewController
/* 选中回调:bundleId + 展示名 */
@property (nonatomic, copy) void (^onPick)(NSString *bundleId, NSString *appName);
@end
