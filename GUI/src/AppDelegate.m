#import "AppDelegate.h"
#import "NavController.h"
#import "RootListVC.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    RootListVC *root = [[RootListVC alloc] initWithStyle:UITableViewStyleInsetGrouped];
    /* NavController 而非 UINavigationController:编辑页要能拦住系统返回按钮 */
    NavController *nav =
        [[NavController alloc] initWithRootViewController:root];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}

@end
