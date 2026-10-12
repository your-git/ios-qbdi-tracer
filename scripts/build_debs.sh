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

# deb 暂存必须支持 Unix 权限。工程放在 exFAT 外置盘时，目录可能固定为
# 0700，dpkg 会拒绝打包；在系统临时目录暂存，不搬动工程或最终 packages。
STAGE_ROOT="$(mktemp -d /tmp/ios-qbdi-package.XXXXXX)"
trap 'rm -rf "$STAGE_ROOT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

FINAL=""
if [ "$1" = "--release" ] || [ "$1" = "-r" ]; then
    FINAL="FINALPACKAGE=1"
    echo "== 发布模式(去符号)=="
fi

# 同一次构建的 rootful/rootless 包共用一个时间版本。既作为 deb 内部版本传给
# Theos，也在构建后统一规范文件名，避免固定 0.1-1 导致新包看不出来、安装不覆盖。
BUILD_VERSION="$(date +%y%m%d%H%M)"
PACKAGE_ID="com.snk.qbditracer"

# 切换 scheme 必须 make clean,否则会混用上次的中间产物 → 装上行为诡异
build_one() {
    scheme="$1"; label="$2"; arch="$3"
    echo
    echo "==================== 构建 $label 版 ===================="
    make clean >/dev/null 2>&1 || true
    if [ "$scheme" = "rootless" ]; then
        THEOS_PACKAGE_SCHEME=rootless make package \
            THEOS_STAGING_DIR="$STAGE_ROOT/stage" PACKAGE_VERSION="$BUILD_VERSION" $FINAL
    else
        # 显式清空,避免继承外部环境里残留的 rootless 设置
        env -u THEOS_PACKAGE_SCHEME make package \
            THEOS_STAGING_DIR="$STAGE_ROOT/stage" PACKAGE_VERSION="$BUILD_VERSION" $FINAL
    fi


    # 即使某个 Theos 版本给文件名追加了调试后缀，也在这里统一规范成时间戳文件名。
    built="$(ls -t packages/*_"$arch".deb 2>/dev/null | head -1)"
    if [ -z "$built" ]; then
        echo "❌ 构建完成但没有找到 $arch deb"
        exit 1
    fi
    dest="packages/${PACKAGE_ID}_${BUILD_VERSION}_${arch}.deb"
    if [ "$built" != "$dest" ]; then
        mv -f "$built" "$dest"
    fi
    echo "→ $dest"
}

build_one rootful  "rootful (iphoneos-arm)"     "iphoneos-arm"
build_one rootless "rootless (iphoneos-arm64)" "iphoneos-arm64"

echo
echo "✅ 完成。产出的 deb:"
echo "   packages/${PACKAGE_ID}_${BUILD_VERSION}_iphoneos-arm.deb"
echo "   packages/${PACKAGE_ID}_${BUILD_VERSION}_iphoneos-arm64.deb"
echo
echo "分发说明:"
echo "  传统越狱(rootful)  → 装 *_iphoneos-arm.deb"
echo "  rootless 越狱      → 装 *_iphoneos-arm64.deb"
