#!/bin/bash
# macOS 统一入口：检查环境、安装缺失工具、构建官方 QBDI/Dobby、打包。
# 兼容 macOS 自带 Bash 3.2；不要用 sudo 运行整个脚本。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE=build
RELEASE=0
ERRORS=0
WORK_DIR=""

usage() {
    cat <<'EOF'
用法: ./scripts/setup_and_build.sh [--release] [--check | --setup-only]
  默认          安装缺失工具，编译 QBDI/Dobby，生成两种 deb
  --release, -r 生成发布版（FINALPACKAGE=1）
  --check       只检查环境和网络，不安装、不编译、不修改文件
  --setup-only  只准备工具和 Theos，不编译 QBDI/Dobby 和项目
  --help, -h    显示帮助

请先安装完整 Xcode 并完成首次启动。Homebrew 首次安装可能需要管理员密码。
Theos 使用已有 THEOS 环境变量，否则使用 ~/theos；无需手动 export。
EOF
}

for arg in "$@"; do
    case "$arg" in
        --release|-r) RELEASE=1 ;;
        --check|--setup-only)
            [ "$MODE" = build ] || { echo "❌ --check 与 --setup-only 不可重复或混用" >&2; exit 2; }
            MODE="${arg#--}"
            ;;
        --help|-h) usage; exit 0 ;;
        *) echo "❌ 未知参数: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

fail() { echo "❌ $*" >&2; exit 1; }
problem() { echo "❌ $*" >&2; ERRORS=$((ERRORS + 1)); }
cleanup() { if [ -n "$WORK_DIR" ]; then rm -rf "$WORK_DIR"; fi; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[ "$(uname -s)" = Darwin ] || fail "此入口仅支持 macOS。"
[ "$(id -u)" != 0 ] || fail "请以普通用户运行，不要 sudo 整个脚本。"

echo "[1/5] 检查完整 Xcode / iOS SDK"
# 只修改子进程环境，不改系统 xcode-select 配置。
DEV_DIR="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
if [ -z "${DEVELOPER_DIR:-}" ] && [[ "$DEV_DIR" != *.app/Contents/Developer ]]; then
    if [ -d /Applications/Xcode.app/Contents/Developer ]; then
        DEV_DIR=/Applications/Xcode.app/Contents/Developer
    fi
fi
if [[ "$DEV_DIR" == *.app/Contents/Developer ]] && [ -d "$DEV_DIR" ]; then
    export DEVELOPER_DIR="$DEV_DIR"
    # Theos 会用此变量重新设置 DEVELOPER_DIR，必须同步传递选中的 Xcode。
    export THEOS_PLATFORM_SDK_ROOT="$DEV_DIR"
    SDK="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"
    if [ -d "$SDK" ] && xcrun --sdk iphoneos --find clang >/dev/null 2>&1 \
        && xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
        echo "✅ Xcode: $DEVELOPER_DIR"
        echo "✅ iOS SDK: $SDK"
    else
        problem "Xcode 尚未就绪。请打开 Xcode，接受许可并安装首次启动所需组件和 iOS SDK。"
    fi
else
    problem "未找到完整 Xcode。请从 App Store 或 https://developer.apple.com/download/applications/ 安装。"
    echo "   非默认安装位置可用 DEVELOPER_DIR=/实际路径/Xcode.app/Contents/Developer 指定。"
fi
if [ "$MODE" != check ] && [ "$ERRORS" -ne 0 ]; then
    fail "完成 Xcode 准备后，重新运行同一命令；仅安装 CLT 不够。"
fi

echo "[2/5] 检查 GitHub 网络"
NETWORK_OK=1
if ! curl --fail --location --silent --show-error --connect-timeout 10 --max-time 30 \
    --output /dev/null https://github.com/; then
    NETWORK_OK=0
    if [ "$MODE" = check ]; then
        problem "无法连接 GitHub。请检查网络或终端代理配置（HTTPS_PROXY），然后重试。"
    else
        echo "ℹ️ GitHub 暂不可用；仅当所有工具和项目依赖已齐备时可以继续。"
    fi
else
    echo "✅ GitHub 可连接（实际 clone / 下载失败时仍会停止）"
fi
need_network() {
    [ "$NETWORK_OK" -eq 1 ] || fail "此步骤需要下载。请检查 GitHub 网络或终端代理配置（HTTPS_PROXY），然后重试。"
}

echo "[3/5] 检查 / 安装构建工具"
# Homebrew 已安装但未加入 PATH 时，也能找到它；不执行 shellenv 输出。
if ! command -v brew >/dev/null 2>&1; then
    for prefix in /opt/homebrew /usr/local; do
        if [ -x "$prefix/bin/brew" ]; then
            export PATH="$prefix/bin:$prefix/sbin:$PATH"
            break
        fi
    done
fi

MISSING=()
for tool in git cmake ninja python3 xz; do
    if command -v "$tool" >/dev/null 2>&1 && "$tool" --version >/dev/null 2>&1; then
        echo "✅ $tool"
    else
        MISSING+=("$tool")
    fi
done
# ldid 不支持通用 --version，用路径检查；实际签名由 Theos 验证。
if command -v ldid >/dev/null 2>&1; then
    echo "✅ ldid"
else
    MISSING+=(ldid)
fi

THEOS="${THEOS:-$HOME/theos}"
[[ "$THEOS" = /* ]] || fail "THEOS 必须是绝对路径：$THEOS"
export THEOS
theos_ready() {
    [ -f "$THEOS/makefiles/common.mk" ] && [ -f "$THEOS/makefiles/aggregate.mk" ] \
        && [ -f "$THEOS/makefiles/application.mk" ] && [ -f "$THEOS/makefiles/tweak.mk" ] \
        && [ -f "$THEOS/vendor/logos/bin/logos.pl" ] \
        && [ -f "$THEOS/vendor/include/substrate.h" ]
}
NEED_THEOS=0
theos_ready || NEED_THEOS=1

if [ "$MODE" = check ]; then
    for tool in ${MISSING[@]+"${MISSING[@]}"}; do problem "缺少或不可运行: $tool"; done
    if ! command -v brew >/dev/null 2>&1; then
        echo "ℹ️ 未找到 Homebrew；需要安装工具时，默认模式会启动官方安装器。"
    fi
else
    if [ "${#MISSING[@]}" -gt 0 ] || [ "$NEED_THEOS" -eq 1 ]; then
        need_network
        WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/qbdi-setup.XXXXXX")"
        if ! command -v brew >/dev/null 2>&1; then
            echo "安装 Homebrew（官方安装器可能提示管理员密码）..."
            curl --fail --location --show-error --connect-timeout 10 --max-time 120 \
                https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh \
                --output "$WORK_DIR/install-homebrew.sh"
            /bin/bash "$WORK_DIR/install-homebrew.sh"
            for prefix in /opt/homebrew /usr/local; do
                if [ -x "$prefix/bin/brew" ]; then
                    export PATH="$prefix/bin:$prefix/sbin:$PATH"
                    break
                fi
            done
            command -v brew >/dev/null 2>&1 || fail "Homebrew 安装后仍不可用，请检查安装器输出。"
        fi
        if [ "${#MISSING[@]}" -gt 0 ]; then
            FORMULAE=()
            for tool in "${MISSING[@]}"; do
                if [ "$tool" = python3 ]; then FORMULAE+=(python); else FORMULAE+=("$tool"); fi
            done
            echo "安装缺失工具: ${FORMULAE[*]}"
            brew install "${FORMULAE[@]}"
            hash -r
        fi
    fi
    for tool in git cmake ninja python3 xz; do
        command -v "$tool" >/dev/null 2>&1 && "$tool" --version >/dev/null 2>&1 \
            || fail "安装后 $tool 仍不可用，请检查 PATH 和 Homebrew 输出。"
    done
    command -v ldid >/dev/null 2>&1 || fail "安装后仍找不到 ldid。"
fi

echo "[4/5] 检查 / 安装 Theos"
if [ "$NEED_THEOS" -eq 1 ]; then
    if [ "$MODE" = check ]; then
        problem "Theos 缺失或不完整: $THEOS"
    else
        # 不更新或覆盖用户已有的非空目录。
        if [ -e "$THEOS" ]; then
            [ -d "$THEOS" ] && [ -z "$(ls -A "$THEOS")" ] \
                || fail "Theos 目录已存在但不完整。请自行修复或指定新的 THEOS 路径：$THEOS"
        fi
        # 与官方安装器一样递归获取子模块；本项目使用上面已验证的 Xcode SDK。
        # 不执行安装器中的全局 xcode-select 切换或额外 tvOS SDK 下载。
        echo "从 Theos 官方仓库安装到 $THEOS ..."
        git clone --recursive https://github.com/theos/theos.git "$THEOS"
        theos_ready || fail "Theos 安装不完整，请检查安装器输出。"
    fi
else
    echo "✅ 复用 Theos: $THEOS"
fi

echo "[5/5] QBDI / Dobby 与项目打包"
deps_ready() {
    local file
    for file in Engine/lib/arm64/libQBDI.a Engine/lib/arm64/libdobby.a \
        Engine/include/QBDI.h Engine/include/dobby.h Engine/include/QBDI/Config.h \
        Engine/include/QBDI/Version.h Engine/include/QBDI/Options.h Engine/include/QBDI/State.h; do
        [ -s "$ROOT/$file" ] || return 1
    done
}
if [ "$MODE" = check ]; then
    if deps_ready; then
        echo "✅ 已有 QBDI / Dobby 静态库和关键头文件"
    else
        echo "ℹ️ QBDI / Dobby 依赖尚未齐备；默认模式会从官方仓库下载源码并编译。"
    fi
    [ "$ERRORS" -eq 0 ] || fail "发现 $ERRORS 项环境问题。修复 Xcode / 网络后，可运行默认模式安装缺失工具。"
    echo "✅ 环境检查通过。"
elif [ "$MODE" = setup-only ]; then
    echo "✅ 环境准备完成。THEOS=$THEOS"
    echo "继续编译: ./scripts/setup_and_build.sh --release"
else
    if deps_ready; then
        echo "✅ 复用项目内现有 QBDI / Dobby 依赖"
    else
        need_network
        /bin/sh "$ROOT/scripts/build_deps_ios.sh"
        deps_ready || fail "依赖构建后仍缺少静态库或关键头文件，请检查构建输出。"
    fi
    if [ "$RELEASE" -eq 1 ]; then
        /bin/sh "$ROOT/scripts/build_debs.sh" --release
    else
        /bin/sh "$ROOT/scripts/build_debs.sh"
    fi
fi
