# srun-pppoe-cli — 深澜 PPPoE 独立拨号器

不启动 `网络准入认证客户端`（Electron 那套 260MB 的程序），一个 PowerShell 脚本完成同样的 PPPoE 拨号。

提供linux版本，参见/linux文件夹

逆向来源：`srun4-portal-pppoe` 的 `resources/SrunClientEncryptAccount.dll` + `resources/app.asar → electron-preload.js`。
逻辑是从官方 DLL 直接调参反推出来的，不是猜的。

---

## 用法

```powershell
cd D:\hermes\srun-pppoe

.\srun.cmd                      # 不带参数 = help
.\srun.cmd help                 # 完整帮助
.\srun.cmd status               # 状态 + IPv4/IPv6 + 客户端是否在跑
.\srun.cmd dial                 # 用记住的账号拨号（首次会问账号密码）
.\srun.cmd disconnect           # 断开
```

参数（全小写；PowerShell 本身大小写不敏感）：

| 参数 | 说明 |
|---|---|
| `-user <学号>` | 不带 `@` 时按 `-domain` 拼后缀 |
| `-domain stu\|teacher\|other\|none` | `stu`=@stu.nchu.edu.cn（默认） `teacher`=@nchu.edu.cn `other`=@tmp `none`=不加 |
| `-pass <密码>` | 不推荐，会短暂出现在进程列表里 |
| `-passfromclientlog` | 密码从官方客户端日志里取 |
| `-killclient` | 拨号前关掉官方客户端 |
| `-force` | 已连接也强制重拨（会断线几秒） |
| `-retry <N>` | 失败重试次数，默认 3（退避 10/30/60 秒） |
| `-name <名称>` | 拨号项名称，默认 `srun-pppoe` |
| `-dry` | 只打印要发的账号，不碰现有连接 |
| `-at <unix秒>` | 调试用，按指定时刻编码账号 |

```powershell
.\srun.cmd dial -user 20240001                                  # 学生段
.\srun.cmd dial -user 20240001 -domain teacher                   # 教师段
.\srun.cmd dial -user 20240001 -killclient -passfromclientlog    # 日常用这个
.\srun.cmd dial -dry                                             # 先看要发什么再真拨
```

密码也可放环境变量，避免出现在命令行历史：

```powershell
$env:SRUN_PASS = '你的密码'; .\srun.cmd dial -user 20240001
```

优先级：`-pass` > `-passfromclientlog` > `$env:SRUN_PASS` > 交互输入。

## 它到底做了什么

1. 拼完整账号：`学号@stu.nchu.edu.cn`（学生）/ `工号@nchu.edu.cn`（教师）/ `@tmp`（其他）。
2. 用等价于 `SRunEncodeAccountV4D` 的算法把账号编码成 `{S4}<tag>\r\n<hex>`。
3. `rasdial "srun-pppoe" "<编码账号>" "<密码>"` —— 剩下的 PPPoE 协商、IP 下发全交给 Windows。
4. 拨号项不存在时（比如官方客户端已卸载）自动生成 pbk 电话簿项。
5. 成功后可顺便探一下 `10.1.88.4:80` 确认进了校园网。

不需要管理员权限（和官方客户端一样是用户级拨号）。

## 账号编码算法

```
{S4}%x\r\n<hex>
  %x    = 本地当日已过秒数 + sum(账号 @ 前面那段的字节)      ← 17 位，不加任何前缀位
  <hex> = 账号 @ 前面那段，每个字节 +4，转小写十六进制
  @域名 原样保留在后面（不参与编码、不参与求和）
```

不是加密，是可逆的，且每秒变一次（防重放）。例：

```
20240001@stu.nchu.edu.cn  @ 18:20:24
  sod  = 18*3600+20*60+24 = 66024
  sum  = 393
  tag  = 66024 + 393 = 66409 = 0x10371
  hex  = "3634363834343435"        # 每字节 +4
  =>   {S4}10371\r\n3634363834343435@stu.nchu.edu.cn
```

## 验证情况

| 项 | 状态 |
|---|---|
| 账号编码 vs 官方客户端实际发出的账号串 | 9/9 条逐字符一致（上午 + 傍晚两个时段） |
| `status` 读取在线状态 / IPv4 / IPv6 / Portal 可达 | 实机跑通 |
| 已连接时拒绝重复拨号 | 实机跑通 |
| 生成的 pbk 与官方 `srun.pbk` | 仅 section 名 / UID / GUID / 时间戳 / Ipv6InterfaceId 不同，key 序列完全一致 |
| **真正拨通（官方客户端已关闭）** | ✅ 实机跑通，服务器侧会话时间刷新 |

## 注意

- 密码会作为 `rasdial` 的命令行参数出现（Windows 拨号的固有方式，官方客户端也一样），进程列表里短暂可见。介意就用交互提示或 `$env:SRUN_PASS`。
- `-force` 会真的断网几秒。
- pbk 里 `PreferredPort=PPPoE5-0` 是照官方模板抄的；换机器如果报 868 之类的错，把这一行删掉让 Windows 自己选 WAN Miniport (PPPOE)。
- 学校如果改了服务器 / 域名 / 算法，这脚本就不灵了 —— 重新看 `electron-preload.js` 和那个 DLL 即可。

## 排障：628 / 651

这两个码都不是「密码错」，是 PPPoE 会话层的问题：

| 码 | 含义 | 处理 |
|---|---|---|
| 628 | 服务器在认证完成前断开（旧会话未释放 / PPPoE 栈残留 / 重试太快 / **tag 算错**） | 先用 `-dry` 排除 tag；再等 30~120 秒 |
| 651 | 本机 PPPoE 协议栈卡死（WAN Miniport 进入坏状态） | 禁用再启用物理网卡，或管理员执行 `Restart-Service RasMan -Force` |
| 691 | 账号或密码错 | 不重试，检查凭据 |
| 722 | 服务器无应答（PPPoE 发现阶段失败） | 网线没插 / 不在校园网内 |

已知触发场景（真机复现）：

- **睡眠/唤醒后第一次拨号**：网卡和 WAN Miniport 还没就绪，第一次常连 PPPoE 发现都走不完。建议唤醒后等 15 秒。
- **Wi-Fi 移动热点共享 PPPoE**：会报 651，且必须重置网卡才能恢复。别在 PPPoE 链路上开 Windows 移动热点（ICS 会重绑接口，把 PPPoE 会话带崩）。
- **重试太快**：失败后 2 秒就再拨会一直 628，旧会话还没在 BAS 侧释放。

判断方法：翻 `Get-WinEvent -LogName Application -ProviderName RasClient`，看 20227（失败）/ 20225（会话建立）/ 20226（断开）的时间序列。

## 为什么必须关掉官方客户端再拨

客户端在托盘里持续探活（`RedialOnLinkFailure=1`），一发现断线就 2 秒内自己抢回会话。
脚本拨号时会撞上「会话已存在」→ 628。用 `-killclient`，或先在托盘退出客户端。

## 踩坑记录：`{S4}` tag 的 0x10000 陷阱

早期版本把 tag 写成了 `0x10000 | ((sod+sum) & 0xFFFF)`，**傍晚测试完全看不出问题** ——
下午 18:04 之后 `sod+sum > 65535`，加不加 `0x10000` 结果一样；只有上午 `sod+sum < 65535` 时才会多出一个 `1`，
服务器直接踢，报 628。

判据（账号 `20240001`，字节和 393）：

| 时刻 | sod | 正确 tag | 错误 tag |
|---|---|---|---|
| 18:20:24 | 66024 | `10371` | `10371`（一样，看不出） |
| 11:24:21 | 41061 | `a1ee` | `1a1ee`（多一位 `1`） |

**教训：验证时间相关算法必须在上午做一次，只在一个时段比对等于没验证。**
