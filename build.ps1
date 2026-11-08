<#
.SYNOPSIS
  Builds StepMania from .\source and produces a CLEAN, ready-to-play build in .\stepmania-MMDDYYYY

.DESCRIPTION
  Workflow:
    1. Paste/edit the StepMania source code in .\source   (this script NEVER modifies it).
    2. Run build.ps1. Internally it:
         - mirrors .\source (without .git) to .\_work\stepmania   (StepMania's CMake writes the .exe
           into <source>\Program, which is why the build is done on a copy)
         - compiles with CMake + Ninja + MSVC into .\_work\build\<Config>   (incremental)
         - packages a clean build into  .\stepmania-MMDDYYYY   (US date format)
    3. The clean build contains ONLY what a ready-to-play StepMania build ships with:
         Program\ (StepMania.exe, StepMania.vdi, DLLs), portable.ini and the data folders
         (Announcers, BackgroundEffects, BackgroundTransitions, BGAnimations, Characters, Courses,
          Data, Docs, NoteSkins, Scripts, Songs, Themes).
       It does NOT contain: src, extern, CMake, Build, Installer, Manual, Utils, Xcode, icons, _assets,
         files in the repo root (CMakeLists, .git*, README...), mapconv.exe, .map, Themes\_Installer.
    If you run it again on the same day, the same folder is refreshed (Save, Cache, Logs and
    Screenshots are kept).

  Toolchain: uses the portable toolchain in .\toolchain if present (see setup-toolchain.ps1),
  otherwise falls back to an installed Visual Studio (2022 / toolset v143 required).

.EXAMPLE
  .\build.ps1                 # Release, incremental -> .\stepmania-11082026
  .\build.ps1 -Run            # build, package and launch the game from the clean folder
  .\build.ps1 -Name finished  # -> .\stepmania-finished
  .\build.ps1 -Clean          # rebuild everything from scratch (also needed after moving/renaming this folder)
  .\build.ps1 -SyncOnly       # only refresh the internal working copy
#>
[CmdletBinding()]
param(
    [ValidateSet('Release', 'Debug', 'RelWithDebInfo', 'MinSizeRel')]
    [string]$Config = 'Release',

    # Source code (read-only). Empty = .\source
    [string]$Source = '',

    # Internal folder holding the working copy and build objects. Empty = .\_work
    [string]$Work = '',

    # Name of the final folder: stepmania-<Name>. Empty = US date (MMddyyyy)
    [string]$Name = '',

    # Only used without .\toolchain. Empty = auto-detect the newest Visual Studio.
    [string]$VsRoot = '',
    [string]$CMakeExe = '',  # only used without .\toolchain. Empty = cmake from PATH
    [string]$SdkRoot = '',   # optional: Windows SDK root if it is not auto-detected

    [switch]$NoPortable, # ignore .\toolchain and use the installed Visual Studio
    [switch]$SkipVerify, # skip the quick integrity check of the portable toolchain
    [switch]$Clean,      # delete _work\build\<Config> before building
    [switch]$SyncOnly,   # only copy the source, do not build
    [switch]$NoPackage,  # build but do not create the clean folder
    [switch]$Run         # launch the exe when done
)

$ErrorActionPreference = 'Stop'

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

if (-not $Source) { $Source = Join-Path $PSScriptRoot 'source' }
if (-not $Work)   { $Work   = Join-Path $PSScriptRoot '_work' }

# ---- Checks ---------------------------------------------------------------
# Accept the source directly in source\  OR inside ONE subfolder (e.g. source\stepmania\)
if (-not (Test-Path (Join-Path $Source 'CMakeLists.txt')) -and (Test-Path $Source)) {
    $sub = @(Get-ChildItem $Source -Directory -ErrorAction SilentlyContinue |
             Where-Object { (Test-Path (Join-Path $_.FullName 'CMakeLists.txt')) -and (Test-Path (Join-Path $_.FullName 'src')) })
    if ($sub.Count -eq 1) { $Source = $sub[0].FullName; Write-Host "Source found in subfolder: $Source" -ForegroundColor Yellow }
    elseif ($sub.Count -gt 1) { throw "Several folders with source code found in '$Source' ($($sub.Name -join ', ')). Leave only one or use -Source <path>." }
}
if (-not (Test-Path (Join-Path $Source 'CMakeLists.txt'))) {
    throw "StepMania source code not found in: $Source`nPaste it there (the folder that contains CMakeLists.txt, src, Themes...)."
}
$tc       = Join-Path $PSScriptRoot 'toolchain'
$portable = (-not $NoPortable) -and (Test-Path (Join-Path $tc 'msvc\VC\Tools\MSVC')) -and (Test-Path (Join-Path $tc 'cmake\bin\cmake.exe'))
if ($portable) {
    Write-Host "Toolchain: PORTABLE ($tc)" -ForegroundColor Green
    $CMakeExe = Join-Path $tc 'cmake\bin\cmake.exe'
} else {
    if (-not $CMakeExe) { $c = Get-Command cmake.exe -ErrorAction SilentlyContinue; if ($c) { $CMakeExe = $c.Source } }
    if (-not $CMakeExe -or -not (Test-Path $CMakeExe)) { throw "cmake not found. Run setup-toolchain.ps1 to get the portable toolchain, or install CMake and put it in PATH (or pass -CMakeExe)." }
}

if (-not $portable -and -not $VsRoot) {
    $bases = 'C:\Program Files\Microsoft Visual Studio', 'C:\Program Files (x86)\Microsoft Visual Studio'
    $cands = foreach ($b in $bases) {
        if (Test-Path $b) {
            Get-ChildItem $b -Directory | Where-Object Name -match '^\d{4}$' | ForEach-Object {
                $year = $_.Name
                Get-ChildItem $_.FullName -Directory | Where-Object {
                    Test-Path (Join-Path $_.FullName 'VC\Auxiliary\Build\vcvars64.bat') } |
                    ForEach-Object { [pscustomobject]@{ Year = [int]$year; Path = $_.FullName } }
            }
        }
    }
    $best = $cands | Sort-Object Year -Descending | Select-Object -First 1
    if (-not $best) { throw "No Visual Studio with C++ found. Run setup-toolchain.ps1, or install VS 2022 Build Tools ('Desktop development with C++'), or pass -VsRoot." }
    $VsRoot = $best.Path
    if ($best.Year -lt 2022) {
        Write-Warning "Only Visual Studio $($best.Year) found. This source needs toolset v143 (VS 2022); with VS $($best.Year) mbedtls/ixwebsocket fail to compile."
    }
}
if (-not $portable) {
    Write-Host "Visual Studio: $VsRoot"
    $vcvars = Join-Path $VsRoot 'VC\Auxiliary\Build\vcvars64.bat'
    if (-not (Test-Path $vcvars)) { throw "vcvars64.bat not found: $vcvars" }
}

# Safety: the working copy cannot be the source itself nor live inside it
$srcFull  = (Resolve-Path $Source).Path.TrimEnd('\')
$workFull = [System.IO.Path]::GetFullPath($Work).TrimEnd('\')
if ($workFull -ieq $srcFull -or $workFull.StartsWith($srcFull + '\', 'OrdinalIgnoreCase')) {
    throw "Work ($workFull) cannot be the source folder or be inside it."
}

$stage    = Join-Path $workFull 'stepmania'
$buildDir = Join-Path $workFull "build\$Config"
New-Item -ItemType Directory -Force $stage | Out-Null

# ---- 1. Sync source -------------------------------------------------------
Step "Syncing source: $srcFull -> $stage"
# /MIR : copies new/changed files and removes from the COPY what no longer exists in the source
# /XD  : leave .git and runtime/output folders alone (neither copied nor deleted)
# Robocopy keeps timestamps, so Ninja only recompiles what really changed.
robocopy $srcFull $stage /MIR /XD .git Program Cache Save Logs /NFL /NDL /NJH /NJS /NP /MT:16 | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed (code $LASTEXITCODE)" }

# Program\ of the copy: seed with whatever the source has (e.g. parallel_lights_io.dll)
# without overwriting anything already there (/XC /XN /XO = do not overwrite).
if (Test-Path (Join-Path $srcFull 'Program')) {
    robocopy (Join-Path $srcFull 'Program') (Join-Path $stage 'Program') /E /XC /XN /XO /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy (Program) failed (code $LASTEXITCODE)" }
}
New-Item -ItemType Directory -Force (Join-Path $stage 'Program') | Out-Null

$global:LASTEXITCODE = 0   # robocopy returns 1-7 on success
if ($SyncOnly) { Write-Host "Done (sync only)." -ForegroundColor Green; return }

# ---- 2. MSVC environment (x64) --------------------------------------------
if ($portable) {
    Step "Portable toolchain environment (x64)"
    # Quick integrity check of the key tools against the inventory (full check: verify-toolchain.ps1)
    if (-not $SkipVerify) {
        $invFile = Join-Path $tc 'inventory.json'
        if (-not (Test-Path $invFile)) { throw "toolchain\inventory.json is missing. Run setup-toolchain.ps1 (or use -NoPortable)." }
        $inv = Get-Content $invFile -Raw | ConvertFrom-Json
        $keys = $inv.PSObject.Properties.Name | Where-Object { $_ -match '(?i)^(msvc\\VC\\Tools\\MSVC\\[^\\]+\\bin\\Hostx64\\x64\\(cl|link|lib|c1|c1xx|c2|mspdb\d+|tbbmalloc|vcruntime\d+(_1)?)\.(exe|dll)|cmake\\bin\\cmake\.exe|ninja\\ninja\.exe|sdk\\Windows Kits\\10\\bin\\[^\\]+\\x64\\(rc|rcdll|mt)\.(exe|dll))$' }
        foreach ($k in $keys) {
            if ((Get-FileHash (Join-Path $tc $k) -Algorithm SHA256).Hash -ine $inv.$k) { throw "INTEGRITY: '$k' was modified since installation. Aborting. (run .\verify-toolchain.ps1 for details)" }
        }
        Write-Host "    Integrity OK ($($keys.Count) key tools checked)"
    }
    $msvcVer = (Get-ChildItem (Join-Path $tc 'msvc\VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
    $msvc    = Join-Path $tc "msvc\VC\Tools\MSVC\$msvcVer"
    $kitRoot = Join-Path $tc 'sdk\Windows Kits\10'
    $sdkVer  = (Get-ChildItem (Join-Path $kitRoot 'Lib') -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
    Write-Host "    MSVC $msvcVer | Windows SDK $sdkVer"
    $env:PATH    = (Join-Path $msvc 'bin\Hostx64\x64'), (Join-Path $kitRoot "bin\$sdkVer\x64"), (Join-Path $tc 'cmake\bin'), (Join-Path $tc 'ninja'), $env:PATH -join ';'
    $env:INCLUDE = (Join-Path $msvc 'include'), (Join-Path $kitRoot "Include\$sdkVer\ucrt"), (Join-Path $kitRoot "Include\$sdkVer\um"),
                   (Join-Path $kitRoot "Include\$sdkVer\shared"), (Join-Path $kitRoot "Include\$sdkVer\winrt") -join ';'
    $env:LIB     = (Join-Path $msvc 'lib\x64'), (Join-Path $kitRoot "Lib\$sdkVer\ucrt\x64"), (Join-Path $kitRoot "Lib\$sdkVer\um\x64") -join ';'
    $env:VCToolsInstallDir = "$msvc\"
    $env:WindowsSdkDir = "$kitRoot\"; $env:WindowsSDKVersion = "$sdkVer\"
}
else {
Step "Loading Visual Studio environment (x64)"
$envDump = cmd /c "`"$vcvars`" >nul && set"
foreach ($line in $envDump) {
    if ($line -match '^([^=]+)=(.*)$') { Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2] }
}

# vcvars sometimes fails to detect the Windows SDK (e.g. installed on another drive). If rc.exe is missing, add it manually.
if (-not (Get-Command rc.exe -ErrorAction SilentlyContinue)) {
    $kitRoots = @($SdkRoot,
                  (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' -ErrorAction SilentlyContinue).KitsRoot10,
                  (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots' -ErrorAction SilentlyContinue).KitsRoot10,
                  'C:\Program Files (x86)\Windows Kits\10') | Where-Object { $_ -and (Test-Path $_) }
    $kit = $null; $ver = $null
    foreach ($r in $kitRoots) {
        $v = Get-ChildItem (Join-Path $r 'Lib') -Directory -ErrorAction SilentlyContinue |
             Where-Object { (Test-Path (Join-Path $_.FullName 'um\x64\kernel32.lib')) -and (Test-Path (Join-Path $r "bin\$($_.Name)\x64\rc.exe")) } |
             Sort-Object Name -Descending | Select-Object -First 1
        if ($v) { $kit = $r.TrimEnd('\'); $ver = $v.Name; break }
    }
    if (-not $kit) { throw "Windows 10 SDK (rc.exe) not found. Install it or pass -SdkRoot 'path\to\Windows Kits\10'." }
    Write-Host "Windows SDK $ver in $kit"
    $env:PATH    = "$kit\bin\$ver\x64;$env:PATH"
    $env:INCLUDE = ("$kit\Include\$ver\ucrt", "$kit\Include\$ver\um", "$kit\Include\$ver\shared", "$kit\Include\$ver\winrt", $env:INCLUDE) -join ';'
    $env:LIB     = ("$kit\Lib\$ver\ucrt\x64", "$kit\Lib\$ver\um\x64", $env:LIB) -join ';'
}

$ninjaDir = Join-Path $VsRoot 'Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja'
if (-not (Test-Path (Join-Path $ninjaDir 'ninja.exe'))) {
    $nj = Get-Command ninja.exe -ErrorAction SilentlyContinue
    if (-not $nj) { throw "ninja.exe not found. Install the 'C++ CMake tools for Windows' component of VS, or put ninja in PATH." }
    $ninjaDir = Split-Path $nj.Source
}
$env:PATH = "$ninjaDir;$(Split-Path $CMakeExe);$env:PATH"
}   # end: system toolchain (installed VS)

# ---- 3. Configure + build -------------------------------------------------
if ($Clean -and (Test-Path $buildDir)) {
    Step "Cleaning $buildDir"
    Remove-Item $buildDir -Recurse -Force
}

$sw = [Diagnostics.Stopwatch]::StartNew()

if (-not (Test-Path (Join-Path $buildDir 'build.ninja'))) {
    if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force }   # leftovers of a failed configure
    Step "Configuring CMake ($Config)"
    & $CMakeExe -S $stage -B $buildDir -G Ninja "-DCMAKE_BUILD_TYPE=$Config" "-DCMAKE_C_COMPILER=cl" "-DCMAKE_CXX_COMPILER=cl"
    if ($LASTEXITCODE -ne 0) { throw "CMake configure failed (code $LASTEXITCODE)" }
}

# global.cpp creates the PCH (/Yc) and every other file uses it (/Yu). With Ninja there is no
# guaranteed order between them (race -> "C1083 global.pch: Permission denied"), so build it first.
Step "Building precompiled header (global.pch)"
& $CMakeExe --build $buildDir --target src/CMakeFiles/StepMania.dir/global.cpp.obj
if ($LASTEXITCODE -ne 0) { throw "Failed to generate the PCH (code $LASTEXITCODE)" }

Step "Building ($Config)"
& $CMakeExe --build $buildDir
if ($LASTEXITCODE -ne 0) { throw "Build failed (code $LASTEXITCODE)" }

$sw.Stop()

# ---- 4. Result ------------------------------------------------------------
$exe = Get-ChildItem (Join-Path $stage 'Program') -Filter 'StepMania*.exe' -ErrorAction SilentlyContinue |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $exe) { throw "Build succeeded, but StepMania*.exe was not found in $stage\Program" }

Write-Host ("`nBuild OK in {0:mm\:ss}" -f $sw.Elapsed) -ForegroundColor Green

# ---- 5. Package the clean build -------------------------------------------
$finalExe = $exe.FullName; $finalDir = $stage
if (-not $NoPackage) {
    # Data folders shipped in a clean build (taken from a reference 5.1 build)
    $dataDirs  = 'Announcers', 'BackgroundEffects', 'BackgroundTransitions', 'BGAnimations', 'Characters',
                 'Courses', 'Data', 'Docs', 'NoteSkins', 'Scripts', 'Songs', 'Themes'
    $folder    = if ($Name) { "stepmania-$Name" } else { 'stepmania-' + (Get-Date -Format 'MMddyyyy') }
    $outDir    = Join-Path $PSScriptRoot $folder
    Step "Packaging clean build: $outDir"
    New-Item -ItemType Directory -Force $outDir | Out-Null

    foreach ($d in $dataDirs) {
        $from = Join-Path $stage $d
        if (-not (Test-Path $from)) { Write-Warning "The source has no '$d' folder (skipped)"; continue }
        $rcArgs = @($from, (Join-Path $outDir $d), '/MIR', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/MT:16')
        if ($d -eq 'Themes') { $rcArgs += @('/XD', '_Installer') }     # only used by the NSIS installer
        robocopy @rcArgs | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed while copying $d (code $LASTEXITCODE)" }
    }
    # Remove a Themes\_Installer left over from a previous packaging
    $oldInst = Join-Path $outDir 'Themes\_Installer'
    if (Test-Path $oldInst) { Remove-Item $oldInst -Recurse -Force }

    # Program\: only the exe, its .vdi (crash stack traces) and the DLLs. No mapconv.exe, no .map.
    $progOut = Join-Path $outDir 'Program'
    if (Test-Path $progOut) { Remove-Item $progOut -Recurse -Force }
    New-Item -ItemType Directory -Force $progOut | Out-Null
    Get-ChildItem (Join-Path $stage 'Program') -File |
        Where-Object { $_.Name -match '^StepMania.*\.(exe|vdi)$' -or $_.Extension -eq '.dll' } |
        ForEach-Object { Copy-Item $_.FullName $progOut -Force }

    # Portable mode: Save/Cache/Logs live inside the folder (the reference build ships it empty)
    $ini = Join-Path $outDir 'portable.ini'
    if (-not (Test-Path $ini)) { New-Item -ItemType File $ini | Out-Null }

    $global:LASTEXITCODE = 0
    $finalExe = (Get-ChildItem $progOut -Filter 'StepMania*.exe' | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
    $finalDir = $outDir
    $mb = [math]::Round((Get-ChildItem $outDir -Recurse -File | Measure-Object Length -Sum).Sum / 1MB)
    Write-Host "Clean build ready: $outDir  ($mb MB)" -ForegroundColor Green
}

Write-Host "Executable: $finalExe"
Write-Host "Your source was NOT modified: $srcFull"

if ($Run) {
    Step "Launching $(Split-Path $finalExe -Leaf)"
    Start-Process -FilePath $finalExe -WorkingDirectory $finalDir
}
