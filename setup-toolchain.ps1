<#
.SYNOPSIS
  Downloads a PORTABLE toolchain (MSVC v143 + Windows SDK + CMake + Ninja) into .\toolchain
  WITHOUT installing anything on the system, with integrity and signature checks.

.DESCRIPTION
  Sources (HTTPS only):
    - Microsoft : aka.ms/vs/17/release/channel  ->  download.visualstudio.microsoft.com
    - CMake     : api.github.com/repos/Kitware/CMake     (official release)
    - Ninja     : api.github.com/repos/ninja-build/ninja (official release)

  Checks:
    1. SHA-256 of EVERY downloaded file against the Microsoft manifest / the GitHub API digest.
    2. Authenticode signature ("Valid" + signer Microsoft Corporation) of every downloaded MSI
       and of ALL .exe/.dll files extracted from MSVC and the SDK. (Independent of the manifest.)
    3. SHA-256 inventory of the whole folder (toolchain\inventory.json) to detect later
       tampering:  .\verify-toolchain.ps1
    4. Microsoft Defender scan (if available).

  Note: these checks show that the binaries are the ones published and signed by
  Microsoft/Kitware/Ninja and have not been altered; they are not a source-code audit.
#>
[CmdletBinding()]
param(
    [string]$ToolchainDir = '',
    [string]$SdkVersion   = '22621',      # Win11SDK_10.0.<SdkVersion>
    [string]$MsvcMinor    = '',           # e.g. '14.44'; empty = newest in the manifest
    [switch]$Force,                       # reinstall even if already present
    [switch]$SkipDefender
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "    [OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    [!!] $m" -ForegroundColor Yellow }

if (-not $ToolchainDir) { $ToolchainDir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'toolchain' }
$dl = Join-Path $ToolchainDir '_downloads'
New-Item -ItemType Directory -Force $dl | Out-Null
$script:warnings = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------- helpers
function Get-Verified {
    param([string]$Url, [string]$Dest, [string]$Sha256, [int64]$Size = 0)
    if ($Url -notmatch '^https://') { throw "Non-HTTPS URL rejected: $Url" }
    if (-not $Sha256) { throw "No reference SHA-256 for $Url (refusing to download without verification)" }
    if (Test-Path $Dest) {
        if ((Get-FileHash $Dest -Algorithm SHA256).Hash -ieq $Sha256) { return }
        Remove-Item $Dest -Force
    }
    New-Item -ItemType Directory -Force (Split-Path $Dest) | Out-Null
    & curl.exe -sS -L --fail --retry 3 --proto '=https' --tlsv1.2 -o $Dest $Url
    if ($LASTEXITCODE -ne 0) { throw "Download failed: $Url" }
    $h = (Get-FileHash $Dest -Algorithm SHA256).Hash
    if ($h -ine $Sha256) {
        Remove-Item $Dest -Force
        throw "SHA-256 MISMATCH for $Url`n  expected: $Sha256`n  got:      $h"
    }
}

function Test-MsSigned {
    # Returns $null if OK, or a text with the reason if it fails.
    param([string]$Path)
    $s = Get-AuthenticodeSignature -LiteralPath $Path
    if ($s.Status -ne 'Valid') { return "signature $($s.Status)" }
    if ($s.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { return "unexpected signer: $($s.SignerCertificate.Subject)" }
    return $null
}

function Get-MsiCabinets {
    param([string]$Msi)
    $inst = New-Object -ComObject WindowsInstaller.Installer
    $db   = $inst.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $inst, @($Msi, 0))
    $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @('SELECT Cabinet FROM Media'))
    $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
    $out = @()
    while ($true) {
        $rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
        if (-not $rec) { break }
        $c = $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, @(1))
        if ($c -and -not $c.StartsWith('#')) { $out += $c }
    }
    $view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null) | Out-Null
    return $out
}

function Expand-Vsix {
    param([string]$Vsix, [string]$DestRoot)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Vsix)
    try {
        foreach ($e in $zip.Entries) {
            if (-not $e.FullName.StartsWith('Contents/')) { continue }
            $rel = [Uri]::UnescapeDataString($e.FullName.Substring(9))
            if (-not $rel -or $rel.EndsWith('/')) { continue }
            $target = [IO.Path]::GetFullPath((Join-Path $DestRoot $rel))
            if (-not $target.StartsWith([IO.Path]::GetFullPath($DestRoot), 'OrdinalIgnoreCase')) { throw "Suspicious path in vsix: $($e.FullName)" }  # anti zip-slip
            New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
        }
    } finally { $zip.Dispose() }
}

# ---------------------------------------------------------------- 1. Microsoft manifest
Step 'Visual Studio manifest (Microsoft)'
$chanFile = Join-Path $dl 'channel.json'
& curl.exe -sS -L --fail --proto '=https' --tlsv1.2 -o $chanFile 'https://aka.ms/vs/17/release/channel'
if ($LASTEXITCODE -ne 0) { throw 'Could not download the VS channel' }
$chan = Get-Content $chanFile -Raw | ConvertFrom-Json
$mi   = ($chan.channelItems | Where-Object { $_.type -eq 'Manifest' } | Select-Object -First 1).payloads[0]
if ($mi.url -notmatch '^https://download\.visualstudio\.microsoft\.com/') { throw "Unexpected manifest URL: $($mi.url)" }
$vsman = Join-Path $dl 'VisualStudio.vsman'
& curl.exe -sS -L --fail --proto '=https' --tlsv1.2 -o $vsman $mi.url
if ($LASTEXITCODE -ne 0) { throw 'Could not download VisualStudio.vsman' }
$vh = (Get-FileHash $vsman -Algorithm SHA256).Hash
if ($vh -ieq $mi.sha256) { Ok 'Manifest: SHA-256 matches the channel' }
else {
    $msg = "The manifest SHA-256 does NOT match the one declared by Microsoft's channel (size {0:N0} vs {1:N0}). The server/TLS is Microsoft's, but the manifest cannot be anchored by hash; protection falls back to per-package SHA-256 + Authenticode signature of every binary." -f (Get-Item $vsman).Length, $mi.size
    Warn $msg; $script:warnings.Add($msg)
}
$pk = (Get-Content $vsman -Raw | ConvertFrom-Json).packages

# ---------------------------------------------------------------- 2. MSVC
$msvcDir = Join-Path $ToolchainDir 'msvc'
if ($Force -and (Test-Path $msvcDir)) { Remove-Item $msvcDir -Recurse -Force }
if (-not (Test-Path (Join-Path $msvcDir 'VC\Tools\MSVC'))) {
    Step 'MSVC (v143 compiler, host x64 -> target x64)'
    $pat = '^Microsoft\.VC\.(14\.\d+)\.\d+\.\d+\.Tools\.HostX64\.TargetX64\.base$'
    $cand = $pk | Where-Object { $_.id -match $pat } | ForEach-Object { [pscustomobject]@{ Minor = $Matches[1]; Id = $_.id } }
    if ($MsvcMinor) { $cand = $cand | Where-Object Minor -eq $MsvcMinor }
    $pick = $cand | Sort-Object { [version]$_.Minor } -Descending | Select-Object -First 1
    if (-not $pick) { throw 'No MSVC packages found in the manifest' }
    $prefix = $pick.Id -replace '\.Tools\.HostX64\.TargetX64\.base$', ''
    Write-Host "    Version: $prefix"
    $ids = "$prefix.Tools.HostX64.TargetX64.base", "$prefix.Tools.HostX64.TargetX64.Res.base",
           "$prefix.CRT.Headers.base", "$prefix.CRT.x64.Desktop.base",
           "$prefix.CRT.x64.Store.base"      # contains lib\x64\oldnames.lib (the linker needs it)
    foreach ($id in $ids) {
        $p = @($pk | Where-Object { $_.id -ieq $id -and (-not $_.language -or $_.language -ieq 'en-US') }) | Select-Object -First 1
        if (-not $p) { throw "Package not found: $id" }
        $pl = $p.payloads[0]
        if ($pl.url -notmatch '^https://download\.visualstudio\.microsoft\.com/') { throw "Unexpected URL: $($pl.url)" }
        $f = Join-Path $dl $pl.fileName
        Write-Host ("    {0}  ({1:N1} MB)" -f $id, ($pl.size / 1MB))
        Get-Verified -Url $pl.url -Dest $f -Sha256 $pl.sha256
        Expand-Vsix -Vsix $f -DestRoot $msvcDir
    }
    Ok 'MSVC downloaded, SHA-256 verified and extracted'
} else { Ok 'MSVC already present (use -Force to reinstall)' }

# ---------------------------------------------------------------- 3. Windows SDK
$sdkDir = Join-Path $ToolchainDir 'sdk'
if ($Force -and (Test-Path $sdkDir)) { Remove-Item $sdkDir -Recurse -Force }
if (-not (Test-Path (Join-Path $sdkDir 'Windows Kits\10\Include'))) {
    Step "Windows SDK 10.0.$SdkVersion (headers, libs, rc.exe)"
    $pkg = @($pk | Where-Object { $_.id -ieq "Win11SDK_10.0.$SdkVersion" -or $_.id -ieq "Win10SDK_10.0.$SdkVersion" }) | Select-Object -First 1
    if (-not $pkg) { throw "SDK $SdkVersion is not in the manifest" }
    $byName = @{}; foreach ($pl in $pkg.payloads) { $byName[$pl.fileName] = $pl }
    $msis = 'Universal CRT Headers Libraries and Sources-x86_en-us.msi',
            'Windows SDK Desktop Headers x86-x86_en-us.msi',
            'Windows SDK Desktop Headers x64-x86_en-us.msi',
            'Windows SDK Desktop Libs x64-x86_en-us.msi',
            'Windows SDK Desktop Tools x64-x86_en-us.msi',
            'Windows SDK for Windows Store Apps Headers-x86_en-us.msi',
            'Windows SDK for Windows Store Apps Libs-x86_en-us.msi'
    # "Windows SDK for Windows Store Apps Tools" ships rc.exe/mt.exe but also MSIX/Store tools
    # (PackageEditor, StoreUploader...) that are not needed to build and whose DLLs are unsigned.
    # => it is downloaded and verified, but extracted to a temp folder and ONLY this allow-list is copied:
    $toolsMsi  = 'Windows SDK for Windows Store Apps Tools-x86_en-us.msi'
    $toolsKeep = 'rc.exe', 'rcdll.dll', 'mt.exe', 'mt.exe.config', 'midlrtmd.dll'   # midlrtmd.dll: dependency of mt.exe
    $msiDir = Join-Path $dl "sdk-$SdkVersion"
    New-Item -ItemType Directory -Force $msiDir, $sdkDir | Out-Null
    foreach ($m in ($msis + $toolsMsi)) {
        $pl = $byName["Installers\$m"]
        if (-not $pl) { throw "MSI not found in the manifest: $m" }
        if ($pl.url -notmatch '^https://download\.visualstudio\.microsoft\.com/') { throw "Unexpected URL: $($pl.url)" }
        $local = Join-Path $msiDir $m
        Get-Verified -Url $pl.url -Dest $local -Sha256 $pl.sha256
        $bad = Test-MsSigned $local
        if ($bad) { throw "MSI rejected ($m): $bad" }
        foreach ($cab in (Get-MsiCabinets $local)) {
            $cp = $byName["Installers\$cab"]
            if (-not $cp) { throw "Cab $cab (from $m) is not in the manifest" }
            Get-Verified -Url $cp.url -Dest (Join-Path $msiDir $cab) -Sha256 $cp.sha256
        }
        Write-Host "    $m  verified + signed"
    }
    foreach ($m in $msis) {
        $p = Start-Process msiexec.exe -ArgumentList @('/a', "`"$(Join-Path $msiDir $m)`"", '/qn', "TARGETDIR=`"$sdkDir`"") -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw "msiexec /a failed for $m (code $($p.ExitCode))" }
    }
    # Store Apps Tools: extract to a temp folder and copy only the allow-list
    $tmpTools = Join-Path $dl 'sdk-tools-extract'
    if (Test-Path $tmpTools) { Remove-Item $tmpTools -Recurse -Force }
    $p = Start-Process msiexec.exe -ArgumentList @('/a', "`"$(Join-Path $msiDir $toolsMsi)`"", '/qn', "TARGETDIR=`"$tmpTools`"") -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "msiexec /a failed for $toolsMsi (code $($p.ExitCode))" }
    $srcX64 = Get-ChildItem (Join-Path $tmpTools 'Windows Kits\10\bin') -Directory | ForEach-Object { Join-Path $_.FullName 'x64' } | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $srcX64) { throw 'bin\<ver>\x64 not found in Store Apps Tools' }
    $dstX64 = Join-Path $sdkDir ("Windows Kits\10\bin\" + (Split-Path (Split-Path $srcX64) -Leaf) + '\x64')
    New-Item -ItemType Directory -Force $dstX64 | Out-Null
    foreach ($n in $toolsKeep) {
        $s = Join-Path $srcX64 $n
        if (Test-Path $s) { Copy-Item $s $dstX64 -Force } elseif ($n -notlike '*.config') { throw "$n is missing from Store Apps Tools" }
    }
    Remove-Item $tmpTools -Recurse -Force
    Ok 'Windows SDK extracted (administrative install: does not touch the system)'
} else { Ok 'Windows SDK already present (use -Force to reinstall)' }

# ---------------------------------------------------------------- 4. CMake and Ninja (GitHub)
function Get-GitHubAsset {
    param([string]$Repo, [string]$NameRegex)
    $rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ 'User-Agent' = 'sm-toolchain'; Accept = 'application/vnd.github+json' }
    $a = $rel.assets | Where-Object { $_.name -match $NameRegex } | Select-Object -First 1
    if (-not $a) { throw "No asset matching $NameRegex in $Repo $($rel.tag_name)" }
    if ($a.browser_download_url -notmatch '^https://github\.com/') { throw "Unexpected URL: $($a.browser_download_url)" }
    $sha = if ($a.digest -match '^sha256:(.+)$') { $Matches[1] } else { $null }
    [pscustomobject]@{ Tag = $rel.tag_name; Name = $a.name; Url = $a.browser_download_url; Sha256 = $sha; Rel = $rel }
}

$cmakeDir = Join-Path $ToolchainDir 'cmake'
if ($Force -and (Test-Path $cmakeDir)) { Remove-Item $cmakeDir -Recurse -Force }
if (-not (Test-Path (Join-Path $cmakeDir 'bin\cmake.exe'))) {
    Step 'CMake (Kitware)'
    $a = Get-GitHubAsset 'Kitware/CMake' '^cmake-[\d\.]+-windows-x86_64\.zip$'
    if (-not $a.Sha256) {   # fallback: the official *-SHA-256.txt file of the same release
        $txt = $a.Rel.assets | Where-Object { $_.name -match '-SHA-256\.txt$' } | Select-Object -First 1
        if ($txt) {
            $t = (Invoke-WebRequest $txt.browser_download_url -UseBasicParsing).Content
            $line = ([Text.Encoding]::UTF8.GetString([Text.Encoding]::UTF8.GetBytes([string]$t)) -split "`n") | Where-Object { $_ -match [regex]::Escape($a.Name) } | Select-Object -First 1
            if ($line -match '^([0-9a-fA-F]{64})') { $a.Sha256 = $Matches[1] }
        }
    }
    Write-Host "    $($a.Name) ($($a.Tag))"
    $zip = Join-Path $dl $a.Name
    Get-Verified -Url $a.Url -Dest $zip -Sha256 $a.Sha256
    $tmp = Join-Path $dl 'cmake-x'; if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive $zip $tmp -Force
    $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1
    New-Item -ItemType Directory -Force $cmakeDir | Out-Null
    Copy-Item (Join-Path $inner.FullName '*') $cmakeDir -Recurse -Force
    Ok "CMake $($a.Tag) verified (SHA-256) and extracted"
} else { Ok 'CMake already present' }

$ninjaDir = Join-Path $ToolchainDir 'ninja'
if ($Force -and (Test-Path $ninjaDir)) { Remove-Item $ninjaDir -Recurse -Force }
if (-not (Test-Path (Join-Path $ninjaDir 'ninja.exe'))) {
    Step 'Ninja'
    $a = Get-GitHubAsset 'ninja-build/ninja' '^ninja-win\.zip$'
    Write-Host "    $($a.Name) ($($a.Tag))"
    $zip = Join-Path $dl $a.Name
    Get-Verified -Url $a.Url -Dest $zip -Sha256 $a.Sha256
    New-Item -ItemType Directory -Force $ninjaDir | Out-Null
    Expand-Archive $zip $ninjaDir -Force
    Ok "Ninja $($a.Tag) verified (SHA-256) and extracted"
} else { Ok 'Ninja already present' }

# ---------------------------------------------------------------- 5. Authenticode signatures
Step 'Checking the Authenticode signature of the Microsoft binaries (MSVC + SDK)'
$bins = @()
$bins += Get-ChildItem $msvcDir -Recurse -File -Include *.exe, *.dll -ErrorAction SilentlyContinue
$bins += Get-ChildItem (Join-Path $sdkDir 'Windows Kits\10\bin') -Recurse -File -Include *.exe, *.dll -ErrorAction SilentlyContinue
$bad = New-Object System.Collections.Generic.List[string]
$i = 0
foreach ($f in $bins) {
    $i++
    if ($i % 100 -eq 0) { Write-Host "    ...$i / $($bins.Count)" }
    $r = Test-MsSigned $f.FullName
    if ($r) { $bad.Add("$($f.FullName.Substring($ToolchainDir.Length)) -> $r") }
}
Write-Host "    Checked: $($bins.Count)  |  with problems: $($bad.Count)"
if ($bad.Count -gt 0) {
    $bad | Select-Object -First 40 | ForEach-Object { Warn $_ }
    throw "Some binaries do not have a valid Microsoft signature (see above). Installation aborted for security."
}
Ok 'All .exe/.dll files of MSVC and the SDK are signed by Microsoft Corporation'

# ---------------------------------------------------------------- 6. Hash inventory
Step 'Generating SHA-256 inventory (to detect future tampering)'
$inv = [ordered]@{}
Get-ChildItem $ToolchainDir -Recurse -File | Where-Object { $_.FullName -notlike "$dl*" -and $_.Name -ne 'inventory.json' } | ForEach-Object {
    $inv[$_.FullName.Substring($ToolchainDir.Length + 1)] = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
}
$inv | ConvertTo-Json -Depth 2 -Compress | Set-Content (Join-Path $ToolchainDir 'inventory.json') -Encoding UTF8
Ok "$($inv.Count) files recorded in toolchain\inventory.json"

# ---------------------------------------------------------------- 7. Defender
if (-not $SkipDefender) {
    Step 'Microsoft Defender scan (can take several minutes)'
    $defenderMsg = 'Defender detected threats.'
    try {
        Start-MpScan -ScanType CustomScan -ScanPath $ToolchainDir -ErrorAction Stop
        $threats = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.Resources -like "*$ToolchainDir*" })
        if ($threats.Count -gt 0) { $threats | ForEach-Object { Warn "Threat: $($_.ThreatID) $($_.Resources)" }; throw $defenderMsg }
        Ok 'Defender: no detections'
    } catch [System.Management.Automation.RuntimeException] {
        if ($_.Exception.Message -eq $defenderMsg) { throw }
        Warn "Could not run the Defender scan: $($_.Exception.Message)"; $script:warnings.Add('Defender scan not performed')
    } catch { Warn "Could not run the Defender scan: $($_.Exception.Message)"; $script:warnings.Add('Defender scan not performed') }
}

# ---------------------------------------------------------------- done
Write-Host "`nPortable toolchain ready in: $ToolchainDir" -ForegroundColor Green
if ($script:warnings.Count) { Write-Host "Warnings:" -ForegroundColor Yellow; $script:warnings | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow } }
Write-Host 'You can delete toolchain\_downloads to save space.'
