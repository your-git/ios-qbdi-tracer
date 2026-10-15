#!/bin/sh
# 准备 QBDI / Dobby 编译依赖，免去 20-40 分钟的源码编译。
#
# 两种情况：
#   1. 工程根目录已有 deps*.tar.gz / deps*.tgz  → 直接解压
#   2. 根目录没有                                        → 从 GitHub Release 下载(默认 5 分钟超时)后解压
#
# 用法：
#   ./scripts/fetch_deps.sh                    解压到工程根目录(默认)
#   ./scripts/fetch_deps.sh /path/to/dir       解压到指定目录
#   ./scripts/fetch_deps.sh -d /path -f        指定目录 + 强制重新解压
#   ./scripts/fetch_deps.sh --proxy-port 7898  走本机 7898 端口的代理下载
#   ./scripts/fetch_deps.sh -h                 显示本帮助
#
# 环境变量：
#   DEPS_URL       覆盖下载地址
#   DEPS_TIMEOUT   下载超时秒数(默认 300 = 5 分钟)
#   HTTPS_PROXY    代理(未用 --proxy-port / --proxy 时沿用)
#
# 解压后结构(与 setup_and_build.sh 的 deps_ready 检查一致)：
#   <目标目录>/Engine/lib/arm64/{libQBDI.a,libdobby.a}
#   <目标目录>/Engine/include/{QBDI.h,dobby.h,QBDI/}
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT"
FORCE=0
HINT=1
PROXY_URL=""
DEPS_URL="${DEPS_URL:-https://github.com/your-git/ios-qbdi-tracer/releases/download/deps-v1/deps-v1.tar.gz}"
DEPS_TIMEOUT="${DEPS_TIMEOUT:-300}"

usage() {
    cat <<'EOF'
准备 QBDI / Dobby 编译依赖，免去 20-40 分钟的源码编译。

两种情况：
  1. 工程根目录已有 deps*.tar.gz / deps*.tgz  → 直接解压
  2. 根目录没有                                        → 从 GitHub Release 下载后解压

用法：
  ./scripts/fetch_deps.sh                    解压到工程根目录(默认)
  ./scripts/fetch_deps.sh /path/to/dir       解压到指定目录
  ./scripts/fetch_deps.sh -d /path -f        指定目录 + 强制重新解压
  ./scripts/fetch_deps.sh --proxy-port 7898  走本机 7898 端口的代理
  ./scripts/fetch_deps.sh --proxy URL        走指定代理(如 socks5://127.0.0.1:7898)
  ./scripts/fetch_deps.sh -h                 显示本帮助

环境变量：
  DEPS_URL       覆盖下载地址
  DEPS_TIMEOUT   下载超时秒数(默认 300 = 5 分钟)
  HTTPS_PROXY    代理(未用 --proxy-port / --proxy 时沿用)

解压后结构(与 setup_and_build.sh 的依赖检查一致)：
  <目标目录>/Engine/lib/arm64/{libQBDI.a,libdobby.a}
  <目标目录>/Engine/include/{QBDI.h,dobby.h,QBDI/}
EOF
    exit 0
}

fail() {
    echo "❌ $1" >&2
    exit 1
}

# ---------- 参数 ----------
while [ $# -gt 0 ]; do
    case "$1" in
        -d|--dest)
            [ $# -ge 2 ] || fail "-d 后面需要一个目录参数"
            DEST="$2"
            shift 2
            ;;
        -f|--force) FORCE=1; shift ;;
        --proxy-port)
            [ $# -ge 2 ] || fail "--proxy-port 后面需要一个端口号"
            case "$2" in
                ''|*[!0-9]*) fail "端口必须是数字: $2" ;;
            esac
            PROXY_URL="http://127.0.0.1:$2"
            shift 2
            ;;
        --proxy)
            [ $# -ge 2 ] || fail "--proxy 后面需要一个代理地址"
            PROXY_URL="$2"
            shift 2
            ;;
        --no-hint)  HINT=0; shift ;;
        -h|--help)  usage ;;
        -*)         fail "未知参数: $1(用 -h 查看用法)" ;;
        *)          DEST="$1"; shift ;;
    esac
done

# ---------- 代理 ----------
# 显式参数优先；否则沿用环境里已有的代理设置
if [ -z "$PROXY_URL" ]; then
    PROXY_URL="${HTTPS_PROXY:-${https_proxy:-${ALL_PROXY:-${all_proxy:-}}}}"
fi
if [ -n "$PROXY_URL" ]; then
    HTTP_PROXY="$PROXY_URL"; HTTPS_PROXY="$PROXY_URL"; ALL_PROXY="$PROXY_URL"
    http_proxy="$PROXY_URL"; https_proxy="$PROXY_URL"; all_proxy="$PROXY_URL"
    export HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
fi

# ---------- 必需文件清单(与 setup_and_build.sh 的 deps_ready 保持一致) ----------
REQUIRED_FILES="Engine/lib/arm64/libQBDI.a
Engine/lib/arm64/libdobby.a
Engine/include/QBDI.h
Engine/include/dobby.h
Engine/include/QBDI/Config.h
Engine/include/QBDI/Version.h
Engine/include/QBDI/Options.h
Engine/include/QBDI/State.h"

deps_ready() {
    for f in $REQUIRED_FILES; do
        [ -s "$DEST/$f" ] || return 1
    done
    return 0
}

missing_files() {
    for f in $REQUIRED_FILES; do
        [ -s "$DEST/$f" ] || echo "  - $f"
    done
}

# 在工程根目录(以及当前工作目录)里找 deps* 压缩包，多个时取最新修改的那个
find_local_archive() {
    newest=""
    for dir in "$ROOT" "$(pwd)"; do
        for f in "$dir"/deps*.tar.gz "$dir"/deps*.tgz; do
            [ -f "$f" ] || continue
            if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then
                newest="$f"
            fi
        done
    done
    printf '%s' "$newest"
}

# 解压前校验：必须是可读的 tar.gz，且解压后正好落在 Engine/ 下
validate_archive() {
    tar tzf "$1" >/dev/null 2>&1 || fail "无法读取压缩包(不是 tar.gz 或已损坏): $1"
    listing="$(tar tzf "$1")"
    echo "$listing" | grep -qx 'Engine/lib/arm64/libQBDI.a' || {
        echo "压缩包前几条内容:" >&2
        echo "$listing" | head -5 | sed 's/^/  /' >&2
        fail "压缩包结构不对：应当直接解压出 Engine/lib/... 与 Engine/include/...，不要多套一层目录"
    }
    echo "$listing" | grep -qx 'Engine/include/QBDI.h' \
        || fail "压缩包结构不对：缺少 Engine/include/QBDI.h"
}

# ---------- 0. 已经齐备就不重复劳动 ----------
echo "工程根目录: $ROOT"
echo "解压目标  : $DEST"
[ -n "$PROXY_URL" ] && echo "代理      : $PROXY_URL"
echo
if deps_ready && [ "$FORCE" -eq 0 ]; then
    echo "✅ 目标目录里依赖已齐备，无需处理。(要强制重新解压，加 -f)"
    exit 0
fi

# ---------- 1. 获取压缩包：本地优先，否则下载 ----------
echo "[1/3] 获取依赖包"
ARCHIVE="$(find_local_archive)"
if [ -n "$ARCHIVE" ]; then
    echo "      ✅ 使用根目录已有压缩包: $ARCHIVE"
else
    echo "      ℹ️  根目录没有 deps* 压缩包，改为从 GitHub 下载"
    echo "      地址: $DEPS_URL"
    echo "      超时: ${DEPS_TIMEOUT}s"
    command -v curl >/dev/null 2>&1 \
        || fail "未找到 curl，无法下载。请手动下载后放到工程根目录，再重跑本脚本。"
    ARCHIVE="$ROOT/$(basename "$DEPS_URL")"
    # --max-time 是整体超时，正好对应「5 分钟」；不加 --retry 以免总耗时突破上限
    if ! curl --fail --location --show-error \
              --connect-timeout 15 \
              --max-time "$DEPS_TIMEOUT" \
              --output "$ARCHIVE" "$DEPS_URL"; then
        rm -f "$ARCHIVE"
        echo >&2
        echo "下载失败。可选办法：" >&2
        echo "  1. 浏览器打开上面的地址，把文件放到工程根目录，再重跑本脚本" >&2
        echo "  2. 走本机代理: ./scripts/fetch_deps.sh --proxy-port 7898" >&2
        echo "  3. 或改用源码编译: ./scripts/build_deps_ios.sh(约 20-40 分钟)" >&2
        exit 1
    fi
    echo "      ✅ 已下载: $ARCHIVE"
fi

# ---------- 2. 解压 ----------
echo "[2/3] 解压到: $DEST"
validate_archive "$ARCHIVE"
mkdir -p "$DEST"
# 排除 macOS 的 AppleDouble / DS_Store 垃圾，避免解压出一堆 ._* 幽灵文件
tar xzf "$ARCHIVE" -C "$DEST" --exclude='.DS_Store' --exclude='._*'

# ---------- 3. 校验 ----------
echo "[3/3] 校验依赖完整性"
if deps_ready; then
    echo "      ✅ 依赖就绪"
    echo
    echo "静态库:"
    echo "  Engine/lib/arm64/libQBDI.a   $(du -h "$DEST/Engine/lib/arm64/libQBDI.a" | cut -f1)"
    echo "  Engine/lib/arm64/libdobby.a  $(du -h "$DEST/Engine/lib/arm64/libdobby.a" | cut -f1)"
    if [ "$HINT" -eq 1 ]; then
        echo
        echo "接下来编译: ./scripts/setup_and_build.sh --release"
    fi
else
    echo "解压后仍缺少以下文件:" >&2
    missing_files >&2
    fail "依赖不完整，压缩包可能已损坏或被改动。"
fi
