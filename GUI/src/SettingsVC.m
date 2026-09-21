#import "SettingsVC.h"

#import "AppSettings.h"
#import <objc/runtime.h>

/* 路径太长,右对齐的窄输入框根本看不全。所以标签交给 section header,
 * 整行只放一个左对齐的等宽输入框。 */
@interface PathFieldCell : UITableViewCell
@property (nonatomic, strong) UITextField *field;
@end

@implementation PathFieldCell
- (instancetype)init {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (self) {
        _field = [UITextField new];
        _field.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
        _field.autocorrectionType = UITextAutocorrectionTypeNo;
        _field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        _field.spellCheckingType = UITextSpellCheckingTypeNo;
        _field.keyboardType = UIKeyboardTypeURL;
        _field.clearButtonMode = UITextFieldViewModeWhileEditing;
        _field.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_field];
        [NSLayoutConstraint activateConstraints:@[
            [_field.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor
                                                 constant:16],
            [_field.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor
                                                  constant:-16],
            [_field.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [_field.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        ]];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return self;
}
@end

@interface SettingsVC () <UITextFieldDelegate>
@property (nonatomic, strong) NSMutableDictionary *draft;
@end

@implementation SettingsVC

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"设置";
    self.tableView.rowHeight = 52;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"完成"
                style:UIBarButtonItemStyleDone
               target:self
               action:@selector(commit)];

    AppSettings *s = [AppSettings shared];
    /* 先把值规范化好再拍快照,否则进页面什么都不动、一返回就误弹「放弃修改」。 */
    self.draft = [@{ @"logRoot": s.logRoot ?: QBDIDefaultLogRoot(),
                     @"exportRoot": s.exportRoot ?: QBDIDefaultExportRoot() } mutableCopy];
    [self beginEditingTarget:self.draft];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
    return 2; /* 0: 输入框  1: 恢复默认 */
}

- (NSString *)tableView:(UITableView *)tableView
    titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"日志根目录" : @"导入导出根目录";
}

- (NSString *)tableView:(UITableView *)tableView
    titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return [NSString stringWithFormat:
            @"Trace 日志写到 %@/,Hook 日志写到 %@/,两个子目录自动创建。\n"
            @"默认:%@",
            QBDI_TRACE_LOG_SUBDIR, QBDI_HOOK_LOG_SUBDIR, QBDIDefaultLogRoot()];
    }
    return [NSString stringWithFormat:
        @"Tracer 配置导出到 %@/,Hook 配置导出到 %@/,两个子目录自动创建。\n"
        @"默认:%@",
        QBDI_TRACE_EXPORT_SUBDIR, QBDI_HOOK_EXPORT_SUBDIR, QBDIDefaultExportRoot()];
}

- (NSString *)keyForSection:(NSInteger)section {
    return section == 0 ? @"logRoot" : @"exportRoot";
}

- (NSString *)defaultForSection:(NSInteger)section {
    return section == 0 ? QBDIDefaultLogRoot() : QBDIDefaultExportRoot();
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSString *key = [self keyForSection:ip.section];
    if (ip.row == 0) {
        PathFieldCell *cell = [PathFieldCell new];
        cell.field.text = self.draft[key];
        cell.field.placeholder = [self defaultForSection:ip.section];
        cell.field.delegate = self;
        objc_setAssociatedObject(cell.field, "settingsKey", key,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [cell.field addTarget:self
                       action:@selector(fieldChanged:)
             forControlEvents:UIControlEventEditingChanged];
        return cell;
    }
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text = @"恢复默认值";
    cell.textLabel.textColor = [UIColor systemBlueColor];
    return cell;
}

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if (ip.row != 1) return;
    [self.view endEditing:YES];
    self.draft[[self keyForSection:ip.section]] = [self defaultForSection:ip.section];
    [tableView reloadData];
    [self updatePopGesture];
}

#pragma mark - 输入

- (void)fieldChanged:(UITextField *)field {
    NSString *key = objc_getAssociatedObject(field, "settingsKey");
    NSString *text = [field.text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    self.draft[key] = text ?: @"";
    /* 绝对路径才有意义;不当场标红的话,用户要到点「完成」时才发现填错。 */
    field.textColor = [text hasPrefix:@"/"] ? [UIColor labelColor]
                                            : [UIColor systemRedColor];
    [self updatePopGesture];
}

- (void)textFieldDidEndEditing:(UITextField *)field {
    [self fieldChanged:field];
}

- (BOOL)textFieldShouldReturn:(UITextField *)field {
    [field resignFirstResponder];
    return YES;
}

#pragma mark - 保存

- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                               message:message
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好"
                                           style:UIAlertActionStyleDefault
                                         handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)commit {
    [self.view endEditing:YES];
    NSString *logRoot = self.draft[@"logRoot"];
    NSString *exportRoot = self.draft[@"exportRoot"];

    /* 目录能不能建、能不能写,只有真去建、真去写才知道(只读挂载、权限不足
     * 都建得出目录却写不进文件),所以 directoryUsable 会落一个探针文件。 */
    if (![AppSettings directoryUsable:logRoot]) {
        [self alert:@"日志目录不可用"
            message:@"这个目录无法创建或没有写入权限,请换一个绝对路径。"];
        return;
    }
    if (![AppSettings directoryUsable:exportRoot]) {
        [self alert:@"导入导出目录不可用"
            message:@"这个目录无法创建或没有写入权限,请换一个绝对路径。"];
        return;
    }

    AppSettings *s = [AppSettings shared];
    NSString *oldLog = s.logRoot, *oldExport = s.exportRoot;
    s.logRoot = logRoot;
    s.exportRoot = exportRoot;
    if (![s save]) {
        s.logRoot = oldLog;
        s.exportRoot = oldExport;
        [self alert:@"保存失败" message:@"写入 settings.json 失败(检查配置目录权限)。"];
        return;
    }
    /* 重新拍快照:保存后页面内容就是已落盘的内容,再返回不应该弹「放弃修改」。 */
    [self beginEditingTarget:self.draft];

    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"已保存"
                         message:@"引擎只在目标 App 启动时读一次配置,"
                                 @"所以新的日志目录要重开目标 App 后才会生效;"
                                 @"正在运行的 App 仍写到原来的位置。\n\n"
                                 @"导入导出目录立即生效。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
              [self.navigationController popViewControllerAnimated:YES];
          }]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
