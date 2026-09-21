#import "HookListVC.h"

#import "MoreMenu.h"

@implementation HookListVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Hook";
    self.navigationItem.leftBarButtonItem = MoreMenuBarButton(self);
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                             target:self
                             action:@selector(plusTapped)];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView
    titleForHeaderInSection:(NSInteger)section {
    return @"Hook 条目";
}

- (NSString *)tableView:(UITableView *)tableView
    titleForFooterInSection:(NSInteger)section {
    return @"Hook 用 Dobby 在目标地址直接修改数据,是对目标 App 的真实改写,"
           @"与 Trace 的只读记录不同。\n\n该功能正在开发中,将在后续版本提供。";
}

- (void)plusTapped {
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"功能正在研发中"
                         message:@"「创建新的 Hook」和「导入 Hook」将在后续版本提供。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好"
                                           style:UIAlertActionStyleDefault
                                         handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
