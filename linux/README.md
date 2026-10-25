# srun.sh —— Linux / OpenWrt 版 Srun PPPoE 拨号器

和 Windows 版 `srun.ps1` 同一个算法，改用 `pppd + rp-pppoe` 插件拨号。
纯 POSIX sh 写的，Debian/Ubuntu/Arch/OpenWrt(busybox ash) 都能跑。

## 依赖

```bash
# Debian / Ubuntu
apt install ppp

# Arch
pacman -S ppp

# OpenWrt
opkg install ppp ppp-mod-pppoe
```

`rp-pppoe.so` 插件由 ppp 包提供（OpenWrt 由 `ppp-mod-pppoe`）；找不到就报
`Plugin rp-pppoe.so not found`。

## 用法

```bash
sudo install -m 755 srun.sh /usr/local/bin/srun.sh

srun.sh help                                  # 帮助
srun.sh encode -u 20240001                    # 只看编码后的账号
srun.sh dial   -i eth0 -u 20240001 -f /etc/srun/passwd    # 前台拨号
srun.sh up     -i eth0 -u 20240001                        # 后台拨号
srun.sh status
srun.sh down
srun.sh service >> /etc/systemd/system/srun.service       # 生成 unit
```

| 参数 | 说明 |
|---|---|
| `-i <网卡>` | 做 PPPoE 的物理网卡，默认 `eth0` |
| `-u <学号>` | 不带 `@` 时按 `-d` 拼后缀 |
| `-d stu\|teacher\|other\|none` | 默认 `stu`（@stu.nchu.edu.cn） |
| `-p <密码>` | 不推荐，`ps` 里可见 |
| `-f <文件>` | 从文件读密码；不给时自动尝试 `/etc/srun/passwd` |
| `-n <名字>` | ppp 接口名，默认 `srun`（就是 `ifname`） |
| `-t <unix秒>` | `encode` 用：按指定时刻编码（测试用） |
| `--dry` | 只打印账号，不拨号、不要 root、不要密码 |
| `--once` | 只拨一次，失败就退出 |
| `--holdoff <秒>` | 重拨间隔，默认 10 |
| `--mtu <n>` | MTU，默认 1492 |
| `--raw` | `encode` 只输出原始账号串（脚本里用） |

密码优先级：`-p` > `-f`/`/etc/srun/passwd` > `$SRUN_PASS` > 交互输入。

推荐把密码单独放文件：

```bash
sudo mkdir -p /etc/srun
echo '你的密码' | sudo tee /etc/srun/passwd >/dev/null
sudo chmod 600 /etc/srun/passwd
echo '20240001' | sudo tee /etc/srun/account >/dev/null   # 可选，省得每次 -u
```

## 它做了什么

```
pppd plugin rp-pppoe.so nic-eth0 \
     user "$ENC" password "$PW" \
     noauth defaultroute replacedefaultroute usepeerdns \
     mtu 1492 mru 1492 \
     lcp-echo-interval 20 lcp-echo-failure 3 \
     +ipv6 ifname srun nodetach
```

其中 `$ENC` 就是 `{S4}<tag>\r\n<hex>@stu.nchu.edu.cn`，**中间带着真实的 CR LF 字节**。
pppd 的 `user` 选项是原样按字符串收下的，CR LF 会作为 CHAP/PAP 的用户名字节发出去 ——
这正是 Srun 要求的形式。

脚本外面套了个 `while` 循环：pppd 退出就重新算一次 tag 再拨。
**不能用 `pppd persist`** —— persist 会复用同一套参数，tag 会变旧导致认证失败。

## 验证情况

| 项 | 状态 |
|---|---|
| 编码算法 vs 官方客户端实际发出的账号串 | ✅ 10/10 逐字节一致（上午 + 傍晚样本） |
| `sh -n` / `bash -n` 语法 | ✅ 通过 |
| `--dry` / `encode` / `status` / `service` | ✅ 实机跑通（无 pppd 环境下） |
| **真实 PPPoE 拨号** | ⚠️ **未实测** —— 手边没有在校园网内的 Linux 机器 |

未实测的原因很直白：PPP 认证得真在校园网二层里跑。
代码路径是对着 `warriorpaw/z-srun` 那类实现和 rp-pppoe 的标准用法写的，
但第一次在真机上跑的时候请按下面顺序排查。

## 真机第一次跑，按这个顺序

```bash
# 1. 编码对不对（不需要 root）
srun.sh encode -u 学号

# 2. 网卡选对了吗（要接在校园网口上，不能是 Wi-Fi）
ip -br link

# 3. 前台上，看完整 pppd 日志
sudo srun.sh dial -i eth0 -u 学号 --once

# 4. 通了之后看地址
srun.sh status
curl -s ifconfig.me
```

常见现象：

| 现象 | 原因 |
|---|---|
| `Plugin rp-pppoe.so not found` | 没装 `ppp-mod-pppoe`（OpenWrt）/ ppp 版本太老 |
| `Timeout waiting for PADO packets` | 网线不在校园网口上 / 交换机端口没开 / 网卡选错 |
| `CHAP authentication failed` | 密码错，或 tag 和服务器时钟差太多（先 `chronyc tracking` 对时） |
| 认证通过但立刻断开 | 账号已在别处在线（同一个 PPPoE 池只能一个会话），先让别处下线 |
| 通了但没网 | MTU：试 `--mtu 1480`；或 DNS 没下发，检查 `usepeerdns` + `/etc/resolv.conf` |

## 和 Windows 版的差异

| | Windows `srun.ps1` | Linux `srun.sh` |
|---|---|---|
| 拨号器 | `rasdial` + WAN Miniport | `pppd` + `rp-pppoe.so` |
| 管理员 | 不需要 | 需要 root |
| 断线重连 | 脚本内退避重试 | 外层 while 循环，每次都重算 tag |
| IPv6 | 系统自己配 | 加 `+ipv6` |
| 开机自启 | 计划任务 | systemd（`srun.sh service`） |

## 关于 OpenWrt

流程一样，只是 `ifname` 换成 `pppoe-wan` 之类，并把 `srun.sh` 挂成 procd 服务：

```sh
# /etc/init.d/srun
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/srun.sh dial -i eth0 -n srun
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
```

注意 OpenWrt 上别同时开自带的 `network` PPPoE 接口，两个 pppd 会抢同一个网口。
