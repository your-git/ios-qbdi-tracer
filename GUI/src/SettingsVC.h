#import <UIKit/UIKit.h>

#import "FormEditVC.h"

/* 设置页:日志根目录 / 导入导出根目录。
 * 继承 FormEditVC 以复用"禁右滑返回 + 未保存就返回要确认"的统一行为。 */
@interface SettingsVC : FormEditVC
@end
