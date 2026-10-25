<#
.SYNOPSIS
    Srun PPPoE 独立拨号器 —— 不依赖官方客户端。

.DESCRIPTION
    账号编码算法逆向自 SrunClientEncryptAccount.dll（SRunEncodeAccountV4D 的等价实现），
    拨号走系统自带的 rasdial + WAN Miniport (PPPOE)。

    送给 rasdial 的账号格式：
        {S4}<tag>\r\n<hex><@域名>
        tag = 当日已过秒数 + 本地部分各字节之和     （17 位，不要 OR 0x10000）
        hex = 本地部分每个字节 +4 后的十六进制

.PARAMETER action
    help / status / dial / disconnect / encode

.EXAMPLE
    srun help
    srun status
    srun dial -user 20240001
    srun dial -user 20240001 -killclient -passfromclientlog

.NOTES
    依赖 Windows PowerShell 5.1（系统自带）+ rasdial + WAN Miniport (PPPOE)。
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('help', 'status', 'dial', 'disconnect', 'encode')]
    [string]$action = 'help',

    # 学号/工号；带 @ 则原样使用，否则按 -domain 拼后缀
    [string]$user,

    # 密码。不推荐（命令行参数会短暂出现在进程列表里）
    [string]$pass,

    [ValidateSet('stu', 'teacher', 'other', 'none')]
    [string]$domain = 'stu',

    # 拨号项名称，就是 rasdial 的第一个参数
    [string]$name = 'srun-pppoe',

    # 电话簿目录
    [string]$pbkdir = (Join-Path $env:APPDATA 'Microsoft\Network\Connections\Pbk'),

    # 仅供调试: 用固定的 unix 秒构造账号, 保证输出可复现
    [int]$at = 0,

    # 拨号失败后的重试次数(默认 3 次, 退避 10/30/60 秒)
    [int]$retry = 3,

    # 只打印将要交给 rasdial 的账号, 不真的拨号
    [switch]$dry,

    # 从官方客户端日志里取上次用的密码(省得手输)
    [switch]$passfromclientlog,

    # 拨号前关掉官方客户端, 免得它抢会话(它掉线会立刻自己重拨)
    [switch]$killclient,

    # 已连接时强制重拨
    [switch]$force,

    # 打印版本
    [switch]$version
)

$ErrorActionPreference = 'Stop'
$SrunVersion = '1.1.0'
$ConfigDir = Join-Path $env:APPDATA 'srun-cli'
$ConfigFile = Join-Path $ConfigDir 'config.json'
$Domains = @{ stu = 'stu.nchu.edu.cn'; teacher = 'nchu.edu.cn'; other = 'tmp'; none = '' }
$ClientExeName = '网络准入认证客户端'
$ClientLog = Join-Path $env:APPDATA '网络准入认证客户端\logs\renderer.log'

# ================================================================ 帮助
function Show-Help {
    $C = 'Cyan'; $D = 'DarkGray'; $W = 'White'; $Y = 'Yellow'
    Write-Host ''
    Write-Host '  srun  ——  Srun PPPoE 独立拨号器' -ForegroundColor $C
    Write-Host '  不依赖官方客户端，账号编码算法是逆向出来的' -ForegroundColor $D
    Write-Host ''
    Write-Host '  用法    srun <动作> [参数]' -ForegroundColor $W
    Write-Host ''
    Write-Host '  动作' -ForegroundColor $W
    Write-Host '    help        显示这段帮助'
    Write-Host '    status      连接状态、IPv4/IPv6、Portal 是否可达、客户端是否在跑'
    Write-Host '    dial        拨号（失败自动退避重试）'
    Write-Host '    disconnect  断开'
    Write-Host '    encode      只打印编码后的账号，不拨号（调试用）'
    Write-Host ''
    Write-Host '  参数（全小写；PowerShell 本身大小写不敏感）' -ForegroundColor $W
    Write-Host '    -user <学号>            不带 @ 时按 -domain 拼后缀'
    Write-Host '    -domain stu|teacher|other|none'
    Write-Host '                            stu=@stu.nchu.edu.cn（默认）' -ForegroundColor $D
    Write-Host '                            teacher=@nchu.edu.cn   other=@tmp   none=不加' -ForegroundColor $D
    Write-Host '    -pass <密码>            不推荐：会短暂出现在进程列表里'
    Write-Host '    -passfromclientlog      从官方客户端日志里取上次用的密码'
    Write-Host '    -killclient             拨号前关掉官方客户端（它会抢会话）'
    Write-Host '    -force                  已连接也强制重拨'
    Write-Host '    -retry <N>              失败重试次数，默认 3（退避 10/30/60 秒）'
    Write-Host '    -name <名称>            拨号项名字，默认 srun-pppoe'
    Write-Host '    -dry                    只打印要发的账号，绝不碰当前连接'
    Write-Host '    -at <unix秒>            调试用：按指定时刻编码账号'
    Write-Host '    -version                打印版本'
    Write-Host ''
    Write-Host '  例子' -ForegroundColor $W
    Write-Host '    srun status' -ForegroundColor $D
    Write-Host '    srun dial -user 20240001' -ForegroundColor $D
    Write-Host '    srun dial -user 20240001 -killclient -passfromclientlog' -ForegroundColor $D
    Write-Host '    srun dial -dry                   先看要发什么，确认无误再真拨' -ForegroundColor $D
    Write-Host ''
    Write-Host '  密码来源优先级' -ForegroundColor $W
    Write-Host '    -pass  >  -passfromclientlog  >  环境变量 SRUN_PASS  >  交互输入' -ForegroundColor $D
    Write-Host ''
    Write-Host '  常见失败码' -ForegroundColor $W
    Write-Host '    628  服务器在认证完成前断开：旧会话没释放 / PPPoE 栈残留 / 重试太快' -ForegroundColor $D
    Write-Host '    651  本机 PPPoE 栈卡死：禁用再启用物理网卡，或重启 RasMan 服务' -ForegroundColor $D
    Write-Host '    691  账号或密码错（不重试，直接退出）' -ForegroundColor $D
    Write-Host '    722  服务器无应答：网线没插 / 不在校园网内' -ForegroundColor $D
    Write-Host ''
    Write-Host '  注意' -ForegroundColor $Y
    Write-Host '    官方客户端在托盘里持续探活，一掉线就自己抢回会话。' -ForegroundColor $D
    Write-Host '    用本脚本拨号时请加 -killclient，或先在托盘退出客户端。' -ForegroundColor $D
    Write-Host ''
}

# ---------------------------------------------------------------- 核心: 账号编码
# SRunEncodeAccountV4D 等价实现, 已与官方客户端实际发出的账号串逐条比对通过。
# 返回值 = "{S4}<tag>\r\n<hex><@域名>"  其中
#   tag = 当日已过秒数 + sum(本地部分字节)     (17 位, 不要 OR 0x10000)
#   hex = 每个字节 +4 后的十六进制(小写)
function Get-SrunAccount {
    param([string]$Account, [int]$Now = 0)

    $at = $Account.IndexOf('@')
    if ($at -ge 0) {
        $local = $Account.Substring(0, $at)
        $rest = $Account.Substring($at)
    } else {
        $local = $Account
        $rest = ''
    }

    if ($Now -gt 0) {
        $dt = [DateTimeOffset]::FromUnixTimeSeconds($Now).ToLocalTime().DateTime
    } else {
        $dt = Get-Date
    }
    $sod = [int][Math]::Floor($dt.TimeOfDay.TotalSeconds)

    $bytes = [Text.Encoding]::ASCII.GetBytes($local)
    $sum = 0
    foreach ($b in $bytes) { $sum += $b }
    # tag = 当日秒数 + 本地部分字节和, 17 位无符号. 千万不要 OR 上 0x10000:
    # 傍晚(sod+sum > 65535)时 OR 和 不 OR 结果一样, 只有上午才会露馅 —— 之前就是这样错过 bug 的.
    $tag = ($sod + $sum) -band 0x1FFFF

    $sb = New-Object Text.StringBuilder
    foreach ($b in $bytes) { [void]$sb.Append(('{0:x2}' -f ($b + 4))) }

    return ('{S4}' + ('{0:x}' -f $tag) + "`r`n" + $sb.ToString() + $rest)
}

# ---------------------------------------------------------------- pbk 模板
# 与官方客户端生成的 srun.pbk 完全同构 (PBVersion 会被 Windows 自动升级到 8)
function Get-PbkTemplate {
    param([string]$EntryName, [string]$EntryGuid, [int]$Uid, [int]$Low, [int]$High)

    $lines = @(
        "[$EntryName]", 'Encoding=1', 'PBVersion=8', 'Type=5', 'AutoLogon=0', 'UseRasCredentials=0',
        "LowDateTime=$Low", "HighDateTime=$High", "DialParamsUID=$Uid", "Guid=$EntryGuid",
        'VpnStrategy=0', 'ExcludedProtocols=0', 'LcpExtensions=1', 'DataEncryption=8', 'SwCompression=0',
        'NegotiateMultilinkAlways=0', 'SkipDoubleDialDialog=0', 'DialMode=0', 'OverridePref=15',
        'RedialAttempts=3', 'RedialSeconds=60', 'IdleDisconnectSeconds=0', 'RedialOnLinkFailure=1',
        'CallbackMode=0', 'CustomDialDll=', 'CustomDialFunc=', 'CustomRasDialDll=',
        'ForceSecureCompartment=0', 'DisableIKENameEkuCheck=0', 'AuthenticateServer=0', 'ShareMsFilePrint=0',
        'BindMsNetClient=0', 'SharedPhoneNumbers=0', 'GlobalDeviceSettings=0', 'PrerequisiteEntry=',
        'PrerequisitePbk=', 'PreferredPort=PPPoE5-0', 'PreferredDevice=WAN Miniport (PPPOE)',
        'PreferredBps=0', 'PreferredHwFlow=0', 'PreferredProtocol=0', 'PreferredCompression=0',
        'PreferredSpeaker=0', 'PreferredMdmProtocol=0', 'PreviewUserPw=1', 'PreviewDomain=0',
        'PreviewPhoneNumber=0', 'ShowDialingProgress=1', 'ShowMonitorIconInTaskBar=1', 'CustomAuthKey=0',
        'AuthRestrictions=552', 'IpPrioritizeRemote=1', 'IpInterfaceMetric=0', 'IpHeaderCompression=0',
        'IpAddress=0.0.0.0', 'IpDnsAddress=0.0.0.0', 'IpDns2Address=0.0.0.0', 'IpWinsAddress=0.0.0.0',
        'IpWins2Address=0.0.0.0', 'IpAssign=1', 'IpNameAssign=1', 'IpDnsFlags=0', 'IpNBTFlags=0',
        'TcpWindowSize=0', 'UseFlags=3', 'IpSecFlags=0', 'IpDnsSuffix=', 'Ipv6Assign=1', 'Ipv6Address=::',
        'Ipv6PrefixLength=0', 'Ipv6PrioritizeRemote=1', 'Ipv6InterfaceMetric=0', 'Ipv6NameAssign=1',
        'Ipv6DnsAddress=::', 'Ipv6Dns2Address=::', 'Ipv6Prefix=0000000000000000',
        'Ipv6InterfaceId=0000000000000000', 'DisableClassBasedDefaultRoute=0', 'DisableMobility=0',
        'NetworkOutageTime=0', 'IDI=', 'IDR=', 'ImsConfig=0', 'IdiType=0', 'IdrType=0', 'ProvisionType=0',
        'PreSharedKey=', 'CacheCredentials=0', 'NumCustomPolicy=0', 'NumEku=0', 'UseMachineRootCert=0',
        'Disable_IKEv2_Fragmentation=0', 'PlumbIKEv2TSAsRoutes=0', 'NumServers=0', 'RouteVersion=1',
        'NumRoutes=0', 'NumNrptRules=0', 'AutoTiggerCapable=0', 'NumAppIds=0', 'NumClassicAppIds=0',
        'SecurityDescriptor=', 'ApnInfoProviderId=', 'ApnInfoUsername=', 'ApnInfoPassword=',
        'ApnInfoAccessPoint=', 'ApnInfoAuthentication=1', 'ApnInfoCompression=0',
        'DeviceComplianceEnabled=0', 'DeviceComplianceSsoEnabled=0', 'DeviceComplianceSsoEku=',
        'DeviceComplianceSsoIssuer=', 'FlagsSet=0', 'Options=0',
        'DisableDefaultDnsSuffixes=0', 'NumTrustedNetworks=0', 'NumDnsSearchSuffixes=0',
        'PowershellCreatedProfile=0', 'ProxyFlags=0', 'ProxySettingsModified=0', 'ProvisioningAuthority=',
        'AuthTypeOTP=0', 'GREKeyDefined=0', 'NumPerAppTrafficFilters=0', 'AlwaysOnCapable=0',
        'DeviceTunnel=0', 'PrivateNetwork=0', 'ManagementApp=', '',
        'NETCOMPONENTS=', 'ms_msclient=0', 'ms_server=0', '',
        'MEDIA=rastapi', 'Port=PPPoE5-0', 'Device=WAN Miniport (PPPOE)', '',
        'DEVICE=PPPoE', 'LastSelectedPhone=0', 'PromoteAlternates=0', 'TryNextAlternateOnFail=1', '', ''
    )
    return ($lines -join "`r`n")
}

function Test-PbkEntry {
    param([string]$EntryName)
    foreach ($f in (Get-ChildItem -Path $PbkDir -Filter '*.pbk' -ErrorAction SilentlyContinue)) {
        $txt = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::ASCII)
        if ($txt -match [regex]::Escape("[$EntryName]")) { return $true }
    }
    return $false
}

function New-PbkEntry {
    param([string]$EntryName)

    if (-not (Test-Path $PbkDir)) { New-Item -ItemType Directory -Path $PbkDir -Force | Out-Null }

    $ft = [int64]([DateTime]::UtcNow.ToFileTimeUtc())
    $bb = [BitConverter]::GetBytes($ft)
    $low = [BitConverter]::ToInt32($bb, 0)
    $high = [BitConverter]::ToInt32($bb, 4)
    $guid = ([guid]::NewGuid().ToString('N')).ToUpperInvariant()
    $uid = Get-Random -Minimum 100000 -Maximum 999999

    $content = Get-PbkTemplate -EntryName $EntryName -EntryGuid $guid -Uid $uid -Low $low -High $high
    $path = Join-Path $PbkDir ($EntryName + '.pbk')
    [IO.File]::WriteAllText($path, $content, [Text.Encoding]::ASCII)
    Write-Host "  已创建宽带拨号项: $path" -ForegroundColor DarkGray
    return $path
}

# ---------------------------------------------------------------- rasdial 封装
function Invoke-Rasdial {
    param([string[]]$RasArgs)
    $raw = & rasdial @RasArgs 2>&1
    $code = $LASTEXITCODE
    $text = ($raw | Out-String).Trim()
    return [pscustomobject]@{ Code = $code; Text = $text }
}

function Get-RasHint {
    param([int]$Code)
    switch ($Code) {
        0       { '成功' }
        623     { '找不到宽带拨号项(电话簿里没有这个名称)' }
        628     { '服务器在认证完成前主动断开 —— 常见原因: 上一条会话未释放 / PPPoE 栈残留 / 短时间内失败太多次被冷却。等几十秒再试' }
        651     { '调制解调器报告错误(PPPoE 协议栈卡死) —— 需要禁用/启用物理网卡, 或重启 RasMan 服务' }
        681     { '设备没有应答, 检查网线 / 是否在校园网内' }
        691     { '账号或密码错误' }
        720     { '该连接已存在或端口被占用(可能已连接, 试 -Force)' }
        722     { '服务器无应答(PPPoE 发现阶段失败)' }
        756     { '该连接已经建立' }
        778     { '服务器没有应答, 可能是账号被踢/在线数超限' }
        789     { 'L2TP/IPSec 协商失败(与本工具无关)' }
        868     { '找不到 WAN Miniport (PPPOE) 设备' }
        default { "rasdial 失败码 $Code" }
    }
}

function Get-LinkInfo {
    param([string]$EntryName)
    $ips = Get-NetIPAddress -InterfaceAlias $EntryName -ErrorAction SilentlyContinue
    $v4 = $ips | Where-Object { $_.AddressFamily -eq 'IPv4' } | Select-Object -First 1
    $v6 = $ips | Where-Object { $_.AddressFamily -eq 'IPv6' -and $_.IPAddress -notlike 'fe80*' } | Select-Object -First 1
    return [pscustomobject]@{ IPv4 = $v4.IPAddress; IPv6 = $v6.IPAddress; Up = [bool]$v4 }
}

function Test-PortalReachable {
    param([string]$HostAddr = '10.1.88.4', [int]$Port = 80, [int]$TimeoutMs = 2000)
    $c = New-Object Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($HostAddr, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $c.EndConnect($iar)
        return $true
    } catch { return $false } finally { $c.Close() }
}

# ---------------------------------------------------------------- 配置记住账号
function Read-Config {
    if (Test-Path $ConfigFile) {
        try { return (Get-Content $ConfigFile -Raw | ConvertFrom-Json) } catch { return $null }
    }
    return $null
}
function Save-Config {
    param([string]$Account)
    if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
    @{ account = $Account; updated = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content $ConfigFile -Encoding UTF8
}

function Resolve-Account {
    if ($User) {
        if ($User -like '*@*') { return $User }
        $suffix = $Domains[$Domain]
        if ($suffix) { return ($User + '@' + $suffix) } else { return $User }
    }
    $cfg = Read-Config
    if ($cfg -and $cfg.account) { return $cfg.account }
    return $null
}

function Get-PassFromClientLog {
    # 官方客户端把 rasdial 的三个参数明文打进了自己的日志, 取最后一条
    $log = Join-Path $env:APPDATA '网络准入认证客户端\logs\renderer.log'
    if (-not (Test-Path -LiteralPath $log)) { return $null }
    $txt = Get-Content -LiteralPath $log -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $txt) { return $null }
    $ms = [regex]::Matches($txt, "rasdial \[\s*'[^']*',\s*'[^']*',\s*'([^']{4,})'")
    if ($ms.Count -eq 0) { return $null }
    return $ms[$ms.Count - 1].Groups[1].Value
}

function Resolve-Password {
    if ($Pass) { return $Pass }
    if ($PassFromClientLog) {
        $p = Get-PassFromClientLog
        if ($p) {
            Write-Host '  密码取自官方客户端日志(不显示、不落盘)' -ForegroundColor DarkGray
            return $p
        }
        Write-Host '  客户端日志里没找到可用密码, 改为手动输入' -ForegroundColor Yellow
    }
    if ($env:SRUN_PASS) { return $env:SRUN_PASS }
    $sec = Read-Host -AsSecureString '密码'
    return [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}

# ================================================================ 主流程
if ($version) {
    Write-Host "srun $SrunVersion"
    return
}

switch ($Action) {

    'help' {
        Show-Help
    }

    'encode' {
        $acct = Resolve-Account
        if (-not $acct) { throw '需要 -user 参数（或先用 dial 成功一次让它记住账号）' }
        $enc = Get-SrunAccount -Account $acct -Now $At
        Write-Host "账号(明文): $acct"
        Write-Host '交给 rasdial 的账号:'
        Write-Host ('  ' + ($enc -replace "`r`n", '\r\n')) -ForegroundColor Cyan
    }

    'status' {
        $info = Get-LinkInfo -EntryName $Name
        $exists = Test-PbkEntry -EntryName $Name
        Write-Host "拨号项 [$Name]: $(if ($exists) { '存在' } else { '不存在' })"
        if ($info.Up) {
            Write-Host "状态: 已连接" -ForegroundColor Green
            Write-Host "  IPv4: $($info.IPv4)"
            if ($info.IPv6) { Write-Host "  IPv6: $($info.IPv6)" }
            Write-Host "  Portal 10.1.88.4:80 可达: $(Test-PortalReachable)"
        } else {
            Write-Host '状态: 未连接' -ForegroundColor Yellow
        }
        Write-Host "  官方客户端进程: $(@(Get-Process -Name $ClientExeName -ErrorAction SilentlyContinue).Count)" -ForegroundColor DarkGray
    }

    'disconnect' {
        if (-not (Test-PbkEntry -EntryName $Name)) { Write-Host "拨号项 [$Name] 不存在"; break }
        $r = Invoke-Rasdial @($Name, '/d')
        if ($r.Code -eq 0) {
            Write-Host "已断开 [$Name]" -ForegroundColor Green
        } else {
            Write-Host ("断开失败: " + (Get-RasHint $r.Code)) -ForegroundColor Red
            Write-Host $r.Text -ForegroundColor DarkGray
        }
    }

    'dial' {
        $acct = Resolve-Account
        if (-not $acct) {
            $u = Read-Host '账号(学号/工号)'
            $suffix = $Domains[$Domain]
            if ($u -like '*@*') { $acct = $u } elseif ($suffix) { $acct = "$u@$suffix" } else { $acct = $u }
        }

        if (-not $acct -or $acct -match '^@' -or $acct -match '^$') {
            Write-Host '没拿到账号(非交互运行时 Read-Host 拿到空值)。请用 -user 学号 指定，或先手动跑一次让它记住账号。' -ForegroundColor Red
            exit 1
        }

        # -dry: 只打印将要交给 rasdial 的账号, 绝不碰当前连接
        if ($Dry) {
            $enc = Get-SrunAccount -Account $acct
            Write-Host "拨号: $acct  ->  $Name" -ForegroundColor Cyan
            Write-Host ('  [dry] 交给 rasdial 的账号: ' + ($enc -replace "`r`n", '\r\n')) -ForegroundColor DarkGray
            break
        }

        $info = Get-LinkInfo -EntryName $Name
        if ($info.Up) {
            if (-not $Force) {
                Write-Host "[$Name] 已连接 ($($info.IPv4)), 不重复拨号。要重拨加 -force" -ForegroundColor Yellow
                break
            }
            Write-Host '强制重拨: 先断开…' -ForegroundColor DarkGray
            Invoke-Rasdial @($Name, '/d') | Out-Null
            Start-Sleep -Seconds 1
        }

        # -KillClient: 官方客户端每 2 秒在探活, 一掉线就自己抢回去, 会跟本脚本打架
        if ($KillClient) {
            $procs = @(Get-Process -Name '网络准入认证客户端' -ErrorAction SilentlyContinue)
            if ($procs.Count -gt 0) {
                Write-Host "  关闭官方客户端 ($($procs.Count) 个进程)…" -ForegroundColor DarkGray
                $procs | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
            }
        }

        $pass = if ($Dry) { '' } else { Resolve-Password }

        # 拨号前先清一次, 免得上一条半死会话顶着(这也是 628 的常见来源)
        if (-not $Dry) {
            Invoke-Rasdial @($Name, '/d') | Out-Null
            Start-Sleep -Milliseconds 800
        }

        $delays = @(10, 30, 60)
        $attempt = 0
        while ($true) {
            $attempt++
            # tag 每秒都在变, 每次重拨必须重新编码
            $enc = Get-SrunAccount -Account $acct
            $tag = if ($attempt -gt 1) { " (第 $attempt 次尝试)" } else { '' }
            Write-Host "拨号: $acct  ->  $Name$tag" -ForegroundColor Cyan

            if ($Dry) {
                Write-Host ('  [Dry] 交给 rasdial 的账号: ' + ($enc -replace "`r`n", '\r\n')) -ForegroundColor DarkGray
                break
            }

            $r = Invoke-Rasdial @($Name, $enc, $pass)
            if ($r.Code -eq 623) {
                New-PbkEntry -EntryName $Name | Out-Null
                Start-Sleep -Milliseconds 500
                $r = Invoke-Rasdial @($Name, $enc, $pass)
            }

            if ($r.Code -eq 0) {
                Save-Config -Account $acct
                $info = Get-LinkInfo -EntryName $Name
                Write-Host '拨号成功' -ForegroundColor Green
                Write-Host "  IPv4: $($info.IPv4)"
                if ($info.IPv6) { Write-Host "  IPv6: $($info.IPv6)" }
                Write-Host "  Portal 10.1.88.4:80 可达: $(Test-PortalReachable)"
                break
            }

            Write-Host ('拨号失败: ' + (Get-RasHint $r.Code)) -ForegroundColor Red

            # 账号密码错 / 参数错 不重试
            if ($r.Code -in @(691, 623, 681, 722)) {
                if ($r.Text) { Write-Host $r.Text -ForegroundColor DarkGray }
                exit 1
            }
            if ($attempt -ge ($Retry + 1)) {
                if ($r.Text) { Write-Host $r.Text -ForegroundColor DarkGray }
                Write-Host "已重试 $Retry 次仍失败。若是 628: 等 1~2 分钟再拨; 若是 651: 禁用/启用网卡后重试" -ForegroundColor Yellow
                exit 1
            }

            $wait = $delays[[Math]::Min($attempt - 1, $delays.Count - 1)]
            Write-Host "  ${wait} 秒后重试($attempt/$Retry)…" -ForegroundColor DarkYellow
            Start-Sleep -Seconds $wait
            Invoke-Rasdial @($Name, '/d') | Out-Null
        }
    }
}
