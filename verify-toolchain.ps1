<#
.SYNOPSIS
  Checks that the portable toolchain has not been modified since it was installed.
.DESCRIPTION
  1. Recomputes the SHA-256 of every file and compares it with toolchain\inventory.json
     (detects changed, deleted or ADDED files).
  2. Re-verifies the Authenticode signature of cl.exe, link.exe, lib.exe, rc.exe, mt.exe.
  Exits with code 1 if anything does not match.
#>
[CmdletBinding()]
param([string]$ToolchainDir = '')

$ErrorActionPreference = 'Stop'
if (-not $ToolchainDir) { $ToolchainDir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'toolchain' }
$invFile = Join-Path $ToolchainDir 'inventory.json'
if (-not (Test-Path $invFile)) { throw "No inventory found: run setup-toolchain.ps1 first." }

$inv = Get-Content $invFile -Raw | ConvertFrom-Json
$expected = @{}; $inv.PSObject.Properties | ForEach-Object { $expected[$_.Name] = $_.Value }

$problems = New-Object System.Collections.Generic.List[string]
$seen = @{}
$dl = Join-Path $ToolchainDir '_downloads'
Get-ChildItem $ToolchainDir -Recurse -File | Where-Object { $_.FullName -notlike "$dl*" -and $_.Name -ne 'inventory.json' } | ForEach-Object {
    $rel = $_.FullName.Substring($ToolchainDir.Length + 1)
    $seen[$rel] = $true
    if (-not $expected.ContainsKey($rel)) { $problems.Add("NEW (not in the inventory): $rel"); return }
    if ((Get-FileHash $_.FullName -Algorithm SHA256).Hash -ine $expected[$rel]) { $problems.Add("MODIFIED: $rel") }
}
foreach ($k in $expected.Keys) { if (-not $seen.ContainsKey($k)) { $problems.Add("MISSING: $k") } }

foreach ($n in 'cl.exe', 'link.exe', 'lib.exe') {
    Get-ChildItem (Join-Path $ToolchainDir 'msvc') -Recurse -Filter $n -ErrorAction SilentlyContinue | Where-Object FullName -match 'Hostx64\\x64' | Select-Object -First 1 | ForEach-Object {
        $s = Get-AuthenticodeSignature $_.FullName
        if ($s.Status -ne 'Valid' -or $s.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { $problems.Add("INVALID SIGNATURE: $($_.FullName) ($($s.Status))") }
    }
}
Get-ChildItem (Join-Path $ToolchainDir 'sdk') -Recurse -Include rc.exe, mt.exe -ErrorAction SilentlyContinue | Where-Object FullName -match '\\x64\\' | ForEach-Object {
    $s = Get-AuthenticodeSignature $_.FullName
    if ($s.Status -ne 'Valid' -or $s.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { $problems.Add("INVALID SIGNATURE: $($_.FullName) ($($s.Status))") }
}

if ($problems.Count) {
    Write-Host "TOOLCHAIN NOT VERIFIED: $($problems.Count) problem(s)" -ForegroundColor Red
    $problems | Select-Object -First 50 | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "Toolchain OK: $($expected.Count) files match the inventory and the signatures are valid." -ForegroundColor Green
