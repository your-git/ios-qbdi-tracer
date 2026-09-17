#import <UIKit/UIKit.h>

#import "FormEditVC.h"

@interface TraceEditVC : FormEditVC
/* item 是 ConfigStore 里的可变字典;isNew=YES 时"完成"才加入列表 */
- (instancetype)initWithItem:(NSMutableDictionary *)item isNew:(BOOL)isNew;
@end
