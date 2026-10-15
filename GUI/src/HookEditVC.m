#import "ListSort.h"
#import "HookEditVC.h"

#import "ExprInput.h"
#import "HexValue.h"
#import "HookModEditVC.h"
#import "HookStore.h"
#import <objc/runtime.h>

static NSString *modTypeName(NSDictionary *mod) {
    NSString *t = mod[@"type"];
    if ([t isEqualToString:@"bytes"]) return @"字节";
    if ([t isEqualToString:@"string"]) return @"字符串";
    return @"数值";
}

@interface HookFieldCell : UITableViewCell
@property (nonatomic, strong) UITextField *field;
@end
@implementation HookFieldCell
- (instancetype)init {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (self) {
        _field = [UITextField new];
        _field.textAlignment = NSTextAlignmentRight;
        _field.clearButtonMode = UITextFieldViewModeWhileEditing;
        _field.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_field];
        [NSLayoutConstraint activateConstraints:@[
            [_field.leadingAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
            [_field.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [_field.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [_field.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        ]];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return self;
}
@end

@interface HookEditVC () <UITextFieldDelegate>
@property (nonatomic, strong) NSMutableDictionary *hook;
@property (nonatomic, assign) BOOL isNew;
@end

@implementation HookEditVC

- (instancetype)initWithHook:(NSMutableDictionary *)hook isNew:(BOOL)isNew {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) { _hook = hook; _isNew = isNew; }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.isNew ? @"添加 Hook" : @"编辑 Hook";
    self.tableView.rowHeight = 52;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"完成" style:UIBarButtonItemStyleDone
               target:self action:@selector(done)];

    /* 规范化默认值(快照之前) */
    for (NSString *key in @[ @"delaySecs", @"maxHits" ]) {
        id v = self.hook[key];
        if (![v isKindOfClass:[NSNumber class]]) {
            self.hook[key] = @([v respondsToSelector:@selector(integerValue)]
                                   ? [v integerValue] : 0);
        }
    }
    id target = self.hook[@"target"];
    if ([target isKindOfClass:[NSNumber class]]) {
        self.hook[@"target"] = [NSString stringWithFormat:@"0x%llx",
                                [target unsignedLongLongValue]];
    }
    if (![self.hook[@"mods"] isKindOfClass:[NSMutableArray class]]) {
        NSArray *old = [self.hook[@"mods"] isKindOfClass:[NSArray class]]
                           ? self.hook[@"mods"] : @[];
        NSMutableArray *copy = [NSMutableArray array];
        for (NSDictionary *m in old)
            if ([m isKindOfClass:[NSDictionary class]]) [copy addObject:[m mutableCopy]];
        self.hook[@"mods"] = copy;
    }
    [self beginEditingTarget:self.hook];
}

- (NSSet<NSString *> *)snapshotExcludedKeys {
    return [NSSet setWithObject:@"mods"]; /* mods 子结构由子页编辑,不参与本页回滚 */
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

#pragma mark - Table

/* 0:目标 App  1:模块与地址  2:选项  3:功能 */
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[ @"目标 App", @"模块与目标地址(十六进制)", @"选项", @"功能" ][section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 2) return @"执行次数上限:0 = 每次命中都修改;填 N = 只改前 N 次。";
    if (section == 3) return @"Hook 用 Dobby 在目标地址真实改写数据。补丁会覆盖目标地址"
                             @"往后 0x10 字节,请选不会有其它代码(循环头/分支目标)跳进来的位置。";
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    if (section == 1) return 2;
    if (section == 2) return 2;
    return (NSInteger)[self.hook[@"mods"] count] + 1; /* +1 = 添加功能 */
}

- (HookFieldCell *)field:(NSString *)key label:(NSString *)label
             placeholder:(NSString *)placeholder numeric:(BOOL)numeric hex:(BOOL)hex {
    HookFieldCell *c = [HookFieldCell new];
    c.textLabel.text = label;
    c.field.placeholder = placeholder;
    c.field.delegate = self;
    c.field.keyboardType = numeric ? UIKeyboardTypeNumberPad : UIKeyboardTypeASCIICapable;
    id v = self.hook[key];
    c.field.text = [v isKindOfClass:[NSString class]] ? v : [v description];
    objc_setAssociatedObject(c.field, "hookKey", key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(c.field, "hookNumeric", @(numeric), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [c.field addTarget:self action:@selector(fieldChanged:) forControlEvents:UIControlEventEditingChanged];
    if (hex) AttachHexKeyboard(c.field);
    return c;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        c.textLabel.text = @"App";
        c.detailTextLabel.text = [self.hook[@"appName"] length] ? self.hook[@"appName"] : self.hook[@"bundleId"];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }
    if (ip.section == 1) {
        if (ip.row == 0) return [self field:@"module" label:@"模块名" placeholder:@"ModuleName" numeric:NO hex:NO];
        return [self field:@"target" label:@"目标地址" placeholder:@"0x..." numeric:NO hex:YES];
    }
    if (ip.section == 2) {
        if (ip.row == 0) return [self field:@"delaySecs" label:@"延迟(秒)" placeholder:@"0" numeric:YES hex:NO];
        return [self field:@"maxHits" label:@"执行次数上限" placeholder:@"0=不限" numeric:YES hex:NO];
    }
    NSMutableArray *mods = self.hook[@"mods"];
    if (ip.row == (NSInteger)mods.count) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.textLabel.text = @"+ 添加功能";
        c.textLabel.textColor = [UIColor systemBlueColor];
        return c;
    }
    NSDictionary *mod = mods[ip.row];
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSString *expr = [mod[@"expr"] length] ? mod[@"expr"] : @"(未设置)";
    c.textLabel.text = [NSString stringWithFormat:@"修改数据 · %@", modTypeName(mod)];
    NSString *sub = expr;
    if ([mod[@"type"] isEqualToString:@"number"]) {
        sub = [NSString stringWithFormat:@"%@ · %@位 = %@", expr,
               mod[@"width"] ?: @64, [mod[@"value"] length] ? mod[@"value"] : @"?"];
    } else {
        sub = [NSString stringWithFormat:@"%@ = %@", expr,
               [mod[@"value"] length] ? mod[@"value"] : @"?"];
    }
    if (![mod[@"enabled"] boolValue]) sub = [@"已停用 · " stringByAppendingString:sub];
    c.detailTextLabel.text = sub;
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

#pragma mark - 输入

- (void)fieldChanged:(UITextField *)field {
    NSString *key = objc_getAssociatedObject(field, "hookKey");
    NSString *text = [field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([key isEqualToString:@"target"]) {
        unsigned long long n = 0;
        field.textColor = HexParseInput(text, &n) ? [UIColor labelColor] : [UIColor systemRedColor];
    }
    [self updatePopGesture];
}

- (void)textFieldDidEndEditing:(UITextField *)field {
    NSString *key = objc_getAssociatedObject(field, "hookKey");
    if (key == nil) return;
    if ([key isEqualToString:@"target"]) {
        unsigned long long n = 0;
        if (HexParseInput(field.text, &n)) field.text = [NSString stringWithFormat:@"0x%llx", n];
        self.hook[key] = field.text ?: @"";
    } else if ([objc_getAssociatedObject(field, "hookNumeric") boolValue]) {
        self.hook[key] = @(field.text.integerValue);
    } else {
        self.hook[key] = field.text ?: @"";
    }
    [self fieldChanged:field];
}

- (BOOL)textFieldShouldReturn:(UITextField *)field {
    [field resignFirstResponder];
    return YES;
}

#pragma mark - 添加/编辑功能

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != 3) return;
    NSMutableArray *mods = self.hook[@"mods"];
    if (ip.row == (NSInteger)mods.count) {
        [self addFunction:[tableView cellForRowAtIndexPath:ip]];
        return;
    }
    /* 编辑已有功能 */
    NSMutableDictionary *mod = mods[ip.row];
    HookModEditVC *vc = [[HookModEditVC alloc] initWithMod:mod];
    __weak typeof(self) weakSelf = self;
    vc.onDone = ^{ [weakSelf.tableView reloadData]; };
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)addFunction:(UITableViewCell *)source {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"添加功能"
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"修改数据"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self addModifyData];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"读取数据"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self alert:@"功能正在研发中" message:@"「读取数据」将在后续版本提供。"];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = source;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)addModifyData {
    NSMutableArray *mods = self.hook[@"mods"];
    NSMutableDictionary *mod = [[HookStore shared] newMod];
    HookModEditVC *vc = [[HookModEditVC alloc] initWithMod:mod];
    __weak typeof(self) weakSelf = self;
    vc.onDone = ^{ [mods addObject:mod]; [weakSelf.tableView reloadData]; };
    [self.navigationController pushViewController:vc animated:YES];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section != 3) return nil;
    NSMutableArray *mods = self.hook[@"mods"];
    if (ip.row >= (NSInteger)mods.count) return nil;
    __weak typeof(self) weakSelf = self;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"删除" handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            [mods removeObjectAtIndex:ip.row];
            [weakSelf.tableView reloadData];
            done(YES);
        }];
    return [UISwipeActionsConfiguration configurationWithActions:@[ del ]];
}

#pragma mark - 完成

- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)done {
    [self.view endEditing:YES];
    NSString *module = [self.hook[@"module"] stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (module.length == 0) {
        [self alert:@"模块名不能为空" message:@"请填写目标模块名(dyld 镜像名子串)。"];
        return;
    }
    self.hook[@"module"] = module;
    unsigned long long target = 0;
    if (!HexParseInput([self.hook[@"target"] description], &target)) {
        [self alert:@"目标地址无效" message:@"目标地址只能包含 0X、0-9 和 A-F。"];
        return;
    }
    NSArray *mods = self.hook[@"mods"];
    if (mods.count == 0) {
        [self alert:@"没有功能" message:@"请至少添加一条修改数据功能。"];
        return;
    }
    BOOL anyEnabled = NO;
    for (NSDictionary *m in mods) {
        if ([m[@"enabled"] boolValue] && [m[@"expr"] length] > 0) { anyEnabled = YES; break; }
    }
    if (!anyEnabled) {
        [self alert:@"没有生效的功能"
            message:@"至少要有一条启用且填了表达式的修改数据功能。"];
        return;
    }

    HookStore *store = [HookStore shared];
    BOOL appended = self.isNew;
    if (appended) {
        self.hook[@"addedAt"] = QBDINewAddedAt();
        [store.hooks addObject:self.hook];
    }
    if (![store save]) {
        if (appended) [store.hooks removeObjectIdenticalTo:self.hook];
        [self alert:@"错误" message:@"保存失败(检查配置目录权限)。"];
        return;
    }
    self.isNew = NO;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"完成"
        message:@"Hook 已保存,请重开目标 App 生效。" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *x) {
            [self.navigationController popToRootViewControllerAnimated:YES];
        }]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
