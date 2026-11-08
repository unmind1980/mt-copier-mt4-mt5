<#
.SYNOPSIS
    clean_terminal_logs.ps1 - Minimalist retention cleaner for MetaTrader terminal logs and caches.

.DESCRIPTION
    MetaTrader 4 and MetaTrader 5 create daily log files in <terminal>\logs\ and <terminal>\MQL*\Logs\,
    and NEVER delete them automatically. Over months and years on a VPS, thousands of small log files
    accumulate, exhausting disk space and NTFS MFT entries.

    This script enforces strict retention policies:
    - Retains at most 10 newest daily log files per log folder (MaxBackups = 10).
    - Preserves logs from the last 7 days.
    - Cleans legacy tester logs and temporary build staging caches (_copier_build_*).
    - Runs in safe dry-run preview mode by default; pass -Yes to perform actual deletions.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\clean_terminal_logs.ps1
    (Preview what would be cleaned)

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\clean_terminal_logs.ps1 -Yes
    (Actually perform cleanup)
#>

[CmdletBinding()]
param (
    [int]$MaxBackups = 10,
    [int]$MaxAgeDays = 7,
    [switch]$CleanBuilds = $true,
    [switch]$Yes = $false,
    [string[]]$Paths = @()
)

$ErrorActionPreference = "SilentlyContinue"

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "  MT-Copier: MetaTrader Terminal Log & Cache Retention Cleaner" -ForegroundColor Cyan
Write-Host "  Policy: Max $MaxBackups backups per folder, age cutoff: $MaxAgeDays days" -ForegroundColor Cyan
if (-not $Yes) {
    Write-Host "  MODE: DRY-RUN (Preview only. Pass -Yes to execute deletions)" -ForegroundColor Yellow
} else {
    Write-Host "  MODE: ACTIVE EXECUTION (Deleting expired files)" -ForegroundColor Green
}
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host ""

$cutoffDate = (Get-Date).AddDays(-$MaxAgeDays)
$discoveredRoots = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

# 1. Discover terminals in APPDATA
$appDataTerminal = Join-Path $env:APPDATA "MetaQuotes\Terminal"
if (Test-Path $appDataTerminal) {
    Get-ChildItem -Path $appDataTerminal -Directory | ForEach-Object {
        if ($_.Name -notmatch "^_copier_build_") {
            [void]$discoveredRoots.Add($_.FullName)
        }
    }
}

# 2. Discover terminals from tools/targets.conf
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir = Split-Path -Parent $scriptDir
$targetsConf = Join-Path $repoDir "tools\targets.conf"

if (Test-Path $targetsConf) {
    Get-Content $targetsConf | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#")) {
            # Convert Unix-style /e/... to E:\...
            if ($line -match "^/([a-zA-Z])/(.*)$") {
                $winPath = "$($Matches[1]):\$($Matches[2].Replace('/', '\'))"
                if (Test-Path $winPath) {
                    [void]$discoveredRoots.Add($winPath)
                }
            } elseif (Test-Path $line) {
                [void]$discoveredRoots.Add((Get-Item $line).FullName)
            } elseif (Test-Path (Join-Path $appDataTerminal $line)) {
                [void]$discoveredRoots.Add((Join-Path $appDataTerminal $line))
            }
        }
    }
}

# 3. Add common portable roots on drive E: if existing
foreach ($cand in @("E:\MetaTrader 5", "E:\MT5-Portable-Test", "E:\MT5-BT")) {
    if (Test-Path $cand) {
        [void]$discoveredRoots.Add((Get-Item $cand).FullName)
    }
}

# 4. Add user-supplied paths
foreach ($p in $Paths) {
    if (Test-Path $p) {
        [void]$discoveredRoots.Add((Get-Item $p).FullName)
    }
}

$totalScannedFiles = 0
$totalDeletedFiles = 0
$totalFreedBytes = 0
$terminalSummaries = @()

foreach ($termRoot in $discoveredRoots) {
    $termName = Split-Path -Leaf $termRoot
    $logFolders = @()

    # Terminal root logs
    $tl = Join-Path $termRoot "logs"
    if (Test-Path $tl) { $logFolders += $tl }

    # MQL4 / MQL5 Logs
    foreach ($mql in @("MQL4", "MQL5")) {
        $ml = Join-Path $termRoot "$mql\Logs"
        if (Test-Path $ml) { $logFolders += $ml }
    }

    # Tester Logs
    $testL = Join-Path $termRoot "tester\logs"
    if (Test-Path $testL) { $logFolders += $testL }

    if ($logFolders.Count -eq 0) {
        continue
    }

    $termScanned = 0
    $termDeleted = 0
    $termFreed = 0

    foreach ($folder in $logFolders) {
        $files = Get-ChildItem -Path $folder -Filter "*.log" -File | Sort-Object LastWriteTime -Descending
        $termScanned += $files.Count
        $totalScannedFiles += $files.Count

        $idx = 0
        foreach ($f in $files) {
            $idx++
            # Retain the newest $MaxBackups files, OR files newer than $MaxAgeDays
            $isBeyondBackups = ($idx -gt $MaxBackups)
            $isOlderThanCutoff = ($f.LastWriteTime -lt $cutoffDate)

            if ($folder -match "\\tester\\logs$") {
                # Tester logs can be aggressively cleaned if older than cutoff
                $shouldDelete = $isOlderThanCutoff
            } else {
                $shouldDelete = $isBeyondBackups -and $isOlderThanCutoff
            }

            if ($shouldDelete) {
                $termDeleted++
                $termFreed += $f.Length
                $totalDeletedFiles++
                $totalFreedBytes += $f.Length

                if ($Yes) {
                    Remove-Item -Path $f.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    if ($termScanned -gt 0) {
        $terminalSummaries += [PSCustomObject]@{
            Terminal     = $termName
            ScannedLogs  = $termScanned
            PrunedLogs   = $termDeleted
            ReclaimedMB  = [Math]::Round($termFreed / 1MB, 2)
            Path         = $termRoot
        }
    }
}

if ($terminalSummaries.Count -gt 0) {
    $terminalSummaries | Format-Table -Property Terminal, ScannedLogs, PrunedLogs, ReclaimedMB, Path -AutoSize
} else {
    Write-Host "  No terminal logs found in scanned directories." -ForegroundColor Gray
}

# 5. Clean build staging caches (_copier_build_*) if requested
$buildCacheFreedBytes = 0
$buildCachesRemoved = 0

if ($CleanBuilds -and (Test-Path $appDataTerminal)) {
    Get-ChildItem -Path $appDataTerminal -Directory -Filter "_copier_build_*" | ForEach-Object {
        $cacheDir = $_.FullName
        $cacheSize = (Get-ChildItem -Path $cacheDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        if (-not $cacheSize) { $cacheSize = 0 }
        $buildCacheFreedBytes += $cacheSize
        $buildCachesRemoved++

        if ($Yes) {
            Remove-Item -Path $cacheDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  [Removed Build Cache] $($_.Name) ($([Math]::Round($cacheSize / 1MB, 2)) MB)" -ForegroundColor Gray
        } else {
            Write-Host "  [Would Remove Build Cache] $($_.Name) ($([Math]::Round($cacheSize / 1MB, 2)) MB)" -ForegroundColor Yellow
        }
    }
}

$grandTotalFreedMB = [Math]::Round(($totalFreedBytes + $buildCacheFreedBytes) / 1MB, 2)

Write-Host ""
Write-Host "------------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Clean Summary:" -ForegroundColor White
Write-Host "    Total log files scanned: $totalScannedFiles" -ForegroundColor White
Write-Host "    Total log files $(if ($Yes) { 'deleted' } else { 'eligible for deletion' }): $totalDeletedFiles" -ForegroundColor $(if ($totalDeletedFiles -gt 0) { "Green" } else { "Gray" })
if ($buildCachesRemoved -gt 0) {
    Write-Host "    Build caches $(if ($Yes) { 'removed' } else { 'eligible for removal' }): $buildCachesRemoved ($([Math]::Round($buildCacheFreedBytes / 1MB, 2)) MB)" -ForegroundColor Gray
}
Write-Host "    Total disk space $(if ($Yes) { 'reclaimed' } else { 'to be reclaimed' }): $grandTotalFreedMB MB" -ForegroundColor Yellow
Write-Host "------------------------------------------------------------------" -ForegroundColor Cyan

if (-not $Yes -and ($totalDeletedFiles -gt 0 -or $buildCachesRemoved -gt 0)) {
    Write-Host "To execute actual deletion, run:" -ForegroundColor Yellow
    Write-Host "    powershell -ExecutionPolicy Bypass -File tools\clean_terminal_logs.ps1 -Yes" -ForegroundColor White
    Write-Host "Or via batch shortcut:" -ForegroundColor Yellow
    Write-Host "    tools\clean_terminal_logs.bat --yes" -ForegroundColor White
}
