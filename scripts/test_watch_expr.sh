#!/bin/sh
# watch 取址表达式 / size 进制规则的本机自测(在 mac 上直接跑,不需要设备、不需要 theos)。
#
# 测四件事:
#   1. tests/watch_expr_test.c  —— 引擎 parser 本身:编译、求值、多级解引用、失败诊断
#   2. tests/gui_expr_test.m    —— GUI 的 ExprScan 与引擎 wexpr_compile 判断是否一致
#   3. tests/size_rule_test.m   —— 引擎 parse_size 与 GUI SizeValueFromJSON 是否一致
#   4. tests/trigger_test.m     —— 触发条件期望值(bytes/cstr/u64)的解析与拒绝
#
# 2/3/4 不复制被测代码,而是用 awk 从 GUI/src/ExprInput.m、GUI/src/HexValue.m、
# Engine/src/engine.m 里**原样提取**函数段落再编译 —— 这样测试永远测的是真实源码,
# 不会和它漂移。
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

CFLAGS="-Wall -Wextra -Wno-unused-parameter -Wno-unused-function -g -fsanitize=address,undefined"
ENGINE_SRC="$ROOT/Engine/src"
GUI_SRC="$ROOT/GUI/src"

echo "=== 1/4 引擎表达式 parser ==="
clang $CFLAGS -std=c11 -I"$ENGINE_SRC" \
      "$ROOT/tests/watch_expr_test.c" "$ENGINE_SRC/watch_expr.c" \
      -o "$OUT/t1"
"$OUT/t1"

echo
echo "=== 2/4 GUI 校验 vs 引擎 parser ==="
# 提取 ExprInput.m 里从 EXPR_MAX_DEPTH 到第一个 "#pragma mark" 之间的段落
awk '/^#define EXPR_MAX_DEPTH/{f=1} f&&/^#pragma mark/{exit} f' \
    "$GUI_SRC/ExprInput.m" > "$OUT/expr_extract.inc"
test -s "$OUT/expr_extract.inc" || { echo "提取失败:ExprInput.m 的段落标记变了?"; exit 1; }
clang -fobjc-arc $CFLAGS -I"$OUT" -I"$ENGINE_SRC" -framework Foundation \
      "$ROOT/tests/gui_expr_test.m" "$ENGINE_SRC/watch_expr.c" \
      -o "$OUT/t2"
"$OUT/t2"

echo
echo "=== 3/4 size 进制规则:引擎 vs GUI ==="
awk '/^static uint64_t parse_size/{f=1} f{print} f&&/^\}$/{exit}' \
    "$ENGINE_SRC/engine.m" > "$OUT/engine_size.inc"
awk '/^\/\* JSON → 数值/{f=1} f' "$GUI_SRC/HexValue.m" > "$OUT/gui_size.inc"
test -s "$OUT/engine_size.inc" || { echo "提取失败:engine.m 里没找到 parse_size"; exit 1; }
test -s "$OUT/gui_size.inc" || { echo "提取失败:HexValue.m 里没找到 hex 解析段落"; exit 1; }
clang -fobjc-arc $CFLAGS -I"$OUT" -framework Foundation \
      "$ROOT/tests/size_rule_test.m" -o "$OUT/t3"
"$OUT/t3"

echo
echo "=== 4/4 触发条件期望值解析 ==="
# load_trigger 依赖 engine.m 里的 parse_hex / parse_size / dup_str,一起提取。
# 用 index() 做字面量前缀匹配 —— 函数签名里有 '*',当正则会被当量词。
extract_fn() {
  awk -v sig="$1" 'index($0, sig) == 1 {f=1} f{print} f && /^\}$/{exit}' \
      "$ENGINE_SRC/engine.m"
  echo
}
{
  extract_fn 'static uint64_t parse_hex'
  extract_fn 'static uint64_t parse_size'
  extract_fn 'static const char *dup_str'
  extract_fn 'static bool load_trigger'
} > "$OUT/engine_trigger.inc"
grep -q 'load_trigger' "$OUT/engine_trigger.inc" || \
    { echo "提取失败:engine.m 里没找到 load_trigger"; exit 1; }
# 纯比较逻辑从 qbdi_trace.c 提取(mem_contains + trig_compare,都不碰 mach)
{
  awk 'index($0, "static bool mem_contains") == 1 {f=1} f{print} f && /^\}$/{exit}' \
      "$ENGINE_SRC/qbdi_trace.c"
  echo
  awk 'index($0, "static bool trig_compare") == 1 {f=1} f{print} f && /^\}$/{exit}' \
      "$ENGINE_SRC/qbdi_trace.c"
} > "$OUT/trig_compare.inc"
grep -q 'trig_compare' "$OUT/trig_compare.inc" || \
    { echo "提取失败:qbdi_trace.c 里没找到 trig_compare"; exit 1; }
clang -fobjc-arc $CFLAGS -I"$OUT" -I"$ENGINE_SRC" -framework Foundation \
      "$ROOT/tests/trigger_test.m" "$ENGINE_SRC/watch_expr.c" -o "$OUT/t4"
"$OUT/t4"

echo
echo "全部通过。"
