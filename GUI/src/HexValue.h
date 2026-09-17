#import <Foundation/Foundation.h>

/* 配置里"字节长度"类字段(watch 的 size、触发条件的 triggerScan)的进制处理。
 *
 * JSON 侧:带 "0x" 前缀 = 十六进制,不带 = 十进制,裸数字(NSNumber)= 十进制。
 *          旧配置里这些字段是裸十进制,新 App 写出来一律是 "0x..." 字符串,
 *          靠前缀区分,不需要迁移。
 * 输入框侧:一律按十六进制理解(敲 10 得到 0x10),因为框里显示的永远是带 0x
 *          的规范形式,用户不会在 UI 里看到裸十进制。
 *
 * 引擎侧的对应实现是 Engine/src/engine.m 的 parse_size ——
 * 两边规则必须一致,改了要跑 ./scripts/test_watch_expr.sh 交叉验证。 */

/* JSON 值 → 数值(看前缀定进制) */
unsigned long long HexValueFromJSON(id v);

/* 输入框文本 → 数值,一律十六进制。解析不了返回 NO
 * (调用方应保留上一次的合法值,别静默变 0) */
BOOL HexParseInput(NSString *text, unsigned long long *out);

/* JSON 值 → 输入框显示的规范形式(始终带 0x) */
NSString *HexDisplay(id v);
