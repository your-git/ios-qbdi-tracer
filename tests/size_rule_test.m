/* 交叉测试:引擎 parse_size(从 engine.m 提取) 与 GUI HexValueFromJSON
 * (从 HexValue.m 提取) 必须对同一份 JSON 值给出相同结果。 */
#import <Foundation/Foundation.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

#include "engine_size.inc"  /* 引擎的 parse_size */
#include "gui_size.inc"     /* GUI 的 HexValueFromJSON / HexParseInput / HexDisplay */

static int g_fail = 0;

static void both(id v, unsigned long long want) {
    unsigned long long eng = parse_size(v);
    unsigned long long gui = HexValueFromJSON(v);
    if (eng != gui) {
        printf("FAIL 引擎/GUI 不一致 %s: 引擎=%llu GUI=%llu\n",
               [[v description] UTF8String], eng, gui);
        g_fail++;
        return;
    }
    if (eng != want) {
        printf("FAIL %s = %llu, 期望 %llu\n", [[v description] UTF8String], eng, want);
        g_fail++;
        return;
    }
    printf("ok   %-12s → %llu (两边一致)\n", [[v description] UTF8String], eng);
}


static void check_input(NSString *text, BOOL wantOK, unsigned long long want) {
    unsigned long long got = 0;
    BOOL ok = HexParseInput(text, &got);
    if (ok != wantOK || (ok && got != want)) {
        printf("FAIL HexParseInput(\"%s\") = %s/%llu, 期望 %s/%llu\n",
               [text UTF8String], ok ? "OK" : "NO", got, wantOK ? "OK" : "NO", want);
        g_fail++;
        return;
    }
    printf("ok   输入 \"%s\" → %s%llu\n", [text UTF8String], ok ? "" : "拒绝 ", got);
}

/* 旧值经过"显示 → 再解析"一轮之后不能变 */
static void check_roundtrip(id v, unsigned long long want) {
    NSString *shown = HexDisplay(v);
    unsigned long long back = 0;
    HexParseInput(shown, &back);
    if (back != want) {
        printf("FAIL 往返:%s → %s → %llu, 期望 %llu\n",
               [[v description] UTF8String], [shown UTF8String], back, want);
        g_fail++;
        return;
    }
    printf("ok   往返:%s → %s → %llu\n", [[v description] UTF8String],
           [shown UTF8String], back);
}

int main(void) {
    @autoreleasepool {
        puts("-- 旧配置(NSNumber,十进制) --");
        both(@0, 0);
        both(@64, 64);
        both(@272, 272);
        both(@4096, 4096);

        puts("\n-- 新配置(字符串带 0x = 十六进制) --");
        both(@"0x0", 0);
        both(@"0x10", 16);
        both(@"0x110", 272);
        both(@"0xffff", 65535);
        both(@"0X110", 272);

        puts("\n-- 手写、无前缀字符串 = 十进制 --");
        both(@"0", 0);
        both(@"10", 10);
        both(@"110", 110);
        both(@"272", 272);

        puts("\n-- 边角 --");
        both(@"", 0);
        both(@" 0x10", 16);   /* 前导空格 */
        both((id)[NSNull null], 0);
        both(@{}, 0);

        puts("\n-- size 输入框:一律按十六进制 --");
        check_input(@"10", YES, 0x10);
        check_input(@"0x10", YES, 0x10);
        check_input(@"110", YES, 0x110);
        check_input(@"ff", YES, 0xff);
        check_input(@"", YES, 0);
        check_input(@"0", YES, 0);
        check_input(@"zz", NO, 0);
        check_input(@"0xzz", NO, 0);
        check_input(@"12345678901234567", NO, 0); /* 超 64 位 */

        puts("\n-- 旧配置的值不能被改坏 --");
        check_roundtrip(@272, 272);      /* 旧版十进制 NSNumber */
        check_roundtrip(@"100", 100);    /* 无前缀字符串 = 十进制 */
        check_roundtrip(@"0x110", 272);

        printf("\n%s\n", g_fail == 0 ? "ALL PASS" : "SOME FAILED");
    }
    return g_fail != 0;
}
