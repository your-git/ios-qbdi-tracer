#import <UIKit/UIKit.h>

#import "FormEditVC.h"

/* "修改数据"功能的编辑页。编辑的是 hook 的 mods 数组里的一条可变字典。
 * mod: { enabled, kind:"modify", type:"bytes|string|number", width, expr, value } */
@interface HookModEditVC : FormEditVC
- (instancetype)initWithMod:(NSMutableDictionary *)mod;
@property (nonatomic, copy) void (^onDone)(void);
@end
