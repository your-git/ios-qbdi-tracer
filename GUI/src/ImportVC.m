#import "ImportVC.h"
#import "ConfigStore.h"

@interface ImportVC ()
@property (nonatomic, strong) NSArray<NSString *> *files;
@end

@implementation ImportVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"从文件导入";
    self.tableView.rowHeight = 52.0;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.files = [[ConfigStore shared] listImportableFiles];
    [self.tableView reloadData];
}

- (ConfigStore *)store { return [ConfigStore shared]; }

- (NSString *)tableView:(UITableView *)tv
    titleForHeaderInSection:(NSInteger)s {
    return [NSString stringWithFormat:@"%@ 下的配置文件", [[self store] exportDir]];
}

- (NSString *)tableView:(UITableView *)tv
    titleForFooterInSection:(NSInteger)s {
    if (self.files.count == 0) {
        return @"目录为空。可用 Finder 连接手机 → 文件共享 → QBDI Tracer,"
               @"把导出的 .json 放进来;或用「粘贴 JSON」导入。\n\n"
               @"导出目录可在「更多 → 设置」里修改。";
    }
    /* 旧版导出文件直接堆在 Documents 根下,升级后也一并列出,不然用户会以为丢了。 */
    return @"同时列出了旧版散落在 Documents 根目录下的导出文件。";
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return (NSInteger)self.files.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv
         cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"f"];
    if (c == nil) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                   reuseIdentifier:@"f"];
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
    NSError *err = nil;
    NSMutableDictionary *item = [[self store] importItemFromData:data error:&err];
    if (item == nil) {
        [self alert:@"导入失败"
            message:err.localizedDescription ?: @"配置格式无效"
               pop:NO];
        return;
    }
    [[self store].items addObject:item];
    BOOL ok = [[self store] save];
    if (!ok) {
        [self alert:@"导入失败" message:@"保存配置失败(检查权限)" pop:NO];
        return;
    }
    if (self.onImported) self.onImported();
    [self alert:@"导入成功"
        message:[NSString stringWithFormat:@"已导入:%@", path.lastPathComponent]
           pop:YES];
}

- (void)alert:(NSString *)title message:(NSString *)msg pop:(BOOL)pop {
    UIAlertController *ac =
        [UIAlertController alertControllerWithTitle:title
                                            message:msg
                                     preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
              if (pop) [self.navigationController popViewControllerAnimated:YES];
          }]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
