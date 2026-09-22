#import "ImportVC.h"

#import "ConfigStore.h"
#import "HookStore.h"

@interface ImportVC ()
@property (nonatomic, strong) NSArray<NSString *> *files;
@property (nonatomic, strong) UISegmentedControl *pager;
@end

@implementation ImportVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"从文件导入";
    self.tableView.rowHeight = 52.0;
    self.pager = [[UISegmentedControl alloc] initWithItems:@[ @"Trace", @"Hook" ]];
    self.pager.selectedSegmentIndex = self.initialHookPage ? 1 : 0;
    [self.pager addTarget:self action:@selector(pageChanged)
         forControlEvents:UIControlEventValueChanged];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    /* 底部工具栏放分页控件 */
    UIBarButtonItem *flex = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *seg = [[UIBarButtonItem alloc] initWithCustomView:self.pager];
    self.toolbarItems = @[ flex, seg, flex ];
    [self.navigationController setToolbarHidden:NO animated:animated];
    [self reloadFiles];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.navigationController setToolbarHidden:YES animated:animated];
}

- (BOOL)onHookPage { return self.pager.selectedSegmentIndex == 1; }

- (void)pageChanged { [self reloadFiles]; }

- (void)reloadFiles {
    self.files = [self onHookPage] ? [[HookStore shared] listImportableFiles]
                                   : [[ConfigStore shared] listImportableFiles];
    [self.tableView reloadData];
}

#pragma mark - Table

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    NSString *dir = [self onHookPage] ? [[HookStore shared] exportDir]
                                      : [[ConfigStore shared] exportDir];
    return [NSString stringWithFormat:@"%@ 下的配置文件", dir];
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (self.files.count == 0) {
        return @"目录为空。可用 Finder 连接手机 → 文件共享 → QBDI Tracer,把导出的 .json "
               @"放进来;或用「粘贴 JSON」导入。导出目录可在「更多 → 设置」里修改。";
    }
    return @"同时列出了旧版散落在 Documents 根目录下的导出文件。"
           @"若选中的文件其实是另一类配置,会自动导到正确的一类。";
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return (NSInteger)self.files.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"f"];
    if (c == nil) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"f"];
    }
    NSString *path = self.files[ip.row];
    c.textLabel.text = path.lastPathComponent;
    NSDate *m = [[NSFileManager defaultManager]
        attributesOfItemAtPath:path error:nil].fileModificationDate;
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyy-MM-dd HH:mm";
    c.detailTextLabel.text = m ? [df stringFromDate:m] : @"";
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *path = self.files[ip.row];
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSString *type = [HookStore detectType:data]; /* 按内容判定真实类型,不看在哪一页 */
    if (type == nil) {
        [self alert:@"导入失败" message:@"配置格式无效,无法识别是 Trace 还是 Hook。" pop:NO];
        return;
    }

    NSError *err = nil;
    NSString *note = nil;
    BOOL ok = NO;
    if ([type isEqualToString:@"hook"]) {
        NSMutableDictionary *hook = [[HookStore shared] importHookFromData:data error:&err];
        if (hook != nil) {
            [[HookStore shared].hooks addObject:hook];
            ok = [[HookStore shared] save];
            if (ok && ![self onHookPage]) note = @"这是一份 Hook 配置,已作为 Hook 导入。";
        }
    } else {
        NSMutableDictionary *item = [[ConfigStore shared] importItemFromData:data error:&err];
        if (item != nil) {
            [[ConfigStore shared].items addObject:item];
            ok = [[ConfigStore shared] save];
            if (ok && [self onHookPage]) note = @"这是一份 Tracer 配置,已作为 Tracer 导入。";
        }
    }

    if (err != nil && !ok) {
        [self alert:@"导入失败" message:err.localizedDescription ?: @"配置格式无效" pop:NO];
        return;
    }
    if (!ok) {
        [self alert:@"导入失败" message:@"保存配置失败(检查权限)" pop:NO];
        return;
    }
    if (self.onImported) self.onImported();
    NSString *msg = [NSString stringWithFormat:@"已导入:%@%@", path.lastPathComponent,
                     note ? [@"\n\n" stringByAppendingString:note] : @""];
    [self alert:@"导入成功" message:msg pop:YES];
}

- (void)alert:(NSString *)title message:(NSString *)msg pop:(BOOL)pop {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) {
            if (pop) [self.navigationController popViewControllerAnimated:YES];
        }]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
