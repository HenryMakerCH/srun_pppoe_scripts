#!/bin/sh
# srun.sh —— Srun 深澜 PPPoE 独立拨号器 (Linux / OpenWrt / 任何有 pppd 的系统)
#
# 账号编码算法与 Windows 版 srun.ps1 完全一致:
#     {S4}<tag>\r\n<hex><@域名>
#     tag = 当日已过秒数(本地) + sum(账号 @ 前面各字节)      ← 17 位, 不加任何前缀位
#     hex = 账号 @ 前面每个字节 +4 的两位小写十六进制
#
# 依赖: pppd (含 rp-pppoe.so 插件)、od、date
#   Debian/Ubuntu: apt install ppp
#   OpenWrt:       opkg install ppp ppp-mod-pppoe
#
# 用法见 `srun.sh help`。

set -u

VERSION="1.0.0"
DOMAIN_STU="stu.nchu.edu.cn"
DOMAIN_TEACHER="nchu.edu.cn"
DOMAIN_OTHER="tmp"

IFACE="eth0"
DOMAIN="stu"
ENTRY="srun"
TS=""
USER_=""
PASS=""
PASSFILE=""
ONCE=0
DRY=0
RAW=0
HOLDOFF=10
MTU=1492
PIDFILE="/var/run/srun.pid"
LOGFILE="/var/log/srun.log"

# ---------------------------------------------------------------- 帮助
show_help() {
cat <<'EOF'

  srun.sh  ——  Srun PPPoE 独立拨号器 (Linux / OpenWrt)
  不依赖官方客户端，账号编码算法是逆向出来的

  用法    srun.sh <动作> [参数]

  动作
    help        显示这段帮助
    encode      只打印编码后的账号，不拨号（调试用）
    dial        拨号（前台运行，断线自动用新 tag 重拨）
    up          拨号（后台运行，日志写 /var/log/srun.log）
    down        断开
    status      查看状态
    service     打印可直接用的 systemd unit

  参数
    -i <网卡>       做 PPPoE 的物理网卡，默认 eth0
    -u <学号>       不带 @ 时按 -d 拼后缀
    -d <域>         stu(默认)=@stu.nchu.edu.cn  teacher=@nchu.edu.cn
                    other=@tmp  none=不加后缀
    -p <密码>       不推荐（ps 里可见）
    -f <文件>       从文件读密码（默认尝试 /etc/srun/passwd）
                    ← 推荐: echo '你的密码' > /etc/srun/passwd && chmod 600 /etc/srun/passwd
    -n <名字>       ppp 接口名，默认 srun
    -t <unix秒>     encode 用：按指定时刻编码（测试用）
    --once          只拨一次，失败就退出（默认无限重试）
    --holdoff <秒>  重拨间隔，默认 10
    --mtu <n>       MTU，默认 1492
    --dry           只打印要交给 pppd 的账号，不拨号

  例子
    srun.sh encode -u 20240001
    srun.sh dial   -i enp3s0 -u 20240001 -f /etc/srun/passwd
    srun.sh up     -i eth0   -u 20240001
    srun.sh down
    srun.sh status

  密码来源优先级
    -p  >  -f/--passfile  >  环境变量 SRUN_PASS  >  交互输入

  常见失败
    认证失败 / 一直 reconnecting   多半是 tag 与服务器时钟不同步：
                                   先对时(chronyc tracking)，再看 encode 的输出
    pppd: Plugin rp-pppoe.so not found   ppp-mod-pppoe 没装
    Timeout waiting for PADO          网线没插 / 不在校园网内 / 网口不对
    628 一类的会话冲突                 上一个会话没断：先 srun.sh down，等 30 秒

EOF
}

# ---------------------------------------------------------------- 编码
# 输出: {S4}tag CR LF hex @domain   (含真实 CR LF 字节)
encode_account() {
    _acct="$1"
    _ts="${2:-}"

    case "$_acct" in
        *@*) _local="${_acct%%@*}"; _rest="${_acct#"$_local"}" ;;
        *)   _local="$_acct";      _rest="" ;;
    esac

    if [ -n "$_ts" ]; then
        _h=$(date -d "@$_ts" +%H); _m=$(date -d "@$_ts" +%M); _s=$(date -d "@$_ts" +%S)
    else
        _h=$(date +%H); _m=$(date +%M); _s=$(date +%S)
    fi
    # 去掉前导 0，避免 shell 把 08 / 09 当八进制
    _h=${_h#0}; _m=${_m#0}; _s=${_s#0}
    _sod=$(( ${_h:-0} * 3600 + ${_m:-0} * 60 + ${_s:-0} ))

    _bytes=$(printf '%s' "$_local" | od -An -tu1 -v)
    _sum=0
    _hex=""
    for _b in $_bytes; do
        _sum=$(( _sum + _b ))
        _hex="${_hex}$(printf '%02x' $(( _b + 4 )))"
    done

    _tag=$(( _sod + _sum ))
    printf '{S4}%x\r\n%s%s' "$_tag" "$_hex" "$_rest"
}

# ---------------------------------------------------------------- 参数
ACTION=""
while [ $# -gt 0 ]; do
    case "$1" in
        help|-h|--help) ACTION="help"; shift ;;
        encode|dial|up|down|status|service) ACTION="$1"; shift ;;
        -i) IFACE="$2"; shift 2 ;;
        -u) USER_="$2"; shift 2 ;;
        -d) DOMAIN="$2"; shift 2 ;;
        -p) PASS="$2"; shift 2 ;;
        -f|--passfile) PASSFILE="$2"; shift 2 ;;
        -n) ENTRY="$2"; shift 2 ;;
        -t) TS="$2"; shift 2 ;;
        --once) ONCE=1; shift ;;
        --holdoff) HOLDOFF="$2"; shift 2 ;;
        --mtu) MTU="$2"; shift 2 ;;
        --dry) DRY=1; shift ;;
        --raw) RAW=1; shift ;;
        *) echo "未知参数: $1 (看 srun.sh help)" >&2; exit 2 ;;
    esac
done

[ -z "$ACTION" ] && ACTION="help"

case "$DOMAIN" in
    stu)     SUFFIX="$DOMAIN_STU" ;;
    teacher) SUFFIX="$DOMAIN_TEACHER" ;;
    other)   SUFFIX="$DOMAIN_OTHER" ;;
    none)    SUFFIX="" ;;
    *) echo "未知域: $DOMAIN" >&2; exit 2 ;;
esac

resolve_account() {
    if [ -n "$USER_" ]; then
        case "$USER_" in
            *@*) printf '%s' "$USER_" ;;
            *)   if [ -n "$SUFFIX" ]; then printf '%s@%s' "$USER_" "$SUFFIX"; else printf '%s' "$USER_"; fi ;;
        esac
        return
    fi
    if [ -f /etc/srun/account ]; then
        tr -d ' \t\r\n' < /etc/srun/account
        return
    fi
    printf ''
}

resolve_password() {
    if [ -n "$PASS" ]; then printf '%s' "$PASS"; return; fi
    if [ -n "$PASSFILE" ]; then
        [ -r "$PASSFILE" ] || { echo "读不了密码文件: $PASSFILE" >&2; exit 1; }
        tr -d '\r\n' < "$PASSFILE"; return
    fi
    if [ -r /etc/srun/passwd ]; then tr -d '\r\n' < /etc/srun/passwd; return; fi
    if [ -n "${SRUN_PASS:-}" ]; then printf '%s' "$SRUN_PASS"; return; fi
    if [ -t 0 ]; then
        printf '密码: ' >&2
        stty -echo 2>/dev/null
        read -r _p
        stty echo 2>/dev/null
        echo >&2
        printf '%s' "$_p"
        return
    fi
    echo "没有密码：用 -p / -f 文件 / SRUN_PASS 环境变量" >&2
    exit 1
}

# ---------------------------------------------------------------- 动作
case "$ACTION" in

help)
    show_help
    ;;

encode)
    acct=$(resolve_account)
    [ -z "$acct" ] && { echo "需要 -u 学号" >&2; exit 1; }
    enc=$(encode_account "$acct" "$TS")
    if [ "$RAW" = "1" ]; then printf '%s' "$enc"; exit 0; fi
    printf '账号(明文): %s\n' "$acct"
    printf '交给 pppd 的账号:\n  '
    printf '%s' "$enc" | od -c | head -3
    printf '  注意: od 输出里的 \\r \\n 就是真实的 CR LF 字节（账号里必须带着）\n'
    ;;

dial|up)
    acct=$(resolve_account)
    [ -z "$acct" ] && { echo "需要 -u 学号（或写 /etc/srun/account）" >&2; exit 1; }

    # --dry: 只打印账号，不需要 root、不需要密码
    if [ "$DRY" = "1" ]; then
        enc=$(encode_account "$acct" "")
        printf '  [dry] %s 交给 pppd 的账号 (od -c，\\r \\n 是真实字节):\n' "$acct"
        printf '%s' "$enc" | od -An -c | sed 's/^/    /'
        exit 0
    fi

    pw=$(resolve_password)

    if [ "$ACTION" = "up" ]; then
        [ "$(id -u)" = "0" ] || { echo "up/dial 需要 root" >&2; exit 1; }
        if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
            echo "已经在跑了 (pid $(cat "$PIDFILE"))" >&2; exit 1
        fi
        # 后台跑自己，日志落盘
        nohup "$0" dial -i "$IFACE" -d "$DOMAIN" -n "$ENTRY" --holdoff "$HOLDOFF" --mtu "$MTU" \
              $( [ -n "$USER_" ] && echo "-u $USER_" ) $( [ -n "$PASSFILE" ] && echo "-f $PASSFILE" ) \
              >>"$LOGFILE" 2>&1 &
        echo "$!" > "$PIDFILE"
        echo "后台拨号已启动 pid=$! 日志: $LOGFILE"
        exit 0
    fi

    [ "$(id -u)" = "0" ] || { echo "拨号需要 root" >&2; exit 1; }

    # 编译期检查插件
    if ! pppd --version >/dev/null 2>&1; then echo "没装 pppd" >&2; exit 1; fi

    trap 'echo; echo "收到信号，收尾…"; exit 0' INT TERM

    attempt=0
    while :; do
        attempt=$(( attempt + 1 ))
        # tag 每秒都在变 —— 每次重拨必须重新编码
        enc=$(encode_account "$acct" "")
        printf '[%s] 第 %d 次拨号  %s  via %s\n' "$(date '+%F %T')" "$attempt" "$acct" "$IFACE"

        if [ "$DRY" = "1" ]; then
            printf '  [dry] 账号: '; printf '%s' "$enc" | sed -e 's/\r/\\r/g' -e 's/\n/\\n/g'; echo
            break
        fi

        pppd plugin rp-pppoe.so "nic-$IFACE" \
             user "$enc" password "$pw" \
             noauth defaultroute replacedefaultroute usepeerdns \
             mtu "$MTU" mru "$MTU" \
             lcp-echo-interval 20 lcp-echo-failure 3 \
             +ipv6 \
             ifname "$ENTRY" \
             nodetach
        rc=$?
        printf '[%s] pppd 退出 rc=%d\n' "$(date '+%F %T')" "$rc"

        [ "$ONCE" = "1" ] && exit "$rc"
        sleep "$HOLDOFF"
    done
    ;;

down)
    [ "$(id -u)" = "0" ] || { echo "down 需要 root" >&2; exit 1; }
    if [ -f "$PIDFILE" ]; then
        pid=$(cat "$PIDFILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null
            sleep 2
            kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
            echo "已停止拨号进程 $pid"
        fi
        rm -f "$PIDFILE"
    fi
    # 顺手把残留的 pppd 收掉
    pkill -TERM -f "pppd plugin rp-pppoe.so nic-.* user {S4}" 2>/dev/null
    echo "已断开"
    ;;

status)
    echo "pppd: $(pppd --version 2>/dev/null || echo '未安装')"
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
        echo "拨号进程: 运行中 (pid $(cat "$PIDFILE"))"
    else
        echo "拨号进程: 未运行"
    fi
    if ip link show "$ENTRY" >/dev/null 2>&1; then
        echo "接口 $ENTRY:"
        ip -br addr show "$ENTRY" 2>/dev/null | sed 's/^/  /'
        echo "  默认路由:"
        ip route show default 2>/dev/null | sed 's/^/    /'
    else
        echo "接口 $ENTRY: 不存在（未连接）"
    fi
    ;;

service)
cat <<EOF
# /etc/systemd/system/srun.service
[Unit]
Description=Srun PPPoE dialer
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/srun.sh dial -i $IFACE -n $ENTRY
ExecStop=/usr/local/bin/srun.sh down
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    ;;

*)
    show_help
    ;;
esac
