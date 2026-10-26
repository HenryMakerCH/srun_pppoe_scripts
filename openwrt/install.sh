#!/bin/sh
# install.sh —— 在 OpenWrt 路由器上安装 srun.pppoe 拨号服务
#
# 用法（把本目录整体传到路由器后）：
#   sh /tmp/srun-src/install.sh
#
# 幂等：可以反复执行。不会覆盖你已有的 /etc/srun/account、/etc/srun/passwd。

set -e

# ---------------- 按你的环境改这几个 ----------------
IFACE=wan                      # 做 PPPoE 的物理网卡（OpenWrt 上一般是 wan）
ENTRY=srun                     # 生成的 ppp 接口名
TZ_SPEC=CST-8                  # POSIX 时区（tag 用本地当日秒数，必须对）
TZ_NAME=Asia/Shanghai
DNS_UPSTREAM=10.1.1.1          # 校园网 DNS；留空则只用服务器下发的
DOMAIN=stu                     # 账号后缀：stu / teacher / other / none
# ----------------------------------------------------

SRC=$(cd "$(dirname "$0")" && pwd)

[ "$(id -u)" = "0" ] || { echo "请用 root 运行" >&2; exit 1; }

echo "== 1/7 安装文件"
install -m 755 "$SRC/srun.sh"      /usr/bin/srun.sh
install -m 755 "$SRC/srun.init"    /etc/init.d/srun
install -m 755 "$SRC/ppp-ip-up"    /etc/ppp/ip-up
install -m 755 "$SRC/ppp-ip-down"  /etc/ppp/ip-down
install -m 755 "$SRC/srun.sh"      /usr/bin/srun.sh
mkdir -p /etc/srun && chmod 700 /etc/srun
[ -f /etc/srun/account ] || : > /etc/srun/account
[ -f /etc/srun/passwd ]  || : > /etc/srun/passwd
chmod 600 /etc/srun/account /etc/srun/passwd

echo "== 2/7 检查依赖（ppp + pppoe 插件）"
if ! command -v pppd >/dev/null 2>&1; then
	echo "缺少 pppd：请先装 ppp（apk add ppp ppp-mod-pppoe）" >&2
	exit 1
fi
ls /usr/lib/pppd/*/pppoe.so >/dev/null 2>&1 || {
	echo "警告：找不到 /usr/lib/pppd/*/pppoe.so，装 ppp-mod-pppoe" >&2
}

echo "== 3/7 时区（tag 用本地当日秒数，必须对）"
uci set system.@system[0].timezone="$TZ_SPEC"
uci set system.@system[0].zonename="$TZ_NAME"
uci commit system
/etc/init.d/system reload 2>/dev/null || true

echo "== 4/7 把 $IFACE 从 netifd 手里交出来（否则 udhcpc 和 pppd 抢网口）"
uci set network.wan.proto='none'
uci set network.wan6.disabled='1'
uci commit network
ifup wan 2>/dev/null || true

echo "== 5/7 防火墙：$ENTRY 加入 wan 区（要 NAT + MSS clamp）"
uci -q del_list firewall.@zone[1].device="$ENTRY"
uci add_list firewall.@zone[1].device="$ENTRY"
uci commit firewall
/etc/init.d/firewall restart 2>/dev/null || true

if [ -n "$DNS_UPSTREAM" ]; then
	echo "== 6/7 dnsmasq 静态上游 $DNS_UPSTREAM（防止 ip-down 竞态清空上游）"
	uci -q del_list dhcp.@dnsmasq[0].server="$DNS_UPSTREAM"
	uci add_list dhcp.@dnsmasq[0].server="$DNS_UPSTREAM"
	uci commit dhcp
	/etc/init.d/dnsmasq restart 2>/dev/null || true
else
	echo "== 6/7 跳过静态上游 DNS"
fi

echo "== 7/7 开机对时兜底 + 自启"
grep -q '/etc/srun/timestamp' /etc/crontabs/root 2>/dev/null || {
	echo '*/1 * * * * touch /etc/srun/timestamp' >> /etc/crontabs/root
}
/etc/init.d/cron restart 2>/dev/null || true
touch /etc/srun/timestamp
/etc/init.d/srun enable

cat <<EOF

装好了。接下来两步（脚本不碰你的凭据）：

  1) 写账号：  echo '学号@stu.nchu.edu.cn' > /etc/srun/account
  2) 写密码：  umask 077; cat > /etc/srun/passwd    (输入密码，回车后 Ctrl-D)

然后先空跑确认账号编码：
  /usr/bin/srun.sh encode

真拨一次看日志：
  /usr/bin/srun.sh dial --once

通了之后启动服务：
  /etc/init.d/srun start
  /usr/bin/srun.sh status

排障：logread | grep srun ; cat /var/log/pppd-srun.log
EOF
