<#
.SYNOPSIS
  Checks for (and installs) updates of StepMania Windows Builder itself.

.DESCRIPTION
  Compares this copy of the builder with the latest commit of its GitHub repository.
  -Check: only compares (asks the GitHub API, downloads nothing, changes nothing).
  default: does the same check and, if there is something new:
     1. downloads the latest commit as a ZIP (a few hundred KB)
     2. copies the files you changed yourself to  <builder>\app-backups\MMDDYYYY-HHMM\
     3. replaces the builder's files: the launcher, cli\, scripts\ and README.md
  Never touched: toolchain\, source\, your builds, _work\, source-backups\ and your settings
  (scripts\.gui-settings.json, scripts\.last-source).

  How it knows its own version: scripts\.app-version.json (written by every update). Without it
  (e.g. a copy downloaded as a ZIP) it compares the files themselves with the latest commit.
  The GitHub API allows 60 checks per hour without an account.

.EXAMPLE
  .\scripts\update-app.ps1 -Check
  .\scripts\update-app.ps1
#>
[CmdletBinding()]
param(
    [switch]$Check,      # only compare, change nothing
    [switch]$Json,       # also print the result as one line: ##JSON {...}  (used by the window)
    [string]$Repo = 'SchneiderAFX/stepmania-windows-builder',
    [string]$Branch = 'main'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$scriptsDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$root        = Split-Path -Parent $scriptsDir
. (Join-Path $scriptsDir 'progress.ps1')
$inv         = [Globalization.CultureInfo]::InvariantCulture
$versionFile = Join-Path $scriptsDir '.app-version.json'
$filesList   = Join-Path $scriptsDir '.app-files.txt'
$latin1      = [Text.Encoding]::GetEncoding(28591)      # maps every byte to one char and back, unchanged

$result = [ordered]@{ Status = ''; Message = ''; Known = $false; Local = $null; Latest = $null; NewCount = 0; Changes = @()
                      Url = "https://github.com/$Repo/commits/$Branch"; Backup = '' }
function Out-Result { if ($Json) { Write-Host ('##JSON ' + ($result | ConvertTo-Json -Depth 5 -Compress)) } }
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

# ---------------------------------------------------------------- GitHub
$hdr = @{ 'User-Agent' = 'StepMania-Windows-Builder'; Accept = 'application/vnd.github+json' }
function Invoke-GitHub([string]$path) {
    try {
        return Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/$path" -Headers $hdr -TimeoutSec 30
    } catch {
        $resp = $_.Exception.Response
        $code = if ($resp) { [int]$resp.StatusCode } else { 0 }
        if ($code -eq 403 -or $code -eq 429) {
            $reset = $resp.Headers['X-RateLimit-Reset']
            $when = if ($reset) { [DateTimeOffset]::FromUnixTimeSeconds([int64]$reset).LocalDateTime.ToString('HH:mm', $inv) } else { 'in a while' }
            Stop-With 'ratelimit' "GitHub allows 60 checks per hour without an account and that limit was reached. Try again at $when."
        }
        if ($code -eq 404 -or $code -eq 422) { return $null }
        Stop-With 'offline' "Could not reach GitHub ($($_.Exception.Message)). Check your internet connection."
    }
}

# The builder's own files in a commit: everything except the repository's dotfiles (.gitattributes...)
# and source\ (where the user's sources live).
function Test-AppPath([string]$p) { return ($p -notmatch '^\.' -and $p -notmatch '^source/' -and $p -notmatch '/\.') }

function Get-AppTree([string]$sha) {
    $t = Invoke-GitHub "git/trees/$($sha)?recursive=1"
    if (-not $t) { return $null }
    $map = @{}
    foreach ($e in $t.tree) { if ($e.type -eq 'blob' -and (Test-AppPath $e.path)) { $map[$e.path] = $e.sha } }
    return $map
}

# ---------------------------------------------------------------- compare files like git does
$sha1 = [Security.Cryptography.SHA1]::Create()
function Test-IsText([byte[]]$b) { $n = [math]::Min($b.Length, 8000); for ($i = 0; $i -lt $n; $i++) { if ($b[$i] -eq 0) { return $false } }; return $true }
function Get-BlobSha([byte[]]$b) {
    $h = [Text.Encoding]::ASCII.GetBytes("blob $($b.Length)`0")
    $all = New-Object byte[] ($h.Length + $b.Length)
    [Array]::Copy($h, $all, $h.Length); [Array]::Copy($b, 0, $all, $h.Length, $b.Length)
    return (($sha1.ComputeHash($all) | ForEach-Object { $_.ToString('x2') }) -join '')
}
# git stores text files with LF line ends (.gitattributes: text=auto); a local copy may have CRLF.
# Returns the git ids this file can match: as it is, and with CRLF turned into LF.
function Get-LocalShas([string]$file) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return @() }
    $b = [IO.File]::ReadAllBytes($file)
    $ids = @(Get-BlobSha $b)
    if (Test-IsText $b) { $ids += Get-BlobSha ($latin1.GetBytes($latin1.GetString($b).Replace("`r`n", "`n"))) }
    return $ids
}
function Test-SameFile([string]$rel, [string]$sha) {
    return ((Get-LocalShas (Join-Path $root ($rel -replace '/', '\'))) -contains $sha)
}
function Test-MatchesTree($tree) {
    foreach ($k in $tree.Keys) { if (-not (Test-SameFile $k $tree[$k])) { return $false } }
    return $true
}

# ---------------------------------------------------------------- which version is this?
function Read-LocalCommit {
    try {
        if (Test-Path -LiteralPath $versionFile) {
            $v = Get-Content -LiteralPath $versionFile -Raw | ConvertFrom-Json
            if ($v.Commit -match '^[0-9a-f]{40}$') { return $v }
        }
    } catch { }
    # a git clone of the builder: its current commit
    $gitDir = Join-Path $root '.git'
    if (Test-Path -LiteralPath (Join-Path $gitDir 'HEAD')) {
        $head = (Get-Content -LiteralPath (Join-Path $gitDir 'HEAD') -Raw).Trim()
        $sha = $head
        if ($head -match '^ref: (.+)$') {
            $ref = $Matches[1]
            $loose = Join-Path $gitDir ($ref -replace '/', '\')
            $sha = if (Test-Path -LiteralPath $loose) { (Get-Content -LiteralPath $loose -Raw).Trim() } else { '' }
            if (-not $sha -and (Test-Path -LiteralPath (Join-Path $gitDir 'packed-refs'))) {
                foreach ($l in Get-Content -LiteralPath (Join-Path $gitDir 'packed-refs')) { if ($l -match "^([0-9a-f]{40}) $([regex]::Escape($ref))$") { $sha = $Matches[1] } }
            }
        }
        if ($sha -match '^[0-9a-f]{40}$') { return [pscustomobject]@{ Commit = $sha; Date = ''; Message = '' } }
    }
    return $null
}
function Save-Version($c) {
    [pscustomobject]@{ Commit = $c.Sha; Date = $c.Date; Message = $c.Message } | ConvertTo-Json | Set-Content -LiteralPath $versionFile -Encoding ascii
}

if (-not $Check) { Set-Steps 4; Step "Checking GitHub for the latest version" }
$latestRaw = Invoke-GitHub "commits/$Branch"
if (-not $latestRaw) { Stop-With 'error' "The repository github.com/$Repo (branch $Branch) was not found." }
$latest = [ordered]@{
    Sha     = [string]$latestRaw.sha
    Short   = ([string]$latestRaw.sha).Substring(0, 7)
    Date    = Format-When ([string]$latestRaw.commit.committer.date)
    Message = (([string]$latestRaw.commit.message) -split "`n")[0].Trim()
}
$result.Latest = $latest

$local = Read-LocalCommit
$latestTree = $null
if ($local -and $local.Commit -eq $latest.Sha) {
    $result.Known = $true
    $result.Local = [ordered]@{ Sha = $local.Commit; Short = $local.Commit.Substring(0, 7); Date = $local.Date }
} else {
    # Not recorded (or recorded as an older commit): maybe the files already are the latest ones
    # (a fresh ZIP download, or copied by hand). Then remember it.
    $latestTree = Get-AppTree $latest.Sha
    if (-not $latestTree) { Stop-With 'error' 'Could not read the file list of the latest version from GitHub.' }
    if (Test-MatchesTree $latestTree) {
        $result.Known = $true
        $result.Local = [ordered]@{ Sha = $latest.Sha; Short = $latest.Short; Date = $latest.Date }
        Save-Version $latest
        $local = [pscustomobject]@{ Commit = $latest.Sha }
    }
}

if ($local -and $local.Commit -eq $latest.Sha) {
    $result.Status = 'uptodate'
    $result.Message = "StepMania Windows Builder is up to date (commit $($latest.Short), $($latest.Date))."
    Write-Host $result.Message
    if (-not $Check) { Ok 'Nothing to update' }
    Out-Result
    exit 0
}

# Something newer (or different) is on GitHub
$result.Status = 'available'
if ($local) {
    $result.Known = $true
    $result.Local = [ordered]@{ Sha = $local.Commit; Short = $local.Commit.Substring(0, 7); Date = [string]$local.Date }
    $cmp = Invoke-GitHub "compare/$($local.Commit)...$($latest.Sha)"
    if ($cmp) {
        $result.NewCount = [int]$cmp.ahead_by
        $result.Changes = @(@($cmp.commits) | Select-Object -Last 15 | ForEach-Object {
            '{0}  {1}' -f (Format-When ([string]$_.commit.committer.date)).Substring(0, 10), (([string]$_.commit.message) -split "`n")[0].Trim()
        })
        [array]::Reverse($result.Changes)       # newest first
    } else {
        $result.Known = $false                  # that commit is not on GitHub (e.g. a local test copy)
    }
}
$result.Message = if ($result.Known -and $result.NewCount -gt 0) {
    "A new version is available: $($result.NewCount) new change(s), the latest from $($latest.Date): $($latest.Message)"
} else {
    "Your copy differs from the latest version on GitHub (commit $($latest.Short), $($latest.Date): $($latest.Message))."
}
Write-Host $result.Message
foreach ($c in $result.Changes) { Write-Host "    $c" }
if ($Check) { Out-Result; exit 0 }

# ---------------------------------------------------------------- update
Step "Downloading commit $($latest.Short)"
$tmp = Join-Path $env:TEMP ("smwb-app-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
    $zip = Join-Path $tmp 'app.zip'
    $code = Invoke-Curl -Url "https://codeload.github.com/$Repo/zip/$($latest.Sha)" -Dest $zip
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $zip)) { Stop-With 'offline' "The download failed (curl exit code $code). Check your internet connection." }
    $new = Join-Path $tmp 'files'
    Expand-ZipWithBar -Zip $zip -DestRoot $new -StripFirstDir -Label 'Extracting'

    if (-not $latestTree) { $latestTree = Get-AppTree $latest.Sha }
    $newFiles = @($latestTree.Keys | Sort-Object)
    foreach ($f in $newFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $new ($f -replace '/', '\')))) { Stop-With 'error' "The download is incomplete ($f is missing). Nothing was changed." }
    }

    # Files that will go away: in the previous version (the list of the last update, or else the
    # file list of the commit you had), gone from the new one
    $oldTree = if ($result.Known -and $local) { Get-AppTree $local.Commit } else { $null }
    $oldFiles = @()
    if (Test-Path -LiteralPath $filesList) { $oldFiles = @(Get-Content -LiteralPath $filesList | Where-Object { $_ -and (Test-AppPath $_) }) }
    elseif ($oldTree) { $oldFiles = @($oldTree.Keys) }
    $removed = @($oldFiles | Where-Object { $newFiles -notcontains $_ -and (Test-Path -LiteralPath (Join-Path $root ($_ -replace '/', '\'))) })

    Step 'Backing up the files you changed'
    # Changed by you = different from the version you had. Without a known version, every file that
    # differs from the new one is kept, to be safe.
    $backup = Join-Path $root ('app-backups\' + (Get-Date).ToString('MMddyyyy-HHmm', $inv))
    $saved = 0
    foreach ($f in @($newFiles + $removed | Select-Object -Unique)) {
        $p = Join-Path $root ($f -replace '/', '\')
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        $mine = if ($oldTree) { -not ($oldTree.ContainsKey($f) -and (Test-SameFile $f $oldTree[$f])) }
                else { -not ($latestTree.ContainsKey($f) -and (Test-SameFile $f $latestTree[$f])) }
        if (-not $mine) { continue }
        $dest = Join-Path $backup ($f -replace '/', '\')
        New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
        Copy-Item -LiteralPath $p -Destination $dest -Force
        $saved++
    }
    if ($saved) { Ok "$saved file(s) copied to $backup"; $result.Backup = $backup } else { Ok 'You had not changed any file' }

    Step 'Installing the new version'
    # All or nothing: a copy of every file about to change is kept, and if one cannot be replaced
    # (e.g. another program has it open) everything goes back as it was.
    $undo = Join-Path $tmp 'previous'
    $created = New-Object System.Collections.Generic.List[string]
    $saved = @()                                   # builder-relative paths that have a copy in $undo
    foreach ($f in @($newFiles + $removed | Select-Object -Unique)) {
        $p = Join-Path $root ($f -replace '/', '\')
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            $u = Join-Path $undo ($f -replace '/', '\')
            New-Item -ItemType Directory -Force (Split-Path $u) | Out-Null
            Copy-Item -LiteralPath $p -Destination $u -Force
            $saved += $f
        }
    }
    function Write-WithRetry([string]$path, [byte[]]$bytes) {
        for ($try = 1; ; $try++) {
            try { [IO.File]::WriteAllBytes($path, $bytes); return }
            catch { if ($try -ge 6) { throw }; Start-Sleep -Milliseconds 500 }     # e.g. an antivirus reading it
        }
    }
    $n = 0
    $current = ''
    try {
        foreach ($f in $newFiles) {
            $current = $f
            $src = Join-Path $new ($f -replace '/', '\')
            $dst = Join-Path $root ($f -replace '/', '\')
            New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
            $b = [IO.File]::ReadAllBytes($src)
            if (Test-IsText $b) {
                # Windows line ends (CRLF): .bat files misbehave with LF only
                $b = $latin1.GetBytes($latin1.GetString($b).Replace("`r`n", "`n").Replace("`n", "`r`n"))
            }
            if (-not (Test-Path -LiteralPath $dst)) { $created.Add($dst) }
            Write-WithRetry $dst $b
            $n++
        }
        foreach ($f in $removed) { $current = $f; Remove-Item -LiteralPath (Join-Path $root ($f -replace '/', '\')) -Force }
    } catch {
        $why = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        Warn "Could not replace $($current): $why"
        Warn 'Putting every file back as it was...'
        $bad = 0
        foreach ($f in $saved) {
            $rel = $f -replace '/', '\'
            $p = Join-Path $root $rel
            $restored = $false
            for ($try = 1; $try -le 6 -and -not $restored; $try++) {
                try { Copy-Item -LiteralPath (Join-Path $undo $rel) -Destination $p -Force; $restored = $true }
                catch { Start-Sleep -Milliseconds 500 }
            }
            if (-not $restored) {
                # still locked: if it was never changed (the failed file itself), there is nothing to restore
                $same = (Get-FileHash -LiteralPath $p -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash -eq (Get-FileHash -LiteralPath (Join-Path $undo $rel) -Algorithm SHA256).Hash
                if (-not $same) { $bad++; Warn "Could not restore $p" }
            }
        }
        foreach ($p in $created) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
        if ($bad) {
            Stop-With 'error' ("The update failed on $current and $bad file(s) could not be put back. Download the builder again from GitHub. " +
                               "Your toolchain, sources, builds and settings are not affected.") 1
        }
        Stop-With 'error' "The update failed: $current could not be replaced ($why). Nothing was changed. Close any program that may be using it and try again." 1
    }
    Set-Content -LiteralPath $filesList -Value $newFiles -Encoding ascii
    Save-Version $latest
    Ok "$n file(s) updated$(if ($removed.Count) { ", $($removed.Count) removed" })"

    $result.Status = 'updated'
    $result.Message = "Updated to commit $($latest.Short) ($($latest.Date))."
    Write-Host ''
    Write-Host $result.Message -ForegroundColor Green
    Out-Result
    exit 0
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
