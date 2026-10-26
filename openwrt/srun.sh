#!/bin/sh
# srun.sh —— Srun 深澜 PPPoE 独立拨号器
# OpenWrt / busybox ash 版（无 od / pkill / nohup 依赖）
#
# 账号编码算法与 Windows 版 srun.ps1 完全一致:
#     {S4}<tag>\r\n<hex><@域名>
#     tag = 当日已过秒数(本地时区) + sum(账号 @ 前面各字节)   ← 17 位, 不加任何前缀位
#     hex = 账号 @ 前面每个字节 +4 的两位小写十六进制
#
# 依赖: pppd + pppoe.so(OpenWrt 的 ppp-mod-pppoe)、date、hexdump 或 od、awk
#   OpenWrt:  apk add ppp ppp-mod-pppoe     (通常已随镜像装好)
#
# 注意: tag 用的是【本地时区】的当日秒数。OpenWrt 默认 UTC，
#       用前必须把时区设成 Asia/Shanghai 并把时钟对好，否则认证必失败。

set -u

VERSION="1.1.0-owrt"
DOMAIN_STU="stu.nchu.edu.cn"
DOMAIN_TEACHER="nchu.edu.cn"
DOMAIN_OTHER="tmp"

IFACE="wan"
DOMAIN="stu"
ENTRY="srun"
TS=""
USER_=""
PASS=""
PASSFILE=""
ONCE=0
DRY=0
RAW=0
HOLDOFF=30
MTU=1492
OFFSET=0
PIDFILE="/var/run/srun.pid"
LOGFILE="/var/log/srun.log"
PPPLOG="/var/log/pppd-srun.log"

show_help() {
cat <<'EOF'

  srun.sh  ——  Srun PPPoE 独立拨号器 (OpenWrt 版)

  用法    srun.sh <动作> [参数]

  动作
    help        显示帮助
    encode      只打印编码后的账号（调试用，不需要 root）
    dial        前台拨号，断线自动用新 tag 重拨（procd 用这个）
    up          后台拨号（不用 procd 时）
    down        断开
    status      查看状态
    service     打印 procd 启动脚本

  参数
    -i <网卡>       做 PPPoE 的物理网卡，默认 wan
    -u <学号>       不带 @ 时按 -d 拼后缀
    -d <域>         stu(默认)=@stu.nchu.edu.cn  teacher=@nchu.edu.cn
                    other=@tmp  none=不加后缀
    -p <密码>       不推荐（ps 里可见）
    -f <文件>       从文件读密码（默认尝试 /etc/srun/passwd）
    -n <名字>       ppp 接口名，默认 srun
    -t <unix秒>     encode 用：按指定时刻编码（测试用）
    --once          只拨一次，失败就退出
    --holdoff <秒>  重拨间隔，默认 15
    --mtu <n>       MTU，默认 1492
    --dry           只打印要交给 pppd 的账号，不拨号

  密码来源优先级
    -p  >  -f/--passfile  >  /etc/srun/passwd  >  环境变量 SRUN_PASS

  常见失败
    Timeout waiting for PADO   网线不在校园网口 / 网卡选错
    CHAP authentication failed 密码错，或 tag 与服务器时钟差太多（先对时/看时区）
    Plugin pppoe.so not found  ppp-mod-pppoe 没装
    认证通过立刻断开           账号已在别处在线（同一个池只能一个会话）

EOF
}

# ---------------------------------------------------------------- 编码
# 输出: {S4}tag CR LF hex @domain   (含真实 CR LF 字节)
tz_offset() {
    _z=$(date +%z 2>/dev/null || echo +0000)
    case "$_z" in
        -*) _sign=-1 ; _z=${_z#-} ;;
        +*) _sign=1  ; _z=${_z#+} ;;
        *)  _sign=1  ;;
    esac
    [ ${#_z} -lt 4 ] && { echo 0; return; }
    _h=${_z%??} ; _m=${_z#??}
    _h=${_h#0} ; _m=${_m#0}
    echo $(( _sign * ( ${_h:-0} * 3600 + ${_m:-0} * 60 ) ))
}

bytes_of() {
    # 输出每个字节的十进制值，空格分隔
    if command -v hexdump >/dev/null 2>&1; then
        printf '%s' "$1" | hexdump -v -e '/1 "%u "'
    else
        printf '%s' "$1" | od -An -tu1 -v
    fi
}

encode_account() {
    _acct="$1"
    _ts="${2:-}"
    _off="${3:-0}"

    case "$_acct" in
        *@*) _local="${_acct%%@*}"; _rest="${_acct#"$_local"}" ;;
        *)   _local="$_acct";      _rest="" ;;
    esac

    if [ -n "$_ts" ]; then
        _sod=$(( ( _ts + $(tz_offset) ) % 86400 ))
    else
        _h=$(date +%H); _m=$(date +%M); _s=$(date +%S)
        _h=${_h#0}; _m=${_m#0}; _s=${_s#0}
        _sod=$(( ${_h:-0} * 3600 + ${_m:-0} * 60 + ${_s:-0} ))
    fi
    # 时钟偏差补偿（开机没 RTC，只能靠扫描试出来）
    [ "$_off" != "0" ] && _sod=$(( _sod + _off ))
    while [ "$_sod" -lt 0 ]; do _sod=$(( _sod + 86400 )); done
    _sod=$(( _sod % 86400 ))

    _sum=0
    _hex=""
    for _b in $(bytes_of "$_local"); do
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
        --offset) OFFSET="$2"; shift 2 ;;
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
    echo "没有密码：先写 /etc/srun/passwd（chmod 600），或用 -p / SRUN_PASS" >&2
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
    printf '时区: %s  当日秒数: %s\n' "$(date +%Z)" "$(date +%H:%M:%S)"
    printf '交给 pppd 的账号:\n  '
    printf '%s' "$enc" | hexdump -C 2>/dev/null || printf '%s' "$enc" | od -c
    printf '  注意: 上面 \\r \\n 是真实 CR LF 字节（账号里必须带着）\n'
    ;;

dial|up)
    acct=$(resolve_account)
    [ -z "$acct" ] && { echo "需要 -u 学号（或写 /etc/srun/account）" >&2; exit 1; }

    if [ "$DRY" = "1" ]; then
        enc=$(encode_account "$acct" "")
        printf '  [dry] %s 交给 pppd 的账号:\n' "$acct"
        printf '%s' "$enc" | hexdump -C 2>/dev/null | sed 's/^/    /'
        exit 0
    fi

    pw=$(resolve_password)
    [ -n "$pw" ] || { echo "密码为空：先在 /etc/srun/passwd 里写入真实密码（chmod 600）" >&2; exit 1; }

    [ "$(id -u)" = "0" ] || { echo "拨号需要 root" >&2; exit 1; }

    # 清掉上一轮遗留的孤儿 pppd：procd 重新拉起本脚本时不会重跑 init 的 start_service，
    # 而脚本被强杀时 pppd 不会跟着死，会一直占着 PPPoE 会话，新实例再拨就永远 rc=8。
    for _p in /proc/[0-9]*; do
        [ -r "$_p/cmdline" ] || continue
        if tr '\0' ' ' < "$_p/cmdline" 2>/dev/null | grep -q "pppoe\.so nic-$IFACE"; then
            printf '清掉遗留的 pppd (%s)\n' "${_p#/proc/}"
            kill -TERM "${_p#/proc/}" 2>/dev/null
        fi
    done
    sleep 1

    if [ "$ACTION" = "up" ]; then
        if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
            echo "已经在跑了 (pid $(cat "$PIDFILE"))" >&2; exit 1
        fi
        "$0" dial -i "$IFACE" -d "$DOMAIN" -n "$ENTRY" --holdoff "$HOLDOFF" --mtu "$MTU" \
              $( [ -n "$USER_" ] && echo "-u $USER_" ) $( [ -n "$PASSFILE" ] && echo "-f $PASSFILE" ) \
              >>"$LOGFILE" 2>&1 &
        echo "$!" > "$PIDFILE"
        echo "后台拨号已启动 pid=$! 日志: $LOGFILE"
        exit 0
    fi

    pppd --version >/dev/null 2>&1 || { echo "没装 pppd" >&2; exit 1; }
    [ -f /usr/lib/pppd/*/pppoe.so ] || echo "警告: 找不到 /usr/lib/pppd/*/pppoe.so（ppp-mod-pppoe 没装？）" >&2

    trap 'echo; echo "收到信号，收尾…"; exit 0' INT TERM

    # 时钟偏移：这块板子没有 RTC，开机时钟是 sysfixtime 从文件 mtime 猜的，
    # 而 tag 用的是本地当日秒数，实测只偏 2~4 分钟就被回 E2531（"User not found"）。
    # 策略：连续失败 3 次后，按 1 分钟一档慢慢试（40 秒一次，最多 ±12 分钟），
    # 试通就用它把系统时钟校正回来。手动指定用 --offset。
    off=$OFFSET
    fails=0
    sweep_i=0
    sweeping=0
    attempt=0

    while :; do
        attempt=$(( attempt + 1 ))
        # tag 每秒都在变 —— 每次重拨必须重新编码
        enc=$(encode_account "$acct" "" "$off")
        offmsg=""
        [ "$off" != "0" ] && offmsg=" (手动偏移 ${off}s)"
        printf '[%s] 第 %d 次拨号  %s  via %s%s\n' "$(date '+%F %T')" "$attempt" "$acct" "$IFACE" "$offmsg"

        rm -f /tmp/srun-ok
        pppd plugin pppoe.so "nic-$IFACE" \
             user "$enc" password "$pw" \
             noauth defaultroute replacedefaultroute usepeerdns \
             mtu "$MTU" mru "$MTU" \
             lcp-echo-interval 20 lcp-echo-failure 3 \
             +ipv6 \
             ifname "$ENTRY" \
             logfile "$PPPLOG" \
             nodetach &
        pppid=$!

        # 最多等 25 秒：认证成功时 /etc/ppp/ip-up 会创建 /tmp/srun-ok
        # 注意 busybox 的 sleep 只吃整数（0.5 会报 invalid number）
        i=0
        while [ "$i" -lt 25 ] && [ ! -f /tmp/srun-ok ] && kill -0 "$pppid" 2>/dev/null; do
            sleep 1; i=$(( i + 1 ))
        done

        if [ -f /tmp/srun-ok ]; then
            printf '[%s] 认证通过%s\n' "$(date '+%F %T')" "$offmsg"
            if [ "$off" != "0" ]; then
                date -s "@$(( $(date +%s) + off ))" >/dev/null 2>&1
                printf '  已按 %ss 校正系统时钟，现在: %s\n' "$off" "$(date '+%F %T')"
            fi
            off=$OFFSET; sweeping=0; sweep_i=0; fails=0
            wait "$pppid"; rc=$?
            printf '[%s] 连接断开 rc=%d\n' "$(date '+%F %T')" "$rc"
            [ "$ONCE" = "1" ] && exit "$rc"
            sleep "$HOLDOFF"
            continue
        fi

        kill "$pppid" 2>/dev/null
        wait "$pppid" 2>/dev/null; rc=$?
        fails=$(( fails + 1 ))
        printf '[%s] 拨号失败 rc=%d（连续第 %d 次）\n' "$(date '+%F %T')" "$rc" "$fails"
        case "$rc" in
            19) printf '  认证被拒：账号/密码错，或时钟偏了（tag 不对），或旧会话没释放\n' ;;
            8)  printf '  PPPoE 发现失败：网线不在校园网口，或还有旧的 pppd 占着会话\n' ;;
            5)  printf '  服务器没回 LCP（多半是短时间内试太多被临时限制）\n' ;;
        esac

        # 连续 2 次失败后开始按分钟试时钟偏移（正方向优先：断电后时钟通常偏慢）
        if [ "$fails" -ge 2 ] && [ "$OFFSET" = "0" ]; then
            sweeping=1
            sweep_i=$(( sweep_i + 1 ))
            case $sweep_i in
                1) off=60 ;;   2) off=-60 ;;  3) off=120 ;;  4) off=-120 ;;
                5) off=180 ;;  6) off=-180 ;; 7) off=240 ;;  8) off=-240 ;;
                9) off=300 ;; 10) off=-300 ;; 11) off=360 ;; 12) off=-360 ;;
               13) off=480 ;; 14) off=-480 ;; 15) off=600 ;; 16) off=-600 ;;
               17) off=720 ;; 18) off=-720 ;;
                *) off=0; sweeping=0; sweep_i=0; fails=0
                   printf '  ±12 分钟都试过了仍不通：查账号密码，或校园网把账号临时限制了\n' ;;
            esac
            [ "$off" != "0" ] && printf '  下一次按 %s 秒偏移试（相当于把时钟往前/后拨）\n' "$off"
        fi

        [ "$ONCE" = "1" ] && exit "$rc"
        # 退避：扫描时 30 秒一次，否则 30s → 60s → 120s 封顶，别把 BRAS 惹毛
        s=$HOLDOFF
        [ "$sweeping" = "1" ] && s=30
        [ "$sweeping" = "0" ] && [ "$fails" -ge 3 ] && s=60
        [ "$sweeping" = "0" ] && [ "$fails" -ge 6 ] && s=120
        printf '  %ds 后重试\n' "$s"
        sleep "$s"
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
    # 收掉残留：只认 argv[1] 恰好是 /usr/bin/srun.sh 的主循环 + pppd 的 nic-<if>
    # （不能只 grep 字符串，否则会把命令行里"提到"这些字样的 shell 一起杀掉）
    for _p in /proc/[0-9]*; do
        [ -r "$_p/cmdline" ] || continue
        _pid=${_p#/proc/}
        [ "$_pid" = "$$" ] && continue
        _a2=$(tr '\0' '\n' < "$_p/cmdline" 2>/dev/null | sed -n '2p')
        if [ "$_a2" = "/usr/bin/srun.sh" ]; then
            echo "停止主循环 $_pid"
            kill -TERM "$_pid" 2>/dev/null
            continue
        fi
        if tr '\0' ' ' < "$_p/cmdline" 2>/dev/null | grep -q "pppoe\.so nic-$IFACE"; then
            echo "收掉残留 pppd $_pid"
            kill -TERM "$_pid" 2>/dev/null
        fi
    done
    echo "已断开"
    ;;

status)
    echo "pppd: $(pppd --version 2>/dev/null || echo '未安装')"
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
        echo "拨号进程: 运行中 (pid $(cat "$PIDFILE"))"
    else
        echo "拨号进程: 未运行（procd 托管时由 /etc/init.d/srun 管）"
    fi
    echo "时区/时钟: $(date '+%F %T %Z')"
    if [ -e "/sys/class/net/$ENTRY" ]; then
        echo "接口 $ENTRY: operstate=$(cat /sys/class/net/$ENTRY/operstate 2>/dev/null)"
        ip -o -4 addr show dev "$ENTRY" 2>/dev/null | sed 's/^/  /'
        ip -o -6 addr show dev "$ENTRY" 2>/dev/null | grep -v 'fe80' | sed 's/^/  /'
        echo "  默认路由:"
        ip route show default 2>/dev/null | sed 's/^/    /'
        echo "  对端/DNS: $(cat /etc/ppp/resolv.conf 2>/dev/null | tr '\n' ' ')"
    else
        echo "接口 $ENTRY: 不存在（未连接）"
    fi
    echo "pppd 日志尾部:"
    tail -n 8 "$PPPLOG" 2>/dev/null | sed 's/^/  /'
    ;;

service)
cat <<EOF
#!/bin/sh /etc/rc.common
# /etc/init.d/srun
START=95
STOP=10
USE_PROCD=1

start_service() {
	procd_open_instance
	procd_set_param command /usr/bin/srun.sh dial -i $IFACE -n $ENTRY --holdoff $HOLDOFF
	procd_set_param respawn 3600 5 5
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_close_instance
}

stop_service() {
	/usr/bin/srun.sh down
}
EOF
    ;;

*)
    show_help
    ;;
esac
