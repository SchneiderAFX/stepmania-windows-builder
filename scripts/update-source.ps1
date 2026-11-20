<#
.SYNOPSIS
  Checks for (and installs) updates of a source that is a git clone of a GitHub repository.

.DESCRIPTION
  -Check: compares your copy with the latest commit of its branch on GitHub, WITHOUT downloading or
          changing anything (it only asks the GitHub API). Shows the new commits, the files they change,
          the submodules they move, and the files you changed yourself.
  default: does the same check and, if there is something new, updates the source:
     1. backs up every file you changed to  <builder>\source-backups\<name>-MMDDYYYY-HHMM\
     2. puts your changes aside (git stash), downloads the latest commit, moves the source to it,
        updates the submodules
     3. re-applies your changes. If the update changed the same lines, the updated file is kept and
        your version stays in the backup folder; you are told which files.
  Files that git does not track (e.g. new songs you added) are never touched.

  Only GitHub repositories can be compared (StepMania, ITGmania and their forks are on GitHub).
  The GitHub API allows 60 checks per hour without an account.

.EXAMPLE
  .\scripts\update-source.ps1 -Source stepmania-fixes -Check
  .\scripts\update-source.ps1 -Source stepmania-fixes
#>
[CmdletBinding()]
param(
    # Folder name inside source\ (e.g. stepmania-fixes) or a path. Empty = the only source in source\.
    [string]$Source = '',
    [switch]$Check,      # only compare, change nothing
    [switch]$Json        # also print the result as one line: ##JSON {...}  (used by the window)
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$scriptsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root       = Split-Path -Parent $scriptsDir
. (Join-Path $scriptsDir 'progress.ps1')
$inv = [Globalization.CultureInfo]::InvariantCulture

# ---------------------------------------------------------------- which source
$sourceRoot = Join-Path $root 'source'
if (-not $Source) {
    if (Test-Path -LiteralPath (Join-Path $sourceRoot 'CMakeLists.txt')) { $Source = $sourceRoot }
    else {
        $subs = @(Get-ChildItem -LiteralPath $sourceRoot -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'CMakeLists.txt') })
        if ($subs.Count -ne 1) { throw "Say which source: -Source <name>. Sources: $(($subs | ForEach-Object { $_.Name }) -join ', ')" }
        $Source = $subs[0].FullName
    }
} elseif (-not (Test-Path -LiteralPath $Source -PathType Container)) {
    $Source = Join-Path $sourceRoot $Source
}
if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw "Source not found: $Source" }
$Source = (Get-Item -LiteralPath $Source).FullName.TrimEnd('\')
$name   = Split-Path $Source -Leaf

$result = [ordered]@{ Source = $name; Path = $Source; Status = ''; Message = '' }
function Out-Result {
    if ($Json) { Write-Host ('##JSON ' + ($result | ConvertTo-Json -Depth 6 -Compress)) }
}
function Stop-With([string]$status, [string]$msg, [int]$code = 3) {
    $result.Status = $status; $result.Message = $msg
    Write-Host $msg -ForegroundColor Yellow
    Out-Result
    exit $code
}
function Format-When([string]$iso) {
    if (-not $iso) { return '' }
    return ([datetime]::Parse($iso, $inv, [Globalization.DateTimeStyles]::RoundtripKind)).ToLocalTime().ToString('MM/dd/yyyy HH:mm', $inv)
}

# ---------------------------------------------------------------- read .git without needing git
$gitDir = Join-Path $Source '.git'
if (-not (Test-Path -LiteralPath $gitDir -PathType Container)) {
    Stop-With 'nogit' ("'$name' has no git information (it was pasted or downloaded as a ZIP), so it cannot be compared with GitHub. " +
                       'To get updates, download it again with Download... (or cli\2. get-source.bat).')
}
$headRef = (Get-Content -LiteralPath (Join-Path $gitDir 'HEAD') -Raw).Trim()
function Get-RefSha([string]$ref) {
    $loose = Join-Path $gitDir ($ref -replace '/', '\')
    if (Test-Path -LiteralPath $loose) { return (Get-Content -LiteralPath $loose -Raw).Trim() }
    $packed = Join-Path $gitDir 'packed-refs'
    if (Test-Path -LiteralPath $packed) {
        foreach ($l in Get-Content -LiteralPath $packed) { if ($l -match "^([0-9a-f]{40}) $([regex]::Escape($ref))$") { return $Matches[1] } }
    }
    return $null
}
$branch = ''
if ($headRef -match '^ref: refs/heads/(.+)$') { $branch = $Matches[1]; $localSha = Get-RefSha "refs/heads/$branch" }
else { $localSha = $headRef }
if ($localSha -notmatch '^[0-9a-f]{40}$') { Stop-With 'error' "Could not read the current commit of '$name'." }

$remoteUrl = ''
$inOrigin = $false
foreach ($l in Get-Content -LiteralPath (Join-Path $gitDir 'config')) {
    if ($l -match '^\s*\[remote "origin"\]') { $inOrigin = $true; continue }
    if ($l -match '^\s*\[') { $inOrigin = $false }
    if ($inOrigin -and $l -match '^\s*url\s*=\s*(.+?)\s*$') { $remoteUrl = $Matches[1] }
}
if ($remoteUrl -notmatch 'github\.com[/:]([^/]+)/([^/]+?)(\.git)?/?$') {
    Stop-With 'notgithub' "'$name' comes from $(if ($remoteUrl) { $remoteUrl } else { 'an unknown place' }). Only GitHub repositories can be compared."
}
$owner = $Matches[1]; $repo = $Matches[2]
$result.Owner = $owner; $result.Repo = $repo
$result.RepoUrl = "https://github.com/$owner/$repo"

# ---------------------------------------------------------------- ask GitHub
$hdr = @{ 'User-Agent' = 'StepMania-Windows-Builder'; Accept = 'application/vnd.github+json' }
function Invoke-GitHub([string]$path) {
    try {
        $uri = "https://api.github.com/repos/$owner/$repo" + $(if ($path) { "/$path" } else { '' })
        return Invoke-RestMethod -Uri $uri -Headers $hdr -TimeoutSec 30
    } catch {
        $resp = $_.Exception.Response
        $code = if ($resp) { [int]$resp.StatusCode } else { 0 }
        if ($code -eq 403 -or $code -eq 429) {
            $reset = $resp.Headers['X-RateLimit-Reset']
            $when = if ($reset) { [DateTimeOffset]::FromUnixTimeSeconds([int64]$reset).LocalDateTime.ToString('HH:mm', $inv) } else { 'in a while' }
            Stop-With 'ratelimit' "GitHub allows 60 checks per hour without an account and that limit was reached. Try again at $when."
        }
        if ($code -eq 404) { throw [System.IO.FileNotFoundException]::new($path) }
        Stop-With 'offline' "Could not reach GitHub ($($_.Exception.Message)). Check your internet connection."
    }
}

Set-Steps $(if ($Check) { 1 } else { 6 })
Step "Checking for updates: $name  (github.com/$owner/$repo)"
if (-not $branch) {
    try { $branch = (Invoke-GitHub '').default_branch } catch { Stop-With 'notfound' "The repository github.com/$owner/$repo was not found (is it private or deleted?)." }
}
$result.Branch = $branch
try { $head = Invoke-GitHub "commits/$branch" }
catch { Stop-With 'notfound' "The branch '$branch' was not found on github.com/$owner/$repo (renamed, deleted, or a private repository)." }

$result.LocalSha  = $localSha
$result.RemoteSha = $head.sha
$result.RemoteDate = Format-When $head.commit.committer.date
$result.Commits = @(); $result.Files = @(); $result.Submodules = @(); $result.Areas = @()
$result.NewCount = 0; $result.FileCount = 0

if ($head.sha -eq $localSha) {
    $result.Status = 'uptodate'
    $result.LocalDate = $result.RemoteDate
} else {
    try { $cmp = Invoke-GitHub "compare/$localSha...$($head.sha)" }
    catch { Stop-With 'unknown' "Your copy of '$name' is at a commit that GitHub does not know (made locally, or the history was rewritten). It cannot be compared automatically." }
    $result.LocalDate = Format-When $cmp.base_commit.commit.committer.date
    switch ($cmp.status) {
        'ahead'    { $result.Status = 'available' }
        'identical'{ $result.Status = 'uptodate' }
        'behind'   { $result.Status = 'local-ahead' }
        default    { $result.Status = 'diverged' }
    }
    $result.NewCount = [int]$cmp.ahead_by
    $sub = @()
    $gm = Join-Path $Source '.gitmodules'
    if (Test-Path -LiteralPath $gm) { $sub = @(Select-String -LiteralPath $gm -Pattern '^\s*path\s*=\s*(.+?)\s*$' | ForEach-Object { $_.Matches[0].Groups[1].Value }) }
    $commits = @($cmp.commits)
    [array]::Reverse($commits)     # newest first
    $result.Commits = @($commits | Select-Object -First 100 | ForEach-Object {
        [ordered]@{ Sha = $_.sha.Substring(0, 7); Message = (($_.commit.message -split "`n")[0]).Trim()
                    Author = $_.commit.author.name; Date = Format-When $_.commit.committer.date }
    })
    $files = @($cmp.files)
    $result.FileCount = $files.Count
    $result.Files = @($files | Select-Object -First 300 | ForEach-Object { [ordered]@{ Name = $_.filename; Status = $_.status } })
    $result.Submodules = @($files | Where-Object { $sub -contains $_.filename } | ForEach-Object { $_.filename })
    $result.Areas = @($files | Where-Object { $sub -notcontains $_.filename } |
                      Group-Object { ($_.filename -split '/')[0] } | Sort-Object Count -Descending |
                      ForEach-Object { [ordered]@{ Name = $_.Name; Count = $_.Count } })
}
$result.CompareUrl = if ($result.Status -eq 'uptodate') { "$($result.RepoUrl)/commits/$branch" } else { "$($result.RepoUrl)/compare/$($localSha.Substring(0,7))...$($head.sha.Substring(0,7))" }

# ---------------------------------------------------------------- your own changes (needs git)
$git = Find-GitExe -BuilderRoot $root
$result.LocalChanges = $null
if ($git) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $st = @(& $git -C $Source -c core.quotepath=off status --porcelain --untracked-files=no --ignore-submodules=dirty 2>$null)
    $ErrorActionPreference = $prev
    $global:LASTEXITCODE = 0
    $result.LocalChanges = @($st | Where-Object { $_ -match '^.. ' } | ForEach-Object { $_.Substring(3).Trim('"') })
}

# ---------------------------------------------------------------- report
$c = $result
Write-Host ("    Your copy:  {0}  ({1})" -f $c.LocalSha.Substring(0, 7), $c.LocalDate)
Write-Host ("    Latest:     {0}  ({1})  on branch {2}" -f $c.RemoteSha.Substring(0, 7), $c.RemoteDate, $c.Branch)
switch ($c.Status) {
    'uptodate'    { Ok "'$name' is up to date." }
    'available'   {
        Write-Host ("    {0} new commit(s), {1} file(s) changed{2}" -f $c.NewCount, $c.FileCount,
                    $(if ($c.Submodules.Count) { ", submodules: $($c.Submodules -join ', ')" } else { '' })) -ForegroundColor Cyan
        foreach ($m in $c.Commits | Select-Object -First 15) { Write-Host ("      {0}  {1}  {2}" -f $m.Sha, $m.Date, $m.Message) }
        if ($c.Commits.Count -gt 15) { Write-Host "      ... and $($c.Commits.Count - 15) more" }
    }
    'local-ahead' { Warn "Your copy has commits that are not on GitHub ($name is AHEAD of $($c.Branch)). Nothing to download." }
    'diverged'    { Warn "Your copy and GitHub have both changed ($name has commits that are not on GitHub). It cannot be updated automatically." }
}
if ($null -eq $c.LocalChanges) { Write-Host '    (git not found: your own changes could not be listed)' }
elseif ($c.LocalChanges.Count) { Warn ("You changed {0} file(s): {1}" -f $c.LocalChanges.Count, (($c.LocalChanges | Select-Object -First 5) -join ', ')) }

if ($Check -or $c.Status -ne 'available') {
    Out-Result
    exit 0
}

# ================================================================ update
if (-not $git) { Stop-With 'nogitexe' 'git was not found, so the source cannot be updated. Run cli\2. get-source.bat once (it installs a portable git), then try again.' 4 }
function Invoke-Git {
    # runs git in the source; returns its exit code (git prints progress on stderr: not an error)
    # Its output is shown, never returned: the function must return ONLY the exit code.
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & $git -C $Source -c core.longpaths=true -c user.name=StepManiaBuilder -c user.email=builder@localhost @args 2>&1 |
        ForEach-Object { Write-Host "    $_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    $global:LASTEXITCODE = 0
    return $code
}

# 1. backup
$backup = $null
$changed = @($c.LocalChanges)
Step 'Backing up your changes'
if ($changed.Count) {
    $backup = Join-Path $root ("source-backups\{0}-{1}" -f $name, (Get-Date).ToString('MMddyyyy-HHmm', $inv))
    foreach ($f in $changed) {
        $from = Join-Path $Source ($f -replace '/', '\')
        if (Test-Path -LiteralPath $from -PathType Leaf) {
            $to = Join-Path $backup ($f -replace '/', '\')
            New-Item -ItemType Directory -Force (Split-Path $to -Parent) | Out-Null
            Copy-Item -LiteralPath $from -Destination $to -Force
        }
    }
    Ok "$($changed.Count) file(s) copied to $backup"
} else {
    Ok 'You have no changes in this source; nothing to back up.'
}

# 2. download the new commit (only that commit: the source is a shallow copy)
Step "Downloading the update ($($c.NewCount) new commit(s))"
if ((Invoke-Git fetch --depth=1 --progress origin $c.Branch) -ne 0) { Stop-With 'error' 'Downloading the update failed. Check your internet connection and try again. Nothing was changed.' 1 }

# 3. move the source to it
Step 'Applying the update'
$stashed = $false
if ($changed.Count) {
    if ((Invoke-Git stash push -m "StepMania Builder: before updating to $($c.RemoteSha.Substring(0,7))") -ne 0) { Stop-With 'error' "Could not put your changes aside. Nothing was changed; your files are also in $backup" 1 }
    $stashed = $true
}
if ((Invoke-Git reset --hard FETCH_HEAD) -ne 0) {
    if ($stashed) { [void](Invoke-Git stash pop) }
    Stop-With 'error' 'Could not apply the update. Your source was left as it was.' 1
}
Write-Host '    Updating submodules (git shows its progress below)...'
if ((Invoke-Git submodule update --init --recursive --depth 1 --progress) -ne 0) {
    Warn 'Some submodules could not be updated. Run Update again; if it keeps failing, download the source again.'
}

# 4. your changes back
Step 'Re-applying your changes'
$conflicts = @()
if ($stashed) {
    if ((Invoke-Git stash pop) -ne 0) {
        $conflicts = @(& $git -C $Source -c core.quotepath=off diff --name-only --diff-filter=U 2>$null)
        $global:LASTEXITCODE = 0
        foreach ($f in $conflicts) { [void](Invoke-Git checkout HEAD -- $f) }      # keep the updated file
        [void](Invoke-Git reset -q)                                                # leave the others as plain changes
        [void](Invoke-Git stash drop -q)        # git keeps it after a conflict; your versions are in the backup folder
    }
    if ($conflicts.Count) {
        Warn "$($conflicts.Count) file(s) were changed by you AND by the update; the updated version was kept:"
        foreach ($f in $conflicts) { Write-Host "      $f" }
        Warn "Your version of each one is in $backup (copy back what you need)."
    } else { Ok "Your changes were re-applied ($($changed.Count) file(s))." }
} else { Ok 'Nothing to re-apply.' }

Step 'Done'
$result.Status = 'updated'
$result.Backup = $backup
$result.Conflicts = $conflicts
$result.Message = "Updated '$name': $($c.LocalSha.Substring(0,7)) -> $($c.RemoteSha.Substring(0,7))"
Write-Host "`n$($result.Message)" -ForegroundColor Green
Out-Result
exit 0
