#import <UIKit/UIKit.h>

#import "FormEditVC.h"

@interface TriggerEditVC : FormEditVC
- (instancetype)initWithTrigger:(NSMutableDictionary *)trigger
                           start:(unsigned long long)start
                             end:(unsigned long long)end;
@property (nonatomic, copy) void (^onDone)(void);
@end
