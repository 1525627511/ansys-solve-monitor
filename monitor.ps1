<#
  ANSYS Solve Monitor  /  ANSYS 求解监控器
  ------------------------------------------------------------------
  可移植版：拷到任何一台电脑、任何目录都能用，无需安装、无需改代码。
  用法: 双击「启动监控.bat」 或
        powershell -ExecutionPolicy Bypass -File monitor.ps1
  参数: -Root <路径>   手动指定工程目录(或直接拖 .wbpj 到 bat 上)
        -Once          只打印一帧就退出(自检)
        -Diagnose      打印目录探测结果(排查用)
#>
param(
    [switch]$Once,
    [switch]$Diagnose,
    [string]$Root = ''
)

$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:CfgFile   = Join-Path $script:ScriptDir 'config.txt'
$script:LogFile   = Join-Path $script:ScriptDir ("monitor_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
$script:OverrideRoot = $Root
$script:ScanCache = $null
$script:ScanCacheTime = [datetime]::MinValue

# ================= 配置 =================
function Get-Config {
    $cfg = @{ Roots = @(); StallMinutes = 12; PollSeconds = 5; Beep = 'on'; AutoScan = 'on' }
    if (Test-Path $script:CfgFile) {
        foreach ($line in (Get-Content $script:CfgFile -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
            $kv = $line.Split('=', 2)
            if ($kv.Count -lt 2) { continue }
            $k = $kv[0].Trim(); $v = $kv[1].Trim()
            if ($v -eq '') { continue }
            switch -Regex ($k) {
                '^(项目根目录|ProjectRoot)$'          { $cfg.Roots += ($v -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
                '^(卡死判定分钟|StallMinutes)$'        { $cfg.StallMinutes = [int]$v }
                '^(刷新秒数|PollSeconds)$'             { $cfg.PollSeconds = [int]$v }
                '^(提示音|Beep)$'                      { $cfg.Beep = $v.ToLower() }
                '^(自动扫描|AutoScan)$'                { $cfg.AutoScan = $v.ToLower() }
            }
        }
    }
    return $cfg
}

# ================= 根目录解析 =================
function Test-ProjectRoot {
    param([string]$Path)
    if (-not $Path) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    # 该目录下是否有 *_files\dp0\*\MECH 或 _ProjectScratch
    if (Test-Path -LiteralPath (Join-Path $Path '_ProjectScratch')) { return $true }
    foreach ($f in @(Get-ChildItem -LiteralPath $Path -Directory -Filter '*_files' -ErrorAction SilentlyContinue)) { return $true }
    return $false
}

function Find-RootsByScan {
    if ($script:ScanCache -and ((Get-Date) - $script:ScanCacheTime).TotalSeconds -lt 60) { return $script:ScanCache }
    $found = New-Object System.Collections.ArrayList
    $drives = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Root -match '^[A-Za-z]:\\$' })
    foreach ($d in $drives) {
        try {
            $hits = Get-ChildItem -LiteralPath $d.Root -Directory -Filter '*_files' -Recurse -Depth 3 -ErrorAction SilentlyContinue
            foreach ($h in $hits) {
                if ($h.Parent -and (Test-Path -LiteralPath (Join-Path $h.Parent.FullName '_ProjectScratch')) -or
                    ($h.Parent -and (Test-Path -LiteralPath (Join-Path $h.FullName 'dp0')))) {
                    if (-not $found.Contains($h.Parent.FullName)) { [void]$found.Add($h.Parent.FullName) }
                }
            }
        } catch { }
    }
    $script:ScanCache = @($found)
    $script:ScanCacheTime = Get-Date
    return $script:ScanCache
}

function Resolve-Roots {
    param($Cfg)
    $roots = New-Object System.Collections.ArrayList

    if ($script:OverrideRoot) {
        $p = $script:OverrideRoot
        if ($p -match '\.wbpj$') { $p = Split-Path -Parent $p }
        if (Test-Path -LiteralPath $p) { [void]$roots.Add($p) }
    }
    foreach ($r in $Cfg.Roots) { if (Test-Path -LiteralPath $r) { [void]$roots.Add($r) } }

    # 工具自身所在目录及其上两级（把工具放进工程目录时零配置）
    $d = $script:ScriptDir
    for ($i = 0; $i -lt 3; $i++) {
        if ($d -and (Test-ProjectRoot -Path $d)) { [void]$roots.Add($d) }
        $d = Split-Path -Parent $d
        if (-not $d) { break }
    }

    if ($roots.Count -eq 0 -and $Cfg.AutoScan -ne 'off') {
        foreach ($r in (Find-RootsByScan)) { [void]$roots.Add($r) }
    }
    return @($roots | Select-Object -Unique)
}

# ================= 寻找求解产物 =================
function Find-Artifacts {
    param([string[]]$Roots)
    $cands = New-Object System.Collections.ArrayList
    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }

        # 项目目录: <root>\*_files\dp0\<SYS>\MECH\
        foreach ($mech in @(Get-ChildItem -LiteralPath $root -Directory -Filter '*_files' -ErrorAction SilentlyContinue)) {
            $dp0 = Join-Path $mech.FullName 'dp0'
            if (Test-Path -LiteralPath $dp0) {
                foreach ($sys in @(Get-ChildItem -LiteralPath $dp0 -Directory -ErrorAction SilentlyContinue)) {
                    $m = Join-Path $sys.FullName 'MECH'
                    if (-not (Test-Path -LiteralPath $m)) { continue }
                    foreach ($f in 'file.mntr', 'file.stat', 'ds_file.stat', 'solve.out') {
                        $p = Join-Path $m $f
                        if (Test-Path -LiteralPath $p) { [void]$cands.Add([pscustomobject]@{ Path = $p; Dir = $m }) }
                    }
                }
            }
            # 项目内临时目录: <root>\*_files\_ProjectScratch\<Scr*>
            $psx = Join-Path $mech.FullName '_ProjectScratch'
            if (Test-Path -LiteralPath $psx) {
                foreach ($s in @(Get-ChildItem -LiteralPath $psx -Directory -ErrorAction SilentlyContinue)) {
                    foreach ($f in 'file.mntr', 'file.stat', 'ds_file.stat', 'solve.out') {
                        $p = Join-Path $s.FullName $f
                        if (Test-Path -LiteralPath $p) { [void]$cands.Add([pscustomobject]@{ Path = $p; Dir = $s.FullName }) }
                    }
                }
            }
        }

        # 根目录下: <root>\_ProjectScratch\<Scr*>
        $psr = Join-Path $root '_ProjectScratch'
        if (Test-Path -LiteralPath $psr) {
            foreach ($s in @(Get-ChildItem -LiteralPath $psr -Directory -ErrorAction SilentlyContinue)) {
                foreach ($f in 'file.mntr', 'file.stat', 'ds_file.stat', 'solve.out') {
                    $p = Join-Path $s.FullName $f
                    if (Test-Path -LiteralPath $p) { [void]$cands.Add([pscustomobject]@{ Path = $p; Dir = $s.FullName }) }
                }
            }
        }
    }
    if ($cands.Count -eq 0) { return $null }

    $live = $cands | Sort-Object { (Get-Item -LiteralPath $_.Path).LastWriteTime } -Descending | Select-Object -First 1
    return [pscustomobject]@{
        Dir  = $live.Dir
        Mntr = Join-Path $live.Dir 'file.mntr'
        Stat = Join-Path $live.Dir 'file.stat'
        Gst  = Join-Path $live.Dir 'file.gst'
        Err  = Join-Path $live.Dir 'file.err'
        Out  = Join-Path $live.Dir 'solve.out'
        Ds   = Join-Path $live.Dir 'ds.dat'
    }
}

# ================= 解析 =================
function Get-StepEndTime {
    param([string]$DsDat)
    if (-not (Test-Path -LiteralPath $DsDat)) { return $null }
    $hit = Select-String -LiteralPath $DsDat -Pattern '^\s*time\s*,\s*([-\d\.Ee+]+)' -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($hit -and $hit.Matches[0].Groups[1].Value) { return [double]$hit.Matches[0].Groups[1].Value }
    return $null
}

function Read-Mntr {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $rows = New-Object System.Collections.ArrayList
    foreach ($l in @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        if ($l -match '^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)') {
            [void]$rows.Add([pscustomobject]@{
                LS   = [int]$matches[1];  Sub  = [int]$matches[2]
                Iter = [int]$matches[5];  Incr = [double]$matches[6]
                Time = [double]$matches[7]; Wall = [double]$matches[8]
                MxDs = [double]$matches[9]; MxPl = [double]$matches[10]
                MxRe = [double]$matches[11]
            })
        }
    }
    if ($rows.Count -eq 0) { return $null }
    return $rows
}

function Read-Text {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    return ((Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue | Where-Object { $_ -match '\S' }) -join ' ').Trim()
}

function Get-SolverState {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    foreach ($l in @(Get-Content -LiteralPath $Path -TotalCount 400 -ErrorAction SilentlyContinue)) {
        if ($l -match 'EQUATION SOLVER OPTION\s+\.*\s*(.+)$') { return $matches[1].Trim() }
    }
    return ''
}

# ================= 格式化 =================
function Format-Bar {
    param([double]$Pct, [int]$Width = 40)
    if ([double]::IsNaN($Pct)) { $Pct = 0 }
    $Pct = [math]::Min(100, [math]::Max(0, $Pct))
    $n = [int][math]::Round($Width * $Pct / 100.0)
    return ('[' + ('#' * $n) + ('.' * ($Width - $n)) + ']')
}

function Format-Duration {
    param([double]$Seconds)
    if ($null -eq $Seconds -or [double]::IsNaN($Seconds) -or $Seconds -lt 0) { return '--' }
    if ($Seconds -gt [double]::MaxValue / 2) { return '--' }
    $ts = [TimeSpan]::FromSeconds($Seconds)
    if ($ts.TotalHours -ge 1) { return ('{0:0}h{1:00}m' -f [math]::Floor($ts.TotalHours), $ts.Minutes) }
    return ('{0:0}m{1:00}s' -f $ts.Minutes, $ts.Seconds)
}

# ================= 启动 =================
$cfg = Get-Config
$roots = Resolve-Roots -Cfg $cfg

if ($Diagnose) {
    Write-Host '=== 目录探测 ==='
    Write-Host ("脚本目录: {0}" -f $script:ScriptDir)
    Write-Host ("配置根目录: {0}" -f (($cfg.Roots -join ' ; ') -replace '^$', '(空)'))
    Write-Host ("实际使用: {0}" -f ($roots -join ' ; '))
    $a = Find-Artifacts -Roots $roots
    if ($a) { Write-Host ("找到求解目录: {0}" -f $a.Dir) } else { Write-Host '未找到任何求解目录' }
    exit 0
}

"=== 监控启动 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" |
    Out-File -FilePath $script:LogFile -Encoding UTF8
"根目录: $($roots -join ' ; ')" | Out-File -FilePath $script:LogFile -Append -Encoding UTF8

$lastSub = -1
$lastChange = Get-Date
$runStart = $null
$avgStepSec = $null
$finished = $false
$quitByUser = $false
$exitCode = 0

while ($true) {
    $now = Get-Date
    $proc = @(Get-Process -Name ANSYS -ErrorAction SilentlyContinue)
    $art = Find-Artifacts -Roots $roots

    if ($proc.Count -gt 0 -and $null -eq $runStart) {
        $runStart = $proc[0].StartTime
        $lastChange = $now
        "求解进程出现 pid=$($proc[0].Id) 起 $($runStart.ToString('HH:mm:ss'))" |
            Out-File -FilePath $script:LogFile -Append -Encoding UTF8
    }

    $rows = $null; $stat = ''; $dsstat = ''; $stepEnd = $null; $solver = ''
    if ($art) {
        $rows    = Read-Mntr -Path $art.Mntr
        $stat    = Read-Text -Path $art.Stat
        $dsstat  = Read-Text -Path (Join-Path $art.Dir 'ds_file.stat')
        $stepEnd = Get-StepEndTime -DsDat $art.Ds
        $solver  = Get-SolverState -Path $art.Out
    }

    $last = $null
    if ($rows -and $rows.Count -gt 0) { $last = $rows[$rows.Count - 1] }

    if ($rows -and $rows.Count -ge 2) {
        $span = $rows[$rows.Count - 1].Sub - $rows[0].Sub
        if ($span -gt 0) { $avgStepSec = ($rows[$rows.Count - 1].Wall - $rows[0].Wall) / $span }
    }

    if ($last -and $last.Sub -ne $lastSub) {
        $lastSub = $last.Sub
        $lastChange = $now
        ("子步 {0} 完成  t={1}  墙钟={2}s  位移={3}mm  塑性={4}" -f `
            $last.Sub, $last.Time, $last.Wall, $last.MxDs, $last.MxPl) |
            Out-File -FilePath $script:LogFile -Append -Encoding UTF8
    }

    $stallMin = [math]::Round(($now - $lastChange).TotalMinutes, 1)

    if (-not $Once) { Clear-Host }
    try { $w = [Console]::WindowWidth } catch { $w = 100 }
    if ($w -lt 60) { $w = 100 }
    $line = ('-' * [math]::Min($w, 110))

    Write-Host ''
    Write-Host '  ================  ANSYS 求解监控  ================' -ForegroundColor Cyan
    Write-Host ("  时间 {0}   轮询 {1}s   卡死判定 {2} 分钟" -f (Get-Date -Format 'HH:mm:ss'), $cfg.PollSeconds, $cfg.StallMinutes) -ForegroundColor DarkGray
    Write-Host $line -ForegroundColor DarkGray

    if ($proc.Count -eq 0 -and -not $runStart) {
        Write-Host '  等待求解开始……（在 Workbench/Mechanical 里点「求解」后会自动接上）' -ForegroundColor Yellow
    }
    elseif ($proc.Count -eq 0) {
        Write-Host '  求解进程已退出，正在读取最终状态……' -ForegroundColor Yellow
    }
    else {
        $p0 = $proc[0]
        Write-Host ("  求解进程 pid={0}   已运行 {1}   CPU {2:N0}s   内存 {3:N0} MB" -f `
            $p0.Id, (Format-Duration ((Get-Date) - $p0.StartTime).TotalSeconds), $p0.CPU, ($p0.WorkingSet64 / 1MB)) -ForegroundColor Green
    }

    if ($art) {
        Write-Host ("  结果目录 {0}" -f $art.Dir) -ForegroundColor DarkGray
        if ($solver) { Write-Host ("  求解器   {0}" -f $solver) -ForegroundColor DarkGray }
    }
    else {
        Write-Host '  未找到求解目录：请检查 config.txt 的「项目根目录」' -ForegroundColor Yellow
    }
    Write-Host $line -ForegroundColor DarkGray

    if ($last) {
        $pct = 0.0
        if ($stepEnd -and $stepEnd -gt 0) { $pct = 100.0 * $last.Time / $stepEnd }
        Write-Host ("  进度 {0} {1,5:N1}%   t = {2:N3} / {3:N3} s" -f (Format-Bar $pct), $pct, $last.Time, $stepEnd) -ForegroundColor Cyan
        Write-Host ''
        Write-Host ("  子步 {0,-6} 累计迭代 {1,-6} 位移 {2,10:N2} mm   塑性 {3,10:E3}   残差 {4,10:N2} N" -f `
            $last.Sub, $last.Iter, $last.MxDs, $last.MxPl, $last.MxRe)
        Write-Host ("  求解墙钟 {0,8:N0} s ({1})   本步用时 {2}" -f $last.Wall, (Format-Duration $last.Wall), (Format-Duration $avgStepSec)) -ForegroundColor DarkGray
        if ($avgStepSec -and $stepEnd -and $last.Incr -gt 0) {
            $remain = ($stepEnd - $last.Time) / $last.Incr * $avgStepSec
            Write-Host ("  预计剩余 {0}   预计完成 {1}" -f (Format-Duration $remain), ((Get-Date).AddSeconds($remain).ToString('HH:mm'))) -ForegroundColor DarkGray
        }
    }
    else {
        Write-Host '  尚无子步数据（正在建矩阵 / 组装方程，属正常）' -ForegroundColor Yellow
    }

    Write-Host $line -ForegroundColor DarkGray
    if ($stat)   { Write-Host ("  求解器  {0}" -f $stat)   -ForegroundColor DarkGray }
    if ($dsstat) { Write-Host ("  迭代器  {0}" -f $dsstat) -ForegroundColor DarkGray }

    if ($rows -and $rows.Count -gt 1) {
        Write-Host ''
        Write-Host '  最近子步走势:' -ForegroundColor DarkGray
        Write-Host ('    {0,6} {1,10} {2,12} {3,12} {4,12}' -f '子步', '时刻t(s)', '位移(mm)', '塑性应变', '累计墙钟') -ForegroundColor DarkGray
        foreach ($r in ($rows | Select-Object -Last 6)) {
            Write-Host ('    {0,6} {1,10:N3} {2,12:N2} {3,12:E3} {4,12:N0}' -f $r.Sub, $r.Time, $r.MxDs, $r.MxPl, $r.Wall)
        }
    }

    if ($proc.Count -gt 0 -and $stallMin -ge $cfg.StallMinutes) {
        Write-Host ''
        Write-Host ("  !! 已经 {0} 分钟没有新子步，可能卡住或已发散" -f $stallMin) -ForegroundColor Red
        Write-Host '     建议：先看 file.err；确实卡死再到 GUI 里点「停止求解」' -ForegroundColor Red
        if ($cfg.Beep -eq 'on') { try { [console]::Beep(880, 300) } catch { } }
    }
    elseif ($proc.Count -gt 0) {
        Write-Host ("  距上个新子步 {0} 分钟（正常）" -f $stallMin) -ForegroundColor DarkGray
    }

    Write-Host $line -ForegroundColor DarkGray
    Write-Host '  [Q] 退出监控（不会影响求解）    日志: ' -NoNewline -ForegroundColor DarkGray
    Write-Host (Split-Path -Leaf $script:LogFile) -ForegroundColor DarkGray

    if ($Once) { break }
    if ($proc.Count -eq 0 -and $runStart) { $finished = $true; break }

    $deadline = (Get-Date).AddSeconds($cfg.PollSeconds)
    while ((Get-Date) -lt $deadline) {
        try { $hasKey = [Console]::KeyAvailable } catch { $hasKey = $false }
        if ($hasKey) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq 'Q') { $exitCode = 0; $quitByUser = $true; $finished = $true; break }
        }
        Start-Sleep -Milliseconds 200
    }
    if ($finished) { break }
}

if ($finished -and -not $Once -and -not $quitByUser) {
    Start-Sleep -Seconds 15
    $art = Find-Artifacts -Roots $roots
    Clear-Host
    Write-Host ''
    Write-Host '  ================  求解结束  ================' -ForegroundColor Cyan
    if ($art -and (Test-Path -LiteralPath $art.Out)) {
        $hits = Select-String -LiteralPath $art.Out -Pattern 'RUN COMPLETED|REASON FOR TERMINATION|TIME OF LAST SOLUTION|ERROR MESSAGES ENCOUNTERED|WARNING MESSAGES ENCOUNTERED|FINISHED SOLVE|Equation solver used' -ErrorAction SilentlyContinue
        foreach ($h in $hits) { Write-Host ('  ' + $h.Line.Trim()) }
        $ok = @($hits | Where-Object { $_.Line -match 'RUN COMPLETED' }).Count -gt 0
        Write-Host ''
        if ($ok) { Write-Host '  结论：求解成功（RUN COMPLETED）' -ForegroundColor Green }
        else     { Write-Host '  结论：求解未正常结束，请看上面 REASON FOR TERMINATION' -ForegroundColor Red }
    }
    $rows = $null
    if ($art) { $rows = Read-Mntr -Path $art.Mntr }
    if ($rows -and $rows.Count -gt 0) {
        $l = $rows[$rows.Count - 1]
        Write-Host ''
        Write-Host ("  最后子步 {0}  t={1}  位移 {2:N2} mm  塑性 {3:E3}  总墙钟 {4:N0}s ({5})" -f `
            $l.Sub, $l.Time, $l.MxDs, $l.MxPl, $l.Wall, (Format-Duration $l.Wall)) -ForegroundColor Cyan
    }
    Write-Host ''
    Write-Host ("  完整日志: {0}" -f $script:LogFile) -ForegroundColor DarkGray
    if ($cfg.Beep -eq 'on') { try { [console]::Beep(660, 250); [console]::Beep(990, 350) } catch { } }
}

exit $exitCode
