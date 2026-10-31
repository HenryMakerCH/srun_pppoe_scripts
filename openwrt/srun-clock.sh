#!/bin/sh
# srun-clock.sh —— 从局域网校时源（一般就是开着 srun-timesync.ps1 的那台电脑）取时间
#
# 这块板子没有 RTC，冷启动时时钟靠 sysfixtime 按 /etc 里文件的 mtime 猜，
# 常常差 2~5 分钟；而 Srun 的 {S4} tag 用的是本地当日秒数，实测偏 3 分钟
# BRAS 就回 E2531（看着像密码错）。所以开机第一拨基本必失败，拨号器只能
# 按 60s 一档盲扫，扫到才对上（今天拨了 7 次）。
#
# 拨号器在每次拨之前调这个脚本：先问一次电脑要 epoch，再算 tag。
#
# 用法：srun-clock.sh [--quiet] [--force]
#   配置：/etc/srun/timesync.conf，一行一个 host:port，支持 # 注释
#   --quiet  只在真的改了钟时说话
#   --force  不看 5 秒容差，直接改钟
# 退出码：0 = 时钟可用（本来就准也算），1 = 一个源都取不到或数据不像时间
#
# 备选源（跟 /etc/srun/timesync.conf 同一格式），任何一行取到就用：
#   /etc/srun/timesync.conf  -> 只认这一个文件，没有就试下面的
CONF=/etc/srun/timesync.conf
TOL=5

Q=0
FORCE=0
for a in "$@"; do
    case "$a" in
        --quiet) Q=1 ;;
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "用法: $0 [--quiet] [--force]" >&2; exit 2 ;;
    esac
done
say() { [ "$Q" = "1" ] || echo "$@"; }

[ -r "$CONF" ] || { say "没有 $CONF（不知道自己该问谁要时间）"; exit 1; }

# fetch_epoch <host> <port> —— 打印取到的 10 位 epoch，失败打印空
fetch_epoch() {
    _h=$1
    _p=$2
    _out=""
    if command -v wget >/dev/null 2>&1; then
        _out=$(wget -q -T 2 -O - "http://$_h:$_p/" 2>/dev/null)
    fi
    if [ -z "$_out" ] && command -v uclient-fetch >/dev/null 2>&1; then
        _out=$(uclient-fetch -q -T 2 -O - "http://$_h:$_p/" 2>/dev/null)
    fi
    printf '%s' "$_out" | tr -dc '0-9'
}

now=$(date +%s)
got=""
tried=""
while read -r src; do
    src=$(printf '%s' "$src" | sed -e 's/#.*//' -e 's/[[:space:]]//g')
    [ -n "$src" ] || continue
    host=${src%%:*}
    case "$src" in
        *:*) port=${src##*:} ;;
        *)   port=8899 ;;
    esac
    [ -n "$host" ] || continue
    e=$(fetch_epoch "$host" "$port")
    tried="$tried $src"
    case "$e" in
        1[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])
            got=$e
            break
            ;;
        *) : ;;
    esac
done < "$CONF"

if [ -z "$got" ]; then
    say "局域网校时源不可达（试过:$tried），沿用本地时钟 $(date '+%F %T')"
    exit 1
fi

diff=$(( got - now ))
abs=$diff
[ "$abs" -lt 0 ] && abs=$(( -abs ))
if [ "$FORCE" = "0" ] && [ "$abs" -le "$TOL" ]; then
    # 已经准了：顺手把 lastgood 刷新一下，断电重启更靠得住
    echo "$got" > /etc/srun/lastgood 2>/dev/null
    say "时钟已准（与源差 ${diff}s）"
    exit 0
fi

if date -s "@$got" >/dev/null 2>&1; then
    say "已按局域网源校时：修正 ${diff}s，现在 $(date '+%F %T')"
    logger -t srun-clock "LAN sync: delta ${diff}s, now $(date '+%F %T')" 2>/dev/null
    echo "$got" > /etc/srun/lastgood 2>/dev/null
    exit 0
fi

# 极老的 busybox 不认 -- 的 @epoch 写法，退一步用 -u 直接给时间字符串
if date -u -s "$(date -u -d "@$got" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" >/dev/null 2>&1; then
    say "已按局域网源校时（备选写法）：现在 $(date '+%F %T')"
    echo "$got" > /etc/srun/lastgood 2>/dev/null
    exit 0
fi

say "date -s 失败，改钟没成功"
exit 1
