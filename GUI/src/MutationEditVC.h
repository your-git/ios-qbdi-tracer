#import "FormEditVC.h"

@interface MutationEditVC : FormEditVC
- (instancetype)initWithMutation:(NSMutableDictionary *)mutation;
@property(nonatomic, copy) void (^onDone)(void);
@end
