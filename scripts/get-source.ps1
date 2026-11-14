<#
.SYNOPSIS
  Downloads the StepMania or ITGmania source code (with all submodules) into .\source

.DESCRIPTION
  Sources (HTTPS only):
    - StepMania : https://github.com/stepmania/stepmania.git
    - ITGmania  : https://github.com/itgmania/itgmania.git
    - any other repository you choose (e.g. a fork) with -Url, or option [3] of the menu.
      That is code you decided to trust: the builder verifies the toolchain, not the source.

  Needs git. It uses, in this order:
    1. git from PATH, Program Files or GitHub Desktop
    2. a portable MinGit in .\tools\git (downloaded from the official git-for-windows
       GitHub release, SHA-256 verified) - only if no git is found
  So you do not need to install anything.

  By default it makes a shallow clone (latest commit only): much smaller and faster, and it is
  all that is needed to build. Use -FullHistory to download the whole git history.

  Each download goes into its own folder inside .\source, named after the repository
  (source\stepmania, source\itgmania, source\<fork name>), so several sources can live side by side.
  If that folder already exists you can keep it and download the new one with another name, or
  delete it and download it again. A source pasted directly in .\source (older layout) is first
  moved into its own folder, with your confirmation.

.EXAMPLE
  .\scripts\get-source.ps1                       # asks which game
  .\scripts\get-source.ps1 -Game itgmania        # -> source\itgmania
  .\scripts\get-source.ps1 -Game stepmania -FullHistory
  .\scripts\get-source.ps1 -Game stepmania -FolderName sm-test    # -> source\sm-test
  .\scripts\get-source.ps1 -Url https://github.com/SomeUser/stepmania-fork   # -> source\stepmania-fork
  .\scripts\get-source.ps1 -Game itgmania -Target D:\src\itg      # exact folder (must be empty)
#>
[CmdletBinding()]
param(
    [ValidateSet('', 'stepmania', 'itgmania')]
    [string]$Game = '',

    # Clone another repository instead (e.g. a fork). HTTPS only. Cannot be used together with -Game.
    [string]$Url = '',

    # Name of the folder inside source\. Empty = the repository name (stepmania, itgmania, the fork's name)
    [string]$FolderName = '',

    # Folder that holds the sources. Empty = .\source
    [string]$SourceRoot = '',

    # Exact folder to clone into instead (must be empty). Overrides -SourceRoot / -FolderName.
    [string]$Target = '',

    [switch]$FullHistory,   # download the whole git history (slower, larger)
    [switch]$UseMinGit      # ignore any installed git and use the portable MinGit
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$scriptsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root       = Split-Path -Parent $scriptsDir          # builder folder (this script lives in <builder>\scripts)
$explicitTarget = [bool]$Target
if (-not $SourceRoot) { $SourceRoot = Join-Path $root 'source' }

. (Join-Path $scriptsDir 'progress.ps1')

$games = [ordered]@{
    stepmania = @{ Name = 'StepMania'; Folder = 'stepmania'; Url = 'https://github.com/stepmania/stepmania.git'; Size = 'about 600 MB' }
    itgmania  = @{ Name = 'ITGmania';  Folder = 'itgmania';  Url = 'https://github.com/itgmania/itgmania.git';   Size = 'about 600 MB' }
}

# ---------------------------------------------------------------- git discovery
function Find-Git {
    param([switch]$IgnoreSystem)
    if (-not $IgnoreSystem) {
        $c = Get-Command git.exe -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
        foreach ($p in @("$env:ProgramFiles\Git\cmd\git.exe", "${env:ProgramFiles(x86)}\Git\cmd\git.exe", "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe")) {
            if ($p -and (Test-Path $p)) { return $p }
        }
        $gh = Get-ChildItem "$env:LOCALAPPDATA\GitHubDesktop" -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
              Sort-Object { try { [version]($_.Name -replace '^app-', '') } catch { [version]'0.0' } } -Descending |
              ForEach-Object { Join-Path $_.FullName 'resources\app\git\cmd\git.exe' } |
              Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($gh) { return $gh }
    }
    $local = Join-Path $root 'tools\git\cmd\git.exe'
    if (Test-Path $local) { return $local }
    return $null
}

function Install-MinGit {
    Step 'No git found: downloading portable MinGit (official git-for-windows release)'
    $rel = Invoke-RestMethod 'https://api.github.com/repos/git-for-windows/git/releases/latest' -Headers @{ 'User-Agent' = 'sm-builder'; Accept = 'application/vnd.github+json' }
    $a = $rel.assets | Where-Object { $_.name -match '^MinGit-[\d\.]+-64-bit\.zip$' } | Select-Object -First 1
    if (-not $a) { throw "MinGit 64-bit asset not found in git-for-windows $($rel.tag_name)" }
    if ($a.browser_download_url -notmatch '^https://github\.com/git-for-windows/') { throw "Unexpected URL: $($a.browser_download_url)" }
    if ($a.digest -notmatch '^sha256:(.+)$') { throw "No SHA-256 published for $($a.name); refusing to download without verification." }
    $sha = $Matches[1]
    $tools = Join-Path $root 'tools'
    New-Item -ItemType Directory -Force $tools | Out-Null
    $zip = Join-Path $tools $a.name
    Write-Host ("    {0} ({1}, {2:N0} MB)" -f $a.name, $rel.tag_name, ($a.size / 1MB))
    if ((Invoke-Curl -Url $a.browser_download_url -Dest $zip -Bar) -ne 0) { throw "Download failed: $($a.browser_download_url)" }
    Write-Host '    Verifying...'
    $h = (Get-FileHash $zip -Algorithm SHA256).Hash
    if ($h -ine $sha) { Remove-Item $zip -Force; throw "SHA-256 MISMATCH for $($a.name)`n  expected: $sha`n  got:      $h" }
    Ok 'SHA-256 verified'
    $dest = Join-Path $tools 'git'
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Expand-ZipWithBar -Zip $zip -DestRoot $dest -Label 'Extracting git'
    Remove-Item $zip -Force
    $git = Join-Path $dest 'cmd\git.exe'
    if (-not (Test-Path $git)) { throw 'MinGit extracted, but cmd\git.exe was not found.' }
    return $git
}

function New-CustomRepo {
    # Validates a repository URL typed by the user and describes it like the entries of $games.
    param([string]$RepoUrl)
    $u = $RepoUrl.Trim().Trim('"').Trim("'").TrimEnd('/')
    if ($u -notmatch '^https://[A-Za-z0-9.\-]+(:\d+)?/[A-Za-z0-9._~%/\-]+$') {
        throw "Invalid repository URL: '$RepoUrl'`nUse the HTTPS address of the repository, e.g. https://github.com/SomeUser/stepmania-fork"
    }
    $name = ($u -split '/')[-1] -replace '\.git$', ''
    return @{ Name = $name; Folder = $name; Url = $u; Size = 'size unknown' }
}

# ---------------------------------------------------------------- choose what to download
if ($Url -and $Game) { throw 'Use either -Game or -Url, not both.' }
if (-not $Url -and -not $Game) {
    if ([Console]::IsInputRedirected) { throw "No -Game given and no console to ask. Use: get-source.ps1 -Game stepmania|itgmania  (or -Url <https URL>)" }
    Write-Host ''
    Write-Host 'Which source code do you want to download?' -ForegroundColor Cyan
    Write-Host ("  [1] StepMania  (github.com/stepmania/stepmania, {0})" -f $games['stepmania'].Size)
    Write-Host ("  [2] ITGmania   (github.com/itgmania/itgmania, {0})" -f $games['itgmania'].Size)
    Write-Host '  [3] Other repository (e.g. a fork) - paste its URL'
    Write-Host '  [Q] Quit'
    $ans = (Read-Host 'Choice').Trim().ToLower()
    switch ($ans) {
        '1' { $Game = 'stepmania' }
        '2' { $Game = 'itgmania' }
        '3' {
            Write-Host '    Paste the HTTPS address of the repository, e.g. https://github.com/SomeUser/stepmania-fork'
            Write-Host '    (the builder checks the toolchain, not the source: only use repositories you trust)' -ForegroundColor Yellow
            $Url = (Read-Host '    Repository URL').Trim()
            if (-not $Url) { Write-Host 'Cancelled.'; exit 2 }
        }
        default { Write-Host 'Cancelled.'; exit 2 }
    }
}
$g = if ($Url) { New-CustomRepo $Url } else { $games[$Game] }

# ---------------------------------------------------------------- target folder
function Remove-Folder([string]$Path) {
    # rmdir copes with very long paths and the read-only files inside .git
    cmd /c "rmdir /s /q `"$Path`""
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $Path) { throw "Could not delete $Path completely (is a file in it open in another program?)." }
}
function Get-FreeName([string]$Dir, [string]$Base) {
    $n = 2
    while (Test-Path -LiteralPath (Join-Path $Dir "$Base-$n")) { $n++ }
    return "$Base-$n"
}
function Read-Answer([string]$Prompt) {
    $a = ''
    try { $a = "$(Read-Host $Prompt)".Trim() } catch { }
    return $a
}

if (-not $explicitTarget) {
    $SourceRoot = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
    $folder = if ($FolderName) { $FolderName.Trim() } else { $g.Folder }
    if ($folder -notmatch '^[A-Za-z0-9][A-Za-z0-9._ \-]*$' -or $folder -match '\.\.') {
        throw "Invalid folder name: '$folder' (use letters, numbers, '.', '-', '_' or spaces)."
    }
    New-Item -ItemType Directory -Force $SourceRoot | Out-Null

    # Older layout: one source pasted directly in source\. To keep several side by side, it has to live in
    # its own folder: MOVE it (same drive = instant, nothing is changed inside it), with the user's OK.
    if (Test-Path -LiteralPath (Join-Path $SourceRoot 'CMakeLists.txt')) {
        $oldGame = 'stepmania'
        $core = Join-Path $SourceRoot 'StepmaniaCore.cmake'
        if (Test-Path -LiteralPath $core) {
            $m = Select-String -LiteralPath $core -Pattern 'set\(SM_EXE_NAME\s+"([^"]+)"' | Select-Object -First 1
            if ($m) { $oldGame = ($m.Matches[0].Groups[1].Value.ToLower() -replace '[^a-z0-9]+', '-').Trim('-') }
        }
        $oldFolder = $oldGame
        if (Test-Path -LiteralPath (Join-Path $SourceRoot $oldFolder)) { $oldFolder = Get-FreeName $SourceRoot $oldGame }
        Write-Host ''
        Write-Host "source\ already holds a source directly in it: $SourceRoot" -ForegroundColor Yellow
        Write-Host '    To keep several sources side by side, each one needs its own folder.'
        Write-Host "    The existing one will be MOVED (not changed) to: source\$oldFolder"
        if ((Read-Answer '    Move it now? [Y/N]') -notmatch '^(y|yes|s|si)$') {
            Write-Host "Cancelled. Nothing was changed. (Or move it yourself into a folder such as source\$oldFolder.)"
            exit 2
        }
        $dest = Join-Path $SourceRoot $oldFolder
        New-Item -ItemType Directory -Force $dest | Out-Null
        Get-ChildItem -LiteralPath $SourceRoot -Force |
            Where-Object { $_.Name -ne $oldFolder -and $_.Name -notmatch '^(\.gitkeep|\.keep|put-[a-z0-9\-]+-here\.txt)$' } |
            ForEach-Object { Move-Item -LiteralPath $_.FullName -Destination $dest }
        Ok "Moved to source\$oldFolder"
    }

    # A source with that name already exists: keep it (download with another name) or replace it
    $Target = Join-Path $SourceRoot $folder
    if (-not (Test-DirIsEmpty $Target)) {
        $free = Get-FreeName $SourceRoot $folder
        Write-Host ''
        Write-Host "A source named '$folder' already exists: $Target" -ForegroundColor Yellow
        Write-Host "  [1] Keep it, and download the new one as source\$free   (recommended)"
        Write-Host "  [2] DELETE it and download it again   (any change you made in it will be LOST)" -ForegroundColor Yellow
        Write-Host '  [Q] Cancel'
        switch -Regex (Read-Answer 'Choice [1]') {
            '^1?$' { $folder = $free; $Target = Join-Path $SourceRoot $folder }
            '^2$'  {
                if ((Read-Answer "    Delete source\$folder for good? Type YES to confirm") -ne 'yes') { Write-Host 'Cancelled. Nothing was deleted.'; exit 2 }
                Write-Host "    Deleting source\$folder..."
                Remove-Folder $Target
                Ok 'Deleted'
            }
            default { Write-Host 'Cancelled.'; exit 2 }
        }
    }
}

$Target = [IO.Path]::GetFullPath($Target).TrimEnd('\')
$existed = Test-Path $Target
if (-not (Test-DirIsEmpty $Target)) {
    throw "Target folder is not empty: $Target`nRename or empty it first (nothing is overwritten)."
}
# A folder that only holds a placeholder file (e.g. put-stepmania-here.txt) counts as empty, but git cannot
# clone into a non-empty folder: clone next to it and move the result in (the placeholder is left alone).
$hasPlaceholder = $existed -and ((Get-ChildItem $Target -Force | Measure-Object).Count -gt 0)
$cloneTo = $Target
if ($hasPlaceholder) {
    $cloneTo = Join-Path (Split-Path $Target -Parent) ('.' + (Split-Path $Target -Leaf) + '-download')
    if (Test-Path $cloneTo) { Remove-Item $cloneTo -Recurse -Force }    # leftover of a failed attempt
}

# ---------------------------------------------------------------- git
$git = Find-Git -IgnoreSystem:$UseMinGit
if (-not $git) { $git = Install-MinGit }
Write-Host ("Using git: {0}  ({1})" -f $git, ((& $git --version) -join ' '))

# ---------------------------------------------------------------- clone
Step ("Downloading {0} source into {1}" -f $g.Name, $Target)
$mode = if ($FullHistory) { 'full history' } else { 'shallow: latest commit only' }
Write-Host "    $($g.Url)  ($mode, with submodules; $($g.Size))"
$cloneArgs = @('-c', 'core.longpaths=true', 'clone', '--recurse-submodules')
if (-not $FullHistory) { $cloneArgs += @('--depth', '1', '--shallow-submodules') }
$cloneArgs += @($g.Url, $cloneTo)

Write-Host '    This usually takes 1-3 minutes depending on your connection. git shows its own progress below'
Write-Host '    (Receiving objects / Resolving deltas / one block per submodule). It is working, not stuck.'
Write-Host ''
$cloneArgs += '--progress'      # show progress even when the output is not a terminal
$sw = [Diagnostics.Stopwatch]::StartNew()
# git prints its progress on stderr, straight to the console; do not let PowerShell treat that as an error
$prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
# Public repositories only: a mistyped or private URL must fail, not wait for a user name/password prompt
$prevPrompt = $env:GIT_TERMINAL_PROMPT; $env:GIT_TERMINAL_PROMPT = '0'
& $git @cloneArgs
$code = $LASTEXITCODE
$env:GIT_TERMINAL_PROMPT = $prevPrompt
$ErrorActionPreference = $prevEap
if ($code -ne 0) {
    # Do not leave a half-downloaded source behind (it would block the next attempt)
    if (Test-Path $cloneTo) { Get-ChildItem $cloneTo -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
    if ((-not $existed -or $hasPlaceholder) -and (Test-Path $cloneTo)) { Remove-Item $cloneTo -Force -ErrorAction SilentlyContinue }
    $hint = if ($Url) { 'Check the URL (it must be a public repository) and your internet connection, then try again.' } else { 'Check your internet connection and try again.' }
    throw "git clone failed (code $code). $hint"
}
$sw.Stop()
if ($hasPlaceholder) {
    # same drive: moving is just a rename, so it is instant
    Get-ChildItem $cloneTo -Force | ForEach-Object { Move-Item -LiteralPath $_.FullName -Destination $Target -Force }
    Remove-Item $cloneTo -Recurse -Force
}
Write-Host "`n    Download finished. Checking the result..."
$hash = (& $git -C $Target rev-parse --short HEAD) -join ''
$mb = [math]::Round((Get-ChildItem $Target -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB)
$global:LASTEXITCODE = 0
$missingSub = @(Get-MissingSubmodules $Target)
if ($missingSub.Count) {
    Warn "Some submodules are empty after the download: $($missingSub -join ', ')"
    Warn "The build will stop until they are there. Inside the source folder run: git submodule update --init --recursive"
}
if (-not (Test-Path (Join-Path $Target 'CMakeLists.txt'))) {
    Warn 'This repository has no CMakeLists.txt in its root: it does not look like StepMania/ITGmania source code.'
}
if (-not $explicitTarget) {
    # 3. build.bat offers this source first (Enter) when there are several
    try { Set-Content -LiteralPath (Join-Path $scriptsDir '.last-source') -Value (Split-Path $Target -Leaf) -Encoding ascii } catch { }
}
Write-Host ("`n{0} source ready in {1}  (commit {2}, {3} MB, {4:N0} s)" -f $g.Name, $Target, $hash, $mb, $sw.Elapsed.TotalSeconds) -ForegroundColor Green
