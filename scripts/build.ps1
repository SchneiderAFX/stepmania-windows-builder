<#
.SYNOPSIS
  Builds StepMania or ITGmania from .\source and produces a CLEAN, ready-to-play build
  in .\stepmania-MMDDYYYY or .\itgmania-MMDDYYYY

.DESCRIPTION
  Workflow:
    1. Put the source code in .\source (this script NEVER modifies it). If .\source is empty, the
       script offers to download StepMania or ITGmania for you (see get-source.ps1).
    2. Run "3. build.bat" (or scripts\build.ps1). The game (StepMania / ITGmania) is detected automatically. Internally it:
         - mirrors .\source (without .git) to .\_work\stepmania   (the game's CMake writes the .exe
           into <source>\Program, which is why the build is done on a copy)
         - compiles with CMake + Ninja + MSVC into .\_work\build\<Config>   (incremental)
         - packages a clean build into  .\<game>-MMDDYYYY   (US date format)
    3. The clean build contains ONLY what a ready-to-play build ships with:
         Program\ (the .exe, its .vdi, DLLs), portable.ini and the data folders
         (Announcers, BackgroundEffects, BackgroundTransitions, BGAnimations, Characters, Courses,
          Data, Docs, NoteSkins, Scripts, Songs, Themes).
       It does NOT contain: src, extern, CMake, Build, Installer, Manual, Utils, Xcode, icons, _assets,
         files in the repo root (CMakeLists, .git*, README...), mapconv.exe, .map, Themes\_Installer.
    If you run it again on the same day, the same folder is refreshed (Save, Cache, Logs and
    Screenshots are kept).

  Toolchain: uses the portable toolchain in .\toolchain if present (see setup-toolchain.ps1),
  otherwise falls back to an installed Visual Studio (2022 / toolset v143 required).

.EXAMPLE
  (Paths such as .\source are relative to the builder folder, the parent of the scripts folder.
   Normally you just double-click 3. build.bat; these are the direct PowerShell equivalents.)

  .\scripts\build.ps1                       # incremental build -> .\stepmania-11082026 (or .\itgmania-11082026)
  .\scripts\build.ps1 -Download itgmania    # if .\source is empty, download ITGmania there, then build it
  .\scripts\build.ps1 -Run                  # build, package and launch the game from the clean folder
  .\scripts\build.ps1 -Name finished        # -> .\stepmania-finished (or .\itgmania-finished)
  .\scripts\build.ps1 -Clean                # rebuild everything from scratch (also needed after moving/renaming this folder)
  .\scripts\build.ps1 -SyncOnly             # only refresh the internal working copy
#>
[CmdletBinding()]
param(
    [ValidateSet('Release', 'Debug', 'RelWithDebInfo', 'MinSizeRel')]
    [string]$Config = 'Release',

    # Source code (read-only). Empty = .\source
    [string]$Source = '',

    # If the source folder is empty: download this game into it without asking.
    [ValidateSet('', 'stepmania', 'itgmania')]
    [string]$Download = '',

    # Internal folder holding the working copy and build objects. Empty = .\_work
    [string]$Work = '',

    # Name of the final folder: <game>-<Name>. Empty = US date (MMddyyyy)
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

. (Join-Path $PSScriptRoot 'progress.ps1')    # progress bars, spinner and numbered steps

# This script lives in <builder>\scripts; everything else (source, toolchain, _work, output) is in <builder>.
$Root = Split-Path -Parent $PSScriptRoot

function Invoke-CMakeBuild {
    # Runs "cmake --build" and turns Ninja's "[123/1335] ..." lines into one percentage bar.
    # Warnings and errors are still printed. Returns cmake's exit code.
    param([string]$Cmake, [string]$BuildDir, [string]$Target = '')
    $cmakeArgs = @('--build', $BuildDir)
    if ($Target) { $cmakeArgs += @('--target', $Target) }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $onBar = $false
    & $Cmake @cmakeArgs | ForEach-Object {
        $line = "$_"
        if ($line -match '^\[(\d+)/(\d+)\]') {
            Write-Bar 'Building' ([int]$Matches[1]) ([int]$Matches[2]) ('{0}/{1}  {2:mm\:ss}' -f $Matches[1], $Matches[2], $clock.Elapsed)
            $onBar = $true
        } else {
            if ($onBar) { Write-Host ''; $onBar = $false }    # finish the bar line before printing other text
            Write-Host $line
        }
    }
    if ($onBar) { Write-Host '' }
    return $LASTEXITCODE
}

Set-Steps 5

if (-not $Source) { $Source = Join-Path $Root 'source' }
if (-not $Work)   { $Work   = Join-Path $Root '_work' }

# ---- git discovery (only used to stamp the game version with the commit hash) ----
function Find-Git {
    $c = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @("$env:ProgramFiles\Git\cmd\git.exe", "${env:ProgramFiles(x86)}\Git\cmd\git.exe", "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe", (Join-Path $Root 'tools\git\cmd\git.exe'))) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    $gh = Get-ChildItem "$env:LOCALAPPDATA\GitHubDesktop" -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
          Sort-Object { try { [version]($_.Name -replace '^app-', '') } catch { [version]'0.0' } } -Descending |
          ForEach-Object { Join-Path $_.FullName 'resources\app\git\cmd\git.exe' } |
          Where-Object { Test-Path $_ } | Select-Object -First 1
    return $gh
}

# ---- Locate the source ----------------------------------------------------
# Accept the source directly in source\  OR inside ONE subfolder (e.g. source\stepmania\)
function Resolve-SourceDir([string]$dir) {
    if (-not (Test-Path $dir)) { return $null }
    if (Test-Path (Join-Path $dir 'CMakeLists.txt')) { return $dir }
    $sub = @(Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue |
             Where-Object { (Test-Path (Join-Path $_.FullName 'CMakeLists.txt')) -and (Test-Path (Join-Path $_.FullName 'src')) })
    if ($sub.Count -eq 1) { Write-Host "Source found in subfolder: $($sub[0].FullName)" -ForegroundColor Yellow; return $sub[0].FullName }
    if ($sub.Count -gt 1) { throw "Several folders with source code found in '$dir' ($($sub.Name -join ', ')). Leave only one or use -Source <path>." }
    return $null
}

$resolved = Resolve-SourceDir $Source
if (-not $resolved) {
    $isEmpty = Test-DirIsEmpty $Source    # also true for a folder that only has a placeholder like put-stepmania-here.txt
    $canAsk  = -not [Console]::IsInputRedirected
    if ($isEmpty -and ($Download -or $canAsk)) {
        Write-Host "`nNo StepMania/ITGmania source code found in: $Source" -ForegroundColor Yellow
        & (Join-Path $PSScriptRoot 'get-source.ps1') -Target $Source -Game $Download
        if ($LASTEXITCODE -eq 2) { Write-Host 'Nothing to build. Paste your source code into that folder and run again.'; exit 2 }
        $resolved = Resolve-SourceDir $Source
    }
    if (-not $resolved) {
        if ($isEmpty) {
            throw "No source code in '$Source'. Run 2. get-source.bat (or build.ps1 -Download stepmania|itgmania) to download it, or paste it there yourself."
        } else {
            throw "StepMania/ITGmania source code not found in: $Source`nThe folder is not empty but has no CMakeLists.txt. Put the source there (the folder that contains CMakeLists.txt, src, Themes...) or use -Source <path>."
        }
    }
}
$Source = $resolved

# ---- Are the git submodules there? -----------------------------------------
# A GitHub "Download ZIP" has no submodules (extern\mbedtls, extern\libpng...), and CMake then fails with
# confusing errors. Detect it here, before anything is copied.
$missingSub = @(Get-MissingSubmodules $Source)
if ($missingSub.Count) {
    $subList = $missingSub -join ', '
    $gitForSub = Find-Git
    $isClone   = Test-Path (Join-Path $Source '.git')
    $fixed = $false
    if ($isClone -and $gitForSub) {
        # (with no console to answer, Read-Host returns nothing = "no")
        Write-Host "`nThe source is missing $($missingSub.Count) git submodule(s): $subList" -ForegroundColor Yellow
        Write-Host '    The source is a git clone whose submodules were never downloaded.'
        Write-Host '    They can be downloaded now (this ADDS files to your source folder; nothing is overwritten).'
        $ans = $null
        try { $ans = Read-Host '    Download the missing submodules now? [Y/N]' } catch { }
        if ("$ans".Trim() -match '^(y|yes|s|si)$') {
            Write-Host '    Downloading submodules (git shows its own progress below)...'
            $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            & $gitForSub -C $Source -c core.longpaths=true submodule update --init --recursive --depth 1 --progress
            $subCode = $LASTEXITCODE
            $ErrorActionPreference = $prevEap
            $global:LASTEXITCODE = 0
            if ($subCode -ne 0) { throw "git submodule update failed (code $subCode). Check your internet connection and try again." }
            $missingSub = @(Get-MissingSubmodules $Source)
            if ($missingSub.Count) { throw "Still missing after the download: $($missingSub -join ', ')" }
            Ok 'Submodules downloaded'
            $fixed = $true
        }
    }
    if (-not $fixed) {
        $why = if ($isClone) { "The source is a git clone, but its submodules were never downloaded (clone made without --recursive)." }
               else { "This happens when the code is downloaded with GitHub's `"Download ZIP`" button: ZIP files do not include submodules." }
        throw ("The source is missing $($missingSub.Count) git submodule(s): $subList`n" + $why + "`n" +
               "Fix (pick one):`n" +
               "  - Empty source\ and run 2. get-source.bat (StepMania, ITGmania, or paste the URL of a fork)`n" +
               "  - Or clone it yourself:  git clone --recursive <repository URL> source`n" +
               "  - If source\ is already a git clone, run inside it:  git submodule update --init --recursive")
    }
}

# ---- Which game is it? -----------------------------------------------------
$exeName = 'StepMania'
$coreCmake = Join-Path $Source 'StepmaniaCore.cmake'
if (Test-Path $coreCmake) {
    $m = Select-String -Path $coreCmake -Pattern 'set\(SM_EXE_NAME\s+"([^"]+)"' | Select-Object -First 1
    if ($m) { $exeName = $m.Matches[0].Groups[1].Value }
}
$gameId = ($exeName.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
if (-not $gameId) { $gameId = 'stepmania' }
Write-Host "Game detected: $exeName" -ForegroundColor Green

# ---- Toolchain ------------------------------------------------------------
$tc       = Join-Path $Root 'toolchain'
$portable = (-not $NoPortable) -and (Test-Path (Join-Path $tc 'msvc\VC\Tools\MSVC')) -and (Test-Path (Join-Path $tc 'cmake\bin\cmake.exe'))
if ($portable) {
    Write-Host "Toolchain: PORTABLE ($tc)" -ForegroundColor Green
    $CMakeExe = Join-Path $tc 'cmake\bin\cmake.exe'
} else {
    if (-not $CMakeExe) { $c = Get-Command cmake.exe -ErrorAction SilentlyContinue; if ($c) { $CMakeExe = $c.Source } }
    if (-not $CMakeExe -or -not (Test-Path $CMakeExe)) { throw "cmake not found. Run 1. setup-toolchain.bat to get the portable toolchain, or install CMake and put it in PATH (or pass -CMakeExe)." }
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
    if (-not $best) { throw "No Visual Studio with C++ found. Run 1. setup-toolchain.bat, or install VS 2022 Build Tools ('Desktop development with C++'), or pass -VsRoot." }
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
Write-Host '    The first time this copies the whole source (several hundred MB); later runs only copy what changed.'
# /MIR : copies new/changed files and removes from the COPY what no longer exists in the source
# /XD  : leave .git and runtime/output folders alone (neither copied nor deleted)
# Robocopy keeps timestamps, so Ninja only recompiles what really changed.
$rcCode = Invoke-WithSpinner -FilePath 'robocopy.exe' -Arguments ('"{0}" "{1}" /MIR /XD .git Program Cache Save Logs /NFL /NDL /NJH /NJS /NP /MT:16' -f $srcFull, $stage) -Label 'Copying source files'
if ($rcCode -ge 8) { throw "robocopy failed (code $rcCode)" }
Ok 'Source synced'

# Program\ of the copy: seed with whatever the source has (e.g. parallel_lights_io.dll)
# without overwriting anything already there (/XC /XN /XO = do not overwrite).
if (Test-Path (Join-Path $srcFull 'Program')) {
    robocopy (Join-Path $srcFull 'Program') (Join-Path $stage 'Program') /E /XC /XN /XO /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy (Program) failed (code $LASTEXITCODE)" }
}
New-Item -ItemType Directory -Force (Join-Path $stage 'Program') | Out-Null

$global:LASTEXITCODE = 0   # robocopy returns 1-7 on success
if ($SyncOnly) { Write-Host "Done (sync only)." -ForegroundColor Green; return }

# The game's CMake runs "git rev-parse --short HEAD" inside the source folder to stamp the version.
# We do not copy .git (it can be huge). Instead, if the source is a git repo and git is available,
# the working copy gets a tiny .git pointer file to the real repository (read-only use).
$gitExe = Find-Git
$commit = ''
$stageGit = Join-Path $stage '.git'
if (Test-Path $stageGit) { Remove-Item $stageGit -Recurse -Force }
$srcGitDir = Join-Path $srcFull '.git'
if ($gitExe -and (Test-Path $srcGitDir -PathType Container)) {
    Set-Content -Path $stageGit -Value ('gitdir: ' + ($srcGitDir -replace '\\', '/')) -Encoding ascii
    $commit = ((& $gitExe -C $stage rev-parse --short HEAD 2>$null) -join '').Trim()
    $env:PATH = (Split-Path $gitExe) + ';' + $env:PATH
    if ($commit) { Write-Host "Source commit: $commit" }
}
$global:LASTEXITCODE = 0

# ---- 2. MSVC environment (x64) --------------------------------------------
if ($portable) {
    Step "Portable toolchain environment (x64)"
    # Quick integrity check of the key tools against the inventory (full check: verify-toolchain.ps1)
    if (-not $SkipVerify) {
        $invFile = Join-Path $tc 'inventory.json'
        if (-not (Test-Path $invFile)) { throw "toolchain\inventory.json is missing. Run 1. setup-toolchain.bat (or use -NoPortable)." }
        $inv = Get-Content $invFile -Raw | ConvertFrom-Json
        $keys = $inv.PSObject.Properties.Name | Where-Object { $_ -match '(?i)^(msvc\\VC\\Tools\\MSVC\\[^\\]+\\bin\\Hostx64\\x64\\(cl|link|lib|c1|c1xx|c2|mspdb\d+|tbbmalloc|vcruntime\d+(_1)?)\.(exe|dll)|cmake\\bin\\cmake\.exe|ninja\\ninja\.exe|sdk\\Windows Kits\\10\\bin\\[^\\]+\\x64\\(rc|rcdll|mt)\.(exe|dll))$' }
        foreach ($k in $keys) {
            if ((Get-FileHash (Join-Path $tc $k) -Algorithm SHA256).Hash -ine $inv.$k) { throw "INTEGRITY: '$k' was modified since installation. Aborting. (run verify-toolchain.bat for details)" }
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
    Write-Host "`nCleaning $buildDir (-Clean)" -ForegroundColor Cyan
    Remove-Item $buildDir -Recurse -Force
}

$sw = [Diagnostics.Stopwatch]::StartNew()

$stamp = Join-Path $buildDir '.source-commit'
$configure = $false
if (-not (Test-Path (Join-Path $buildDir 'build.ninja'))) {
    if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force }   # leftovers of a failed configure
    $configure = $true
} elseif ($commit -and ((Get-Content $stamp -ErrorAction SilentlyContinue) -ne $commit)) {
    $configure = $true    # the source moved to another commit: re-run CMake so the version stamp is updated
}
if ($configure) {
    Step "Configuring CMake ($Config)"
    Write-Host '    CMake inspects the project (about a minute). Its messages appear below.'
    & $CMakeExe -S $stage -B $buildDir -G Ninja "-DCMAKE_BUILD_TYPE=$Config" "-DCMAKE_C_COMPILER=cl" "-DCMAKE_CXX_COMPILER=cl"
    if ($LASTEXITCODE -ne 0) { throw "CMake configure failed (code $LASTEXITCODE)" }
    if ($commit) { Set-Content -Path $stamp -Value $commit -Encoding ascii }
    Ok 'Configured'
} else {
    Step "Configuring CMake ($Config)"
    Ok 'Already configured (skipped)'
}

# global.cpp creates the PCH (/Yc) and every other file uses it (/Yu). With Ninja there is no
# guaranteed order between them (race -> "C1083 global.pch: Permission denied"), so build it first.
$ninjaExe = (Get-Command ninja.exe -ErrorAction SilentlyContinue).Source
$pchTargets = @()
if ($ninjaExe) {
    $pchTargets = @(& $ninjaExe -C $buildDir -t targets all 2>$null | Where-Object { $_ -match 'global\.cpp\.obj:' } | ForEach-Object { $_ -replace ':.*$', '' })
}
Step "Building ($Config)"
Write-Host '    The first build takes a few minutes; later builds only recompile what changed.'
foreach ($pt in $pchTargets) {
    Write-Host '    Precompiled header first...'
    $code = Invoke-CMakeBuild -Cmake $CMakeExe -BuildDir $buildDir -Target $pt
    if ($code -ne 0) { throw "Failed to generate the PCH (code $code)" }
}
$code = Invoke-CMakeBuild -Cmake $CMakeExe -BuildDir $buildDir
if ($code -ne 0) { throw "Build failed (code $code)" }

$sw.Stop()

# ---- 4. Result ------------------------------------------------------------
$exe = Get-ChildItem (Join-Path $stage 'Program') -Filter '*.exe' -ErrorAction SilentlyContinue |
       Where-Object { $_.Name -ne 'mapconv.exe' } |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $exe) { throw "Build succeeded, but no game .exe was found in $stage\Program" }

Write-Host ("`nBuild OK in {0:mm\:ss}" -f $sw.Elapsed) -ForegroundColor Green

# ---- 5. Package the clean build -------------------------------------------
$finalExe = $exe.FullName; $finalDir = $stage
if (-not $NoPackage) {
    # Data folders shipped in a clean build (same layout for StepMania and ITGmania)
    $dataDirs  = 'Announcers', 'BackgroundEffects', 'BackgroundTransitions', 'BGAnimations', 'Characters',
                 'Courses', 'Data', 'Docs', 'NoteSkins', 'Scripts', 'Songs', 'Themes'
    $folder    = if ($Name) { "$gameId-$Name" } else { "$gameId-" + (Get-Date -Format 'MMddyyyy') }
    $outDir    = Join-Path $Root $folder
    Step "Packaging clean build: $outDir"
    New-Item -ItemType Directory -Force $outDir | Out-Null

    $di = 0
    foreach ($d in $dataDirs) {
        $di++
        Write-Bar 'Packaging' ($di - 1) ($dataDirs.Count + 1) ("{0}/{1}  {2}" -f $di, $dataDirs.Count, $d) -Force
        $from = Join-Path $stage $d
        if (-not (Test-Path $from)) { Complete-Bar; Write-Warning "The source has no '$d' folder (skipped)"; continue }
        $skipDirs = @('.git')
        if ($d -eq 'Themes') { $skipDirs += '_Installer' }     # _Installer is only used by the NSIS installer
        # .git directories/files (e.g. the gitlink file of a submodule theme such as Simply Love) are not shipped
        $rcArgs = @($from, (Join-Path $outDir $d), '/MIR', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/MT:16', '/XD') + $skipDirs + @('/XF', '.git')
        robocopy @rcArgs | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed while copying $d (code $LASTEXITCODE)" }
    }
    # Remove a Themes\_Installer left over from a previous packaging
    $oldInst = Join-Path $outDir 'Themes\_Installer'
    if (Test-Path $oldInst) { Remove-Item $oldInst -Recurse -Force }
    Write-Bar 'Packaging' $dataDirs.Count ($dataDirs.Count + 1) 'Program' -Force

    # Program\: only the game exe, its .vdi (crash stack traces) and the DLLs. No mapconv.exe, no .map.
    $progOut = Join-Path $outDir 'Program'
    if (Test-Path $progOut) { Remove-Item $progOut -Recurse -Force }
    New-Item -ItemType Directory -Force $progOut | Out-Null
    Get-ChildItem (Join-Path $stage 'Program') -File |
        Where-Object { ($_.Extension -eq '.exe' -and $_.Name -ne 'mapconv.exe') -or $_.Extension -eq '.vdi' -or $_.Extension -eq '.dll' } |
        ForEach-Object { Copy-Item $_.FullName $progOut -Force }

    # Portable mode: Save/Cache/Logs live inside the folder (the reference builds ship it empty)
    $ini = Join-Path $outDir 'portable.ini'
    if (-not (Test-Path $ini)) { New-Item -ItemType File $ini | Out-Null }

    $global:LASTEXITCODE = 0
    Write-Bar 'Packaging' ($dataDirs.Count + 1) ($dataDirs.Count + 1) 'done' -Force
    Complete-Bar
    $finalExe = (Get-ChildItem $progOut -Filter '*.exe' | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
    $finalDir = $outDir
    $mb = [math]::Round((Get-ChildItem $outDir -Recurse -File | Measure-Object Length -Sum).Sum / 1MB)
    Write-Host "Clean build ready: $outDir  ($mb MB)" -ForegroundColor Green
} else {
    Step 'Packaging the clean build'
    Ok 'Skipped (-NoPackage)'
}

Write-Host "Executable: $finalExe"
Write-Host "Your source was NOT modified: $srcFull"

if ($Run) {
    Step "Launching $(Split-Path $finalExe -Leaf)"
    Start-Process -FilePath $finalExe -WorkingDirectory $finalDir
}
