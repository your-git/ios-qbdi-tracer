#import <UIKit/UIKit.h>

/* 想拦截「返回」的页面实现这个协议。
 * 返回 NO = 这次先别走(实现者自己负责弹确认框;用户确认后自己调 popViewController)。 */
@protocol NavPopGuard <NSObject>
- (BOOL)navShouldPop;
@end

/* 能拦住系统返回按钮的导航控制器。
 *
 * 为什么要子类:UIKit 没有公开的"即将 pop,能否拦下"回调。系统返回按钮
 * (左上角 `< 上一页`)点下去时,是 UINavigationBar 向自己的 delegate 发
 * `navigationBar:shouldPopItem:` —— 而 UINavigationController 私下就是那个
 * delegate。所以在子类里 override 这个方法,就能在 pop 真正发生前问一句
 * 顶层页面同不同意。这依赖 UINavigationController 实现了 UINavigationBarDelegate
 * 这个未文档化的事实(长期稳定,越狱 App 用没问题)。
 *
 * 注意:右滑返回手势**不走**这个回调(它由 interactivePopGestureRecognizer 驱动),
 * 需要页面自己在有未保存改动时把那个手势关掉。
 * 代码主动调 popViewControllerAnimated: 也不走这里,所以确认放弃后直接 pop 即可。 */
@interface NavController : UINavigationController
@end
