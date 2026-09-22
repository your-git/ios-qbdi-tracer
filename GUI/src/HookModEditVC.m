#import "HookModEditVC.h"

#import "ExprInput.h"
#import "HexValue.h"
#import <objc/runtime.h>
#include <stdint.h>

/* GUI 侧的目标分类,镜像引擎 hook.c 的 outer_bracket / bare_register / classify。
 * 两边任一改了,另一边要跟着改(与 ExprInput↔watch_expr 同理)。引擎才是权威,
 * 这里只为在「完成」时给出即时错误。 */
typedef enum { HOOK_TGT_MEM, HOOK_TGT_BARE_REG, HOOK_TGT_INVALID } HookTargetKind;

/* 整串是否被一对最外层 [] 包住 */
static BOOL exprBracketed(NSString *expr) {
    NSString *t = [expr stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length < 2 || ![t hasPrefix:@"["] || ![t hasSuffix:@"]"]) return NO;
    NSInteger depth = 0;
    for (NSUInteger i = 0; i < t.length; i++) {
        unichar c = [t characterAtIndex:i];
        if (c == '[') depth++;
        else if (c == ']') {
            depth--;
            if (depth == 0 && i != t.length - 1) return NO; /* 提前归零 */
        }
    }
    return depth == 0;
}

/* 是否是单个裸寄存器(x0..x28 除 x17、fp、lr)。 */
static BOOL exprBareRegister(NSString *expr) {
    NSString *t = [[expr stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if ([t isEqualToString:@"fp"] || [t isEqualToString:@"lr"]) return YES;
    if (![t hasPrefix:@"x"] || t.length < 2) return NO;
    NSString *digits = [t substringFromIndex:1];
    NSCharacterSet *bad = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if ([digits rangeOfCharacterFromSet:bad].location != NSNotFound) return NO;
    NSInteger n = digits.integerValue;
    if (n == 29 || n == 30) return YES;
    return n >= 0 && n <= 28 && n != 17;
}

static HookTargetKind classifyTarget(NSString *expr) {
    if (exprBracketed(expr)) return HOOK_TGT_MEM;
    if (exprBareRegister(expr)) return HOOK_TGT_BARE_REG;
    return HOOK_TGT_INVALID;
}

@interface HookModFieldCell : UITableViewCell
@property (nonatomic, strong) UITextField *field;
@end
@implementation HookModFieldCell
- (instancetype)init {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (self) {
        _field = [UITextField new];
        _field.translatesAutoresizingMaskIntoConstraints = NO;
        _field.clearButtonMode = UITextFieldViewModeWhileEditing;
        [self.contentView addSubview:_field];
        [NSLayoutConstraint activateConstraints:@[
            [_field.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [_field.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [_field.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [_field.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        ]];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return self;
}
@end

@interface HookModEditVC () <UITextFieldDelegate>
@property (nonatomic, strong) NSMutableDictionary *mod;
@end

@implementation HookModEditVC

- (instancetype)initWithMod:(NSMutableDictionary *)mod {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) _mod = mod;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"修改数据";
    self.tableView.rowHeight = 52;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"确定" style:UIBarButtonItemStyleDone
               target:self action:@selector(commit)];
    /* 规范化默认值(在快照之前),避免进页面什么都不动、返回却弹「放弃修改」。 */
    if (self.mod[@"enabled"] == nil) self.mod[@"enabled"] = @YES;
    self.mod[@"kind"] = @"modify";
    if (![self.mod[@"type"] isKindOfClass:[NSString class]]) self.mod[@"type"] = @"number";
    NSInteger w = [self.mod[@"width"] integerValue];
    if (w != 8 && w != 16 && w != 32 && w != 64) self.mod[@"width"] = @64;
    if (![self.mod[@"expr"] isKindOfClass:[NSString class]]) self.mod[@"expr"] = @"";
    if (![self.mod[@"value"] isKindOfClass:[NSString class]]) self.mod[@"value"] = @"";
    [self beginEditingTarget:self.mod];
}

- (BOOL)isNumber { return [self.mod[@"type"] isEqualToString:@"number"]; }
- (BOOL)isBytes  { return [self.mod[@"type"] isEqualToString:@"bytes"]; }
- (BOOL)isString { return [self.mod[@"type"] isEqualToString:@"string"]; }

- (NSString *)typeDisplay {
    if ([self isBytes]) return @"字节";
    if ([self isString]) return @"字符串";
    return @"数值";
}

#pragma mark - Table

/* 0:启用  1:写入目标  2:修改类型(+位宽)  3:修改内容 */
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 2) return [self isNumber] ? 2 : 1;
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[ @"功能", @"写入目标(寄存器/取址表达式)", @"修改类型", @"修改内容" ][section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1) {
        return @"数值:裸寄存器如 x0 直接改寄存器;[x0]、[x0+0x10] 改内存。\n"
               @"字节:只能改内存,必须用 [ ] 指定地址。\n"
               @"字符串:裸寄存器 x0 表示 x0 指向的首地址,写到那里。";
    }
    if (section == 3) {
        if ([self isBytes]) return @"十六进制字节,按内存顺序,如 08a48c90(最多 256 字节)。";
        if ([self isString]) return @"UTF-8 字符串,底层自动补 0 结尾。长度最好不超过原字符串,"
                                     @"否则可能覆盖相邻数据导致意外退出(最多 256 字节含结尾 0)。";
        return @"十六进制数值,如 0x1234。数值必须能装进所选位宽。"
               @"改寄存器时只能选 32 或 64 位。";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0) {
        UITableViewCell *c = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.textLabel.text = @"启用";
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *sw = [UISwitch new];
        sw.on = [self.mod[@"enabled"] boolValue];
        [sw addTarget:self action:@selector(enabledChanged:)
            forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
        return c;
    }
    if (ip.section == 1) {
        UITableViewCell *c = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        c.textLabel.text = @"表达式";
        NSString *expr = self.mod[@"expr"];
        c.detailTextLabel.text = expr.length ? expr : @"点此输入";
        c.detailTextLabel.textColor = expr.length ? [UIColor secondaryLabelColor]
                                                  : [UIColor tertiaryLabelColor];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }
    if (ip.section == 2) {
        UITableViewCell *c = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if (ip.row == 0) {
            c.textLabel.text = @"类型";
            c.detailTextLabel.text = [self typeDisplay];
        } else {
            c.textLabel.text = @"位宽";
            c.detailTextLabel.text = [NSString stringWithFormat:@"%ld 位",
                                      (long)[self.mod[@"width"] integerValue]];
        }
        return c;
    }
    /* section 3:修改内容输入框 */
    HookModFieldCell *c = [HookModFieldCell new];
    c.field.text = self.mod[@"value"];
    c.field.delegate = self;
    c.field.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
    c.field.autocorrectionType = UITextAutocorrectionTypeNo;
    c.field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    c.field.spellCheckingType = UITextSpellCheckingTypeNo;
    if ([self isString]) {
        c.field.placeholder = @"要写入的字符串";
        c.field.keyboardType = UIKeyboardTypeDefault;
    } else {
        c.field.placeholder = [self isBytes] ? @"08a48c90" : @"0x1234";
        AttachHexKeyboard(c.field); /* 字节/数值都用十六进制辅助键盘 */
    }
    [c.field addTarget:self action:@selector(valueChanged:)
      forControlEvents:UIControlEventEditingChanged];
    return c;
}

#pragma mark - 交互

- (void)enabledChanged:(UISwitch *)sw {
    self.mod[@"enabled"] = @(sw.on);
    [self updatePopGesture];
}

- (void)valueChanged:(UITextField *)field {
    self.mod[@"value"] = field.text ?: @"";
    [self updatePopGesture];
}

- (void)textFieldDidEndEditing:(UITextField *)field {
    self.mod[@"value"] = field.text ?: @"";
    [self updatePopGesture];
}
- (BOOL)textFieldShouldReturn:(UITextField *)field {
    [field resignFirstResponder];
    return YES;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    [self.view endEditing:YES];
    if (ip.section == 1) {
        __weak typeof(self) weakSelf = self;
        ExprPrompt(self, self.mod[@"expr"], ^(NSString *expr) {
            weakSelf.mod[@"expr"] = expr ?: @"";
            [weakSelf.tableView reloadData];
            [weakSelf updatePopGesture];
        });
        return;
    }
    if (ip.section == 2 && ip.row == 0) {
        [self pickType:[tableView cellForRowAtIndexPath:ip]];
        return;
    }
    if (ip.section == 2 && ip.row == 1) {
        [self pickWidth:[tableView cellForRowAtIndexPath:ip]];
        return;
    }
}

- (void)pickType:(UITableViewCell *)source {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"修改类型"
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *labels = @[ @"字节", @"字符串", @"数值" ];
    NSArray *keys = @[ @"bytes", @"string", @"number" ];
    for (NSUInteger i = 0; i < labels.count; i++) {
        NSString *key = keys[i];
        [sheet addAction:[UIAlertAction actionWithTitle:labels[i]
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                BOOL toString = [key isEqualToString:@"string"];
                self.mod[@"type"] = key;
                [self.tableView reloadData];
                [self updatePopGesture];
                if (toString) [self showStringWarning];
            }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = source;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showStringWarning {
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"字符串长度提醒"
                         message:@"修改的字符串长度最好不要超过原始字符串,否则可能覆盖"
                                 @"相邻数据,造成目标 App 意外退出。\n\n底层会自动补一个 0 结尾。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"知道了"
                                          style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)pickWidth:(UITableViewCell *)source {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"数值位宽"
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSNumber *w in @[ @8, @16, @32, @64 ]) {
        [sheet addAction:[UIAlertAction
            actionWithTitle:[NSString stringWithFormat:@"%@ 位", w]
                      style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                self.mod[@"width"] = w;
                [self.tableView reloadData];
                [self updatePopGesture];
            }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = source;
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 校验与提交

- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好"
        style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

/* 十六进制串(忽略空格/:/,,可带 0x)是否为偶数个 hex 位且非空 */
static BOOL bytesValid(NSString *value) {
    NSString *t = [value stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([[t lowercaseString] hasPrefix:@"0x"]) t = [t substringFromIndex:2];
    NSInteger n = 0;
    for (NSUInteger i = 0; i < t.length; i++) {
        unichar c = [t characterAtIndex:i];
        if (c == ' ' || c == '\t' || c == ':' || c == ',') continue;
        BOOL hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
        if (!hex) return NO;
        n++;
    }
    return n > 0 && (n % 2) == 0 && (n / 2) <= 256;
}

- (void)commit {
    [self.view endEditing:YES];
    NSString *expr = [self.mod[@"expr"] stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *value = self.mod[@"value"] ?: @"";

    if (expr.length == 0 || !ExprSyntaxOK(expr)) {
        [self alert:@"表达式无效" message:@"请填写合法的寄存器或取址表达式。"];
        return;
    }
    HookTargetKind tgt = classifyTarget(expr);
    if (tgt == HOOK_TGT_INVALID) {
        [self alert:@"表达式无效"
            message:@"改内存请用 [地址],改寄存器请填单个寄存器名(如 x0)。"];
        return;
    }

    if ([self isBytes]) {
        if (tgt == HOOK_TGT_BARE_REG) {
            [self alert:@"字节写入无效"
                message:@"字节修改必须用 [ ] 指定内存地址,裸寄存器写不了字节。"];
            return;
        }
        if (!bytesValid(value)) {
            [self alert:@"字节内容无效"
                message:@"请输入偶数个十六进制位(最多 256 字节),如 08a48c90。"];
            return;
        }
    } else if ([self isNumber]) {
        unsigned long long n = 0;
        if (value.length == 0 || !HexParseInput(value, &n)) {
            [self alert:@"数值无效" message:@"请输入十六进制数值,如 0x1234。"];
            return;
        }
        NSInteger width = [self.mod[@"width"] integerValue];
        if (tgt == HOOK_TGT_BARE_REG && width != 32 && width != 64) {
            [self alert:@"位宽无效"
                message:@"改寄存器时位宽只能选 32 或 64 位。"];
            return;
        }
        if (width < 64) {
            unsigned long long limit = (width >= 64) ? ~0ULL : ((1ULL << width) - 1);
            if (n > limit) {
                [self alert:@"数值超出范围"
                    message:[NSString stringWithFormat:@"数值超出 %ld 位能表示的范围。",
                             (long)width]];
                return;
            }
        }
    } else { /* string */
        NSUInteger bytes = [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        if (bytes + 1 > 256) {
            [self alert:@"字符串过长" message:@"字符串(含结尾 0)不能超过 256 字节。"];
            return;
        }
    }

    self.mod[@"expr"] = expr;
    if (self.onDone) self.onDone();
    [self.navigationController popViewControllerAnimated:YES];
}

@end
