/* 触发条件的期望值解析:引擎 load_trigger(从 engine.m 提取)必须按
 * 「bytes = 按内存顺序的十六进制串」的约定解析,并拒掉所有写坏的写法。 */
#import <Foundation/Foundation.h>

#include "config.h"   /* TraceSpec / TrigMatch */

/* 引擎里那几个函数(构建时由脚本从 engine.m 原样提取) */
#include "engine_trigger.inc"

/* 纯比较逻辑,从 qbdi_trace.c 原样提取 */
#include "trig_compare.inc"

static int g_fail = 0;

/* 期望解析成功,且字节内容与 want 一致 */
static void ok_bytes(NSString *value, const char *want, int wantN) {
    TraceSpec t;
    memset(&t, 0, sizeof(t));
    char err[96] = "";
    NSDictionary *it = @{ @"triggerExpr": @"[x2+0x10]",
                          @"triggerMatch": @"bytes",
                          @"triggerValue": value };
    if (!load_trigger(it, &t, err, sizeof(err))) {
        printf("FAIL \"%s\" 应当接受,却被拒:%s\n", [value UTF8String], err);
        g_fail++;
        return;
    }
    if (t.trigger_match != TRIG_BYTES) {
        printf("FAIL \"%s\" match 类型错:%d\n", [value UTF8String], t.trigger_match);
        g_fail++;
        return;
    }
    if (t.want_nbytes != wantN || memcmp(t.want_bytes, want, (size_t)wantN) != 0) {
        printf("FAIL \"%s\" 字节不对:得到 %d 字节 [", [value UTF8String], t.want_nbytes);
        for (int i = 0; i < t.want_nbytes; i++) printf("%02x", t.want_bytes[i]);
        printf("], 期望 %d 字节 [", wantN);
        for (int i = 0; i < wantN; i++) printf("%02x", (unsigned char)want[i]);
        printf("]\n");
        g_fail++;
        return;
    }
    printf("ok   bytes \"%s\" → %d 字节 [", [value UTF8String], t.want_nbytes);
    for (int i = 0; i < t.want_nbytes; i++) printf("%02x", t.want_bytes[i]);
    printf("]\n");
}

static void reject(NSString *match, NSString *value) {
    TraceSpec t;
    memset(&t, 0, sizeof(t));
    char err[96] = "";
    NSDictionary *it = @{ @"triggerExpr": @"[x2+0x10]",
                          @"triggerMatch": match,
                          @"triggerValue": value };
    if (load_trigger(it, &t, err, sizeof(err))) {
        printf("FAIL %s \"%s\" 应当被拒,却接受了\n", [match UTF8String],
               [value UTF8String]);
        g_fail++;
        return;
    }
    printf("ok   拒绝 %s \"%s\":%s\n", [match UTF8String], [value UTF8String], err);
}


/* 解析出一条 spec(失败则 g_fail++ 并返回 false) */
static bool build(NSDictionary *it, TraceSpec *t, const char *what) {
    memset(t, 0, sizeof(*t));
    char err[96] = "";
    if (!load_trigger(it, t, err, sizeof(err))) {
        printf("FAIL %s 应当接受,却被拒:%s\n", what, err);
        g_fail++;
        return false;
    }
    return true;
}

static void check_where(NSString *match, NSString *where, TrigWhere want,
                        const char *what) {
    TraceSpec t;
    NSMutableDictionary *it = [@{ @"triggerExpr": @"[x2+0x10]",
                                 @"triggerMatch": match,
                                 @"triggerValue": @"0a0b" } mutableCopy];
    if (where != nil) it[@"triggerWhere"] = where;
    if (![match isEqualToString:@"bytes"]) it[@"triggerValue"] = @"ab";
    if (!build(it, &t, what)) return;
    if (t.trigger_where != want) {
        printf("FAIL %s: where = %d, 期望 %d\n", what, t.trigger_where, want);
        g_fail++;
        return;
    }
    printf("ok   %s → %s\n", what,
           want == TRIG_AT_CONTAINS ? "contains" : "prefix");
}

/* 纯比较逻辑(从 qbdi_trace.c 提取),data 是"已经读到的数据" */
static void check_cmp(TrigMatch m, TrigWhere w, NSString *value,
                      const char *data, size_t n, bool want) {
    TraceSpec t;
    NSDictionary *it = @{ @"triggerExpr": @"[x0]",
                          @"triggerMatch": (m == TRIG_BYTES ? @"bytes" : @"cstr"),
                          @"triggerWhere": (w == TRIG_AT_CONTAINS ? @"contains"
                                                                  : @"prefix"),
                          @"triggerValue": value };
    if (!build(it, &t, [value UTF8String])) return;
    bool got = trig_compare(&t, (const unsigned char *)data, n);
    if (got != want) {
        printf("FAIL compare %s %s \"%s\" vs %zu 字节: 得到 %s, 期望 %s\n",
               m == TRIG_BYTES ? "bytes" : "cstr",
               w == TRIG_AT_CONTAINS ? "contains" : "prefix",
               [value UTF8String], n, got ? "命中" : "不命中",
               want ? "命中" : "不命中");
        g_fail++;
        return;
    }
    printf("ok   compare %s %-8s \"%s\" → %s\n",
           m == TRIG_BYTES ? "bytes" : "cstr",
           w == TRIG_AT_CONTAINS ? "contains" : "prefix",
           [value UTF8String], got ? "命中" : "不命中");
}

static void check_trigger_address(NSString *address, bool want,
                                  uint64_t expected, const char *what) {
    TraceSpec t;
    memset(&t, 0, sizeof(t));
    t.static_start = 0x1000;
    t.static_end = 0x2000;
    char err[160] = "";
    NSMutableDictionary *it = [@{ @"triggerExpr": @"[x0]" } mutableCopy];
    if (address != nil) it[@"triggerAddress"] = address;
    bool got = load_trigger(it, &t, err, sizeof(err));
    if (got != want || (got && t.trigger_address != expected)) {
        printf("FAIL %s: got=%d address=0x%llx err=%s\n", what, got,
               (unsigned long long)t.trigger_address, err);
        g_fail++;
        return;
    }
    printf("ok   %s%s\n", what, got ? "" : " (已拒绝)");
}

int main(void) {
    @autoreleasepool {
        puts("-- bytes:按内存顺序,和 hexdump 里看到的一致 --");
        /* 用户 case:[x2+0x10] 指向的内存前几个字节是 08 a4 8c 90 81 04 10 02 */
        ok_bytes(@"08a48c90", "\x08\xa4\x8c\x90", 4);
        ok_bytes(@"08 a4 8c 90", "\x08\xa4\x8c\x90", 4);
        ok_bytes(@"08:a4,8c 90", "\x08\xa4\x8c\x90", 4);
        ok_bytes(@"08A48C90", "\x08\xa4\x8c\x90", 4);
        ok_bytes(@"08a48c9081041002", "\x08\xa4\x8c\x90\x81\x04\x10\x02", 8);
        ok_bytes(@"00", "\x00", 1);

        puts("\n-- bytes:写坏的都要拒 --");
        reject(@"bytes", @"08a48c9");     /* 奇数位 */
        reject(@"bytes", @"08a48cg0");    /* 非 hex */
        reject(@"bytes", @"");            /* 空 */
        reject(@"bytes", @"   ");         /* 全是分隔符 */
        reject(@"bytes", @"0x08a4");      /* 别写 0x 前缀:x 不是 hex 字符 */
        /* 33 字节,超上限 */
        reject(@"bytes", [@"" stringByPaddingToLength:66 withString:@"ab" startingAtIndex:0]);

        puts("\n-- 其它匹配方式 --");
        {
            TraceSpec t; memset(&t, 0, sizeof(t)); char err[96] = "";
            NSDictionary *it = @{ @"triggerExpr": @"[x2+0x10]",
                                  @"triggerMatch": @"u64",
                                  @"triggerValue": @"0x02100481908ca408" };
            if (load_trigger(it, &t, err, sizeof(err)) &&
                t.trigger_match == TRIG_U64 &&
                t.want_u64 == 0x02100481908ca408ULL) {
                printf("ok   u64 0x%llx\n", (unsigned long long)t.want_u64);
            } else {
                printf("FAIL u64 解析:%s (got 0x%llx)\n", err,
                       (unsigned long long)t.want_u64);
                g_fail++;
            }
        }
        {
            TraceSpec t; memset(&t, 0, sizeof(t)); char err[96] = "";
            NSDictionary *it = @{ @"triggerExpr": @"[x0]",
                                  @"triggerMatch": @"cstr",
                                  @"triggerValue": @"https://" };
            if (load_trigger(it, &t, err, sizeof(err)) &&
                t.trigger_match == TRIG_CSTR && t.want_nbytes == 8 &&
                memcmp(t.want_bytes, "https://", 8) == 0) {
                puts("ok   cstr \"https://\"");
            } else {
                printf("FAIL cstr 解析:%s\n", err);
                g_fail++;
            }
        }
        {
            /* 没配表达式 = 无条件,不能报错 */
            TraceSpec t; memset(&t, 0, sizeof(t)); char err[96] = "";
            if (load_trigger(@{}, &t, err, sizeof(err)) &&
                t.trigger_match == TRIG_NONE && t.trigger_expr == NULL) {
                puts("ok   没配 triggerExpr → 无条件");
            } else {
                printf("FAIL 空配置应当是无条件:%s\n", err);
                g_fail++;
            }
        }
        {
            /* 只配表达式、不配 match → 默认 notnull */
            TraceSpec t; memset(&t, 0, sizeof(t)); char err[96] = "";
            if (load_trigger(@{ @"triggerExpr": @"[x2+0x10]" }, &t, err, sizeof(err)) &&
                t.trigger_match == TRIG_NOTNULL) {
                puts("ok   只配表达式 → 默认 notnull");
            } else {
                printf("FAIL 默认 match 应当是 notnull:%s\n", err);
                g_fail++;
            }
        }
        reject(@"bogus", @"x");            /* 未知匹配方式 */

        puts("\n-- 自定义判断地址 --");
        check_trigger_address(nil, true, 0x1000, "缺省 = start");
        check_trigger_address(@"0x1000", true, 0x1000, "等于 start");
        check_trigger_address(@"0xfe0", true, 0xfe0, "低于 start 且间隔足够");
        check_trigger_address(@"0xff8", false, 0, "低于 start 但补丁重叠");
        check_trigger_address(@"0x1800", false, 0, "落在 trace 区间内");
        check_trigger_address(@"0x2000", true, 0x2000, "等于 end");
        check_trigger_address(@"0x2400", true, 0x2400, "高于 end");
        check_trigger_address(@"0x12zz", false, 0, "含非法字符");
        {
            TraceSpec t; char err[96] = "";
            memset(&t, 0, sizeof(t));
            NSDictionary *it = @{ @"triggerExpr": @"[x0]", @"triggerMatch": @"bytes",
                                  @"triggerWhere": @"somewhere",
                                  @"triggerValue": @"0102" };
            if (!load_trigger(it, &t, err, sizeof(err))) {
                printf("ok   拒绝未知 triggerWhere:%s\n", err);
            } else {
                puts("FAIL 未知 triggerWhere 应当被拒");
                g_fail++;
            }
        }

        puts("\n-- 表达式语法错要连带拒掉整条 --");
        {
            TraceSpec t; memset(&t, 0, sizeof(t)); char err[96] = "";
            NSDictionary *it = @{ @"triggerExpr": @"[[x2+8" };
            if (!load_trigger(it, &t, err, sizeof(err))) {
                printf("ok   拒绝坏表达式:%s\n", err);
            } else {
                puts("FAIL 坏表达式应当被拒");
                g_fail++;
            }
        }

        puts("\n-- 匹配位置的缺省值:字符串=包含,字节=开头 --");
        check_where(@"cstr", nil, TRIG_AT_CONTAINS, "cstr 不指定 where");
        check_where(@"bytes", nil, TRIG_AT_PREFIX, "bytes 不指定 where");
        check_where(@"cstr", @"prefix", TRIG_AT_PREFIX, "cstr 显式 prefix");
        check_where(@"bytes", @"contains", TRIG_AT_CONTAINS, "bytes 显式 contains");

        puts("\n-- 窗口不能比要找的东西还短 --");
        {
            TraceSpec t; char err[96] = "";
            NSDictionary *it = @{ @"triggerExpr": @"[x0]", @"triggerMatch": @"bytes",
                                  @"triggerWhere": @"contains",
                                  @"triggerValue": @"0102030405060708",  /* 8 字节 */
                                  @"triggerScan": @"0x4" };              /* 只读 4 */
            memset(&t, 0, sizeof(t));
            if (!load_trigger(it, &t, err, sizeof(err))) {
                printf("ok   拒绝 scan(0x4) < needle(8):%s\n", err);
            } else {
                puts("FAIL 窗口比 needle 短时应当被拒");
                g_fail++;
            }
        }
        {
            TraceSpec t; char err[96] = "";
            NSDictionary *it = @{ @"triggerExpr": @"[x0]", @"triggerMatch": @"bytes",
                                  @"triggerWhere": @"contains",
                                  @"triggerValue": @"0102",
                                  @"triggerScan": @"0x10000" };  /* 超上限 */
            memset(&t, 0, sizeof(t));
            if (!load_trigger(it, &t, err, sizeof(err))) {
                printf("ok   拒绝超上限的 scan:%s\n", err);
            } else {
                puts("FAIL scan 超 TRIG_MAX_SCAN 应当被拒");
                g_fail++;
            }
        }
        {
            /* scan 缺省 = TRIG_DEF_SCAN */
            TraceSpec t;
            if (build(@{ @"triggerExpr": @"[x0]", @"triggerMatch": @"cstr",
                         @"triggerValue": @"api" }, &t, "cstr 默认 scan") &&
                t.trigger_scan == TRIG_DEF_SCAN) {
                printf("ok   scan 缺省 = 0x%x\n", t.trigger_scan);
            } else {
                printf("FAIL scan 缺省应当是 0x%x,得到 0x%x\n", TRIG_DEF_SCAN,
                       t.trigger_scan);
                g_fail++;
            }
        }

        puts("\n-- 纯比较:开头 vs 包含 --");
        /* 用户的 case:内存里是 08 a4 8c 90 81 04 ... */
        check_cmp(TRIG_BYTES, TRIG_AT_PREFIX, @"08a48c90",
                  "\x08\xa4\x8c\x90\x81\x04", 6, true);
        check_cmp(TRIG_BYTES, TRIG_AT_PREFIX, @"a48c90",
                  "\x08\xa4\x8c\x90\x81\x04", 6, false); /* 不在开头 */
        check_cmp(TRIG_BYTES, TRIG_AT_CONTAINS, @"a48c90",
                  "\x08\xa4\x8c\x90\x81\x04", 6, true);  /* 但被包含 */
        check_cmp(TRIG_BYTES, TRIG_AT_CONTAINS, @"8104",
                  "\x08\xa4\x8c\x90\x81\x04", 6, true);  /* 结尾也算包含 */
        check_cmp(TRIG_BYTES, TRIG_AT_CONTAINS, @"81040a",
                  "\x08\xa4\x8c\x90\x81\x04", 6, false); /* 越界不算 */
        check_cmp(TRIG_BYTES, TRIG_AT_PREFIX, @"08a48c90",
                  "\x08\xa4", 2, false);                   /* 读到的比期望短 */

        puts("\n-- 纯比较:字符串 --");
        check_cmp(TRIG_CSTR, TRIG_AT_CONTAINS, @"api",
                  "https://x.com/api/v2", 20, true);
        check_cmp(TRIG_CSTR, TRIG_AT_PREFIX, @"api",
                  "https://x.com/api/v2", 20, false);
        check_cmp(TRIG_CSTR, TRIG_AT_PREFIX, @"https://",
                  "https://x.com/api/v2", 20, true);
        check_cmp(TRIG_CSTR, TRIG_AT_CONTAINS, @"zzz",
                  "https://x.com/api/v2", 20, false);

        printf("\n%s\n", g_fail == 0 ? "ALL PASS" : "SOME FAILED");
    }
    return g_fail != 0;
}
