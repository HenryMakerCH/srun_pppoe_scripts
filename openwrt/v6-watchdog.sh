#!/bin/sh
# /etc/srun/v6-watchdog.sh —— cron 每 5 分钟跑一次
# PPP 已连上（srun 有 IPv4）但没有全局 IPv6 → 重启 odhcp6c 重新收 RA。
# 典型触发：odhcp6c 自己崩了，或某次拨号时 BRAS 的 RA 丢了。

IFACE=srun
P6=/var/run/srun6.pid

ip -4 addr show dev "$IFACE" 2>/dev/null | grep -q "inet " || exit 0
ip -6 addr show dev "$IFACE" 2>/dev/null | grep -q "inet6 2" && exit 0

logger -t srun-ipv6 "watchdog: $IFACE 没有全局 v6，重启 odhcp6c"
/sbin/start-stop-daemon -K -q -p "$P6" 2>/dev/null
rm -f "$P6"
/sbin/start-stop-daemon -S -q -b -m -p "$P6" -x /usr/sbin/odhcp6c -- -s /etc/srun/v6.sh -f "$IFACE"
exit 0
