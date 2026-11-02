<#
  dsh-watch.ps1 - ANSYS solve snapshot / watcher (for DeepSeek Harness in-chat reporting)

  -Snapshot        print one status frame (for reporting progress in chat)
  -Wait            watch until the solve ends or is judged stalled; writes a log and prints a summary
  Zero dependency: only built-in PowerShell.

  Examples:
    powershell -NoProfile -ExecutionPolicy Bypass -File dsh-watch.ps1 -Snapshot
    powershell -NoProfile -ExecutionPolicy Bypass -File dsh-watch.ps1 -Wait -IntervalSec 60
#>
[CmdletBinding()]
param(
  [string]$Root = '',
  [switch]$Snapshot,
  [switch]$Wait,
  [int]$IntervalSec = 60,
  [int]$StallMinutes = 30,
  [string]$LogPath = ''
)

$ErrorActionPreference = 'SilentlyContinue'

function Get-CandidateRoots {
  $list = New-Object System.Collections.ArrayList
  if ($Root) { [void]$list.Add($Root) }
  $cfg = Join-Path $PSScriptRoot 'config.txt'
  if (Test-Path $cfg) {
    Get-Content $cfg -Encoding UTF8 | ForEach-Object {
      if ($_ -match '^\s*项目根目录\s*=\s*(.+)$') {
        foreach ($p in ($Matches[1] -split ';')) { if ($p.Trim()) { [void]$list.Add($p.Trim()) } }
      }
    }
  }
  [void]$list.Add($PSScriptRoot)
  [void]$list.Add((Split-Path $PSScriptRoot -Parent))
  return $list
}

function Find-SolveDir {
  foreach ($r in (Get-CandidateRoots)) {
    if (-not (Test-Path $r)) { continue }
    $files = @()
    $files += Get-ChildItem -LiteralPath $r -Directory -Filter '*_files' -ErrorAction SilentlyContinue
    foreach ($sub in (Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue)) {
      $files += Get-ChildItem -LiteralPath $sub.FullName -Directory -Filter '*_files' -ErrorAction SilentlyContinue
    }
    foreach ($f in $files) {
      $mech = Join-Path $f.FullName 'dp0\SYS\MECH'
      $scr = Join-Path $f.FullName '_ProjectScratch'
      if ((Test-Path $mech) -or (Test-Path $scr)) {
        return [pscustomobject]@{ Files = $f.FullName; Mech = $mech; Scratch = $scr }
      }
    }
  }
  return $null
}

function Get-LatestScratch {
  param($SolveDir)
  if (-not (Test-Path $SolveDir.Scratch)) { return $null }
  Get-ChildItem -LiteralPath $SolveDir.Scratch -Directory -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Read-Status {
  param($SolveDir)
  $st = [ordered]@{
    Running = [bool](Get-Process ANSYS -ErrorAction SilentlyContinue)
    Sub = 0; Iter = 0; Time = 0.0; Wall = 0.0; Dt = 0.0
    MxDs = 0.0; MxPl = 0.0; PeakDs = 0.0; PeakPl = 0.0; EndTime = 0.0; Percent = 0.0
    StallMin = 0.0; StepSec = 0.0; Verdict = ''; Updated = $null
  }

  $mntrFile = $null
  $scr = Get-LatestScratch $SolveDir
  if ($scr) {
    $c = Join-Path $scr.FullName 'file.mntr'
    if (Test-Path $c) { $mntrFile = $c }
  }
  if (-not $mntrFile) {
    $c = Join-Path $SolveDir.Mech 'file.mntr'
    if (Test-Path $c) { $mntrFile = $c }
  }

  if ($mntrFile) {
    $rows = @()
    Get-Content -LiteralPath $mntrFile | ForEach-Object {
      if ($_ -match '^\s*1\s+\d+\s+') {
        $t = ($_ -split '\s+') | Where-Object { $_ -ne '' }
        if ($t.Count -ge 11) {
          $rows += [pscustomobject]@{
            Sub = [int]$t[1]; Iter = [int]$t[4]; Dt = [double]$t[5]; Time = [double]$t[6]
            Wall = [double]$t[7]; MxDs = [double]$t[8]; MxPl = [double]$t[9]
          }
        }
      }
    }
    if ($rows.Count -gt 0) {
      $last = $rows[-1]
      $st.Sub = $last.Sub; $st.Iter = $last.Iter; $st.Dt = $last.Dt
      $st.Time = $last.Time; $st.Wall = $last.Wall; $st.MxDs = $last.MxDs; $st.MxPl = $last.MxPl
      if ($rows.Count -ge 2) {
        $dSub = $rows[-1].Sub - $rows[0].Sub
        if ($dSub -gt 0) { $st.StepSec = [math]::Round(($rows[-1].Wall - $rows[0].Wall) / $dSub, 1) }
      }
      $st.Updated = (Get-Item -LiteralPath $mntrFile).LastWriteTime
      $st.StallMin = [math]::Round(((Get-Date) - $st.Updated).TotalMinutes, 1)
      $st.PeakDs = ($rows | Measure-Object -Property MxDs -Maximum).Maximum
      $st.PeakPl = ($rows | Measure-Object -Property MxPl -Maximum).Maximum
    }
  }

  $ds = Join-Path $SolveDir.Mech 'ds.dat'
  if (Test-Path $ds) {
    $m = Select-String -LiteralPath $ds -Pattern '^\s*time\s*,\s*([0-9.Ee+\-]+)' | Select-Object -Last 1
    if ($m) { $st.EndTime = [double]$m.Matches[0].Groups[1].Value }
  }
  if ($st.EndTime -gt 0) { $st.Percent = [math]::Round(100 * $st.Time / $st.EndTime, 1) }

  $so = Join-Path $SolveDir.Mech 'solve.out'
  if (Test-Path $so) {
    $run = Select-String -LiteralPath $so -Pattern 'RUN COMPLETED' -Quiet
    $term = Select-String -LiteralPath $so -Pattern 'REASON FOR TERMINATION' | Select-Object -Last 1
    if ($run) { $st.Verdict = 'RUN COMPLETED' }
    elseif ($term) { $st.Verdict = ($term.Line -replace '\s+', ' ').Trim() }
  }
  return [pscustomobject]$st
}

function Format-Status {
  param($S)
  if ($S.Running) { $head = '求解中' } else { $head = '未检测到 ANSYS 求解进程' }
  $lines = @()
  $lines += "[$head] 子步 $($S.Sub)  物理时间 $($S.Time) / $($S.EndTime) s  ($($S.Percent)%)"
  $lines += "  位移 $($S.MxDs) mm（峰值 $($S.PeakDs)）  塑性应变 本步 $($S.MxPl) / 峰值 $($S.PeakPl)  时间步 $($S.Dt)"
  $lines += "  已耗时 $([math]::Round($S.Wall / 60, 1)) 分钟  平均每子步 $($S.StepSec) 秒"
  $lines += "  距上次更新 $($S.StallMin) 分钟"
  if ($S.Verdict) { $lines += "  求解器结论: $($S.Verdict)" }
  return ($lines -join "`n")
}

$solveDir = Find-SolveDir
if (-not $solveDir) { Write-Output 'ERR: 未找到 *_files 项目目录'; exit 2 }

if ($Snapshot -or (-not $Wait)) {
  $st = Read-Status $solveDir
  Write-Output (Format-Status $st)
  exit 0
}

if ($Wait) {
  if (-not $LogPath) { $LogPath = Join-Path $PSScriptRoot ('dsh_watch_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log') }
  "=== DSH 守候开始 $(Get-Date -Format 'HH:mm:ss') ===" | Out-File $LogPath -Encoding UTF8
  $prevSub = -1
  $lastChange = Get-Date
  $stalled = $false
  while ($true) {
    $st = Read-Status $solveDir
    $line = '{0} 子步={1} t={2}/{3} ({4}%) MxDs={5} MxPl={6} 每步={7}s 停滞={8}min 进程={9}' -f `
      (Get-Date -Format 'HH:mm:ss'), $st.Sub, $st.Time, $st.EndTime, $st.Percent, $st.MxDs, $st.MxPl, $st.StepSec, $st.StallMin, $st.Running
    $line | Out-File $LogPath -Append -Encoding UTF8
    if ($st.Sub -ne $prevSub) { $prevSub = $st.Sub; $lastChange = Get-Date }
    if (-not $st.Running) {
      "求解进程已退出 $(Get-Date -Format 'HH:mm:ss')" | Out-File $LogPath -Append -Encoding UTF8
      break
    }
    if (((Get-Date) - $lastChange).TotalMinutes -ge $StallMinutes) {
      "!! 连续 $StallMinutes 分钟无新子步，判定卡死（不自动结束进程，等用户决定）" | Out-File $LogPath -Append -Encoding UTF8
      $stalled = $true
      break
    }
    Start-Sleep -Seconds $IntervalSec
  }
  Start-Sleep -Seconds 15
  $st = Read-Status $solveDir
  '' | Out-File $LogPath -Append -Encoding UTF8
  Format-Status $st | Out-File $LogPath -Append -Encoding UTF8
  "卡死判定: $stalled" | Out-File $LogPath -Append -Encoding UTF8
  Write-Output (Format-Status $st)
  Write-Output "日志: $LogPath"
  exit 0
}
