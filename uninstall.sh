#!/usr/bin/env bash
#
# 卸载 accel-ppp L2TP 服务，回滚 install.sh 做的改动。
#
#   bash uninstall.sh            保留 /etc/accel-ppp.conf 和日志
#   bash uninstall.sh --purge    连配置和日志一起删
#
set -euo pipefail

C_R=$'\033[31m'; C_Y=$'\033[33m'; C_0=$'\033[0m'
die() { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "请用 root 运行"

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

echo "[*] 停止并禁用服务"
systemctl stop accel-ppp 2>/dev/null || true
systemctl disable accel-ppp 2>/dev/null || true
systemctl stop l2tp-firewall 2>/dev/null || true
systemctl disable l2tp-firewall 2>/dev/null || true

echo "[*] 移除 systemd 单元"
rm -f /etc/systemd/system/accel-ppp.service
rm -f /etc/systemd/system/l2tp-firewall.service
systemctl daemon-reload

echo "[*] 移除 NAT / 转发规则"
NET="$(grep -oE '^NET="[^"]+"' /usr/local/sbin/l2tp-firewall.sh 2>/dev/null | cut -d'"' -f2 || true)"
IF="$(grep -oE '^IF="[^"]+"' /usr/local/sbin/l2tp-firewall.sh 2>/dev/null | cut -d'"' -f2 || true)"
if [ -n "${NET:-}" ]; then
    iptables -t nat -D POSTROUTING -s "$NET" -o "${IF:-eth0}" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -s "$NET" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -d "$NET" -j ACCEPT 2>/dev/null || true
fi
iptables -D INPUT -p udp --dport 1701 -j ACCEPT 2>/dev/null || true
iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
rm -f /usr/local/sbin/l2tp-firewall.sh

echo "[*] 移除二进制"
rm -f /usr/sbin/accel-pppd /usr/bin/accel-cmd
rm -rf /usr/lib64/accel-ppp /usr/share/accel-ppp /usr/share/man/man5/accel-ppp.conf.5
rm -f /usr/share/man/man1/accel-cmd.1

echo "[*] 移除开机模块加载与 sysctl 调优"
rm -f /etc/modules-load.d/l2tp.conf
rm -f /etc/sysctl.d/99-l2tp.conf
rm -f /etc/logrotate.d/accel-ppp

if [ "$PURGE" -eq 1 ]; then
    echo "[*] 删除配置与日志"
    rm -rf /etc/accel-ppp /var/log/accel-ppp /var/lib/accel-ppp
else
    echo "[ ] 保留 /etc/accel-ppp.conf、/etc/accel-ppp/、/var/log/accel-ppp/"
    echo "    需要彻底清理请运行：bash uninstall.sh --purge"
fi

echo
echo "${C_Y}注意：net.ipv4.ip_forward 保持为 1，如果这台机器不再需要转发请自行关闭。${C_0}"
echo "卸载完成。"
