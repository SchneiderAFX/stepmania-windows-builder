<#
.SYNOPSIS
  Checks that the portable toolchain has not been modified since it was installed.
.DESCRIPTION
  1. Recomputes the SHA-256 of every file and compares it with toolchain\inventory.json
     (detects changed, deleted or ADDED files). A percentage bar shows the progress.
  2. Re-verifies the Authenticode signature of cl.exe, link.exe, lib.exe, rc.exe, mt.exe.
  3. Scans the toolchain with Microsoft Defender (if available; the scan can take several minutes).
     When it is reached you are asked to continue or skip it (-Defender scan = always scan,
     -Defender skip or -SkipDefender = never scan).
  Exits with code 1 if anything does not match or Defender reports a threat.
#>
[CmdletBinding()]
param(
    [string]$ToolchainDir = '',
    # Microsoft Defender scan at the end: ask = offer "continue / skip" when it is reached (default),
    # scan = always scan without asking, skip = never scan.
    [ValidateSet('ask', 'scan', 'skip')]
    [string]$Defender = 'ask',
    [switch]$SkipDefender                 # same as -Defender skip
)

$ErrorActionPreference = 'Stop'
$scriptsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$here       = Split-Path -Parent $scriptsDir          # builder folder (this script lives in <builder>\scripts)
. (Join-Path $scriptsDir 'progress.ps1')
if (-not $ToolchainDir) { $ToolchainDir = Join-Path $here 'toolchain' }
if (-not (Test-Path $ToolchainDir)) { throw "Toolchain folder not found: $ToolchainDir (run 1. setup-toolchain.bat first)." }
# full, long-form absolute path (the inventory stores paths relative to it)
$ToolchainDir = (Get-Item -LiteralPath $ToolchainDir).FullName.TrimEnd('\')
$invFile = Join-Path $ToolchainDir 'inventory.json'
if (-not (Test-Path $invFile)) { throw "No inventory found: run 1. setup-toolchain.bat first." }

if ($SkipDefender) { $Defender = 'skip' }
Set-Steps $(if ($Defender -eq 'skip') { 2 } else { 3 })
Step 'Checking every file against the inventory'
Write-Host '    Reading the inventory and listing files...'
$inv = Get-Content $invFile -Raw | ConvertFrom-Json
$expected = @{}; $inv.PSObject.Properties | ForEach-Object { $expected[$_.Name] = $_.Value }

$problems = New-Object System.Collections.Generic.List[string]
$seen = @{}
$dl = Join-Path $ToolchainDir '_downloads'
$files = @(Get-ChildItem $ToolchainDir -Recurse -File | Where-Object { $_.FullName -notlike "$dl*" -and $_.Name -ne 'inventory.json' })
$i = 0
foreach ($f in $files) {
    $i++
    $rel = $f.FullName.Substring($ToolchainDir.Length + 1)
    $seen[$rel] = $true
    if (-not $expected.ContainsKey($rel)) { $problems.Add("NEW (not in the inventory): $rel") }
    elseif ((Get-FileHash $f.FullName -Algorithm SHA256).Hash -ine $expected[$rel]) { $problems.Add("MODIFIED: $rel") }
    Write-Bar 'Checking files' $i $files.Count ("{0}/{1} files" -f $i, $files.Count)
}
Complete-Bar
foreach ($k in $expected.Keys) { if (-not $seen.ContainsKey($k)) { $problems.Add("MISSING: $k") } }

Step 'Checking the signatures of the main tools'
$exes = @()
foreach ($n in 'cl.exe', 'link.exe', 'lib.exe') {
    $exes += Get-ChildItem (Join-Path $ToolchainDir 'msvc') -Recurse -Filter $n -ErrorAction SilentlyContinue | Where-Object FullName -match 'Hostx64\\x64' | Select-Object -First 1
}
$exes += Get-ChildItem (Join-Path $ToolchainDir 'sdk') -Recurse -Include rc.exe, mt.exe -ErrorAction SilentlyContinue | Where-Object FullName -match '\\x64\\'
foreach ($e in $exes) {
    $s = Get-AuthenticodeSignature $e.FullName
    if ($s.Status -ne 'Valid' -or $s.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { $problems.Add("INVALID SIGNATURE: $($e.FullName) ($($s.Status))") }
}
Write-Host "    Checked: $(@($exes).Count) tools"

$notes = New-Object System.Collections.Generic.List[string]
if ($Defender -ne 'skip') {
    Step 'Microsoft Defender scan (can take several minutes)'
    if ((Get-DefenderChoice $Defender) -eq 'scan') {
        switch (Invoke-DefenderScan $ToolchainDir) {
            'clean'       { Ok 'Defender: no detections' }
            'threats'     { $problems.Add('Microsoft Defender reported a threat in the toolchain (see above)') }
            'unavailable' { $notes.Add('Defender scan not performed') }
        }
    } else {
        Warn 'Defender check skipped: less secure, the toolchain was not scanned for malware.'
        $notes.Add('Defender scan skipped by choice')
    }
} else {
    $notes.Add('Defender scan skipped (-Defender skip)')
}

if ($problems.Count) {
    Write-Host "`nTOOLCHAIN NOT VERIFIED: $($problems.Count) problem(s)" -ForegroundColor Red
    $problems | Select-Object -First 50 | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "`nToolchain OK: $($expected.Count) files match the inventory and the signatures are valid." -ForegroundColor Green
if ($notes.Count) { Write-Host 'Notes:' -ForegroundColor Yellow; $notes | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow } }
