#import "NavController.h"

/* 让编译器知道 UINavigationController 符合 UINavigationBarDelegate,
 * 否则 override / 调 super 时 shouldPopItem: 不可见(会报 selector 找不到)。 */
@interface UINavigationController (NavBarDelegateVisibility) <UINavigationBarDelegate>
@end

@implementation NavController

- (BOOL)navigationBar:(UINavigationBar *)bar
        shouldPopItem:(UINavigationItem *)item {
    UIViewController *top = self.topViewController;
    if ([top conformsToProtocol:@protocol(NavPopGuard)] &&
        ![(id<NavPopGuard>)top navShouldPop]) {
        /* shouldPopItem: 返回 NO 的已知副作用:返回按钮会卡在半透明状态(UIKit 已经
         * 按"要走了"把它淡出了)。手动淡回来,否则按钮看着像禁用了。 */
        for (UIView *v in bar.subviews) {
            if (v.alpha < 1.0) {
                [UIView animateWithDuration:0.25
                                 animations:^{ v.alpha = 1.0; }];
            }
        }
        return NO;
    }
    /* 必须交给 super:实际的 pop 是它做的,直接 return YES 页面不会退 */
    return [super navigationBar:bar shouldPopItem:item];
}

@end
