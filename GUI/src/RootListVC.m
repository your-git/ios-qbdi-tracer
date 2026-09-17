#import "RootListVC.h"
#import "ConfigStore.h"
#import "AppPickerVC.h"
#import "TraceEditVC.h"
#import "ImportVC.h"

@implementation RootListVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"QBDI Tracer";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                             target:self
                             action:@selector(plusTapped)];
    /* 左上角帮助图标 */
    UIBarButtonItem *help;
    if (@available(iOS 13.0, *)) {
        help = [[UIBarButtonItem alloc]
            initWithImage:[UIImage systemImageNamed:@"questionmark.circle"]
                    style:UIBarButtonItemStylePlain
                   target:self
                   action:@selector(showHelp)];
    } else {
        help = [[UIBarButtonItem alloc] initWithTitle:@"帮助"
                                                style:UIBarButtonItemStylePlain
                                               target:self
                                               action:@selector(showHelp)];
    }
    self.navigationItem.leftBarButtonItem = help;
}

#pragma mark - 帮助

- (void)showHelp {
    UIAlertController *ac =
        [UIAlertController alertControllerWithTitle:@"帮助"
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"查看 Trace 日志输出位置"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
              [self showLogPath];
          }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"关闭"
                                           style:UIAlertActionStyleCancel
                                         handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)showLogPath {
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"Trace 日志输出位置"
                         message:@"/tmp/qbdi_trace_<年月日时分>.log\n\n"
                                  @"例:/tmp/qbdi_trace_202608191630.log\n\n"
                                  @"每次启动目标 App 会按当前时间生成一个新日志文件。"
                                  @"用 Filza 或 SSH 打开查看。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"关闭"
                                           style:UIAlertActionStyleCancel
                                         handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (ConfigStore *)store { return [ConfigStore shared]; }

#pragma mark - + 菜单:创建 / 导入

- (void)plusTapped {
    UIAlertController *ac =
        [UIAlertController alertControllerWithTitle:nil
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"创建新的 Tracer"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
              [self addTrace];
          }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"导入 Tracer"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
              [self importTracer];
          }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消"
                                           style:UIAlertActionStyleCancel
                                         handler:nil]];
    ac.popoverPresentationController.barButtonItem =
        self.navigationItem.rightBarButtonItem;
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)addTrace {
    /* 先选 app,选完进 trace 编辑表单 */
    AppPickerVC *picker = [AppPickerVC new];
    __weak typeof(self) weakSelf = self;
    picker.onPick = ^(NSString *bundleId, NSString *appName) {
        NSMutableDictionary *item = [[weakSelf store] newItem];
        item[@"bundleId"] = bundleId ?: @"";
        item[@"appName"] = appName ?: @"";
        TraceEditVC *edit = [[TraceEditVC alloc] initWithItem:item isNew:YES];
        [weakSelf.navigationController pushViewController:edit animated:YES];
    };
    [self.navigationController pushViewController:picker animated:YES];
}

#pragma mark - 导入

- (void)importTracer {
    UIAlertController *ac =
        [UIAlertController alertControllerWithTitle:@"导入 Tracer"
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"从文件导入"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
              [self importFromFile];
          }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"粘贴 JSON"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
              [self importFromPaste];
          }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消"
                                           style:UIAlertActionStyleCancel
                                         handler:nil]];
    ac.popoverPresentationController.barButtonItem =
        self.navigationItem.rightBarButtonItem;
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)importFromFile {
    ImportVC *vc = [ImportVC new];
    __weak typeof(self) weakSelf = self;
    vc.onImported = ^{ [weakSelf.tableView reloadData]; };
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)importFromPaste {
    UIAlertController *ac =
        [UIAlertController alertControllerWithTitle:@"粘贴 JSON"
                                            message:@"把导出的配置 JSON 粘贴进来"
                                     preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"{ \"version\":1, \"item\":{...} }";
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"导入"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
              NSString *text = ac.textFields.firstObject.text;
              NSError *err = nil;
              NSMutableDictionary *item =
                  [[self store] importItemFromString:text error:&err];
              if (item == nil) {
                  [self toast:err.localizedDescription ?: @"配置格式无效"];
                  return;
              }
              [[self store].items addObject:item];
              if ([[self store] save]) {
                  [self.tableView reloadData];
                  [self toast:@"导入成功"];
              } else {
                  [self toast:@"保存失败(检查权限)"];
              }
          }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消"
                                           style:UIAlertActionStyleCancel
                                         handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2; /* 0: 总开关  1: trace 列表 */
}

- (NSString *)tableView:(UITableView *)tableView
    titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"插件" : @"Trace 条目(点击编辑,左滑复制/删除)";
}

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    return (NSInteger)[self store].items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        UITableViewCell *cell = [tableView
            dequeueReusableCellWithIdentifier:@"sw"];
        if (cell == nil) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:@"sw"];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            UISwitch *sw = [UISwitch new];
            [sw addTarget:self action:@selector(toggleEnabled:)
                forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        }
        cell.textLabel.text = @"启用插件";
        ((UISwitch *)cell.accessoryView).on = [self store].enabled;
        return cell;
    }

    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:@"item"];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"item"];
    }
    NSDictionary *it = [self store].items[indexPath.row];
    NSString *app = [it[@"appName"] length] ? it[@"appName"] : it[@"bundleId"];
    cell.textLabel.text = [NSString stringWithFormat:@"%@  %@",
                           app ?: @"?", it[@"module"] ?: @""];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ - %@",
                                  it[@"start"], it[@"end"]];
    cell.accessoryType = [it[@"enabled"] boolValue]
                             ? UITableViewCellAccessoryCheckmark
                             : UITableViewCellAccessoryNone;
    return cell;
}

- (void)toggleEnabled:(UISwitch *)sw {
    [self store].enabled = sw.on;
    [self persist];
}

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) return;

    /* 点击行 = 编辑该条目 */
    NSMutableDictionary *it = [self store].items[indexPath.row];
    TraceEditVC *edit = [[TraceEditVC alloc] initWithItem:it isNew:NO];
    [self.navigationController pushViewController:edit animated:YES];
}

#pragma mark - 前缘右滑:启用 / 停用

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) return nil;
    NSMutableDictionary *it = [self store].items[indexPath.row];
    BOOL on = [it[@"enabled"] boolValue];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *toggle = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
                            title:(on ? @"停用" : @"启用")
                          handler:^(UIContextualAction *a, UIView *v,
                                    void (^done)(BOOL)) {
              it[@"enabled"] = @(!on);
              [weakSelf persist];
              [weakSelf.tableView reloadRowsAtIndexPaths:@[ indexPath ]
                                       withRowAnimation:UITableViewRowAnimationAutomatic];
              done(YES);
          }];
    toggle.backgroundColor =
        on ? [UIColor systemGrayColor] : [UIColor systemGreenColor];
    return [UISwipeActionsConfiguration configurationWithActions:@[ toggle ]];
}

#pragma mark - 左滑:复制 / 删除

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) return nil;

    __weak typeof(self) weakSelf = self;
    UIContextualAction *del = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
                            title:@"删除"
                          handler:^(UIContextualAction *a, UIView *v,
                                    void (^done)(BOOL)) {
              [weakSelf confirmDeleteAt:indexPath done:done];
          }];
    UIContextualAction *copy = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
                            title:@"复制"
                          handler:^(UIContextualAction *a, UIView *v,
                                    void (^done)(BOOL)) {
              [weakSelf duplicateAt:indexPath];
              done(YES);
          }];
    copy.backgroundColor = [UIColor systemBlueColor];
    UIContextualAction *exp = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
                            title:@"导出"
                          handler:^(UIContextualAction *a, UIView *v,
                                    void (^done)(BOOL)) {
              [weakSelf exportAt:indexPath];
              done(YES);
          }];
    exp.backgroundColor = [UIColor systemGreenColor];
    /* 顺序:导出 / 复制 / 删除(尾缘从右往左显示,数组首个最靠右) */
    return [UISwipeActionsConfiguration
        configurationWithActions:@[ del, copy, exp ]];
}

- (void)exportAt:(NSIndexPath *)indexPath {
    NSDictionary *item = [self store].items[indexPath.row];
    NSError *err = nil;
    NSString *path = [[self store] exportItem:item error:&err];
    if (path == nil) {
        [self toast:err.localizedDescription ?: @"导出失败"];
        return;
    }
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"导出成功"
                         message:[NSString stringWithFormat:@"文件:%@\n\n路径:%@\n\n"
                                  @"用 Finder 连接手机 → 文件共享 → QBDI Tracer 取出。",
                                  path.lastPathComponent, path]
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好"
                                           style:UIAlertActionStyleDefault
                                         handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)duplicateAt:(NSIndexPath *)indexPath {
    NSDictionary *src = [self store].items[indexPath.row];
    NSMutableDictionary *copy = [src mutableCopy];
    copy[@"id"] = [[NSUUID UUID] UUIDString];
    /* watches 也深拷 */
    NSMutableArray *mw = [NSMutableArray array];
    for (NSDictionary *w in src[@"watches"]) {
        [mw addObject:[w mutableCopy]];
    }
    copy[@"watches"] = mw;
    [[self store].items insertObject:copy atIndex:indexPath.row + 1];
    [self persist];
    [self.tableView reloadData];
}

- (void)confirmDeleteAt:(NSIndexPath *)indexPath done:(void (^)(BOOL))done {
    NSDictionary *it = [self store].items[indexPath.row];
    NSString *app = [it[@"appName"] length] ? it[@"appName"] : it[@"bundleId"];
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"删除确认"
                         message:[NSString stringWithFormat:@"确定删除 “%@ %@” 吗?",
                                  app ?: @"", it[@"module"] ?: @""]
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消"
                                           style:UIAlertActionStyleCancel
                                         handler:^(UIAlertAction *a) {
                                             done(NO);
                                         }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"删除"
                                           style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *a) {
              [[self store].items removeObjectAtIndex:indexPath.row];
              [self persist];
              [self.tableView reloadData];
              done(YES);
          }]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - 保存

- (void)persist {
    if (![[self store] save]) {
        [self toast:@"保存失败(检查配置目录权限)"];
    }
}

- (void)toast:(NSString *)msg {
    UIAlertController *ac =
        [UIAlertController alertControllerWithTitle:nil
                                            message:msg
                                     preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:ac animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.2 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
                           [ac dismissViewControllerAnimated:YES completion:nil];
                       });
    }];
}

@end
