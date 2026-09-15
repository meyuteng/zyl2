#!/usr/bin/env bash
#
# 重新生成 dist/ 下的预编译包。
#
# 关键点：请在 **Ubuntu 20.04** 上运行。
#   glibc 是向后兼容的——用 2.31(20.04) 编译出来的二进制，
#   可以直接跑在 20.04 / 22.04 / 24.04 / 26.04 上。
#   反过来用 24.04 编译，产物就只能跑在 24.04 及更新系统上。
#
# accel-ppp 默认按库名链接 OpenSSL（libcrypto.so / libssl.so）。
# Ubuntu 22.04 起系统只提供 libcrypto.so.3，而 20.04 提供的是
# libcrypto.so.1.1，直接动态链接会导致预编译包在新系统上跑不起来。
# 所以这里把 CMakeLists 改成链接 .a 静态库，把 OpenSSL 打进模块里。
#
# 用法：sudo bash build.sh
#
set -euo pipefail

ACCEL_PPP_TAG="${ACCEL_PPP_TAG:-}"          # 留空 = 用默认分支
PKG_VERSION="${PKG_VERSION:-1.14.0}"
PKG_TAG="ubuntu20.04-x86_64"
OUT_NAME="accel-ppp-${PKG_VERSION}-${PKG_TAG}.tar.gz"

SRC="${SRC:-/usr/local/src/accel-ppp}"
LIBDIR="$(gcc -print-multiarch >/dev/null 2>&1 && echo "/usr/lib/$(gcc -print-multiarch)" || echo /usr/lib/x86_64-linux-gnu)"

C_G=$'\033[32m'; C_Y=$'\033[33m'; C_0=$'\033[0m'
log()  { printf '[*] %s\n' "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行"; exit 1; }
[ "$(uname -m)" = "x86_64" ] || { echo "只支持 x86_64"; exit 1; }

. /etc/os-release
if [ "${VERSION_ID:-}" != "20.04" ]; then
    warn "当前是 Ubuntu ${VERSION_ID}，不是 20.04。"
    warn "编译出来的包将无法在低于 ${VERSION_ID} 的系统上运行。"
    printf '继续？[y/N] '; read -r a; [ "$a" = "y" ] || exit 1
fi

log "安装构建依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    build-essential cmake git \
    libssl-dev libpcre2-dev zlib1g-dev pkg-config

log "拉取 accel-ppp 源码"
rm -rf "$SRC"
if [ -n "$ACCEL_PPP_TAG" ]; then
    git clone --depth 1 --branch "$ACCEL_PPP_TAG" https://github.com/accel-ppp/accel-ppp.git "$SRC"
else
    git clone --depth 1 https://github.com/accel-ppp/accel-ppp.git "$SRC"
fi
cd "$SRC"
ok "源码版本：$(git rev-parse --short HEAD)"

log "改用静态 OpenSSL（去掉对 libcrypto.so.1.1 的动态依赖）"
[ -f "$LIBDIR/libssl.a" ] && [ -f "$LIBDIR/libcrypto.a" ] \
    || { echo "找不到 $LIBDIR/libssl.a，装 libssl-dev"; exit 1; }
cp CMakeLists.txt CMakeLists.txt.orig
sed -i "s|^[[:space:]]*set(crypto_lib crypto ssl).*|set(crypto_lib ${LIBDIR}/libssl.a ${LIBDIR}/libcrypto.a z dl)|" CMakeLists.txt
grep -q "libcrypto.a" CMakeLists.txt || { echo "补丁没打上，CMakeLists 结构变了"; exit 1; }
ok "已改为静态链接"

log "编译"
rm -rf build-pkg/pkgroot
mkdir -p build-pkg && cd build-pkg
cmake -DCMAKE_INSTALL_PREFIX=/usr \
      -DRADIUS=FALSE -DSHAPER=FALSE -DLOG_PGSQL=FALSE .. 2>&1 | tail -3
make -j"$(nproc)"
make install DESTDIR="$SRC/build-pkg/pkgroot"
ok "编译完成"

log "验证没有残留的动态 OpenSSL 依赖"
bad=0
for f in "$SRC/build-pkg/pkgroot"/usr/sbin/accel-pppd \
         "$SRC/build-pkg/pkgroot"/usr/lib64/accel-ppp/*.so; do
    if ldd "$f" 2>&1 | grep -qE "libcrypto\.so|libssl\.so"; then
        echo "  x $(basename "$f") 仍动态依赖 OpenSSL"; bad=1
    fi
done
[ "$bad" -eq 0 ] || { echo "静态链接失败，中止"; exit 1; }
ok "校验通过"

log "打包"
OUT="$(pwd)/../../dist"
mkdir -p "$OUT"
rm -f "$OUT/$OUT_NAME"
# 排除 ./usr/var —— accel-ppp 的 install 规则会把日志目录装成 /usr/var，
# 正确位置是 /var/log，由 install.sh 自己创建
tar czf "$OUT/$OUT_NAME" --exclude=./usr/var -C "$SRC/build-pkg/pkgroot" ./usr
cd "$OUT"
sha256sum "$OUT_NAME" > SHA256SUMS
ok "产物：$OUT/$OUT_NAME  ($(du -h "$OUT_NAME" | cut -f1))"
cat SHA256SUMS
