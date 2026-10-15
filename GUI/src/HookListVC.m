#import "HookListVC.h"

#import "AppPickerVC.h"
#import "AppSettings.h"
#import "HookEditVC.h"
#import "HookStore.h"
#import "ImportVC.h"
#import "MoreMenu.h"

static NSString *hookName(NSDictionary *hook) {
    id raw = hook[@"hookName"];
    if (![raw isKindOfClass:[NSString class]]) return @"";
    return [raw stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static BOOL hookEnabled(NSDictionary *hook) {
    id raw = hook[@"enabled"];
    return [raw isKindOfClass:[NSNumber class]] ? [raw boolValue] : YES;
}

@interface HookListVC ()
- (BOOL)duplicateItem:(NSDictionary *)src;
@end

@implementation HookListVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Hook";
    self.navigationItem.leftBarButtonItem = MoreMenuBarButton(self);
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                             target:self
                             action:@selector(plusTapped)];
    [self installSortButton];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadEntries];
}

- (HookStore *)store { return [HookStore shared]; }
- (NSArray<NSMutableDictionary *> *)sourceEntries { return [self store].hooks; }
- (BOOL)isHookList { return YES; }


#pragma mark - + 菜单

- (void)plusTapped {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil message:nil
        preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"创建新的 Hook"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self addHook]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"导入 Hook"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self importHook]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:ac animated:YES completion:nil];
}

/* QBDIListPage:供「更多 → 新增」副本调用 */
- (void)beginCreate { [self addHook]; }
- (void)beginImport { [self importHook]; }

- (void)addHook {
    AppPickerVC *picker = [AppPickerVC new];
    __weak typeof(self) weakSelf = self;
    picker.onPick = ^(NSString *bundleId, NSString *appName) {
        NSMutableDictionary *hook = [[weakSelf store] newHook];
        hook[@"bundleId"] = bundleId ?: @"";
        hook[@"appName"] = appName ?: @"";
        HookEditVC *edit = [[HookEditVC alloc] initWithHook:hook isNew:YES];
        [weakSelf.navigationController pushViewController:edit animated:YES];
    };
    [self.navigationController pushViewController:picker animated:YES];
}

- (void)importHook {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"导入 Hook" message:nil
        preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"从文件导入"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            ImportVC *vc = [ImportVC new];
            vc.initialHookPage = YES; /* 默认进 Hook 分页 */
            __weak typeof(self) weakSelf = self;
            vc.onImported = ^{ [weakSelf reloadEntries]; };
            [self.navigationController pushViewController:vc animated:YES];
        }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"粘贴 JSON"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self importFromPaste]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)importFromPaste {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"粘贴 JSON"
        message:@"把导出的 Hook 配置 JSON 粘贴进来" preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"{ \"version\":1, \"type\":\"hook\", \"hook\":{...} }";
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"导入" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) {
            NSString *text = ac.textFields.firstObject.text;
            NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
            NSError *err = nil;
            NSMutableDictionary *hook = [[self store] importHookFromData:data error:&err];
            if (hook == nil) { [self notify:err.localizedDescription ?: @"配置格式无效"]; return; }
            [[self store].hooks addObject:hook];
            if ([[self store] save]) {
                [self reloadEntries];
                [self notify:@"导入成功"];
            } else {
                [[self store].hooks removeObjectIdenticalTo:hook];
                [self notify:@"保存失败(检查权限)"];
            }
        }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"插件" : @"Hook 条目(点击编辑,左右滑动管理)";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1 && [self store].hooks.count == 0) {
        return @"还没有 Hook。点右上角 + 创建。Hook 会用 Dobby 在目标地址真实改写数据。";
    }
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    return (NSInteger)self.displayedEntries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"sw"];
        if (cell == nil) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"sw"];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            UISwitch *sw = [UISwitch new];
            [sw addTarget:self action:@selector(toggleEnabled:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        }
        cell.textLabel.text = @"启用插件";
        ((UISwitch *)cell.accessoryView).on = [AppSettings shared].enabled;
        return cell;
    }
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"hook"];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"hook"];
    }
    NSDictionary *h = self.displayedEntries[ip.row];
    NSString *app = [h[@"appName"] length] ? h[@"appName"] : h[@"bundleId"];
    NSInteger nmods = [h[@"mods"] isKindOfClass:[NSArray class]] ? [h[@"mods"] count] : 0;
    NSString *target = [NSString stringWithFormat:@"%@  %@ @ %@",
                        app ?: @"?", h[@"module"] ?: @"", h[@"target"] ?: @"?"];
    NSString *name = hookName(h);
    if (name.length > 0) {
        cell.textLabel.text = name;
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\n%ld 条修改数据", target, (long)nmods];
        cell.detailTextLabel.numberOfLines = 2;
    } else {
        cell.textLabel.text = target;
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld 条修改数据", (long)nmods];
        cell.detailTextLabel.numberOfLines = 1;
    }
    cell.accessoryType = hookEnabled(h) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)toggleEnabled:(UISwitch *)sw {
    AppSettings *settings = [AppSettings shared];
    BOOL oldValue = settings.enabled;
    settings.enabled = sw.on;
    if ([settings save]) {
        [self notify:(sw.on ? @"已启用，重启目标 App 后生效" : @"已停用，重启目标 App 后生效")];
    } else {
        settings.enabled = oldValue;
        [sw setOn:oldValue animated:YES];
        [self notify:@"保存失败，已恢复原状态（检查配置目录权限）"];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0) return;
    NSMutableDictionary *h = self.displayedEntries[ip.row];
    HookEditVC *edit = [[HookEditVC alloc] initWithHook:h isNew:NO];
    [self.navigationController pushViewController:edit animated:YES];
}

#pragma mark - 前缘右滑:启停

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0) return nil;
    NSMutableDictionary *h = self.displayedEntries[ip.row];
    BOOL on = hookEnabled(h);
    __weak typeof(self) weakSelf = self;
    UIContextualAction *toggle = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
                            title:(on ? @"停用" : @"启用")
                          handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            BOOL oldValue = hookEnabled(h);
            BOOL newValue = !oldValue;
            h[@"enabled"] = @(newValue);
            BOOL saved = [[weakSelf store] save];
            if (!saved) h[@"enabled"] = @(oldValue);
            done(saved);
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf reloadRow:h];
                [weakSelf notify:(!saved ? @"保存失败，已恢复原状态（检查配置目录权限）"
                                         : (newValue ? @"已启用，重启目标 App 后生效"
                                                     : @"已停用，重启目标 App 后生效"))];
            });
        }];
    toggle.backgroundColor = on ? [UIColor systemGrayColor] : [UIColor systemGreenColor];
    UISwipeActionsConfiguration *cfg = [UISwipeActionsConfiguration configurationWithActions:@[ toggle ]];
    cfg.performsFirstActionWithFullSwipe = YES;
    return cfg;
}

#pragma mark - 左滑:命名 / 导出 / 复制 / 删除

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0) return nil;
    __weak typeof(self) weakSelf = self;
    NSMutableDictionary *h = self.displayedEntries[ip.row];
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"删除" handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            [weakSelf confirmDeleteItem:h done:done];
        }];
    UIContextualAction *copy = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
        title:@"复制" handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            done([weakSelf duplicateItem:h]);
        }];
    copy.backgroundColor = [UIColor systemBlueColor];
    UIContextualAction *exp = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
        title:@"导出" handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            [weakSelf exportItem:h]; done(YES);
        }];
    exp.backgroundColor = [UIColor systemGreenColor];
    UIContextualAction *rename = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
        title:@"命名" handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            [weakSelf renameHook:h done:done];
        }];
    rename.backgroundColor = [UIColor systemOrangeColor];
    return [UISwipeActionsConfiguration configurationWithActions:@[ del, copy, exp, rename ]];
}

- (void)renameHook:(NSMutableDictionary *)hook done:(void (^)(BOOL))done {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Hook 命名"
        message:@"名称只用于区分条目；留空会清除自定义名称。" preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"例：登录返回值改写";
        field.text = hookName(hook);
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
        handler:^(UIAlertAction *a) { done(NO); }]];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) {
            id oldValue = hook[@"hookName"];
            NSString *name = [ac.textFields.firstObject.text stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (name.length > 0) hook[@"hookName"] = name;
            else [hook removeObjectForKey:@"hookName"];
            BOOL saved = [[weakSelf store] save];
            if (!saved) {
                if (oldValue != nil) hook[@"hookName"] = oldValue;
                else [hook removeObjectForKey:@"hookName"];
            }
            done(saved);
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf reloadRow:hook];
                if (!saved) [weakSelf notify:@"保存失败，已恢复原名称（检查配置目录权限）"];
            });
        }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)reloadRow:(NSMutableDictionary *)hook {
    [self reloadEntries];
}

- (void)exportItem:(NSDictionary *)hook {
    NSError *err = nil;
    NSString *path = [[self store] exportHook:hook error:&err];
    if (path == nil) { [self notify:err.localizedDescription ?: @"导出失败"]; return; }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"导出成功"
        message:[NSString stringWithFormat:@"文件:%@\n\n路径:%@\n\n"
                 @"用 Finder 连接手机 → 文件共享 → QBDI Tracer 取出。",
                 path.lastPathComponent, path]
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (BOOL)duplicateItem:(NSDictionary *)src {
    NSMutableDictionary *copy = [src mutableCopy];
    copy[@"id"] = [[NSUUID UUID] UUIDString];
    copy[@"addedAt"] = QBDINewAddedAt();
    NSMutableArray *mm = [NSMutableArray array];
    for (NSDictionary *m in src[@"mods"]) [mm addObject:[m mutableCopy]];
    copy[@"mods"] = mm;
    [[self store].hooks addObject:copy];
    BOOL saved = [[self store] save];
    if (!saved) {
        [[self store].hooks removeObjectIdenticalTo:copy];
        [self notify:@"保存失败(检查配置目录权限)"];
    }
    [self reloadEntries];
    return saved;
}

- (void)confirmDeleteItem:(NSMutableDictionary *)h done:(void (^)(BOOL))done {
    NSString *app = [h[@"appName"] length] ? h[@"appName"] : h[@"bundleId"];
    NSString *name = hookName(h);
    NSString *what = name.length > 0
        ? [NSString stringWithFormat:@"%@（%@ %@）", name, app ?: @"", h[@"module"] ?: @""]
        : [NSString stringWithFormat:@"%@ %@ @ %@", app ?: @"", h[@"module"] ?: @"", h[@"target"] ?: @""];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"删除确认"
        message:[NSString stringWithFormat:@"确定删除 “%@” 吗?", what]
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
        handler:^(UIAlertAction *a) { done(NO); }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *a) {
            NSMutableArray *hooks = [self store].hooks;
            NSUInteger index = [hooks indexOfObjectIdenticalTo:h];
            if (index == NSNotFound) { done(NO); return; }
            [hooks removeObjectAtIndex:index];
            BOOL saved = [[self store] save];
            if (!saved) {
                [hooks insertObject:h atIndex:index];
                [self notify:@"保存失败(检查配置目录权限)"];
            }
            [self reloadEntries];
            done(saved);
        }]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - 提示

- (void)notify:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil message:msg
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
