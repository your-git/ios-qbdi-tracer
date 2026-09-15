#!/bin/sh
# 一键产出 rootful + rootless 两个 deb,解决"装错架构报错"的坑。
#
#   rootful  越狱(unc0ver / checkra1n / Taurine 等)→ 架构 iphoneos-arm
#   rootless 越狱(Dopamine / palera1n rootless)   → 架构 iphoneos-arm64
#
# 两者 dpkg 架构不同,装错会报:
#   package architecture (iphoneos-arm) does not match system (iphoneos-arm64)
#
# 用法:
#   export THEOS=/path/to/theos
#   ./scripts/build_debs.sh              # 出 debug 版两个包
#   ./scripts/build_debs.sh --release    # 出发布版(去符号,FINALPACKAGE=1)
#
# 前置:依赖已就位(先跑过 ./scripts/build_deps_ios.sh 或解压过预编译 deps)。
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ -z "$THEOS" ]; then
    echo "❌ 未设置 THEOS 环境变量。请先 export THEOS=/path/to/theos"
    exit 1
fi

FINAL=""
if [ "$1" = "--release" ] || [ "$1" = "-r" ]; then
    FINAL="FINALPACKAGE=1"
    echo "== 发布模式(去符号)=="
fi

# 切换 scheme 必须 make clean,否则会混用上次的中间产物 → 装上行为诡异
build_one() {
    scheme="$1"; label="$2"
    echo
    echo "==================== 构建 $label 版 ===================="
    make clean >/dev/null 2>&1 || true
    if [ "$scheme" = "rootless" ]; then
        THEOS_PACKAGE_SCHEME=rootless make package $FINAL
    else
        # 显式清空,避免继承外部环境里残留的 rootless 设置
        env -u THEOS_PACKAGE_SCHEME make package $FINAL
    fi
}

build_one rootful  "rootful (iphoneos-arm)"
build_one rootless "rootless (iphoneos-arm64)"

echo
echo "✅ 完成。产出的 deb:"
ls -t packages/*.deb 2>/dev/null | head -2 | while read -r f; do
    echo "   $f"
done
echo
echo "分发说明:"
echo "  传统越狱(rootful)  → 装 *_iphoneos-arm.deb"
echo "  rootless 越狱      → 装 *_iphoneos-arm64.deb"
