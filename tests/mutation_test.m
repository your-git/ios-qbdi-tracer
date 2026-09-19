/* Trace 内寄存器修改配置解析测试。被测函数由脚本从 engine.m 原样提取。 */
#import <Foundation/Foundation.h>

#include "config.h"
#include "engine_mutation.inc"

static int g_fail;

static void clear_spec(TraceSpec *spec) {
    free(spec->mutations);
    spec->mutations = NULL;
    spec->mutation_count = 0;
}

static bool load(id mutations, TraceSpec *spec, char *err, size_t cap) {
    memset(spec, 0, sizeof(*spec));
    NSDictionary *item = mutations == nil ? @{} : @{ @"mutations": mutations };
    return load_mutations(item, spec, err, cap);
}

static void reject(NSDictionary *rule, const char *what) {
    TraceSpec spec;
    char err[160] = "";
    if (load(@[ rule ], &spec, err, sizeof(err))) {
        printf("FAIL %s 应当被拒\n", what);
        clear_spec(&spec);
        g_fail++;
    } else {
        printf("ok   拒绝 %s: %s\n", what, err);
    }
}

int main(void) {
    @autoreleasepool {
        TraceSpec spec;
        char err[160] = "";

        if (load(nil, &spec, err, sizeof(err)) && spec.mutation_count == 0 &&
            spec.mutations == NULL) {
            puts("ok   旧 JSON 缺少 mutations → 空规则");
        } else {
            puts("FAIL 旧 JSON 兼容失败");
            g_fail++;
        }

        NSArray *valid = @[
            @{ @"enabled": @YES, @"offset": @"0x1234", @"reg": @"x8",
               @"width": @32, @"value": @"0xffffffff", @"apply": @"once" },
            @{ @"offset": @"0x2000", @"reg": @"FP", @"value": @"0x55",
               @"apply": @"always" },
            /* 停用规则的其余字段允许缺失，且不会进入运行时数组。 */
            @{ @"enabled": @NO, @"reg": @"sp" },
        ];
        if (load(valid, &spec, err, sizeof(err)) && spec.mutation_count == 2 &&
            spec.mutations[0].offset == 0x1234 &&
            spec.mutations[0].reg_index == 8 && spec.mutations[0].width == 32 &&
            spec.mutations[0].value == UINT32_MAX &&
            spec.mutations[0].every_hit == 0 &&
            spec.mutations[1].reg_index == 29 && spec.mutations[1].width == 64 &&
            spec.mutations[1].every_hit == 1) {
            puts("ok   x8/w8、fp、once/always 与停用规则解析正确");
        } else {
            printf("FAIL 合法规则解析失败: %s\n", err);
            g_fail++;
        }
        clear_spec(&spec);

        reject(@{ @"offset": @"0x1000", @"reg": @"x17", @"value": @"1" },
               "x17");
        reject(@{ @"offset": @"0x1000", @"reg": @"sp", @"value": @"1" },
               "sp");
        reject(@{ @"offset": @"0x1000", @"reg": @"w8", @"value": @"1" },
               "w8 作为 reg（应使用 x8+width）");
        reject(@{ @"offset": @"0x1000", @"reg": @"x8", @"width": @16,
                  @"value": @"1" }, "16 位");
        reject(@{ @"offset": @"0x1000", @"reg": @"lr", @"width": @32,
                  @"value": @"1" }, "lr 32 位");
        reject(@{ @"offset": @"0x1000", @"reg": @"x8", @"width": @32,
                  @"value": @"0x100000000" }, "32 位溢出");
        reject(@{ @"offset": @"12zz", @"reg": @"x8", @"value": @"1" },
               "非法地址");
        reject(@{ @"offset": @"0x1000", @"reg": @"x8", @"value": @"bad!" },
               "非法写入值");
        reject(@{ @"offset": @"0x1000", @"reg": @"x8", @"value": @"1",
                  @"apply": @"sometimes" }, "未知应用方式");
        reject(@{ @"offset": @"0x1000", @"reg": @"x8", @"value": @"1",
                  @"apply": @1 }, "非字符串应用方式");

        printf("\n%s\n", g_fail == 0 ? "ALL PASS" : "SOME FAILED");
    }
    return g_fail != 0;
}
