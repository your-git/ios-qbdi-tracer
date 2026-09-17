#import <UIKit/UIKit.h>

#import "FormEditVC.h"

@interface WatchEditVC : FormEditVC
- (instancetype)initWithWatch:(NSMutableDictionary *)watch;
@property (nonatomic, copy) void (^onDone)(void);
@end
