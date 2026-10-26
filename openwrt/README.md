# Srun 校园网 PPPoE 拨号器（OpenWrt 版）

不装官方客户端，让路由器自己完成 Srun（深澜）PPPoE 认证：账号按
`{S4}<tag>\r\n<hex>@域名` 编码后交给 `pppd`，外面套 keepalive、断线重拨、
开机自启，外加 NTP 校时 / DNS 同步 / 防火墙 NAT 一整套，最终手机和电脑连路由器的
WiFi 就能上网。

- **适用**：PPPoE + CHAP 认证的 Srun 校园网；路由器能拿到 root shell
- **不适用**：Web/Portal 认证的校园网（那是另一套协议）
- Windows 版（`rasdial`）和普通 Linux 版（`pppd` + `rp-pppoe.so`）不在本仓库

已在 **Xiaomi Mi Router 4A Gigabit v2 (R4AV2) + OpenWrt 25.12.2 + pppd 2.5.2** 实测跑通。

## 快速开始（在路由器上）

```sh
# 1) 整个目录传过去（dropbear 没有 sftp，所以用 tar 走管道）
tar cf - . | ssh root@192.168.1.1 'mkdir -p /tmp/srun-src && tar xf - -C /tmp/srun-src'

# 2) 装（会改 wan/防火墙/时区/dnsmasq，幂等，可重复执行）
ssh root@192.168.1.1 'sh /tmp/srun-src/install.sh'

# 3) 写凭据（脚本故意不碰这两样）
ssh root@192.168.1.1 "echo '学号@stu.nchu.edu.cn' > /etc/srun/account"
ssh root@192.168.1.1 'umask 077; cat > /etc/srun/passwd'    # 输入密码，回车后 Ctrl-D

# 4) 先空跑看编码，再真拨一次
ssh root@192.168.1.1 '/usr/bin/srun.sh encode'
ssh root@192.168.1.1 '/usr/bin/srun.sh dial --once'

# 5) 交给 procd
ssh root@192.168.1.1 '/etc/init.d/srun start; /usr/bin/srun.sh status'
```

改 `install.sh` 顶部的 `IFACE / DNS_UPSTREAM / TZ_*` 即可适配别的学校。

## 文件

| 文件 | 装到路由器 | 作用 |
|---|---|---|
| `srun.sh` | `/usr/bin/srun.sh` | 拨号器本体（编码 + pppd 循环 + 自愈） |
| `srun.init` | `/etc/init.d/srun` | procd 服务，开机自启 |
| `ppp-ip-up` | `/etc/ppp/ip-up` | 连上后把 DNS 写进 dnsmasq |
| `ppp-ip-down` | `/etc/ppp/ip-down` | 断开时**不清空**上游 DNS（防竞态） |
| `install.sh` | — | 一键部署脚本 |
| `diag.sh` | — | 手动拨一次并打印完整日志，排障用 |

## 相对 Linux 版改了什么

| 项 | linux 版 | OpenWrt 版 |
|---|---|---|
| 编码取字节 | `od -An -tu1` | `hexdump -v -e '/1 "%u "'`（busybox 没有 od） |
| 后台运行 | `nohup ... &` | 交给 procd（`/etc/init.d/srun`） |
| 掐掉残留 pppd | `pkill -f` | 扫 `/proc/*/cmdline`（busybox 没 pkill） |
| 插件名 | `rp-pppoe.so` | **`pppoe.so`**（OpenWrt 的 ppp 包就叫这个） |
| 日志 | 屏幕 | `logfile /var/log/pppd-srun.log` |
| 时区 | 系统已对 | **必须手动设 CST-8**，否则 tag 算错 8 小时 |
| `-t` 测试 | `date -d @ts` | 自己按 `date +%z` 折算，busybox date 不支持 `-d @` |

## 凭据文件

| 路径 | 内容 |
|---|---|
| `/etc/srun/account` | `学号@stu.nchu.edu.cn`，600 权限 |
| `/etc/srun/passwd` | 密码，600 权限，**空文件不会启动**（脚本里 `-s` 守卫） |

`pppd` 的 `password` 是命令行参数，所以 `ps` 里能看到它 —— 这是 pppd 的固有行为，
官方客户端也一样。

路由器 dropbear 没有 sftp 子系统，`scp` 传不了，用：

```sh
ssh root@192.168.1.1 'cat > /usr/bin/srun.sh' < srun.sh
```

## 首次使用

```sh
# 1) 密码（自己敲，别写进命令行）
ssh root@192.168.1.1 'umask 077; cat > /etc/srun/passwd'
#    输入密码 → 回车 → Ctrl-D

# 2) 先空跑一次看账号编码（不需要密码，不拨号）
ssh root@192.168.1.1 '/usr/bin/srun.sh encode'

# 3) 真拨（前台，能看完整日志）
ssh root@192.168.1.1 '/usr/bin/srun.sh dial --once'

# 4) 通了以后交给 procd
ssh root@192.168.1.1 '/etc/init.d/srun enable; /etc/init.d/srun start'
ssh root@192.168.1.1 '/usr/bin/srun.sh status'
```

## 网络侧的配套改动（部署时已做）

```sh
# netifd 的 wan 改成 none，否则 udhcpc 和 pppd 抢同一个口
uci set network.wan.proto='none'
uci set network.wan6.disabled='1'
uci commit network

# srun 网卡进 wan 防火墙区，才有 NAT
uci add_list firewall.@zone[1].device='srun'
uci commit firewall

# 时区必须 CST-8：tag 用的是本地当日秒数
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci commit system
```

回滚：`/etc/init.d/srun disable; uci set network.wan.proto='dhcp'; uci commit network; ifup wan`

## 时钟：这一节是这台机器真正的命门（实测数据）

`tag = 本地当日秒数 + 账号字节和`，而这个 BRAS 对 tag 的时间非常敏感：

| 时钟偏差 | 结果 |
|---|---|
| 0 | 认证通过 |
| −3 分 00 秒 | 认证通过（勉强） |
| **−3 分 52 秒** | **失败：`E2531: User not found`** ← 看着像密码错，其实是时钟 |
| −2 分 39 秒（刚重启后） | 失败（那次还叠加了旧会话没释放） |

结论：**容忍窗口大约 ±3 分钟**。所以"重启后能上网"这件事完全取决于开机的时钟猜得准不准。

这块板子没有 RTC，开机时钟由 `sysfixtime` 取 `/etc` 里最新的文件 mtime 得到。三道防线：

1. **cron 每分钟 `touch /etc/srun/timestamp`** —— 把"最新 mtime"压在 1 分钟内。
   （注意：OpenWrt 的 `reboot` **不会**调用 init 脚本的 `stop`，所以"关机时盖时间戳"这种做法无效，
   只能靠 cron。）
2. **拨号器自己的时钟扫描**：连续 2 次认证失败后，按 ±1/±2/…/±12 分钟一档、每 30 秒试一次，
   试通了立刻用这个偏移把系统时钟校正回来（日志里会看到"已按 180s 校正系统时钟"）。
   偏得不多时 1~2 分钟就能自愈。
3. 手动兜底：

```sh
ssh root@192.168.1.1 "date -s '2026-10-26 23:30:00'; /etc/init.d/srun restart"
```

链路一旦通了，NTP 会把时钟彻底校准，之后长时间运行不会再偏。

### 实测：重启后的完整过程

```
reboot → 开机 73 秒时已连上，路由器时间与 PC 差 2 秒，第一次拨号就认证通过
```

## DNS（客户端"连上了但找不到 DNS"）

坑的来源：`/etc/ppp/ip-down` 里清空 `/tmp/resolv.conf.d/resolv.conf.auto`。
重启或重拨时，**旧会话的 ip-down 有可能在新会话的 ip-up 之后才执行**，于是刚写进去的
上游 DNS 被擦掉；dnsmasq 没有 upstream，对客户端一律回 `REFUSED`，手机端表现就是
"已连接，但找不到 DNS 地址 / 无法访问互联网"。

修法（两处都已落地）：

1. `ip-down` **不再清空**那个文件，只记一条日志。保留上一次的上游地址无害，重连后
   `ip-up` 会覆盖。
2. 再把校园 DNS 钉成 dnsmasq 的静态上游，彻底不依赖 `/tmp` 文件：

```sh
uci add_list dhcp.@dnsmasq[0].server='10.1.1.1'
uci commit dhcp && /etc/init.d/dnsmasq restart
```

验证三档（都做过）：

```sh
nslookup www.baidu.com 127.0.0.1        # 路由器本机
nslookup www.baidu.com 192.168.1.1      # 模拟客户端拿到的 DNS
nslookup www.baidu.com 10.1.1.1         # 直连校园 DNS
```

手机端如果还显示没有 DNS，让它**关一次 Wi-Fi 再开**（Android 会缓存"无网络"状态）。

## 保活与自拉起（实测过的四层）

| 层 | 机制 | 触发到恢复的实测值 |
|---|---|---|
| 1 | pppd `lcp-echo-interval 20` + `lcp-echo-failure 3` | 链路静默 ~60 秒后 pppd 自己退出 |
| 2 | `srun.sh dial` 的 while 循环：pppd 一退出就重算 tag 重拨 | 掐掉 pppd → **36 秒**后重拨成功（IP 10.31.2.162 → 10.31.1.101） |
| 3 | procd `respawn 3600 5 0`（无上限） | `kill -9` 脚本 6 次，6 次都被拉起，最终只剩 1 个 pppd 且已连上 |
| 4 | 认证失败每 30 秒重试；连续 6 次才扫时钟偏移 | 重启后遇 `E2531` 会一直重试到通 |

另外：`S95srun` 开机自启；cron 每 5 分钟 `touch /etc/srun/timestamp` 让 `sysfixtime` 开机把时钟猜准。

### 踩过的两个洞（都已修）

1. **孤儿 pppd**：脚本被 `kill -9` 时 pppd 不会跟着死，会一直占着 PPPoE 会话，新实例再拨永远
   `rc=8`（PPPoE 发现失败）。修法：`dial` 一开始扫 `/proc/*/cmdline` 清掉 `pppoe.so nic-wan` 的
   残留进程（日志里会打印"清掉遗留的 pppd (pid)"）。
2. **procd respawn 不会重跑 `start_service`**：所以清场逻辑不能只放在 init 里，必须放进脚本本体
   —— 这也是上面第 1 条为什么放在 `dial` 里而不是 init 里。init 里那份保留是为了手动
   `restart` 时也能清。

## 无线

5G 默认起不来的坑（真机实测）：

```
htmode=VHT160 → ACS 选到 36，160MHz 块跨 36-64 含 DFS
hostapd: DFS start_dfs_cac() failed, -1 → Interface initialization failed → AP-DISABLED
```

MT7663 只支持到 80MHz，设 VHT160 必然失败。改成：

```sh
uci set wireless.radio1.htmode='VHT80'
uci set wireless.radio1.channel='36'    # 36/40/44/48 是非 DFS 段
uci commit wireless && wifi reload
```

起来后：`BG6HLQ_5G` / ch36 / 80MHz / txpower 23 dBm。

注意：5G 的加密如果设成单模 `sae`（WPA3），部分手机能看到 SSID 但连不上 —— 改成 `psk2+sae`
混合。2.4G 的 `channel auto` 会落到 9（和邻居重叠），固定 1/6/11 更好。

## 排障：认日志里的服务器原话

第一次实测（密码为空）拿到的是这份，说明二层和 CHAP 都是通的：

```
PPP session is 17984
Connected to C4:07:78:01:E0:02 via interface wan
Using interface srun
No CHAP secret found for authenticating us to BRAS-CR16010-F
CHAP authentication failed: E2901: (Third party 1)Failed to get password from LDAP
```

| 日志 | 含义 | 处理 |
|---|---|---|
| `Timeout waiting for PADO` | 二层没通 | 网线不在校园网口 / 网关选错 |
| `No CHAP secret found ...` | pppd 没拿到密码 | `/etc/srun/passwd` 是空的 |
| `E2901 Failed to get password from LDAP` | 服务器按收到的用户名找不到账号 | 密码/账号错，或 `-d` 域选错 |
| `CHAP authentication failed` 反复 | 认证不过 | 先 `date` 看时刻对不对，再查密码 |
| 通过后立刻断开 | 账号已在别处在线 | 官方客户端/手机先下线，等 30 秒 |
| 通但没网 | MTU / NAT / DNS | `--mtu 1480`；查 `nft list ruleset \| grep srun`；`cat /tmp/resolv.conf.d/resolv.conf.auto` |
