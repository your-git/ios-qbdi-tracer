#import "AppDelegate.h"
#import "AppSettings.h"
#import "HookListVC.h"
#import "NavController.h"
#import "RootListVC.h"

@implementation AppDelegate

/* 每个标签页各自一个 NavController —— 不能两个标签共用一个导航栈,
 * 否则在 Trace 页深入编辑后切到 Hook 页,会把编辑页一起带过去。 */
static NavController *wrap(UIViewController *root, NSString *title,
                           NSString *symbol, NSInteger tag) {
    NavController *nav = [[NavController alloc] initWithRootViewController:root];
    UIImage *icon = nil;
    if (@available(iOS 13.0, *)) {
        icon = [UIImage systemImageNamed:symbol];
    }
    nav.tabBarItem = [[UITabBarItem alloc] initWithTitle:title image:icon tag:tag];
    return nav;
}

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    /* 先触发一次 settings.json 的加载与迁移:老用户升级后,总开关要在
     * 界面显示之前就从旧 config.json 搬过来,否则主页那一行会先闪成"开启"。 */
    (void)[AppSettings shared];

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    RootListVC *trace = [[RootListVC alloc] initWithStyle:UITableViewStyleInsetGrouped];
    HookListVC *hook = [[HookListVC alloc] initWithStyle:UITableViewStyleInsetGrouped];

    UITabBarController *tabs = [UITabBarController new];
    /* NavController 而非 UINavigationController:编辑页要能拦住系统返回按钮 */
    tabs.viewControllers = @[
        wrap(trace, @"Trace", @"scope", 0),
        wrap(hook, @"Hook", @"pencil.and.outline", 1),
    ];
    self.window.rootViewController = tabs;
    [self.window makeKeyAndVisible];
    return YES;
}

@end
