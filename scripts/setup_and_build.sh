#!/bin/bash
# macOS 统一入口：检查环境、安装缺失工具、获取 QBDI/Dobby 依赖、打包。
# 依赖获取顺序：根目录已有的 deps*.tar.gz → GitHub Release 下载 →
# 都失败才从源码编译 QBDI/Dobby。
# 兼容 macOS 自带 Bash 3.2；不要用 sudo 运行整个脚本。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE=build
RELEASE=0
ERRORS=0
WORK_DIR=""
PROXY_URL=""

usage() {
    cat <<'EOF'
用法: ./scripts/setup_and_build.sh [--release] [--check | --setup-only] [--proxy-port 端口]

  默认            安装缺失工具，获取 QBDI/Dobby 依赖，生成两种 deb
  --release, -r   生成发布版（FINALPACKAGE=1）
  --check         只检查环境和网络，不安装、不编译、不修改文件
  --setup-only    只准备工具和 Theos，不编译 QBDI/Dobby 和项目
  --proxy-port N  走本机 127.0.0.1:N 的代理访问 GitHub（如 --proxy-port 7898）
  --proxy URL     走指定代理（如 socks5://127.0.0.1:7898）
  --help, -h      显示帮助

依赖获取顺序：根目录已有的 deps*.tar.gz → GitHub Release 下载 →
都失败才从源码编译 QBDI/Dobby（约 20-40 分钟）。

请先安装完整 Xcode 并完成首次启动。Homebrew 首次安装可能需要管理员密码。
Theos 使用已有 THEOS 环境变量，否则使用 ~/theos；无需手动 export。
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --release|-r) RELEASE=1; shift ;;
        --check|--setup-only)
            [ "$MODE" = build ] || { echo "❌ --check 与 --setup-only 不可重复或混用" >&2; exit 2; }
            MODE="${1#--}"
            shift
            ;;
        --proxy-port)
            [ $# -ge 2 ] || { echo "❌ --proxy-port 需要一个端口号" >&2; exit 2; }
            case "$2" in
                ''|*[!0-9]*) echo "❌ 端口必须是数字: $2" >&2; exit 2 ;;
            esac
            PROXY_URL="http://127.0.0.1:$2"
            shift 2
            ;;
        --proxy)
            [ $# -ge 2 ] || { echo "❌ --proxy 需要一个代理地址" >&2; exit 2; }
            PROXY_URL="$2"
            shift 2
            ;;
        --help|-h) usage; exit 0 ;;
        *) echo "❌ 未知参数: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# ---------- 代理 ----------
# 显式参数优先；否则沿用环境里已有的代理设置。curl / git / brew 都认这些变量。
if [ -z "$PROXY_URL" ]; then
    PROXY_URL="${HTTPS_PROXY:-${https_proxy:-}}"
fi
if [ -n "$PROXY_URL" ]; then
    export HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL" ALL_PROXY="$PROXY_URL"
    export http_proxy="$PROXY_URL" https_proxy="$PROXY_URL" all_proxy="$PROXY_URL"
    export NO_PROXY="${NO_PROXY:-localhost,127.0.0.1,::1}"
fi

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
if [ -n "$PROXY_URL" ]; then
    echo "ℹ️ 使用代理: $PROXY_URL"
fi
NETWORK_OK=1
if ! curl --fail --location --silent --show-error --connect-timeout 30 --max-time 30 \
    --output /dev/null https://github.com/; then
    NETWORK_OK=0
    if [ "$MODE" = check ]; then
        # 注意：macOS 自带 bash 3.2 里变量引用紧跟多字节字符时，会把该字符的首字节
        # 并入变量名并报 "unbound variable"。所以下面必须用带花括号的 ${PROXY_URL}。
        if [ -n "$PROXY_URL" ]; then
            problem "无法连接 GitHub（已尝试代理 ${PROXY_URL}）。请检查网络，或用 --proxy-port 端口 指定代理后重试。"
        else
            problem "无法连接 GitHub。请检查网络，或用 --proxy-port 端口 指定代理后重试。"
        fi
    else
        echo "ℹ️ GitHub 暂不可用；仅当所有工具和项目依赖已齐备时可以继续。"
    fi
else
    echo "✅ GitHub 可连接（实际 clone / 下载失败时仍会停止）"
fi
need_network() {
    [ "$NETWORK_OK" -eq 1 ] || fail "此步骤需要下载。请检查网络，或用 --proxy-port 端口 指定代理后重试。"
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
run_project_script() {
    local script="$1"
    shift
    # Git / 编辑器可能把子脚本转换成 CRLF。入口修复后，也能自动修复子脚本。
    if LC_ALL=C grep -q "$(printf '\r')" "$script"; then
        echo "修复脚本的 Windows 换行: ${script##*/}"
        perl -pi -e 's/\r$//' "$script"
    fi
    /bin/sh "$script" "$@"
}
# 依赖获取的三种情况：本地压缩包 → GitHub 下载 → 源码编译
FETCH_ARGS=()
if [ -n "$PROXY_URL" ]; then
    FETCH_ARGS=(--proxy "$PROXY_URL")
fi
acquire_deps() {
    echo "项目内没有 QBDI / Dobby 依赖，按以下顺序获取："
    echo "  1) 工程根目录已有的 deps*.tar.gz"
    echo "  2) 从 GitHub Release 下载"
    echo "  3) 前两者都不行 → 从源码编译（约 20-40 分钟）"
    echo
    if run_project_script "$ROOT/scripts/fetch_deps.sh" --no-hint "$ROOT" \
        ${FETCH_ARGS[@]+"${FETCH_ARGS[@]}"}; then
        echo "✅ 已通过压缩包 / Release 获取依赖"
    else
        echo
        echo "ℹ️ 本地压缩包和 GitHub 下载都没成功，回退到从源码编译 QBDI / Dobby。"
        [ "$NETWORK_OK" -eq 1 ] || fail "源码编译也需要访问 GitHub。请用 --proxy-port 端口 指定代理，或手动把 deps*.tar.gz 放到工程根目录后重试。"
        run_project_script "$ROOT/scripts/build_deps_ios.sh"
    fi
    deps_ready || fail "依赖仍不完整（Engine/lib/arm64 与 Engine/include）。请检查上面的输出。"
}
if [ "$MODE" = check ]; then
    if deps_ready; then
        echo "✅ 已有 QBDI / Dobby 静态库和关键头文件"
    else
        echo "ℹ️ QBDI / Dobby 依赖尚未齐备；默认模式会依次尝试："
        echo "   1) 解压根目录已有的 deps*.tar.gz"
        echo "   2) 从 GitHub Release 下载"
        echo "   3) 都失败则从源码编译（约 20-40 分钟）"
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
        acquire_deps
    fi
    if [ "$RELEASE" -eq 1 ]; then
        run_project_script "$ROOT/scripts/build_debs.sh" --release
    else
        run_project_script "$ROOT/scripts/build_debs.sh"
    fi
fi
