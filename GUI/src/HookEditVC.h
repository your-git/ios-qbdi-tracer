#import <UIKit/UIKit.h>

#import "FormEditVC.h"

/* Hook 表单。hook 是 HookStore 里的可变字典;isNew=YES 时「完成」才加入列表。 */
@interface HookEditVC : FormEditVC
- (instancetype)initWithHook:(NSMutableDictionary *)hook isNew:(BOOL)isNew;
@end
