<#
.SYNOPSIS
    After user confirmation, sends scanned "junk" to the Recycle Bin (not permanent delete).
    Dry-run by default.

.DESCRIPTION
    Safety constraints (must be honored):
      - Dry-run by default: without -Force, only prints the planned actions; changes nothing.
      - Only temp / browsercache / recyclebin are handled. largeold is NEVER deleted by this script.
      - temp / browsercache: the CONTENTS (files & subdirs) of each target directory are sent to the
        Recycle Bin; the target directory itself is preserved.
      - All deletions use SHFileOperation(FOF_ALLOWUNDO) -> Recycle Bin, so they are recoverable.
      - Emptying the Recycle Bin (EmptyRecycleBin) is permanent and only enabled by -EmptyRecycleBin
        together with -Force, and requires explicit user consent.
      - No-Go zones are never processed: Desktop, Documents, user home root, system drive root.

.PARAMETER Categories    Categories to clean, comma/space separated. Allowed: temp, browsercache, recyclebin. Default empty.
.PARAMETER Force         Actually perform deletions. Without it, dry-run only.
.PARAMETER EmptyRecycleBin  Additionally empty the Recycle Bin (permanent). Only effective with -Force.
.PARAMETER Output        Write the execution result JSON to this path.

.EXAMPLE
    .\clean_junk.ps1 -Categories temp,browsercache                # plan only, no changes
    .\clean_junk.ps1 -Categories temp,browsercache -Force         # send to Recycle Bin
    .\clean_junk.ps1 -Categories recyclebin -Force -EmptyRecycleBin  # empty bin (permanent)
#>
[CmdletBinding()]
param(
    [string[]] $Categories = @(),
    [switch]   $Force = $false,
    [switch]   $EmptyRecycleBin = $false,
    [string]   $Output = ''
)

$ErrorActionPreference = 'SilentlyContinue'

# ---------- No-Go zone check ----------
$noGoRoots = @(
    [Environment]::GetFolderPath('Desktop'),
    [Environment]::GetFolderPath('MyDocuments'),
    $env:USERPROFILE,
    ($env:SystemDrive + '\')
)
function Test-NoGo {
    param([string]$Path)
    try {
        $full = [IO.Path]::GetFullPath($Path).TrimEnd('\').ToLower()
        foreach ($r in $noGoRoots) {
            $rr = [IO.Path]::GetFullPath($r).TrimEnd('\').ToLower()
            if ($full -eq $rr -or $full.StartsWith($rr + '\')) { return $true }
        }
    } catch {}
    return $false
}

# ---------- Send to Recycle Bin (recoverable) ----------
$recycleCode = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class RecycleBin {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct SHFILEOPSTRUCT {
        public IntPtr hwnd;
        public uint wFunc;
        public string pFrom;
        public string pTo;
        public ushort fFlags;
        public bool fAnyOperationsAborted;
        public IntPtr hNameMappings;
        public string lpszProgressTitle;
    }
    [DllImport("shell32.dll", CharSet=CharSet.Unicode)]
    public static extern int SHFileOperation(ref SHFILEOPSTRUCT fop);
    public const uint FO_DELETE = 0x0003;
    public const ushort FOF_ALLOWUNDO = 0x0040;
    public const ushort FOF_NOCONFIRMATION = 0x0010;
    public const ushort FOF_SILENT = 0x0004;
    public const ushort FOF_NOERRORUI = 0x0400;
    public static int ToRecycleBin(string path) {
        SHFILEOPSTRUCT fs = new SHFILEOPSTRUCT();
        fs.wFunc = FO_DELETE;
        fs.pFrom = path + "\0\0";
        fs.fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI;
        return SHFileOperation(ref fs);
    }
}
'@
Add-Type -TypeDefinition $recycleCode -ErrorAction SilentlyContinue
function Send-ToRecycleBin {
    param([string]$Path)
    try {
        $p = [IO.Path]::GetFullPath($Path)
        $rc = [RecycleBin]::ToRecycleBin($p)
        return @{ ok = ($rc -eq 0); code = $rc; path = $p }
    } catch {
        return @{ ok = $false; code = -1; path = $Path; error = $_.Exception.Message }
    }
}

# ---------- Derive the same target dirs as the scanner ----------
$catSet = @{}
foreach ($c in $Categories) {
    $parts = ($c -split '[, ]') | Where-Object { $_.Trim() -ne '' }
    foreach ($p in $parts) { $catSet[$p.Trim().ToLower()] = $true }
}

$plan = @()

if ($catSet['temp']) {
    $tempDirs = @(
        $env:TEMP, $env:TMP,
        (Join-Path $env:SystemRoot 'Temp'),
        (Join-Path $env:SystemRoot 'Prefetch'),
        (Join-Path $env:LOCALAPPDATA 'Temp'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer')
    )
    $seen = @{}
    foreach ($d in $tempDirs) {
        if ($d -and (Test-Path $d)) {
            $rp = [IO.Path]::GetFullPath($d).TrimEnd('\').ToLower()
            if ($seen.ContainsKey($rp)) { continue }
            $seen[$rp] = $true
            if (-not (Test-NoGo $d)) {
                $plan += [PSCustomObject]@{ category='temp'; type='dirContents'; path=$d; action='Send to Recycle Bin (recoverable)' }
            } else {
                Write-Warning "Skipped No-Go path: $d"
            }
        }
    }
}

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
            if ((Test-Path $cp) -and -not (Test-NoGo $cp)) {
                $plan += [PSCustomObject]@{ category='browsercache'; type='dirContents'; path=$cp; action='Send to Recycle Bin (recoverable)' }
            }
        }
    }
    $ffRoot = Join-Path $env:LOCALAPPDATA 'Mozilla\Firefox\Profiles'
    if (Test-Path $ffRoot) {
        Get-ChildItem -Path $ffRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            foreach ($sub in @('cache2', 'thumbnails', 'startupCache')) {
                $cp = Join-Path $_.FullName $sub
                if ((Test-Path $cp) -and -not (Test-NoGo $cp)) {
                    $plan += [PSCustomObject]@{ category='browsercache'; type='dirContents'; path=$cp; action='Send to Recycle Bin (recoverable)' }
                }
            }
        }
    }
}

if ($catSet['recyclebin']) {
    $action = if ($EmptyRecycleBin -and $Force) { 'Permanently empty' } else { 'Pending (needs -EmptyRecycleBin -Force)' }
    $plan += [PSCustomObject]@{ category='recyclebin'; type='emptyRecycleBin'; path='(Recycle Bin)'; action=$action }
}

if ($catSet['largeold']) {
    Write-Warning "The largeold category is never deleted by this script (report only). Ignoring it."
}

# ---------- Execute ----------
$results = @()
if (-not $Force) {
    Write-Output "=== DRY-RUN (no changes made) ==="
    Write-Output "Planned actions; pass -Force to actually execute:"
    $plan | ForEach-Object { Write-Output ("  [{0}] {1}  ->  {2}" -f $_.category, $_.path, $_.action) }
    if ($catSet['recyclebin'] -and -not $EmptyRecycleBin) {
        Write-Output "Note: the recyclebin category also needs -EmptyRecycleBin -Force to actually empty (permanent delete)."
    }
    Write-Output ("Plan items: {0}" -f $plan.Count)
    exit 0
}

Write-Output "=== Cleaning (sent to Recycle Bin) ==="
foreach ($item in $plan) {
    if ($item.type -eq 'emptyRecycleBin') {
        if (-not $EmptyRecycleBin) {
            $results += [PSCustomObject]@{ category=$item.category; path=$item.path; action=$item.action; ok=$false; note='-EmptyRecycleBin not specified, skipped' }
            continue
        }
        try {
            Clear-RecycleBin -Force -ErrorAction Stop
            $results += [PSCustomObject]@{ category=$item.category; path=$item.path; action='Permanently emptied Recycle Bin'; ok=$true; note='Done (unrecoverable)' }
        } catch {
            $results += [PSCustomObject]@{ category=$item.category; path=$item.path; action='Permanently emptied Recycle Bin'; ok=$false; note=$_.Exception.Message }
        }
        continue
    }
    $children = Get-ChildItem -Path $item.path -Force -ErrorAction SilentlyContinue
    $okCount = 0; $failCount = 0
    if ($children.Count -eq 0) {
        $results += [PSCustomObject]@{ category=$item.category; path=$item.path; action=$item.action; ok=$true; note='Directory empty, nothing to do' }
        continue
    }
    foreach ($child in $children) {
        $r = Send-ToRecycleBin $child.FullName
        if ($r.ok) { $okCount++ } else { $failCount++; Write-Warning ("Failed: {0} (code={1})" -f $r.path, $r.code) }
    }
    $results += [PSCustomObject]@{
        category = $item.category
        path = $item.path
        action = $item.action
        ok = ($failCount -eq 0)
        note = ("Succeeded {0}, failed {1}" -f $okCount, $failCount)
    }
}

$summary = [PSCustomObject]@{
    skill = 'cleanup-junk'
    executedUtc = (Get-Date).ToUniversalTime().ToString('o')
    force = $true
    emptyRecycleBin = [bool]$EmptyRecycleBin
    results = $results
}
$json = $summary | ConvertTo-Json -Depth 5
if ($Output) { $json | Out-File -FilePath $Output -Encoding utf8 }
Write-Output $json
