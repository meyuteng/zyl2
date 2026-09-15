#!/usr/bin/env bash
#
# accel-ppp L2TP 服务端一键部署脚本（不启用 IPsec）
#
#   默认：账号 123 / 密码 123 / 允许任意来源连接 / 隧道不加密
#
# 用法：
#   bash install.sh
#   curl -fsSL <你的仓库地址>/install.sh | bash
#
# 可用环境变量覆盖默认值：
#   L2TP_USER=foo L2TP_PASS=bar bash install.sh
#
# 支持：Ubuntu 20.04 / 22.04 / 24.04 / 26.04 (x86_64)
#       更低版本会自动降级为源码编译（需要联网 + 几分钟）
#
set -euo pipefail

# ============================ 可配置项 ============================
# 预编译包所在仓库。你 push 到 GitHub 后把下面两行改成自己的。
GITHUB_USER="${GITHUB_USER:-YOUR_GITHUB_USER}"
GITHUB_REPO="${GITHUB_REPO:-YOUR_GITHUB_REPO}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"

# 也可以直接指定一个基址，覆盖上面的拼装结果
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}}"

L2TP_USER="${L2TP_USER:-123}"
L2TP_PASS="${L2TP_PASS:-123}"
L2TP_PORT="${L2TP_PORT:-1701}"

GW_IP="${GW_IP:-172.28.42.1}"            # 隧道网关（服务端侧）
POOL_RANGE="${POOL_RANGE:-172.28.42.10-250}"  # 分配给客户端的地址池
PPP_MTU="${PPP_MTU:-1400}"               # 无 IPsec 时 1400 很安全，可上到 1450
DNS1="${DNS1:-8.8.8.8}"
DNS2="${DNS2:-8.8.4.4}"

# 1 = 允许任意来源连接（[client-ip-range] 0.0.0.0/0）
# 0 = 只允许 CLIENT_ALLOW 里列出的网段
ALLOW_ALL="${ALLOW_ALL:-1}"
CLIENT_ALLOW="${CLIENT_ALLOW:-0.0.0.0/0}"

PKG_VERSION="1.14.0"
# ==================================================================

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'

log()  { printf '%s[*]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 运行（sudo bash install.sh）"

# ============================ 环境检测 ============================
log "检测系统环境"

[ -r /etc/os-release ] || die "读不到 /etc/os-release，不像是 Linux 发行版"
. /etc/os-release
DISTRO_ID="${ID:-unknown}"
DISTRO_VER="${VERSION_ID:-0}"
case "$DISTRO_ID" in
  ubuntu|debian) ;;
  *) warn "只在 Ubuntu/Debian 上验证过，当前是 ${PRETTY_NAME:-$DISTRO_ID}，继续但可能出问题" ;;
esac

ARCH="$(uname -m)"
[ "$ARCH" = "x86_64" ] || die "预编译包只提供 x86_64，当前是 $ARCH。请改用 build.sh 在本机编译。"

# 从 VERSION_ID 取主版本号（如 20.04 -> 20）
VER_MAJOR="${DISTRO_VER%%.*}"
glibc_ver="$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$' || echo 0)"
ok "系统 ${PRETTY_NAME:-$DISTRO_ID} / ${ARCH} / glibc ${glibc_ver}"

# ============================ 安装依赖 ============================
log "安装运行时依赖"
export DEBIAN_FRONTEND=noninteractive
# </dev/null：本脚本常用 `curl ... | bash` 方式运行，此时 stdin 就是脚本自身。
# apt/dpkg 若从 stdin 读数据会把后面的脚本吃掉，导致执行到一半断掉。
apt-get update -qq </dev/null

# iptables 在新版 Ubuntu 最小化镜像里不一定预装
# linux-modules-extra 提供内核 L2TP 模块（l2tp_netlink / l2tp_ppp），
#   有了它 accel-ppp 才能把数据面交给内核，没有则退回用户态（能跑但更费 CPU）
apt-get install -y -qq --no-install-recommends \
    iptables iproute2 curl ca-certificates kmod procps </dev/null || true

KREL="$(uname -r)"
if apt-get install -y -qq --no-install-recommends "linux-modules-extra-${KREL}" </dev/null 2>/dev/null; then
    ok "内核模块包装好了（linux-modules-extra-${KREL}）"
else
    warn "装不上 linux-modules-extra-${KREL}（自定义内核？）"
    warn "accel-ppp 将退回用户态 L2TP，能正常用，但 CPU 占用会高一些"
fi
ok "依赖就绪"

# ============================ 安装二进制 ============================
cleanup_partial() {
    rm -rf /usr/lib64/accel-ppp /usr/share/accel-ppp
    rm -f /usr/sbin/accel-pppd /usr/bin/accel-cmd
}

install_prebuilt() {
    local url="${REPO_RAW}/dist/accel-ppp-${PKG_VERSION}-ubuntu20.04-x86_64.tar.gz"
    local sums="${REPO_RAW}/dist/SHA256SUMS"
    local tmp; tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN

    log "下载预编译包：$url"
    curl -fsSL --connect-timeout 20 -o "$tmp/pkg.tar.gz" "$url" || return 1
    curl -fsSL --connect-timeout 20 -o "$tmp/SHA256SUMS"  "$sums" 2>/dev/null || true

    if [ -s "$tmp/SHA256SUMS" ]; then
        local want got
        want="$(grep -E "accel-ppp-${PKG_VERSION}-ubuntu20.04-x86_64.tar.gz" "$tmp/SHA256SUMS" | awk '{print $1}' || true)"
        if [ -n "$want" ]; then
            got="$(sha256sum "$tmp/pkg.tar.gz" | awk '{print $1}')"
            [ "$want" = "$got" ] || { warn "SHA256 校验失败"; return 1; }
            ok "SHA256 校验通过"
        fi
    else
        warn "没有 SHA256SUMS，跳过校验"
    fi

    log "解包到 /"
    tar -xzf "$tmp/pkg.tar.gz" -C / || return 1
    chmod 755 /usr/sbin/accel-pppd /usr/bin/accel-cmd
    return 0
}

probe_binary() {
    # 真正跑一次，确认二进制在这台机器上能用（能捕获 glibc 版本不匹配）
    local p=$((L2TP_PORT + 10000))
    cat > /tmp/accel-probe.conf <<EOF
[modules]
log_file
l2tp
ippool
[core]
log-error=/tmp/accel-probe.log
[l2tp]
port=${p}
ip-pool=probe
[ip-pool]
gw-ip-address=10.99.99.1
10.99.99.10-20,name=probe
[client-ip-range]
0.0.0.0/0
EOF
    rm -f /tmp/accel-probe.pid /tmp/accel-probe.err
    if ! /usr/sbin/accel-pppd -c /tmp/accel-probe.conf -p /tmp/accel-probe.pid -d \
            2>/tmp/accel-probe.err; then
        return 1
    fi
    sleep 2
    local pid; pid="$(cat /tmp/accel-probe.pid 2>/dev/null || echo)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        sleep 1
        return 0
    fi
    return 1
}

build_from_source() {
    warn "改用源码编译（需要几分钟）"
    apt-get install -y -qq --no-install-recommends \
        build-essential cmake git libssl-dev libpcre2-dev zlib1g-dev pkg-config </dev/null \
        || die "构建依赖安装失败"

    local src=/usr/local/src/accel-ppp
    rm -rf "$src"
    git clone --depth 1 https://github.com/accel-ppp/accel-ppp.git "$src" \
        || die "克隆 accel-ppp 源码失败（检查网络）"
    cd "$src"
    mkdir -p build && cd build
    cmake -DCMAKE_INSTALL_PREFIX=/usr \
          -DRADIUS=FALSE -DSHAPER=FALSE -DLOG_PGSQL=FALSE .. >/tmp/accel-build.log 2>&1 \
        || { tail -20 /tmp/accel-build.log; die "cmake 配置失败"; }
    make -j"$(nproc)" >>/tmp/accel-build.log 2>&1 \
        || { tail -20 /tmp/accel-build.log; die "编译失败"; }
    make install >>/tmp/accel-build.log 2>&1 || die "安装失败"
    cd /
    ok "源码编译完成"
}

log "安装 accel-ppp ${PKG_VERSION}"

# 停掉可能存在的旧实例，避免覆盖正在运行的文件
systemctl stop accel-ppp 2>/dev/null || true

USED_PREBUILT=0
cleanup_partial
if install_prebuilt; then
    if probe_binary; then
        USED_PREBUILT=1
        ok "预编译包可用"
    else
        warn "预编译包在本机跑不起来（多半是 glibc 太旧）"
        cat /tmp/accel-probe.err 2>/dev/null | head -3 | sed 's/^/    /' || true
        cleanup_partial
    fi
else
    warn "预编译包下载失败"
fi

if [ "$USED_PREBUILT" -eq 0 ]; then
    build_from_source
fi

[ -x /usr/sbin/accel-pppd ] || die "accel-pppd 未安装成功"
ok "accel-pppd 就位：$(/usr/sbin/accel-pppd 2>&1 | head -1 || echo '')"

# ============================ 内核模块 ============================
log "加载内核 L2TP 模块"
modprobe l2tp_netlink 2>/dev/null || true
modprobe l2tp_ppp 2>/dev/null || true
cat > /etc/modules-load.d/l2tp.conf <<'EOF'
l2tp_netlink
l2tp_ppp
EOF
if lsmod | grep -q '^l2tp_ppp'; then
    ok "内核 L2TP 已启用（数据面走内核，CPU 占用最低）"
else
    warn "内核 L2TP 未加载，accel-ppp 将使用用户态 L2TP"
fi

# ============================ 配置文件 ============================
log "生成配置"

mkdir -p /etc/accel-ppp /var/log/accel-ppp /var/lib/accel-ppp
chmod 700 /etc/accel-ppp

[ -f /etc/accel-ppp.conf ] && cp -a /etc/accel-ppp.conf "/etc/accel-ppp.conf.bak.$(date +%Y%m%d-%H%M%S)"

# 允许来源：0.0.0.0/0 会被 accel-ppp 解析为「关闭来源过滤 = 放行所有」
# 注意语义是反的——写别的网段才是真的白名单
if [ "$ALLOW_ALL" = "1" ]; then
    RANGE_LINE="0.0.0.0/0"
else
    RANGE_LINE="$CLIENT_ALLOW"
fi

cat > /etc/accel-ppp.conf <<EOF
# accel-ppp L2TP LNS 配置（由 install.sh 生成）
# 注意：L2TP 本身不加密，本配置不启用 IPsec。

[modules]
log_file
l2tp
chap-secrets
auth_chap_md5
auth_mschap_v1
auth_mschap_v2
auth_pap
ippool
connlimit

[core]
log-error=/var/log/accel-ppp/core.log
thread-count=1

[common]
# 不要开 single-session=replace：
# 同一个账号多设备登录时，开了会互相踢下线。
#single-session=replace

[l2tp]
verbose=0
bind=0.0.0.0
port=${L2TP_PORT}
dictionary=/usr/share/accel-ppp/l2tp/dictionary
host-name=l2tpd
hello-interval=60
timeout=60
rtimeout=1
rtimeout-cap=16
retransmit=5
recv-window=16
ip-pool=l2tp

[ppp]
verbose=0
min-mtu=1280
mtu=${PPP_MTU}
mru=${PPP_MTU}
ipv4=require
ipv6=deny
lcp-echo-interval=30
lcp-echo-failure=4
unit-cache=1

[dns]
dns1=${DNS1}
dns2=${DNS2}

[ip-pool]
gw-ip-address=${GW_IP}
${POOL_RANGE},name=l2tp

[chap-secrets]
gw-ip-address=${GW_IP}
chap-secrets=/etc/accel-ppp/chap-secrets

[log]
log-file=/var/log/accel-ppp/accel-ppp.log
log-emerg=/var/log/accel-ppp/emerg.log
log-fail-file=/var/log/accel-ppp/auth-fail.log
copy=1
level=3

[cli]
telnet=127.0.0.1:2000
tcp=127.0.0.1:2001
verbose=1

[client-ip-range]
${RANGE_LINE}

[connlimit]
limit=100/min
burst=20
timeout=60
EOF

cat > /etc/accel-ppp/chap-secrets <<EOF
# client        server  secret          IP addresses
"${L2TP_USER}"  *       "${L2TP_PASS}"  *
EOF
chmod 600 /etc/accel-ppp/chap-secrets

cat > /etc/logrotate.d/accel-ppp <<'EOF'
/var/log/accel-ppp/*.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
ok "配置写入 /etc/accel-ppp.conf"

# ============================ systemd 服务 ============================
log "配置 systemd 服务"
cat > /etc/systemd/system/accel-ppp.service <<'EOF'
[Unit]
Description=accel-ppp (L2TP LNS)
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStart=/usr/sbin/accel-pppd -d -p /var/run/accel-pppd.pid -c /etc/accel-ppp.conf
PIDFile=/var/run/accel-pppd.pid
ExecReload=/bin/kill -SIGUSR1 $MAINPID
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# ============================ 系统调优 ============================
log "写入 sysctl 调优"
cat > /etc/sysctl.d/99-l2tp.conf <<'EOF'
# L2TP / accel-ppp
net.ipv4.ip_forward = 1

# 默认 socket 缓冲 208KB 在高带宽下会打满并触发丢包，
# 表现为服务端疯狂刷 "send buffer full" 日志把 CPU 拖满
net.core.wmem_default = 4194304
net.core.rmem_default = 4194304
net.core.wmem_max = 12582912
net.core.rmem_max = 12582912
net.core.netdev_max_backlog = 2500
EOF
sysctl -q --system 2>/dev/null || true
ok "ip_forward = $(cat /proc/sys/net/ipv4/ip_forward)"

# ============================ 防火墙 / NAT ============================
log "配置 NAT 与转发规则"

NET="$(echo "$GW_IP" | cut -d. -f1-3).0/24"
DEF_IF="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
[ -n "$DEF_IF" ] || die "找不到默认出口网卡，无法配置 NAT"

cat > /usr/local/sbin/l2tp-firewall.sh <<EOF
#!/bin/sh
# 由 install.sh 生成，systemd 开机自动执行
set -e
NET="${NET}"
IF="${DEF_IF}"

iptables -C INPUT -p udp --dport ${L2TP_PORT} -j ACCEPT 2>/dev/null || \\
    iptables -A INPUT -p udp --dport ${L2TP_PORT} -j ACCEPT

iptables -t nat -C POSTROUTING -s "\$NET" -o "\$IF" -j MASQUERADE 2>/dev/null || \\
    iptables -t nat -A POSTROUTING -s "\$NET" -o "\$IF" -j MASQUERADE

iptables -C FORWARD -s "\$NET" -j ACCEPT 2>/dev/null || iptables -A FORWARD -s "\$NET" -j ACCEPT
iptables -C FORWARD -d "\$NET" -j ACCEPT 2>/dev/null || iptables -A FORWARD -d "\$NET" -j ACCEPT

# TCP MSS 钳制，避免客户端遭遇 PMTU 黑洞
iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \\
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
EOF
chmod 755 /usr/local/sbin/l2tp-firewall.sh

cat > /etc/systemd/system/l2tp-firewall.service <<'EOF'
[Unit]
Description=L2TP NAT/forward rules
Before=accel-ppp.service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/l2tp-firewall.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable -q l2tp-firewall.service
/usr/local/sbin/l2tp-firewall.sh
ok "NAT 规则已生效（出口网卡 ${DEF_IF}，网段 ${NET}）"

# ufw 若开着，单独放行一下
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    ufw allow "${L2TP_PORT}/udp" >/dev/null 2>&1 || true
    ufw route allow from "$NET" >/dev/null 2>&1 || true
    warn "检测到 ufw 处于启用状态，已尝试放行 ${L2TP_PORT}/udp，请自行确认 ufw 未拦截转发"
fi

# ============================ 启动 ============================
log "启动服务"
systemctl enable -q accel-ppp.service
systemctl restart accel-ppp.service
sleep 3

systemctl is-active --quiet accel-ppp.service \
    || { warn "accel-ppp 启动失败，日志："; tail -20 /var/log/accel-ppp/accel-ppp.log 2>/dev/null; \
         journalctl -u accel-ppp -n 20 --no-pager 2>/dev/null; exit 1; }

if ss -lunp 2>/dev/null | grep -q ":${L2TP_PORT} "; then
    ok "accel-ppp 已在 UDP ${L2TP_PORT} 监听"
else
    die "accel-ppp 起来了但没有监听 ${L2TP_PORT}，检查 /var/log/accel-ppp/"
fi

PUB_IP="$(curl -fsS --connect-timeout 5 https://api.ipify.org 2>/dev/null || echo '<本机公网IP>')"

cat <<EOF

${C_G}==================== 部署完成 ====================${C_0}

  服务端地址 : ${PUB_IP}:${L2TP_PORT}  (UDP)
  账号       : ${L2TP_USER}
  密码       : ${L2TP_PASS}
  地址池     : ${POOL_RANGE}   网关 ${GW_IP}
  MTU / MRU  : ${PPP_MTU}
  DNS        : ${DNS1} / ${DNS2}

${C_Y}客户端连接类型请选「L2TP」，不要勾选 IPsec / 预共享密钥。${C_0}

  常用命令：
    查看会话   printf "show sessions\r\n" | timeout 3 nc 127.0.0.1 2000
    服务状态   systemctl status accel-ppp
    实时日志   tail -f /var/log/accel-ppp/accel-ppp.log
    卸载       bash uninstall.sh

${C_R}安全提醒${C_0}
  当前配置是：不加密的 L2TP + 允许任意来源 + 弱口令。
  隧道内容可被中间人看到，口令也可能被爆破。
  仅建议用于自用中转；对公网长期开放请务必换强口令并考虑加固。

EOF
