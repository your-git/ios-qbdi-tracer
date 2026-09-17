#import "HexValue.h"

/* JSON → 数值。NSNumber 按十进制(旧配置);字符串带 "0x" 按十六进制,不带按十进制。 */
unsigned long long HexValueFromJSON(id v) {
    if ([v isKindOfClass:[NSNumber class]]) return [v unsignedLongLongValue];
    if (![v isKindOfClass:[NSString class]]) return 0;
    NSString *t = [v stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];
    if (t.length == 0) return 0;
    BOOL hex = [[t lowercaseString] hasPrefix:@"0x"];
    NSScanner *sc = [NSScanner scannerWithString:hex ? [t substringFromIndex:2] : t];
    unsigned long long out = 0;
    if (hex) {
        if (![sc scanHexLongLong:&out]) return 0;
    } else {
        long long dec = 0;
        if (![sc scanLongLong:&dec] || dec < 0) return 0;
        out = (unsigned long long)dec;
    }
    return sc.isAtEnd ? out : 0;
}

/* 输入框里的文本 → 数值。UI 上一律按十六进制理解("10" = 0x10),0x 前缀可省。
 * 解析不了返回 NO(调用方保留上一次的合法值,不静默变 0 —— 0 是"不截断",方向反了)。 */
BOOL HexParseInput(NSString *text, unsigned long long *out) {
    NSString *t = [text stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceCharacterSet]];
    if (t.length == 0) { *out = 0; return YES; }
    NSString *body = [[t lowercaseString] hasPrefix:@"0x"] ? [t substringFromIndex:2] : t;
    if (body.length == 0 || body.length > 16) return NO;
    unsigned long long v = 0;
    for (NSUInteger i = 0; i < body.length; i++) {
        unichar ch = [[body lowercaseString] characterAtIndex:i];
        int d;
        if (ch >= '0' && ch <= '9') d = (int)(ch - '0');
        else if (ch >= 'a' && ch <= 'f') d = (int)(ch - 'a' + 10);
        else return NO;
        v = (v << 4) | (unsigned long long)d;
    }
    *out = v;
    return YES;
}

/* 配置值 → 输入框显示的规范形式(始终带 0x) */
NSString *HexDisplay(id v) {
    return [NSString stringWithFormat:@"0x%llx", HexValueFromJSON(v)];
}
