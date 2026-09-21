#import "MoreMenu.h"

#import "AppSettings.h"
#import "SettingsVC.h"
#import <objc/runtime.h>

/* 菜单的 target。UIBarButtonItem 只弱引用 target,所以这个对象得挂在
 * host 上跟着它一起活,否则点按钮时 target 已经悬空。 */
@interface MoreMenuCtl : NSObject
@property (nonatomic, weak) UIViewController *host;
@property (nonatomic, weak) UIBarButtonItem *anchor;
@end

@implementation MoreMenuCtl

- (void)show {
    UIViewController *host = self.host;
    if (host == nil) return;

    UIAlertController *ac =
        [UIAlertController alertControllerWithTitle:nil
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"帮助"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
              [self showHelp];
          }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"设置"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
              [host.navigationController pushViewController:[SettingsVC new]
                                                   animated:YES];
          }]];

    UITabBarController *tabs = host.tabBarController;
    if (tabs != nil && tabs.viewControllers.count >= 2) {
        BOOL onTrace = tabs.selectedIndex == 0;
        [ac addAction:[UIAlertAction
            actionWithTitle:(onTrace ? @"切换到 Hook 页面" : @"切换到 Trace 页面")
                      style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *a) {
                        tabs.selectedIndex = onTrace ? 1 : 0;
                    }]];
    }

    [ac addAction:[UIAlertAction actionWithTitle:@"取消"
                                           style:UIAlertActionStyleCancel
                                         handler:nil]];
    ac.popoverPresentationController.barButtonItem = self.anchor;
    [host presentViewController:ac animated:YES completion:nil];
}

#pragma mark - 帮助

- (void)alert:(NSString *)title message:(NSString *)message {
    UIViewController *host = self.host;
    if (host == nil) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                               message:message
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"关闭"
                                           style:UIAlertActionStyleCancel
                                         handler:nil]];
    [host presentViewController:ac animated:YES completion:nil];
}

- (void)showHelp {
    UIViewController *host = self.host;
    if (host == nil) return;
    UIAlertController *ac =
        [UIAlertController alertControllerWithTitle:@"帮助"
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"触发条件注意事项"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
              [self showTriggerNotice];
          }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"触发消耗策略"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
              [self showTriggerPolicy];
          }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Trace 内寄存器修改"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
              [self showMutationHelp];
          }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"查看日志输出位置"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
              [self showLogPath];
          }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"关闭"
                                           style:UIAlertActionStyleCancel
                                         handler:nil]];
    [host presentViewController:ac animated:YES completion:nil];
}

- (void)showLogPath {
    AppSettings *s = [AppSettings shared];
    NSString *message = [NSString stringWithFormat:
        @"当前日志根目录:\n%@\n\n"
        @"Trace 日志:%@/%@/trace_<年月日时分>.log\n"
        @"Hook 日志:%@/%@/hook_<年月日时分>.log\n\n"
        @"例:trace_2611131630.log(26年11月13日16:30)。年份取两位。\n\n"
        @"每次启动目标 App 会按当时的时间生成新日志文件;同一次运行里 Trace 和 "
        @"Hook 的时间戳相同,方便对照。目录不存在时会自动创建。\n\n"
        @"日志根目录可以在「更多 → 设置」里修改,改完需重开目标 App 才生效。\n\n"
        @"用 Filza 或 SSH 打开查看。",
        s.logRoot, s.logRoot, QBDI_TRACE_LOG_SUBDIR,
        s.logRoot, QBDI_HOOK_LOG_SUBDIR];
    [self alert:@"日志输出位置" message:message];
}

- (void)showTriggerNotice {
    [self alert:@"触发条件注意事项"
        message:
        @"1. 可以添加任意数量的触发条件。没有条件时为无条件 Trace；有多条时，"
        @"满足其中任意一条即可。Trace 次数必须是 1–16。\n\n"
        @"自定义消耗策略下，每条触发条件还可以设置 1–16 次的独立触发上限，默认 1 次。\n\n"
        @"2. 第一条条件的判断地址默认使用 Trace 起始地址。继续添加时，会自动带入"
        @"第一条的判断地址和取址表达式，仍可自行修改。\n\n"
        @"3. 自定义判断地址可以低于起始地址，也可以等于或高于结束地址；"
        @"不能位于起始地址和结束地址之间。\n\n"
        @"4. 自定义判断地址命中后，只会授权同一线程下一次到达起始地址时 Trace。"
        @"因此高地址可用于程序之后跳回低地址的流程。\n\n"
        @"5. ARM64 下 Dobby Hook 补丁占 0x10 字节。不同的触发地址之间，以及触发地址"
        @"与起始地址之间，都必须至少相差 0x10。完全相同的触发地址会共享一个 Hook，"
        @"不需要留间隔。\n\n"
        @"6. 自定义判断地址也会安装 Dobby Hook。请尽量选择不会在 Trace 动态调用路径中"
        @"再次执行的控制流位置，避免 Dobby 补丁影响 QBDI 对该路径的执行。"];
}

- (void)showTriggerPolicy {
    [self alert:@"触发策略"
        message:
        @"仅一次：每一条触发条件在当前目标 App 进程中，最多促成一次成功 Trace。"
        @"只有 QBDI 确实运行到配置的结束地址后才算消耗；如果监控失败、提前停止或没有"
        @"到达结束地址，该条件不会被消耗，可以继续重试。若一次 Trace 同时由多条条件"
        @"满足，这些条件会一起被消耗。重启目标 App 后状态重置。\n\n"
        @"可重复：条件不会被消耗。每次满足任意一条条件，都可以继续触发 Trace，直到"
        @"达到设置的 Trace 次数。\n\n"
        @"自定义：在每条触发条件的编辑页面分别设置“触发次数上限”，范围是 1–16，"
        @"默认 1。某条条件达到自己的上限后只停用该条件，其他条件仍可继续触发。"
        @"一次 Trace 如果同时由多条条件授权，这些条件都会各记 1 次。"
        @"只有成功到达结束地址才会计数；失败会释放本次额度。无论各条件上限合计多少，"
        @"最终仍受 Trace 总次数限制。\n\n"
        @"自定义地址的匹配只授权同一线程下一次到达起始地址。"];
}

- (void)showMutationHelp {
    [self alert:@"Trace 内寄存器修改"
        message:
        @"该功能只覆盖 QBDI 虚拟执行上下文中的寄存器，不修改真实 App 的寄存器或内存。"
        @"Trace 结束后原始现场会恢复，但被改写分支在 Trace 内产生的文件、网络、"
        @"系统调用等外部副作用不会自动撤销。\n\n"
        @"静态地址是当前 Trace 模块的相对地址，规则会在该地址的指令执行前生效。"
        @"修改点使用 QBDI 指令回调，不会在该地址额外安装 Dobby Hook。"
        @"如果要改变 load 指令或函数调用产生的返回值，应把规则设在它的下一条指令，"
        @"否则随后执行的 load/调用会再次覆盖寄存器。该地址不要求位于起止地址的数值区间，"
        @"但只有动态执行路径确实经过它时才会生效。\n\n"
        @"“每次 Trace 仅一次”表示一轮 Trace 中首次命中生效；“每次命中”适合循环，"
        @"每次经过该地址都会覆盖。同地址多条规则按列表从上到下执行。\n\n"
        @"支持 x0–x28（不含 x17）、fp、lr。32 位模式等价于写 wN，会清零高 32 位；"
        @"fp、lr 只支持 64 位。不支持 sp、pc，也不会修改内存字节。"];
}

@end

UIBarButtonItem *MoreMenuBarButton(UIViewController *host) {
    MoreMenuCtl *ctl = [MoreMenuCtl new];
    ctl.host = host;

    UIBarButtonItem *item;
    if (@available(iOS 13.0, *)) {
        item = [[UIBarButtonItem alloc]
            initWithImage:[UIImage systemImageNamed:@"line.3.horizontal"]
                    style:UIBarButtonItemStylePlain
                   target:ctl
                   action:@selector(show)];
    } else {
        item = [[UIBarButtonItem alloc] initWithTitle:@"更多"
                                                style:UIBarButtonItemStylePlain
                                               target:ctl
                                               action:@selector(show)];
    }
    ctl.anchor = item;
    /* target 是弱引用,把 ctl 拴在 host 上才不会被立刻回收。 */
    objc_setAssociatedObject(host, "moreMenuCtl", ctl,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return item;
}
