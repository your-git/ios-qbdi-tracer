#import <UIKit/UIKit.h>

/* 取址表达式的输入与校验,供 WatchEditVC(监视取址)和 TraceEditVC(触发条件)共用。
 *
 * 文法与引擎 Engine/src/watch_expr.c 一致:
 *   expr := term (('+' | '-') term)*
 *   term := ['-'] 十六进制常量 | 寄存器 | '[' expr ']'
 * 两边任一改了文法,另一边要跟着改,并跑 ./scripts/test_watch_expr.sh 交叉验证。 */

/* 语法是否合法(只查 token/括号/嵌套/长度,不求值) */
BOOL ExprSyntaxOK(NSString *src);

/* 表达式里的第一个寄存器名(规范化后,x29→fp、x30→lr);语法非法返回 nil */
NSString *ExprBaseReg(NSString *src);

/* 弹出「输入取址表达式」对话框:带寄存器/[]/0x 快捷栏,语法不对就标红并禁用「确定」。
 * 点确定 → onOK(表达式);取消 → 不回调。 */
void ExprPrompt(UIViewController *host, NSString *initial,
                void (^onOK)(NSString *expr));
