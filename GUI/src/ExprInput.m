#import "ExprInput.h"
#import <objc/runtime.h>

/* 文法与引擎 Engine/src/watch_expr.c 一致:
 *   expr := term (('+' | '-') term)*
 *   term := ['-'] 十六进制常量 | 寄存器 | '[' expr ']'
 * 这里只查 token/括号/嵌套/长度,不求值 —— 目的是让用户在弹窗里当场知道写错了,
 * 而不是装到设备上才从日志里发现。引擎侧 wexpr_compile 才是权威(加载期会报错进日志)。
 * 两边任一改了文法,另一边要跟着改。 */

#define EXPR_MAX_DEPTH 8  /* 同 WEXPR_MAX_DEPTH */
#define EXPR_MAX_OPS   24 /* 同 WEXPR_MAX_OPS */

static BOOL IsHexChar(char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
}
static BOOL IsAlnumChar(char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z');
}

/* 在 p(已转小写)处尝试匹配寄存器名;成功返回规范名并写回长度,失败返回 nil */
static NSString *ExprMatchReg(const char *p, size_t *len) {
    if (p[0] == 'x' && p[1] >= '0' && p[1] <= '9') {
        int    n = p[1] - '0';
        size_t l = 2;
        if (p[2] >= '0' && p[2] <= '9') {
            n = n * 10 + (p[2] - '0');
            l = 3;
        }
        if (n > 30 || IsAlnumChar(p[l])) return nil; /* x31/x1a 都算写错 */
        *len = l;
        if (n == 29) return @"fp"; /* x29/x30 是 fp/lr 的别名 */
        if (n == 30) return @"lr";
        return [NSString stringWithFormat:@"x%d", n];
    }
    static const char *const two[] = { "fp", "lr", "sp", "pc" };
    for (size_t i = 0; i < sizeof(two) / sizeof(two[0]); i++) {
        if (p[0] == two[i][0] && p[1] == two[i][1] && !IsAlnumChar(p[2])) {
            *len = 2;
            return @(two[i]);
        }
    }
    return nil;
}

/* 扫一遍表达式。语法正确返回 YES;baseReg 非 NULL 时写回第一个寄存器名。 */
static BOOL ExprScan(NSString *src, NSString **baseReg) {
    if (baseReg != NULL) *baseReg = nil;
    const char *p = [[src lowercaseString] UTF8String];
    if (p == NULL || *p == '\0') return NO;

    int  depth = 0, nops = 0;
    BOOL expectTerm = YES;
    while (*p != '\0') {
        if (*p == ' ' || *p == '\t') { p++; continue; }
        if (expectTerm) {
            if (*p == '[') {
                if (++depth > EXPR_MAX_DEPTH) return NO;
                p++;
                continue; /* 下一个仍应是 term */
            }
            BOOL neg = NO;
            if (*p == '-') { /* 一元负号只对常量有意义 */
                neg = YES;
                p++;
                while (*p == ' ' || *p == '\t') p++;
                if (*p == '\0') return NO;
            }
            if (!neg) {
                size_t rlen = 0;
                NSString *r = ExprMatchReg(p, &rlen);
                if (r != nil) {
                    if (baseReg != NULL && *baseReg == nil) *baseReg = r;
                    p += rlen;
                    expectTerm = NO;
                    if (++nops > EXPR_MAX_OPS) return NO;
                    continue;
                }
            }
            size_t j = 0;
            if (p[0] == '0' && p[1] == 'x') j = 2;
            if (!IsHexChar(p[j])) return NO;
            size_t start = j;
            while (IsHexChar(p[j])) {
                if (j - start >= 16) return NO; /* 超过 64 位 */
                j++;
            }
            p += j;
            expectTerm = NO;
            if (++nops > EXPR_MAX_OPS) return NO;
            continue;
        }
        if (*p == ']') {
            if (depth == 0) return NO;
            depth--;
            p++;
            if (++nops > EXPR_MAX_OPS) return NO; /* 解引用也占一个 op */
            continue;
        }
        if (*p == '+' || *p == '-') {
            p++;
            expectTerm = YES;
            if (++nops > EXPR_MAX_OPS) return NO;
            continue;
        }
        return NO;
    }
    return depth == 0 && !expectTerm;
}

BOOL ExprSyntaxOK(NSString *src) {
    return ExprScan(src, NULL);
}

NSString *ExprBaseReg(NSString *src) {
    NSString *r = nil;
    return ExprScan(src, &r) ? r : nil;
}

#pragma mark - 输入弹窗

/* 弹窗的状态载体(输入框和「确定」按钮都归 alert 持有,这个对象挂在 alert 上陪它一起活) */
@interface ExprPromptCtl : NSObject
@property (nonatomic, weak) UITextField *field;
@property (nonatomic, weak) UIAlertAction *ok;
@end

@implementation ExprPromptCtl

/* 语法不对就标红 + 禁用「确定」,当场看得见,不用等装到设备上翻日志 */
- (void)fieldChanged:(UITextField *)tf {
    BOOL okNow = ExprSyntaxOK(tf.text);
    self.ok.enabled = okNow;
    tf.textColor = (tf.text.length == 0 || okNow) ? [UIColor labelColor]
                                                  : [UIColor systemRedColor];
}

/* iOS 的 ASCII 键盘打 [ ] 0x 要切好几次键盘,给一条横向滚动的快捷栏 */
- (UIView *)accessoryView {
    CGFloat w = [UIScreen mainScreen].bounds.size.width;
    UIScrollView *bar =
        [[UIScrollView alloc] initWithFrame:CGRectMake(0, 0, w, 44)];
    bar.backgroundColor = [UIColor secondarySystemBackgroundColor];
    bar.showsHorizontalScrollIndicator = NO;
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    NSMutableArray *titles = [NSMutableArray array];
    [titles addObjectsFromArray:@[ @"[ ]", @"+", @"-", @"0x" ]];
    for (int i = 0; i <= 28; i++) {
        [titles addObject:[NSString stringWithFormat:@"x%d", i]];
    }
    [titles addObjectsFromArray:@[ @"fp", @"lr", @"sp", @"pc", @"清空" ]];

    UIFont *f = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightMedium];
    CGFloat x = 8;
    for (NSString *t in titles) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:t forState:UIControlStateNormal];
        b.titleLabel.font = f;
        CGFloat bw = [t sizeWithAttributes:@{ NSFontAttributeName: f }].width + 20;
        if (bw < 36) bw = 36;
        b.frame = CGRectMake(x, 5, bw, 34);
        b.backgroundColor = [UIColor tertiarySystemBackgroundColor];
        b.layer.cornerRadius = 6;
        [b addTarget:self
                      action:@selector(insert:)
            forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:b];
        x += bw + 6;
    }
    bar.contentSize = CGSizeMake(x + 2, 44);
    return bar;
}

- (void)insert:(UIButton *)b {
    UITextField *tf = self.field;
    if (tf == nil) return;
    NSString *t = b.currentTitle;
    if ([t isEqualToString:@"清空"]) {
        tf.text = @"";
    } else if ([t isEqualToString:@"[ ]"]) {
        /* 成对插入,光标停在中间 */
        [tf insertText:@"[]"];
        UITextPosition *p =
            [tf positionFromPosition:tf.selectedTextRange.start offset:-1];
        if (p) tf.selectedTextRange = [tf textRangeFromPosition:p toPosition:p];
    } else {
        [tf insertText:t];
    }
    [self fieldChanged:tf];
}

@end

void ExprPrompt(UIViewController *host, NSString *initial,
                void (^onOK)(NSString *expr)) {
    ExprPromptCtl *ctl = [ExprPromptCtl new];
    UIAlertController *al = [UIAlertController
        alertControllerWithTitle:@"取址表达式"
                         message:@"寄存器 ± 十六进制偏移,[] 表示解引用\n"
                                 @"例:x0-0x110   [x0+0x10]   [[x0+8]+0x10]-4"
                  preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *ok = [UIAlertAction
        actionWithTitle:@"确定"
                  style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *a) {
            NSString *t = [ctl.field.text
                stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceCharacterSet]];
            if (!ExprSyntaxOK(t)) return; /* 按钮本该是禁用的,兜一手 */
            if (onOK) onOK(t);
        }];

    NSString *cur = initial ?: @"";
    [al addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = cur;
        tf.placeholder = @"x0-0x110";
        tf.keyboardType = UIKeyboardTypeASCIICapable;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.spellCheckingType = UITextSpellCheckingTypeNo;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        tf.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
        tf.inputAccessoryView = [ctl accessoryView];
        [tf addTarget:ctl
                      action:@selector(fieldChanged:)
            forControlEvents:UIControlEventEditingChanged];
        ctl.field = tf;
    }];

    ctl.ok = ok;
    ok.enabled = ExprSyntaxOK(cur);
    [al addAction:[UIAlertAction actionWithTitle:@"取消"
                                          style:UIAlertActionStyleCancel
                                        handler:nil]];
    [al addAction:ok];
    /* ctl 得活到弹窗消失为止 */
    objc_setAssociatedObject(al, "exprCtl", ctl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [host presentViewController:al animated:YES completion:nil];
}

#pragma mark - 十六进制地址快捷键盘

@interface HexKeyboardCtl : NSObject
@property (nonatomic, weak) UITextField *field;
@end

@implementation HexKeyboardCtl
- (void)tap:(UIButton *)button {
    UITextField *field = self.field;
    if (field == nil) return;
    NSString *title = button.currentTitle;
    if ([title isEqualToString:@"清空"]) {
        field.text = @"";
    } else if ([title isEqualToString:@"删除"]) {
        [field deleteBackward];
    } else if ([title isEqualToString:@"完成"]) {
        [field resignFirstResponder];
        return;
    } else {
        [field insertText:title];
    }
    [field sendActionsForControlEvents:UIControlEventEditingChanged];
}
@end

void AttachHexKeyboard(UITextField *field) {
    if (field == nil) return;
    HexKeyboardCtl *ctl = [HexKeyboardCtl new];
    ctl.field = field;

    CGFloat width = [UIScreen mainScreen].bounds.size.width;
    UIScrollView *bar =
        [[UIScrollView alloc] initWithFrame:CGRectMake(0, 0, width, 44)];
    bar.backgroundColor = [UIColor secondarySystemBackgroundColor];
    bar.showsHorizontalScrollIndicator = NO;
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    NSArray<NSString *> *titles = @[
        @"0X", @"0", @"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9",
        @"A", @"B", @"C", @"D", @"E", @"F", @"删除", @"清空", @"完成"
    ];
    UIFont *font = [UIFont monospacedSystemFontOfSize:15
                                               weight:UIFontWeightMedium];
    CGFloat x = 8;
    for (NSString *title in titles) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button setTitle:title forState:UIControlStateNormal];
        button.titleLabel.font = font;
        CGFloat buttonWidth =
            [title sizeWithAttributes:@{ NSFontAttributeName: font }].width + 20;
        if (buttonWidth < 36) buttonWidth = 36;
        button.frame = CGRectMake(x, 5, buttonWidth, 34);
        button.backgroundColor = [UIColor tertiarySystemBackgroundColor];
        button.layer.cornerRadius = 6;
        [button addTarget:ctl action:@selector(tap:)
          forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:button];
        x += buttonWidth + 6;
    }
    bar.contentSize = CGSizeMake(x + 2, 44);
    field.inputAccessoryView = bar;
    field.keyboardType = UIKeyboardTypeASCIICapable;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    field.spellCheckingType = UITextSpellCheckingTypeNo;
    /* target 必须和输入框同寿命，否则 accessory 按钮会变成悬空 target。 */
    objc_setAssociatedObject(field, "hexKeyboardCtl", ctl,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
