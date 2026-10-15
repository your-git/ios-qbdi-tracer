#!/bin/sh
# 测试实际排序 / 配置 / 设置实现；只将配置目录重定向到临时目录。
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d /tmp/qbdi-list-sort.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
python3 - "$ROOT/GUI/src/AppSettings.m" "$OUT/AppSettings.m" "$OUT/config" <<'PY'
import json, sys
from pathlib import Path
source = Path(sys.argv[1]).read_text()
for path in ('/var/jb/var/mobile/Documents/QBDITracer', '/var/mobile/Documents/QBDITracer'):
    literal = '@' + json.dumps(path)
    assert literal in source, '配置路径改变，请更新测试重定向'
    source = source.replace(literal, '@' + json.dumps(sys.argv[3]))
Path(sys.argv[2]).write_text(source)
PY
clang -fobjc-arc -Wall -Wextra -g -fsanitize=address,undefined \
    -I"$ROOT/GUI/src" -framework Foundation -framework CoreFoundation \
    "$ROOT/tests/list_sort_test.m" "$ROOT/GUI/src/ListSort.m" \
    "$ROOT/GUI/src/ConfigStore.m" "$ROOT/GUI/src/HookStore.m" "$OUT/AppSettings.m" \
    -o "$OUT/test"
"$OUT/test"
