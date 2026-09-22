#import "RootListVC.h"
#import "AppPickerVC.h"
#import "AppSettings.h"
#import "ConfigStore.h"
#import "ImportVC.h"
#import "MoreMenu.h"
#import "TraceEditVC.h"

/* 用户自定义名称是可选字段；旧 JSON 没有该 key 时自然回落到旧展示。 */
static NSString *traceName(NSDictionary *item) {
    id raw = item[@"traceName"];
    if (![raw isKindOfClass:[NSString class]]) return @"";
    return [raw stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

/* 与引擎 parse_bool(it[@"enabled"], true) 保持一致：旧 JSON 缺字段
 * 时应视为启用。原来直接对 nil 调 boolValue 会让 UI 误显示为停用。 */
static BOOL traceEnabled(NSDictionary *item) {
    id raw = item[@"enabled"];
    return [raw isKindOfClass:[NSNumber class]] ? [raw boolValue] : YES;
}

@interface RootListVC ()
- (BOOL)persist;
- (void)notify:(NSString *)msg;
- (void)reloadItem:(NSMutableDictionary *)item;
- (void)renameItem:(NSMutableDictionary *)item
              done:(void (^)(BOOL))done;
@end

@implementation RootListVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"QBDI Tracer";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 68.0;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                             target:self
                             action:@selector(plusTapped)];
    /* 左上角「更多」:帮助、设置、页面切换都在里面(见 MoreMenu.m) */
    self.navigationItem.leftBarButtonItem = MoreMenuBarButton(self);
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

/* QBDIListPage:供「更多 → 新增」副本调用 */
- (void)beginCreate { [self addTrace]; }
- (void)beginImport { [self importTracer]; }

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
                  [self notify:err.localizedDescription ?: @"配置格式无效"];
                  return;
              }
              [[self store].items addObject:item];
              if ([[self store] save]) {
                  [self.tableView reloadData];
                  [self notify:@"导入成功"];
              } else {
                  [self notify:@"保存失败(检查权限)"];
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
    return section == 0 ? @"插件" : @"Trace 条目(点击编辑,左右滑动管理)";
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
        /* 总开关现在住在 settings.json(AppSettings),Trace 和 Hook 共用它。 */
        ((UISwitch *)cell.accessoryView).on = [AppSettings shared].enabled;
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
    NSString *target = [NSString stringWithFormat:@"%@  %@",
                        app ?: @"?", it[@"module"] ?: @""];
    NSString *range = [NSString stringWithFormat:@"%@ - %@",
                       it[@"start"] ?: @"?", it[@"end"] ?: @"?"];
    NSString *name = traceName(it);
    if (name.length > 0) {
        cell.textLabel.text = name;
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\n%@", target, range];
        cell.detailTextLabel.numberOfLines = 2;
    } else {
        cell.textLabel.text = target;
        cell.detailTextLabel.text = range;
        cell.detailTextLabel.numberOfLines = 1;
    }
    cell.accessoryType = traceEnabled(it)
                             ? UITableViewCellAccessoryCheckmark
                             : UITableViewCellAccessoryNone;
    return cell;
}

- (void)toggleEnabled:(UISwitch *)sw {
    /* 总开关写的是 settings.json,不是 config.json。写失败必须把内存和开关一起
     * 回滚,否则会出现"界面已停用、目标 App 重启后仍启用"。 */
    AppSettings *settings = [AppSettings shared];
    BOOL oldValue = settings.enabled;
    settings.enabled = sw.on;
    if ([settings save]) {
        [self notify:(sw.on ? @"已启用，重启目标 App 后生效"
                            : @"已停用，重启目标 App 后生效")];
    } else {
        settings.enabled = oldValue;
        [sw setOn:oldValue animated:YES];
        [self notify:@"保存失败，已恢复原状态（检查配置目录权限）"];
    }
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
    BOOL on = traceEnabled(it);
    __weak typeof(self) weakSelf = self;
    UIContextualAction *toggle = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
                            title:(on ? @"停用" : @"启用")
                          handler:^(UIContextualAction *a, UIView *v,
                                    void (^done)(BOOL)) {
              /* 按钮显示后到真正执行之间可能经历列表刷新，因此在这里
               * 重新读取最新状态，不使用上面只为标题/颜色服务的 on。 */
              BOOL oldValue = traceEnabled(it);
              BOOL newValue = !oldValue;
              it[@"enabled"] = @(newValue);
              BOOL saved = [[weakSelf store] save];
              if (!saved) {
                  /* 文件未写入时把内存也恢复，避免界面与 JSON 不一致。 */
                  it[@"enabled"] = @(oldValue);
              }
              done(saved);
              dispatch_async(dispatch_get_main_queue(), ^{
                  [weakSelf reloadItem:it];
                  if (saved) {
                      [weakSelf notify:(newValue
                          ? @"已启用，重启目标 App 后生效"
                          : @"已停用，重启目标 App 后生效")];
                  } else {
                      [weakSelf notify:@"保存失败，已恢复原状态（检查配置目录权限）"];
                  }
              });
          }];
    toggle.backgroundColor =
        on ? [UIColor systemGrayColor] : [UIColor systemGreenColor];
    UISwipeActionsConfiguration *cfg =
        [UISwipeActionsConfiguration configurationWithActions:@[ toggle ]];
    cfg.performsFirstActionWithFullSwipe = YES;
    return cfg;
}

#pragma mark - 左滑:命名 / 导出 / 复制 / 删除

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) return nil;

    __weak typeof(self) weakSelf = self;
    NSMutableDictionary *it = [self store].items[indexPath.row];
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
    UIContextualAction *rename = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
                            title:@"命名"
                          handler:^(UIContextualAction *a, UIView *v,
                                    void (^done)(BOOL)) {
              [weakSelf renameItem:it done:done];
          }];
    rename.backgroundColor = [UIColor systemOrangeColor];
    /* 保留原有三个操作的相对位置，命名放在最外侧。 */
    return [UISwipeActionsConfiguration
        configurationWithActions:@[ del, copy, exp, rename ]];
}

- (void)renameItem:(NSMutableDictionary *)item
              done:(void (^)(BOOL))done {
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"Trace 命名"
                         message:@"名称只用于区分条目；留空会清除自定义名称。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"例：登录签名计算";
        field.text = traceName(item);
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消"
                                           style:UIAlertActionStyleCancel
                                         handler:^(UIAlertAction *a) {
                                             done(NO);
                                         }]];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"保存"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
        id oldValue = item[@"traceName"];
        NSString *name = [ac.textFields.firstObject.text
            stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (name.length > 0) {
            item[@"traceName"] = name;
        } else {
            [item removeObjectForKey:@"traceName"];
        }

        BOOL saved = [[weakSelf store] save];
        if (!saved) {
            if (oldValue != nil) {
                item[@"traceName"] = oldValue;
            } else {
                [item removeObjectForKey:@"traceName"];
            }
        }
        done(saved);
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf reloadItem:item];
            if (!saved) {
                [weakSelf notify:@"保存失败，已恢复原名称（检查配置目录权限）"];
            }
        });
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)reloadItem:(NSMutableDictionary *)item {
    NSUInteger row = [[self store].items indexOfObjectIdenticalTo:item];
    if (row == NSNotFound) return;
    NSIndexPath *ip = [NSIndexPath indexPathForRow:(NSInteger)row inSection:1];
    [self.tableView reloadRowsAtIndexPaths:@[ ip ]
                           withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)exportAt:(NSIndexPath *)indexPath {
    NSDictionary *item = [self store].items[indexPath.row];
    NSError *err = nil;
    NSString *path = [[self store] exportItem:item error:&err];
    if (path == nil) {
        [self notify:err.localizedDescription ?: @"导出失败"];
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
    NSMutableArray *mt = [NSMutableArray array];
    for (NSDictionary *tr in src[@"triggers"]) {
        [mt addObject:[tr mutableCopy]];
    }
    copy[@"triggers"] = mt;
    NSMutableArray *mm = [NSMutableArray array];
    for (NSDictionary *mutation in src[@"mutations"]) {
        [mm addObject:[mutation mutableCopy]];
    }
    copy[@"mutations"] = mm;
    [[self store].items insertObject:copy atIndex:indexPath.row + 1];
    [self persist];
    [self.tableView reloadData];
}

- (void)confirmDeleteAt:(NSIndexPath *)indexPath done:(void (^)(BOOL))done {
    NSDictionary *it = [self store].items[indexPath.row];
    NSString *app = [it[@"appName"] length] ? it[@"appName"] : it[@"bundleId"];
    NSString *name = traceName(it);
    NSString *what = name.length > 0
        ? [NSString stringWithFormat:@"%@（%@ %@）", name, app ?: @"",
                                   it[@"module"] ?: @""]
        : [NSString stringWithFormat:@"%@ %@", app ?: @"", it[@"module"] ?: @""];
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"删除确认"
                         message:[NSString stringWithFormat:@"确定删除 “%@” 吗?", what]
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

- (BOOL)persist {
    BOOL ok = [[self store] save];
    if (!ok) {
        [self notify:@"保存失败(检查配置目录权限)"];
    }
    return ok;
}

/* 结果提示一律要用户手动点「好」关掉。原来是 1.2 秒自动消失的浮层 ——
 * "已启用，重启目标 App 后生效"这类信息恰恰是用户必须读到的,自动消失容易错过。 */
- (void)notify:(NSString *)msg {
    UIAlertController *ac =
        [UIAlertController alertControllerWithTitle:nil
                                            message:msg
                                     preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好"
                                           style:UIAlertActionStyleDefault
                                         handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
