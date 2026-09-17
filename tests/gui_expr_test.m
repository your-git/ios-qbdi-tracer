/* 交叉测试:GUI 的轻量校验(从 ExprInput.m 原文提取)必须和引擎 wexpr_compile
 * 对同一批输入给出相同的接受/拒绝结论。size 的进制规则见 size_rule_test.m。 */
#import <Foundation/Foundation.h>

#include "watch_expr.h"

/* 从 GUI/src/ExprInput.m 提取的真实源码片段(构建时由脚本生成,不是复制) */
#include "expr_extract.inc"

static int g_fail = 0;

static void check_same(NSString *src) {
    WatchExpr e;
    char err[96];
    BOOL engine = wexpr_compile([src UTF8String], &e, err, sizeof(err)) ? YES : NO;
    BOOL gui = ExprSyntaxOK(src);
    if (engine != gui) {
        printf("FAIL 判断不一致 \"%s\": 引擎=%s GUI=%s (引擎说:%s)\n",
               [src UTF8String], engine ? "接受" : "拒绝", gui ? "接受" : "拒绝",
               engine ? "-" : err);
        g_fail++;
        return;
    }
    /* 接受的情况下,基寄存器也要对上 */
    if (engine) {
        const char *eb = wexpr_base_reg(&e);
        NSString *gb = ExprBaseReg(src);
        if ((eb == NULL) != (gb == nil) ||
            (eb != NULL && ![gb isEqualToString:@(eb)])) {
            printf("FAIL 基寄存器不一致 \"%s\": 引擎=%s GUI=%s\n", [src UTF8String],
                   eb ? eb : "(nil)", gb ? [gb UTF8String] : "(nil)");
            g_fail++;
            return;
        }
        printf("ok   %-26s 都接受 base=%s\n", [src UTF8String], eb ? eb : "-");
    } else {
        printf("ok   %-26s 都拒绝\n", [src UTF8String]);
    }
}

int main(void) {
    @autoreleasepool {
        puts("-- GUI 校验 vs 引擎 parser --");
        NSArray *cases = @[
            @"x0", @"X0", @"x28", @"sp", @"fp", @"pc", @"x29", @"x30",
            @"x0-0x110", @"x0-110", @"x0+10", @" x0 + 0x10 ", @"x0+x1",
            @"x0+-8", @"x0+8-8", @"[sp]", @"[x0+8]", @"[[x0+8]+0x10]",
            @"[[x0+8]+0x10]-4", @"[ [ x0 + 8 ] + 10 ] - 4", @"[x0]",
            @"0x10", @"10", @"[0x100000]", @"[[sp+8]]",
            /* 以下都该被拒 */
            @"", @"   ", @"[[x0+8", @"x0+", @"x0++8", @"]x0[", @"x31", @"x1a",
            @"w0", @"-x0", @"x0 8", @"[[[[[[[[[x0]]]]]]]]]",
            @"x0+1+2+3+4+5+6+7+8+9+a+b+c+d+e+f+1+2", @"$x0", @"x0*2", @"0x",
            @"x0]", @"[x0]]", @"x0-", @"[]", @"fpx", @"spa", @"x", @"lr+",
        ];
        for (NSString *s in cases) check_same(s);

        printf("\n%s\n", g_fail == 0 ? "ALL PASS" : "SOME FAILED");
    }
    return g_fail != 0;
}
