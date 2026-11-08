# progress.ps1 - small console helpers shared by the other scripts (dot-sourced, do not run directly).
#
#   Set-Steps / Step      numbered headers:            ==> [2/5] Building
#   Write-Bar             percentage bar for work with a known size:   [##########--------]  45%
#   Complete-Bar          ends the line of a bar
#   Wait-Spinner          "in progress" spinner + elapsed time for work of unknown length
#   Invoke-WithSpinner    runs a program and shows the spinner while it works
#   Invoke-Curl           HTTPS download (optionally with curl's own progress bar)
#   Ok / Warn             status lines
#
# Everything is plain text (\r to redraw one line), so it also works when the output is redirected to a file.

$script:UiSteps = 0
$script:UiStep  = 0
$script:BarClock = [Diagnostics.Stopwatch]::StartNew()

function Set-Steps([int]$Total) { $script:UiSteps = $Total; $script:UiStep = 0 }

function Step([string]$Text) {
    $script:UiStep++
    $prefix = if ($script:UiSteps -gt 0) { '[{0}/{1}] ' -f $script:UiStep, $script:UiSteps } else { '' }
    Write-Host "`n==> $prefix$Text" -ForegroundColor Cyan
}

function Ok($m)   { Write-Host "    [OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    [!!] $m" -ForegroundColor Yellow }

function Write-Bar {
    param([string]$Label, [double]$Current, [double]$Total, [string]$Suffix = '', [switch]$Force)
    if ($Total -le 0) { return }
    # do not redraw more than ~8 times per second (it would only slow things down), but always draw the last one
    if (-not $Force -and $Current -lt $Total -and $script:BarClock.ElapsedMilliseconds -lt 120) { return }
    $script:BarClock.Restart()
    $pct    = [int][math]::Min(100, [math]::Floor(100.0 * $Current / $Total))
    $width  = 24
    $filled = [int][math]::Floor($width * $pct / 100.0)
    $line   = '    {0,-18} [{1}{2}] {3,3}%  {4}' -f $Label, ('#' * $filled), ('-' * ($width - $filled)), $pct, $Suffix
    if ($line.Length -gt 78) { $line = $line.Substring(0, 78) }   # stay inside an 80-column window
    Write-Host ("`r" + $line.PadRight(78)) -NoNewline
}

function Complete-Bar { Write-Host '' }

function Wait-Spinner {
    # Waits for a [Diagnostics.Process] or a background job, drawing an "in progress" line.
    param([Parameter(Mandatory)]$Task, [string]$Label = 'Working')
    $frames = '|', '/', '-', '\'
    if ($Label.Length -gt 44) { $Label = $Label.Substring(0, 41) + '...' }   # keep room for "(in progress, mm:ss)"
    $sw = [Diagnostics.Stopwatch]::StartNew(); $i = 0
    while ($true) {
        $running = if ($Task -is [Diagnostics.Process]) { -not $Task.HasExited } else { $Task.State -in 'Running', 'NotStarted' }
        if (-not $running) { break }
        $line = '    {0} {1}  (in progress, {2:mm\:ss})' -f $frames[$i % 4], $Label, $sw.Elapsed
        if ($line.Length -gt 78) { $line = $line.Substring(0, 78) }
        Write-Host ("`r" + $line.PadRight(78)) -NoNewline
        Start-Sleep -Milliseconds 200; $i++
    }
    Write-Host ("`r" + (' ' * 78) + "`r") -NoNewline     # erase the spinner line
    if ($Task -is [Diagnostics.Process]) { $Task.WaitForExit() }
}

function Invoke-WithSpinner {
    # Runs a program (no console output expected) and shows the spinner until it ends. Returns its exit code.
    param([string]$FilePath, [string]$Arguments, [string]$Label)
    $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -NoNewWindow -PassThru
    $null = $p.Handle          # keeps the process handle so that ExitCode is not empty afterwards (PowerShell quirk)
    Wait-Spinner $p $Label
    return [int]$p.ExitCode
}

function Invoke-Curl {
    # HTTPS-only download. -Bar shows curl's own progress bar (use it for big files). Returns curl's exit code.
    param([string]$Url, [string]$Dest, [switch]$Bar)
    if ($Url -notmatch '^https://') { throw "Non-HTTPS URL rejected: $Url" }
    $a = @('-L', '--fail', '--retry', '3', '--proto', '=https', '--tlsv1.2', '-o', $Dest)
    if ($Bar) { $a += @('--progress-bar', '--show-error') } else { $a += @('-sS') }
    # curl writes its progress on stderr: do not let PowerShell treat that as an error
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & curl.exe @a $Url
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return $code
}

function Format-MB([double]$Bytes) { '{0:N0} MB' -f ($Bytes / 1MB) }

function Get-DefenderChoice {
    # Decides whether the Defender scan runs. $Mode: 'scan' (just do it), 'skip' (do not), or 'ask'
    # (show the two options and let the user pick; Enter = continue). With no console to answer
    # (input closed/redirected) it falls back to scanning, the safe choice.
    # Returns 'scan' or 'skip'.
    param([ValidateSet('ask', 'scan', 'skip')][string]$Mode = 'ask')
    if ($Mode -ne 'ask') { return $Mode }
    Write-Host ''
    Write-Host '    [1] Continue Windows Defender check  (recommended)' -ForegroundColor Green
    Write-Host '    [2] Skip Windows Defender check' -ForegroundColor Yellow
    Write-Host '        WARNING: skipping it is less secure. The downloaded files would only be checked' -ForegroundColor Yellow
    Write-Host '        by their SHA-256 hashes and Microsoft signatures, not scanned for malware.' -ForegroundColor Yellow
    Write-Host ''
    $ans = $null
    try { $ans = Read-Host '    Choice [1]' } catch { }
    if ("$ans".Trim() -eq '2') { return 'skip' }
    if (-not "$ans".Trim()) { Write-Host '    (no answer: continuing with the Defender check)' }
    return 'scan'
}

function Invoke-DefenderScan {
    # Scans a folder with Microsoft Defender, showing the "in progress" spinner.
    # Returns 'clean', 'threats' (the details were already printed) or 'unavailable'
    # (Defender missing, disabled, managed by another antivirus, or not allowed to run).
    param([Parameter(Mandatory)][string]$Path)
    try {
        $job = Start-MpScan -ScanType CustomScan -ScanPath $Path -AsJob -ErrorAction Stop
        Wait-Spinner $job 'Scanning with Microsoft Defender'
        Receive-Job $job -ErrorAction Stop | Out-Null
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        $threats = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.Resources -like "*$Path*" })
        if ($threats.Count -gt 0) {
            foreach ($t in $threats) { Warn "Threat: $($t.ThreatID) $($t.Resources)" }
            return 'threats'
        }
        return 'clean'
    } catch {
        Warn "Could not run the Defender scan: $($_.Exception.Message)"
        return 'unavailable'
    }
}

function Test-DirIsEmpty {
    # True if the folder does not exist, is empty, or only contains placeholder files such as
    # .gitkeep or put-stepmania-here.txt (repositories often keep an empty folder alive with one).
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $true }
    foreach ($i in @(Get-ChildItem $Path -Force)) {
        if ($i.PSIsContainer -or $i.Name -notmatch '^(\.gitkeep|\.keep|put-[a-z0-9\-]+-here\.txt)$') { return $false }
    }
    return $true
}

function Expand-ZipWithBar {
    # Extracts a zip (or .vsix) showing a percentage bar.
    #   -Prefix         only entries under this path inside the zip (e.g. 'Contents/'); the prefix is removed
    #   -Unescape       URL-decode the names (vsix files store %20 etc.)
    #   -StripFirstDir  drop the first folder of every path (e.g. 'cmake-4.1.0-windows-x86_64/')
    param([string]$Zip, [string]$DestRoot, [string]$Prefix = '', [switch]$Unescape, [switch]$StripFirstDir, [string]$Label = 'Extracting')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    New-Item -ItemType Directory -Force $DestRoot | Out-Null
    $root = [IO.Path]::GetFullPath($DestRoot).TrimEnd('\')
    $z = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $entries = @($z.Entries | Where-Object { $_.FullName.StartsWith($Prefix) -and -not $_.FullName.EndsWith('/') })
        $n = 0
        foreach ($e in $entries) {
            $n++
            $rel = $e.FullName.Substring($Prefix.Length)
            if ($Unescape) { $rel = [Uri]::UnescapeDataString($rel) }
            if ($StripFirstDir) { $k = $rel.IndexOf('/'); if ($k -lt 0) { continue }; $rel = $rel.Substring($k + 1) }
            if (-not $rel) { continue }
            $target = [IO.Path]::GetFullPath((Join-Path $root $rel))
            if (-not $target.StartsWith($root + '\', 'OrdinalIgnoreCase')) { throw "Suspicious path in archive: $($e.FullName)" }   # anti zip-slip
            [void][IO.Directory]::CreateDirectory((Split-Path $target))
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
            Write-Bar $Label $n $entries.Count ("{0}/{1} files" -f $n, $entries.Count)
        }
        Write-Bar $Label $entries.Count $entries.Count ("{0}/{0} files" -f $entries.Count)
        Complete-Bar
    } finally { $z.Dispose() }
}
