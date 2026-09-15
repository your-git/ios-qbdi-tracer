#!/bin/sh
# 构建 QBDI + Dobby(iOS arm64)并把静态库/头文件装进项目本地:
#   Engine/lib/arm64/{libdobby.a, libQBDI.a}
#   Engine/include/{dobby.h, QBDI.h, QBDI/, ...}
#
# 只需跑一次。之后在工程根目录 `make package` 即可。
#
# 前置工具(脚本只检查不自动安装):
#   - Xcode Command Line Tools: xcode-select --install
#   - git    : 随 Xcode CLT
#   - cmake  : brew install cmake
#   - ninja  : brew install ninja   (QBDI 自带静态 LLVM,tablegen 跨目录依赖只能用 ninja 编)
#
# 只构建 arm64(A7~A11 / iPhone 5s~X)。iOS 无 arm32 越狱环境,arm64e 需另行处理。
#
# 想跳过编译? 从项目 GitHub Release 下载预编译的 deps 包,解压到
#   Engine/lib/ 和 Engine/include/ 即可,无需运行本脚本。
set -e

ARCH="arm64"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
THIRD="$ROOT/third_party"          # 永远在本地 third_party 编译,不复用外部工程
DST_LIB="$ROOT/Engine/lib/$ARCH"
DST_INC="$ROOT/Engine/include"

# ---------- 前置工具检查(缺失则报错并给出安装方式,不自动安装)----------
missing=0
need() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "❌ 缺少 $1  —— 安装: $2"
        missing=1
    fi
}
need git   "随 Xcode CLT 附带,或 brew install git"
need cmake  "brew install cmake"
need ninja  "brew install ninja"
need python3 "随 Xcode CLT 附带,或 brew install python"
if ! xcode-select -p >/dev/null 2>&1; then
    echo "❌ 未安装 Xcode Command Line Tools  —— 安装: xcode-select --install"
    missing=1
fi
if [ "$missing" -ne 0 ]; then
    echo
    echo "请先安装上面缺失的工具后重试。"
    exit 1
fi

echo "[1/3] 检查前置工具 ✅"
mkdir -p "$THIRD" "$DST_LIB" "$DST_INC"
cd "$THIRD"

# ---------- QBDI(动态二进制插桩引擎)----------
echo "[2/3] 构建 QBDI(arm64,约 15-30 分钟,一次性) ..."
if [ ! -d QBDI ]; then
    echo "    克隆 QBDI ..."
    git clone --depth 1 -b dev-next https://github.com/QBDI/QBDI.git || {
        echo "❌ git clone QBDI 失败。检查网络或改用镜像: https://github.com.cnpmjs.org/QBDI/QBDI.git"
        exit 1
    }
fi
if [ ! -f QBDI/build-ios/lib/libQBDI.a ]; then
    # 残留的 Makefiles 生成器缓存会导致 tablegen 跨目录依赖失败,检测并清掉
    if [ -f QBDI/build-ios/CMakeCache.txt ] && ! grep -q "CMAKE_GENERATOR:INTERNAL=Ninja" QBDI/build-ios/CMakeCache.txt; then
        echo "    清除非 Ninja 的旧构建缓存 ..."
        rm -rf QBDI/build-ios
    fi
    echo "    cmake + ninja 构建(QBDI 自带静态 LLVM,首次约 20 分钟) ..."
    (cd QBDI && mkdir -p build-ios && cd build-ios && \
        ../cmake/config/config-ios-aarch64.sh && ninja -j"$JOBS") || {
        echo "❌ QBDI 编译失败。常见原因: iOS SDK 版本不匹配 / ninja 命令失败。"
        echo "   检查 QBDI/build-ios/CMakeFiles/CMakeOutput.log 或重试。"
        exit 1
    }
fi

echo "    安装 libQBDI.a + 头文件到项目 ..."
QBDI_A="$(find QBDI/build-ios -name 'libQBDI.a' -type f | head -1)"
[ -n "$QBDI_A" ] && [ -f "$QBDI_A" ] || { echo "❌ 找不到 libQBDI.a,构建可能失败"; exit 1; }
cp "$QBDI_A" "$DST_LIB/libQBDI.a"
rm -rf "$DST_INC/QBDI"
cp -R QBDI/include/QBDI "$DST_INC/QBDI"
# Config.h / Version.h / Options.h / State.h 是构建时生成的(静态链接版用 include-static/)
cp -R QBDI/build-ios/include/QBDI/. "$DST_INC/QBDI/" 2>/dev/null || true
cp QBDI/build-ios/include-static/QBDI/Config.h "$DST_INC/QBDI/Config.h"
cp QBDI/include/QBDI.h "$DST_INC/QBDI.h"

# ---------- Dobby(inline hook 库)----------
echo "[3/3] 构建 Dobby(arm64,约 1-2 分钟) ..."
if [ ! -d Dobby ]; then
    echo "    克隆 Dobby ..."
    git clone --depth 1 -b master https://github.com/jmpews/Dobby.git || {
        echo "❌ git clone Dobby 失败。检查网络或改用镜像: https://github.com.cnpmjs.org/jmpews/Dobby.git"
        exit 1
    }
fi
# Dobby 产物落在 build/cmake-build-iphoneos-<arch>/libdobby.a,优先匹配本 arch 目录
find_dobby() { find Dobby/build -path "*iphoneos-$ARCH*" -name 'libdobby.a' -type f 2>/dev/null | head -1; }
DOBBY_A="$(find_dobby)"
if [ -z "$DOBBY_A" ] || [ ! -f "$DOBBY_A" ]; then
    echo "    python3 platform_builder 构建 ..."
    (cd Dobby && python3 scripts/platform_builder.py --platform=iphoneos --arch="$ARCH" --library_build_type=static) || {
        echo "❌ Dobby 编译失败。检查 python3 / cmake 可用性或 Dobby/build/ 目录。"
        exit 1
    }
    DOBBY_A="$(find_dobby)"
fi
[ -n "$DOBBY_A" ] && [ -f "$DOBBY_A" ] || { echo "❌ 找不到 libdobby.a,构建可能失败"; exit 1; }
cp "$DOBBY_A" "$DST_LIB/libdobby.a"
cp -R Dobby/include/. "$DST_INC/"

echo
echo "✅ 依赖构建完成:"
echo "   静态库: $DST_LIB"
echo "   头文件: $DST_INC"
echo
echo "接下来运行: make package"
