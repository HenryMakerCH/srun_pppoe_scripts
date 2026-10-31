<#
timesync.ps1 —— 给局域网里的路由器当局域网校时源

为什么需要：拨号凭据里的 tag 是「本地当日秒数 + 账号字节和」，Srun 的 BRAS 只容忍
大约 ±3 分钟的偏差。而没 RTC 的路由器冷启动时，时钟是 OpenWrt 的 sysfixtime 按文件
mtime 猜的，猜错就认证失败；认证失败就没有链路，没有链路就没有 NTP —— 死锁。
所以在同网段放一台常开的电脑，路由器在每次拨号前直接问它要 Unix 时间。

这个脚本就是一个只回一行 epoch 的裸 TCP 服务（故意不用 HttpListener：非 localhost
前缀要 URL ACL 和管理员权限，TcpListener 什么也不要）。

用法：
  powershell -NoProfile -ExecutionPolicy Bypass -File timesync.ps1        # 常驻
  powershell -NoProfile -ExecutionPolicy Bypass -File timesync.ps1 -Once  # 打印一次 epoch 退出
  powershell -NoProfile -ExecutionPolicy Bypass -File timesync.ps1 -Port 8899

路由器侧验证：
  wget -q -T 2 -O - http://<本机IP>:8899/        # 应回一个 10 位数字

开机自启（不需要管理员）：把下面的 start-hidden.vbs 放进 shell:startup 文件夹，
或者在任务计划程序里建一个"登录时"触发的任务。
  CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass " & _
      "-WindowStyle Hidden -File ""<本文件全路径>""", 0, False
防火墙开着的机器要把 TCP 8899 入站放通（专用网络）。
#>
param(
    [int]$Port = 8899,
    [switch]$Once
)

if ($Once) {
    [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    exit 0
}

$log = Join-Path $PSScriptRoot 'timesync.log'
function Write-Log([string]$msg) {
    "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg |
        Add-Content -Path $log -Encoding UTF8
}

try {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
    $listener.Start()
} catch {
    Write-Log "端口 $Port 起不来：$($_.Exception.Message)"
    exit 1
}

$ips = @()
try {
    $ips = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
            ForEach-Object { $_.IPAddress }) -join ','
} catch { }
Write-Log "监听 0.0.0.0:$Port  本机地址: $ips"

while ($true) {
    $client = $null
    try {
        $client = $listener.AcceptTcpClient()
        $client.ReceiveTimeout = 3000
        $stream = $client.GetStream()
        # 读一下请求行就行，内容不关心
        $buf = New-Object byte[] 512
        try { $null = $stream.Read($buf, 0, $buf.Length) } catch { }

        $epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $body  = "$epoch`n"
        $head  = "HTTP/1.0 200 OK`r`nContent-Type: text/plain; charset=us-ascii`r`n" +
                 "Content-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($head + $body)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    } catch {
        Write-Log "处理请求出错：$($_.Exception.Message)"
    } finally {
        if ($client) { $client.Close() }
    }
}
