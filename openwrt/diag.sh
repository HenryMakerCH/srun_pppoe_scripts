#!/bin/sh
# 诊断：停服务 → 用 0 偏移手动拨一次 → 看 pppd 到底卡在哪
/etc/init.d/srun stop >/dev/null 2>&1
sleep 2
rm -f /tmp/srun-ok /var/log/pppd-srun.log
echo "=== 当前时间: $(date)"
echo "=== 手动拨号 (offset 0)，观察 50 秒"
/usr/bin/srun.sh dial -i wan -n srun --once >/tmp/diag-srun.log 2>&1 &
DPID=$!
sleep 50
echo "--- srun.sh 输出:"
cat /tmp/diag-srun.log
echo "--- pppd 日志 (/var/log/pppd-srun.log):"
cat /var/log/pppd-srun.log 2>/dev/null | tail -30
echo "--- 接口:"
ip -o -4 addr show dev srun 2>/dev/null || echo "none"
kill -TERM $DPID 2>/dev/null
sleep 1
/usr/bin/srun.sh down >/dev/null 2>&1
echo "=== done"
