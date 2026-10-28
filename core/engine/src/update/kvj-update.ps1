# KVJ's updater on Windows, written into <data>\updates and started by KVJ just
# before it quits (core/engine/src/update/mod.rs). Windows PowerShell 5.1.
# Waits for KVJ to quit, moves what the package replaces (its top-level
# entries, e.g. bin) into <install>\.kvj-previous (renames on the same disk:
# nothing outside the package's own folders is touched), copies the new ones
# in and starts the new KVJ. It writes updates\started-<version> once its
# window is up; then the old files are deleted. Without that word within 90 s
# (or if the new one exits first) it is stopped, the old files put back, the
# old KVJ started, and updates\result.txt says why. Every step is logged to
# the day's session log, like the app's own lines.
param(
    [int]$KvjPid,
    [string]$Root,
    [string]$Stage,
    [string]$Exe,
    [string]$DataDir,
    [string]$Version,
    [string]$From
)
$ErrorActionPreference = 'Stop'
$updates = Join-Path $DataDir 'updates'
$backup = Join-Path $Root '.kvj-previous'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Log([string]$Level, [string]$Text) {
    try {
        $now = Get-Date
        $dir = Join-Path $DataDir 'logs'
        [void][IO.Directory]::CreateDirectory($dir)
        $file = Join-Path $dir ('kvj-' + $now.ToString('yyyy-MM-dd') + '.log')
        [IO.File]::AppendAllText($file, $now.ToString('HH:mm:ss.fff') + " [$Level] 更新：$Text`r`n", $utf8)
    } catch {}
}
# The reason for the KVJ that is started next.
function Fail([string]$Text) {
    Log 'error' $Text
    try { [IO.File]::WriteAllText((Join-Path $updates 'result.txt'), "$Version`n$Text`n", $utf8) } catch {}
    foreach ($name in @('pending.json', "started-$Version")) {
        Remove-Item -LiteralPath (Join-Path $updates $name) -Force -ErrorAction SilentlyContinue
    }
}
function Start-Kvj {
    $path = Join-Path $Root $Exe
    $started = Start-Process -FilePath $path -WorkingDirectory (Split-Path -Parent $path) -PassThru
    # Held now, so ExitCode can still be read after it is gone.
    [void]$started.Handle
    $started
}
# Retried: a virus scanner or the indexer may hold a file a moment after KVJ quits.
function Retry([scriptblock]$Step) {
    for ($i = 1; ; $i++) {
        try {
            & $Step
            return
        } catch {
            if ($i -ge 20) { throw }
            Start-Sleep -Milliseconds 500
        }
    }
}
$moved = New-Object System.Collections.ArrayList
$placed = New-Object System.Collections.ArrayList
function Restore {
    foreach ($name in $placed) {
        $path = Join-Path $Root $name
        if (Test-Path -LiteralPath $path) { Retry { Remove-Item -LiteralPath $path -Recurse -Force } }
    }
    foreach ($name in $moved) {
        Retry { Move-Item -LiteralPath (Join-Path $backup $name) -Destination (Join-Path $Root $name) }
    }
    Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
}
# Back to the old files and the old KVJ; false when they could not be put back.
function Roll-Back([string]$Why) {
    try {
        Restore
    } catch {
        $kept = "无法放回旧版：它在 $backup，请手动移回（$($_.Exception.Message)）"
        Log 'error' $Why
        Fail $kept
        return
    }
    Fail $Why
    try { [void](Start-Kvj) } catch { Log 'error' "无法启动旧版：$($_.Exception.Message)" }
}

Log 'info' "等待 v$From 退出，以安装 v$Version（$Root）"
$deadline = (Get-Date).AddMinutes(2)
while (Get-Process -Id $KvjPid -ErrorAction SilentlyContinue) {
    if ((Get-Date) -gt $deadline) {
        Fail 'KVJ 两分钟内没有退出，没有更新'
        exit 1
    }
    Start-Sleep -Milliseconds 200
}

$entries = @(Get-ChildItem -LiteralPath $Stage -Force -ErrorAction SilentlyContinue)
if ($entries.Count -eq 0 -or -not (Test-Path -LiteralPath (Join-Path $Stage $Exe))) {
    Fail "找不到准备好的新版（$Stage）"
    try { [void](Start-Kvj) } catch {}
    exit 1
}
try {
    if (Test-Path -LiteralPath $backup) { Retry { Remove-Item -LiteralPath $backup -Recurse -Force } }
    [void][IO.Directory]::CreateDirectory($backup)
    foreach ($entry in $entries) {
        $target = Join-Path $Root $entry.Name
        if (Test-Path -LiteralPath $target) {
            Retry { Move-Item -LiteralPath $target -Destination (Join-Path $backup $entry.Name) }
            [void]$moved.Add($entry.Name)
        }
    }
    foreach ($entry in $entries) {
        [void]$placed.Add($entry.Name)
        Copy-Item -LiteralPath $entry.FullName -Destination $Root -Recurse -Force
    }
} catch {
    Roll-Back "无法替换 $Root 里的文件（$($_.Exception.Message)），已回到 v$From"
    exit 1
}

Log 'info' "已放入 v$Version，启动中"
$process = $null
try { $process = Start-Kvj } catch { Log 'warn' "无法启动新版：$($_.Exception.Message)" }
$marker = Join-Path $updates "started-$Version"
$deadline = (Get-Date).AddSeconds(90)
while (-not (Test-Path -LiteralPath $marker)) {
    if ((Get-Date) -gt $deadline -or $null -eq $process -or $process.HasExited) { break }
    Start-Sleep -Milliseconds 200
}
if (Test-Path -LiteralPath $marker) {
    Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $updates "stage-$Version") -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $updates -Filter "$Version-*" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    foreach ($name in @('pending.json', "started-$Version")) {
        Remove-Item -LiteralPath (Join-Path $updates $name) -Force -ErrorAction SilentlyContinue
    }
    Log 'info' "已更新到 v$Version，旧版 v$From 已删除"
    exit 0
}

if ($null -ne $process -and $process.HasExited) {
    $why = "新版 v$Version 启动后退出了（代码 $($process.ExitCode)），已回到 v$From"
} else {
    $why = "新版 v$Version 90 秒内没有启动完成，已回到 v$From"
}
if ($null -ne $process -and -not $process.HasExited) {
    try {
        Stop-Process -Id $process.Id -Force
        [void]$process.WaitForExit(10000)
    } catch {}
}
Roll-Back $why
exit 1
