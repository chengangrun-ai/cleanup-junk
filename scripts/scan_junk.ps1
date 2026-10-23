<#
.SYNOPSIS
    Read-only scanner for Windows "junk" files. Produces a structured JSON report.
    Never creates, modifies, or deletes anything.

.DESCRIPTION
    Scans up to four categories (combinable):
      - temp         system/app temp files & caches (%TEMP%, C:\Windows\Temp, Prefetch, thumbnail cache, etc.)
      - browsercache browser caches (Chrome / Edge / Firefox). Never touches bookmarks/history/cookies.
      - recyclebin   Recycle Bin contents (reports size & count).
      - largeold     Large / long-untouched files in the Downloads folder (report only, never deleted).

    All categories are scanned by default. The JSON report can be handed to clean_junk.ps1
    after the user confirms cleanup. This script is 100% read-only.

.PARAMETER Categories   Categories to scan, comma/space separated. Default: temp,browsercache,recyclebin,largeold
.PARAMETER LargeFileMB  "Large file" threshold in MB for the largeold category. Default 200
.PARAMETER OldDays      "Old file" threshold in days (by last-write time) for largeold. Default 90
.PARAMETER ScanRoot     Scan root for the largeold category. Default $env:USERPROFILE\Downloads
.PARAMETER TopFiles     Max number of largest files to list per temp/browsercache target. Default 50
.PARAMETER Output       Path to write the JSON report. If omitted, prints to stdout.

.EXAMPLE
    .\scan_junk.ps1
    .\scan_junk.ps1 -Categories temp,browsercache -Output report.json
#>
[CmdletBinding()]
param(
    [string[]] $Categories = @('temp', 'browsercache', 'recyclebin', 'largeold'),
    [int]      $LargeFileMB = 200,
    [int]      $OldDays = 90,
    [string]   $ScanRoot = '',
    [int]      $TopFiles = 50,
    [string]   $Output = ''
)

$ErrorActionPreference = 'SilentlyContinue'

$catSet = @{}
foreach ($c in $Categories) {
    $parts = ($c -split '[, ]') | Where-Object { $_.Trim() -ne '' }
    foreach ($p in $parts) { $catSet[$p.Trim().ToLower()] = $true }
}

function Get-DirSizeAndCount {
    param([string]$Path, [int]$TopN)
    $size = 0; $count = 0; $top = @()
    if (-not (Test-Path $Path)) { return @{Size=0; Count=0; Top=@()} }
    $items = Get-ChildItem -Path $Path -Recurse -File -Force -ErrorAction SilentlyContinue
    foreach ($f in $items) {
        try {
            $len = $f.Length
            $size += $len; $count++
            $top += [PSCustomObject]@{ path = $f.FullName; sizeBytes = $len; lastWrite = $f.LastWriteTimeUtc.ToString('o') }
        } catch {}
    }
    $top = $top | Sort-Object sizeBytes -Descending | Select-Object -First $TopN
    return @{ Size = $size; Count = $count; Top = $top }
}

function New-Target {
    param([string]$Path)
    $info = Get-DirSizeAndCount -Path $Path -TopN $TopFiles
    return [PSCustomObject]@{
        path = $Path
        exists = (Test-Path $Path)
        sizeBytes = $info.Size
        fileCount = $info.Count
        topFiles = $info.Top
    }
}

$warnings = @()

# ---------- Category 1: temp ----------
$tempTargets = @()
if ($catSet['temp']) {
    $candidates = @(
        $env:TEMP,
        $env:TMP,
        (Join-Path $env:SystemRoot 'Temp'),
        (Join-Path $env:SystemRoot 'Prefetch'),
        (Join-Path $env:LOCALAPPDATA 'Temp'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer')
    )
    $seen = @{}
    foreach ($p in $candidates) {
        if ($p -and (Test-Path $p)) {
            $rp = [IO.Path]::GetFullPath($p).TrimEnd('\').ToLower()
            if (-not $seen.ContainsKey($rp)) { $seen[$rp] = $true; $tempTargets += New-Target $p }
        }
    }
}

# ---------- Category 2: browsercache ----------
$browserTargets = @()
if ($catSet['browsercache']) {
    $profiles = @()
    $chrome = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'
    if (Test-Path $chrome) {
        $profiles += Join-Path $chrome 'Default'
        Get-ChildItem -Path $chrome -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Profile*' } | ForEach-Object { $profiles += $_.FullName }
    }
    $edge = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'
    if (Test-Path $edge) {
        $profiles += Join-Path $edge 'Default'
        Get-ChildItem -Path $edge -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Profile*' } | ForEach-Object { $profiles += $_.FullName }
    }
    $cacheSubDirs = @('Cache', 'Code Cache', 'Media Cache', 'GPUCache', 'Service Worker\CacheStorage', 'ShaderCache')
    foreach ($prof in $profiles) {
        foreach ($sub in $cacheSubDirs) {
            $cp = Join-Path $prof $sub
            if (Test-Path $cp) { $browserTargets += New-Target $cp }
        }
    }
    $ffRoot = Join-Path $env:LOCALAPPDATA 'Mozilla\Firefox\Profiles'
    if (Test-Path $ffRoot) {
        Get-ChildItem -Path $ffRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            foreach ($sub in @('cache2', 'thumbnails', 'startupCache')) {
                $cp = Join-Path $_.FullName $sub
                if (Test-Path $cp) { $browserTargets += New-Target $cp }
            }
        }
    }
    $warnings += "Browser caches only clean Cache/Code Cache/Media Cache etc. Personal data files (Cookies, History, Bookmarks, Login Data) are never touched."
}

# ---------- Category 3: recyclebin ----------
$rbSize = 0; $rbCount = 0
if ($catSet['recyclebin']) {
    try {
        $shell = New-Object -ComObject Shell.Application
        $rb = $shell.NameSpace(10)
        foreach ($item in $rb.Items()) {
            $rbCount++
            try { $rbSize += $item.Size } catch {}
        }
    } catch {
        $warnings += "Unable to enumerate Recycle Bin: $($_.Exception.Message)"
    }
}

# ---------- Category 4: largeold (report only) ----------
$largeOldFiles = @(); $loSize = 0; $loCount = 0
if ($catSet['largeold']) {
    if (-not $ScanRoot) { $ScanRoot = Join-Path $env:USERPROFILE 'Downloads' }
    $cutoff = (Get-Date).AddDays(-$OldDays)
    $thresholdBytes = $LargeFileMB * 1MB
    if (Test-Path $ScanRoot) {
        $files = Get-ChildItem -Path $ScanRoot -Recurse -File -Force -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            $hit = $false
            try {
                if ($f.Length -ge $thresholdBytes) { $hit = $true }
                elseif ($f.LastWriteTimeUtc -lt $cutoff) { $hit = $true }
            } catch { continue }
            if ($hit) {
                $loCount++; $loSize += $f.Length
                $reason = if ($f.Length -ge $thresholdBytes) { "large (>=${LargeFileMB}MB)" } else { "old (>${OldDays} days untouched)" }
                $largeOldFiles += [PSCustomObject]@{
                    path = $f.FullName
                    sizeBytes = $f.Length
                    lastWrite = $f.LastWriteTimeUtc.ToString('o')
                    reason = $reason
                }
            }
        }
        $largeOldFiles = $largeOldFiles | Sort-Object sizeBytes -Descending
    } else {
        $warnings += "largeold scan root does not exist: $ScanRoot"
    }
    $warnings += "largeold results are REPORT ONLY and are never deleted automatically; deletion is the user's manual decision."
}

# ---------- Summarize ----------
$tempTotal = ($tempTargets | Measure-Object sizeBytes -Sum).Sum
$browserTotal = ($browserTargets | Measure-Object sizeBytes -Sum).Sum
$grandTotal = $tempTotal + $browserTotal + $rbSize + $loSize

$report = [PSCustomObject]@{
    skill = 'cleanup-junk'
    scanTimeUtc = (Get-Date).ToUniversalTime().ToString('o')
    notes = 'Read-only scan. No files were deleted. Run clean_junk.ps1 after user confirmation.'
    categories = [PSCustomObject]@{
        temp = [PSCustomObject]@{ enabled = ($null -ne $catSet['temp']); targets = $tempTargets; totalSizeBytes = $tempTotal; totalFileCount = ($tempTargets | Measure-Object fileCount -Sum).Sum }
        browsercache = [PSCustomObject]@{ enabled = ($null -ne $catSet['browsercache']); targets = $browserTargets; totalSizeBytes = $browserTotal; totalFileCount = ($browserTargets | Measure-Object fileCount -Sum).Sum }
        recyclebin = [PSCustomObject]@{ enabled = ($null -ne $catSet['recyclebin']); sizeBytes = $rbSize; itemCount = $rbCount; note = 'Emptying the Recycle Bin is permanent and unrecoverable; requires separate explicit confirmation.' }
        largeold = [PSCustomObject]@{ enabled = ($null -ne $catSet['largeold']); scanRoot = $ScanRoot; thresholdMB = $LargeFileMB; olderThanDays = $OldDays; files = $largeOldFiles; totalSizeBytes = $loSize; totalCount = $loCount }
    }
    grandTotalBytes = $grandTotal
    warnings = $warnings
}

$json = $report | ConvertTo-Json -Depth 6 -Compress:$false
if ($Output) {
    $json | Out-File -FilePath $Output -Encoding utf8
    Write-Output "Report written to: $Output"
} else {
    Write-Output $json
}
