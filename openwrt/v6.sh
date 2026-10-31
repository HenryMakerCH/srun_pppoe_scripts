#!/bin/sh
# /etc/srun/v6.sh —— odhcp6c 回调：把 BRAS 的 RA 里的全局地址和默认路由装到 PPP 接口上
# 由 /etc/ppp/ip-up 启动的 odhcp6c 调用（单实例，pid 记在 /var/run/srun6.pid）
#
# 为什么不走 netifd：netifd 一旦把这个设备当成自己的 interface（proto dhcpv6），
# 会在 setup/teardown 时把 pppd 刚分配好的 IPv4/IPv6 地址一起 flush，直接断网。
#
# 每次 RA 续期（约 5 分钟一次）BRAS 都会回调本脚本，但地址通常没变。所以先比对
# 「应该有」和「现在有」：一样就静默退出 —— 既不删了再加（会短暂断 v6），也不刷日志。

IFACE="${IFACE:-srun}"

log() { logger -t srun-ipv6 "$*"; }

# 把空格分隔的列表规范化成 "a b " 的形式；两边用同一个函数比，才不会被首尾空格搞到永远不相等
norm() { printf '%s' "$1" | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' '; }

# ---- 从 odhcp6c 传进来的环境算出目标状态 ----
want_addrs=""
for entry in $RA_ADDRESSES; do
	addr=${entry%%,*}
	[ -n "$addr" ] && want_addrs="$want_addrs $addr"
done

want_addrs="$(norm "$want_addrs")"

# 没有 RA 数据（例如手动执行本脚本、或 odhcp6c 只回了个空状态）就什么都不做。
# 少这一行的话，手动跑一次会把现网的全局 v6 地址和默认路由全删掉。
[ -n "$want_addrs" ] || exit 0

want_gw=""
for entry in $RA_ROUTES; do
	dest=${entry%%,*}
	[ "$dest" = "::/0" ] || continue
	rest=${entry#*,}
	want_gw=${rest%%,*}
	[ -n "$want_gw" ] && break
done

want="$want_addrs|$want_gw"

# ---- 现在的实际状态（只看全局地址和默认路由，fe80 是 IPv6CP 协商来的不动）----
have_addrs="$(norm "$(ip -6 addr show dev "$IFACE" 2>/dev/null | awk '/inet6 (2|3)/{print $2}')")"
have_gw="$(ip -6 route show default dev "$IFACE" 2>/dev/null | awk '{print $3}' | head -1)"
have="$have_addrs|$have_gw"

[ "$want" = "$have" ] && exit 0

# ---- 有变化才动 ----
for a in $have_addrs; do
	ip -6 addr del "$a" dev "$IFACE" 2>/dev/null
done
ip -6 route del default dev "$IFACE" 2>/dev/null

for addr in $want_addrs; do
	ip -6 addr add "$addr" dev "$IFACE" 2>/dev/null
done
[ -n "$want_gw" ] && ip -6 route add default via "$want_gw" dev "$IFACE" 2>/dev/null

log "v6 更新: ${want_addrs}| via ${want_gw:-none}"
exit 0
