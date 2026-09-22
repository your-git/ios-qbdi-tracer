/* Hook「修改数据」的纯逻辑测试。被测函数由脚本从 Engine/src/hook.c 和
 * Engine/src/engine.m 原样提取,所以测的永远是真实源码,不会漂移。
 *
 * 重点是那张**不对称写入语义表**(改错就是往错误地址写内存 → 目标 App 崩):
 *   数值 + 裸寄存器 x0   → 改寄存器本身(REG)
 *   数值 + [表达式]      → 改内存(MEM)
 *   字节 + 裸寄存器      → 非法
 *   字节 + [表达式]      → 改内存
 *   字符串 + 裸寄存器 x0 → 改内存(x0 当 char* 首地址)
 *   字符串 + [表达式]    → 改内存 */
#import <Foundation/Foundation.h>

#include <stdio.h>
#include <string.h>

#include "config.h"
#include "hook_pure.inc"   /* hook.c: hex_digit..hook_classify_target */
#include "engine_hook.inc" /* engine.m: parse_int / dup_str / load_hook_mod */

static int g_fail;

#define CHECK(cond, what)                                                      \
    do {                                                                       \
        if (cond) {                                                            \
            printf("ok   %s\n", what);                                         \
        } else {                                                               \
            printf("FAIL %s\n", what);                                         \
            g_fail++;                                                          \
        }                                                                      \
    } while (0)

/* 跑一遍"编码 + 分类",返回是否两步都成功;dst 回写分类结果。 */
static bool classify(HookValType type, uint8_t width, const char *value,
                     const char *expr, HookMod *out) {
    char err[160] = "";
    memset(out, 0, sizeof(*out));
    if (!hook_encode_value(out, type, width, value, err, sizeof(err))) return false;
    return hook_classify_target(out, expr, err, sizeof(err));
}

static void test_outer_bracket(void) {
    puts("\n-- 最外层方括号识别 --");
    char inner[128];
    CHECK(outer_bracket("[x0]", inner, sizeof inner) && strcmp(inner, "x0") == 0,
          "[x0] → x0");
    CHECK(outer_bracket("[x0+0x10]", inner, sizeof inner) &&
              strcmp(inner, "x0+0x10") == 0,
          "[x0+0x10] → x0+0x10");
    CHECK(outer_bracket("[[x0+8]+0x10]", inner, sizeof inner) &&
              strcmp(inner, "[x0+8]+0x10") == 0,
          "嵌套 [[x0+8]+0x10] 只剥一层");
    CHECK(outer_bracket("  [x0]  ", inner, sizeof inner), "容忍首尾空白");
    /* 深度提前归零 = 首 [ 和末 ] 不是配对的最外层,不能当成内存写 */
    CHECK(!outer_bracket("[x0]+[x1]", inner, sizeof inner), "拒绝 [x0]+[x1]");
    CHECK(!outer_bracket("x0", inner, sizeof inner), "拒绝裸 x0");
    CHECK(!outer_bracket("[]", inner, sizeof inner), "拒绝空方括号");
}

static void test_bare_register(void) {
    puts("\n-- 裸寄存器识别 --");
    uint8_t idx = 0xff;
    CHECK(bare_register("x0", &idx) && idx == 0, "x0 → 0");
    CHECK(bare_register("x28", &idx) && idx == 28, "x28 → 28");
    CHECK(bare_register("fp", &idx) && idx == 29, "fp → 29");
    CHECK(bare_register("lr", &idx) && idx == 30, "lr → 30");
    CHECK(bare_register("x29", &idx) && idx == 29, "x29 是 fp 的别名");
    CHECK(bare_register("x30", &idx) && idx == 30, "x30 是 lr 的别名");
    CHECK(bare_register("X0", &idx) && idx == 0, "大小写不敏感");
    /* x17 是 Dobby 的跳板临时寄存器,写它没有意义 */
    CHECK(!bare_register("x17", &idx), "拒绝 x17");
    CHECK(!bare_register("sp", &idx), "拒绝 sp");
    CHECK(!bare_register("pc", &idx), "拒绝 pc");
    CHECK(!bare_register("x31", &idx), "拒绝 x31");
    CHECK(!bare_register("x0+1", &idx), "拒绝 x0+1");
    CHECK(!bare_register("[x0]", &idx), "拒绝 [x0]");
}

static void test_semantics_table(void) {
    puts("\n-- 不对称写入语义表 --");
    HookMod m;
    /* 数值 */
    CHECK(classify(HOOK_VAL_NUMBER, 64, "0x1234", "x0", &m) &&
              m.dst == HOOK_DST_REG && m.reg_index == 0,
          "数值 + 裸寄存器 x0 → 改寄存器");
    CHECK(classify(HOOK_VAL_NUMBER, 64, "0x1234", "lr", &m) &&
              m.dst == HOOK_DST_REG && m.reg_index == 30,
          "数值 + 裸 lr → 改寄存器 30");
    CHECK(classify(HOOK_VAL_NUMBER, 32, "0x1", "[x0]", &m) &&
              m.dst == HOOK_DST_MEM,
          "数值 + [x0] → 改内存");
    /* 字节 */
    CHECK(!classify(HOOK_VAL_BYTES, 0, "08a4", "x0", &m),
          "字节 + 裸寄存器 → 拒绝");
    CHECK(classify(HOOK_VAL_BYTES, 0, "08a4", "[x0+0x10]", &m) &&
              m.dst == HOOK_DST_MEM,
          "字节 + [x0+0x10] → 改内存");
    /* 字符串:裸寄存器当 char* 首地址,仍是内存写 */
    CHECK(classify(HOOK_VAL_STRING, 0, "abc", "x0", &m) &&
              m.dst == HOOK_DST_MEM,
          "字符串 + 裸寄存器 x0 → 改内存(x0 当 char*)");
    CHECK(classify(HOOK_VAL_STRING, 0, "abc", "[x0]", &m) &&
              m.dst == HOOK_DST_MEM,
          "字符串 + [x0] → 改内存");
    /* 既不是裸寄存器也不是 [..] 的一律拒绝 */
    CHECK(!classify(HOOK_VAL_NUMBER, 64, "0x1", "x0+0x10", &m),
          "数值 + x0+0x10(无方括号) → 拒绝");
    CHECK(!classify(HOOK_VAL_NUMBER, 64, "0x1", "", &m), "空表达式 → 拒绝");
}

static void test_encode(void) {
    puts("\n-- 值编码 --");
    HookMod m;
    char err[160];

    /* 字节按**内存顺序**存(与 hexdump 所见一致),分隔符忽略 */
    memset(&m, 0, sizeof m);
    CHECK(hook_encode_value(&m, HOOK_VAL_BYTES, 0, "08 a4:8c,90", err, sizeof err) &&
              m.nbytes == 4 && m.payload[0] == 0x08 && m.payload[1] == 0xa4 &&
              m.payload[2] == 0x8c && m.payload[3] == 0x90,
          "字节按内存顺序,忽略空格/:/,");
    memset(&m, 0, sizeof m);
    CHECK(hook_encode_value(&m, HOOK_VAL_BYTES, 0, "0x08a4", err, sizeof err) &&
              m.nbytes == 2 && m.payload[0] == 0x08,
          "字节容忍 0x 前缀");

    /* 字符串:UTF-8 + 一个 0 结尾 */
    memset(&m, 0, sizeof m);
    CHECK(hook_encode_value(&m, HOOK_VAL_STRING, 0, "abc", err, sizeof err) &&
              m.nbytes == 4 && memcmp(m.payload, "abc\0", 4) == 0,
          "字符串补 00 结尾");
    memset(&m, 0, sizeof m);
    CHECK(hook_encode_value(&m, HOOK_VAL_STRING, 0, "", err, sizeof err) &&
              m.nbytes == 1 && m.payload[0] == 0,
          "空字符串 = 只写一个 00(截断)");

    /* 数值按 width 小端 */
    memset(&m, 0, sizeof m);
    CHECK(hook_encode_value(&m, HOOK_VAL_NUMBER, 32, "0x11223344", err, sizeof err) &&
              m.nbytes == 4 && m.payload[0] == 0x44 && m.payload[3] == 0x11 &&
              m.number == 0x11223344ULL,
          "数值 32 位小端");
    memset(&m, 0, sizeof m);
    CHECK(hook_encode_value(&m, HOOK_VAL_NUMBER, 8, "0xff", err, sizeof err) &&
              m.nbytes == 1 && m.payload[0] == 0xff,
          "数值 8 位");
    memset(&m, 0, sizeof m);
    CHECK(hook_encode_value(&m, HOOK_VAL_NUMBER, 64, "0x1122334455667788", err,
                            sizeof err) &&
              m.nbytes == 8 && m.payload[0] == 0x88 && m.payload[7] == 0x11,
          "数值 64 位小端");
}

static void test_reject(void) {
    puts("\n-- 非法输入必须被拒 --");
    HookMod m;
    char err[160];
#define REJECT(call, what)                                                     \
    do {                                                                       \
        memset(&m, 0, sizeof m);                                               \
        err[0] = '\0';                                                         \
        if (call) {                                                            \
            printf("FAIL %s 应当被拒\n", what);                                \
            g_fail++;                                                          \
        } else {                                                               \
            printf("ok   拒绝 %s: %s\n", what, err);                           \
        }                                                                      \
    } while (0)

    REJECT(hook_encode_value(&m, HOOK_VAL_BYTES, 0, "08a", err, sizeof err),
           "字节奇数个十六进制位");
    REJECT(hook_encode_value(&m, HOOK_VAL_BYTES, 0, "08zz", err, sizeof err),
           "字节含非十六进制字符");
    REJECT(hook_encode_value(&m, HOOK_VAL_BYTES, 0, "", err, sizeof err),
           "字节内容为空");
    REJECT(hook_encode_value(&m, HOOK_VAL_NUMBER, 8, "0x100", err, sizeof err),
           "数值 0x100 装不进 8 位");
    REJECT(hook_encode_value(&m, HOOK_VAL_NUMBER, 16, "0x10000", err, sizeof err),
           "数值 0x10000 装不进 16 位");
    REJECT(hook_encode_value(&m, HOOK_VAL_NUMBER, 24, "0x1", err, sizeof err),
           "位宽 24 不合法");
    REJECT(hook_encode_value(&m, HOOK_VAL_NUMBER, 64, "zz", err, sizeof err),
           "数值不是十六进制");
#undef REJECT
}

static void test_limits(void) {
    puts("\n-- 256 字节上限边界 --");
    HookMod m;
    char err[160];
    char hex512[520], hex514[520], str255[300], str256[300];
    memset(hex512, 'a', 512); hex512[512] = '\0'; /* 256 字节 */
    memset(hex514, 'a', 514); hex514[514] = '\0'; /* 257 字节 */
    memset(str255, 'a', 255); str255[255] = '\0'; /* +结尾0 = 256 */
    memset(str256, 'a', 256); str256[256] = '\0'; /* +结尾0 = 257 */

    memset(&m, 0, sizeof m);
    CHECK(hook_encode_value(&m, HOOK_VAL_BYTES, 0, hex512, err, sizeof err) &&
              m.nbytes == 256,
          "字节 256 = 上限,接受");
    memset(&m, 0, sizeof m);
    CHECK(!hook_encode_value(&m, HOOK_VAL_BYTES, 0, hex514, err, sizeof err),
          "字节 257 超限,拒绝");
    memset(&m, 0, sizeof m);
    CHECK(hook_encode_value(&m, HOOK_VAL_STRING, 0, str255, err, sizeof err) &&
              m.nbytes == 256,
          "字符串 255+结尾0 = 256,接受");
    memset(&m, 0, sizeof m);
    CHECK(!hook_encode_value(&m, HOOK_VAL_STRING, 0, str256, err, sizeof err),
          "字符串 256+结尾0 = 257,拒绝");
}

/* 配置层:load_hook_mod 从 JSON 字典解析,比纯函数多一层类型/位宽规则 */
static void test_load_mod(void) {
    puts("\n-- load_hook_mod(配置层) --");
    HookMod m;
    char err[160];

    memset(&m, 0, sizeof m); err[0] = '\0';
    CHECK(load_hook_mod(@{ @"type": @"number", @"width": @64,
                           @"expr": @"x0", @"value": @"0x1" },
                        &m, err, sizeof err) &&
              m.dst == HOOK_DST_REG,
          "数值 64 位 + x0 → REG");

    memset(&m, 0, sizeof m); err[0] = '\0';
    CHECK(load_hook_mod(@{ @"type": @"bytes", @"expr": @"[x0]",
                           @"value": @"08a4" },
                        &m, err, sizeof err) &&
              m.dst == HOOK_DST_MEM && m.nbytes == 2,
          "字节 + [x0] → MEM");

    /* ARM64 没有 8/16 位寄存器写法,改寄存器只能 32/64 */
    memset(&m, 0, sizeof m); err[0] = '\0';
    CHECK(!load_hook_mod(@{ @"type": @"number", @"width": @8,
                            @"expr": @"x0", @"value": @"0x1" },
                         &m, err, sizeof err),
          "数值 8 位 + 裸寄存器 → 拒绝(寄存器只能 32/64)");
    /* 但 8 位写内存是合法的 */
    memset(&m, 0, sizeof m); err[0] = '\0';
    CHECK(load_hook_mod(@{ @"type": @"number", @"width": @8,
                           @"expr": @"[x0]", @"value": @"0x1" },
                        &m, err, sizeof err) &&
              m.nbytes == 1,
          "数值 8 位 + [x0] → 允许(内存写)");

    /* 「读取数据」还在研发中,不该出现在配置里 */
    memset(&m, 0, sizeof m); err[0] = '\0';
    CHECK(!load_hook_mod(@{ @"kind": @"read", @"type": @"number",
                            @"expr": @"x0", @"value": @"0x1" },
                         &m, err, sizeof err),
          "kind=read → 拒绝(功能未实现)");

    memset(&m, 0, sizeof m); err[0] = '\0';
    CHECK(!load_hook_mod(@{ @"type": @"bogus", @"expr": @"x0", @"value": @"0x1" },
                         &m, err, sizeof err),
          "未知 type → 拒绝");

    memset(&m, 0, sizeof m); err[0] = '\0';
    CHECK(!load_hook_mod(@{ @"type": @"bytes", @"expr": @"x0", @"value": @"08a4" },
                         &m, err, sizeof err),
          "字节 + 裸寄存器 → 拒绝");

    /* width 缺省应为 64 */
    memset(&m, 0, sizeof m); err[0] = '\0';
    CHECK(load_hook_mod(@{ @"type": @"number", @"expr": @"x0", @"value": @"0x1" },
                        &m, err, sizeof err) &&
              m.width == 64,
          "number 缺省 width = 64");
}

int main(void) {
    @autoreleasepool {
        test_outer_bracket();
        test_bare_register();
        test_semantics_table();
        test_encode();
        test_reject();
        test_limits();
        test_load_mod();
        puts(g_fail ? "\nSOME FAIL" : "\nALL PASS");
        return g_fail ? 1 : 0;
    }
}
