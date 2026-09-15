#import <UIKit/UIKit.h>

@interface WatchEditVC : UITableViewController
- (instancetype)initWithWatch:(NSMutableDictionary *)watch;
@property (nonatomic, copy) void (^onDone)(void);
@end
