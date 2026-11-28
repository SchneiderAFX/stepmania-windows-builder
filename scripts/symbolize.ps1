<#
.SYNOPSIS
  Turns the addresses in a crashinfo.txt into function names and file:line, using the debug symbols
  that build.ps1 keeps for every build in .\symbols\<source>.

.DESCRIPTION
  A crash report lists the crash's call stack as raw addresses, e.g.
      00007ff6ecedee21: StepMania!00007ff6ecb50000
  (an address and the base the game was loaded at). With the .exe and .pdb of the exact build that
  crashed, each address becomes a function and a line of code:
      00007ff6ecedee21: StepMania!00007ff6ecb50000   -> RageDisplay::EndFrame + 0x41  (src\RageDisplay.cpp:412)

  The build is found by the crash report's "Image id" line (printed by games built from a source that
  has it). Older crash reports only have the version in their first line; several builds can share it,
  and the newest of them is used (the result says so, since it may be the wrong one).

  The result is printed and saved next to the crash report as <name>-symbolized.txt.

.EXAMPLE
  .\scripts\symbolize.ps1 "D:\Games\stepmania-fixes\crashinfo.txt"
  (or drag the crashinfo.txt onto "cli\4. symbolize crash.bat")
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$CrashInfo = '',

    # Folder with the kept symbols. Empty = .\symbols
    [string]$Symbols = ''
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
if (-not $Symbols) { $Symbols = Join-Path $Root 'symbols' }

if (-not $CrashInfo) {
    try { $CrashInfo = "$(Read-Host 'Path of the crashinfo.txt (you can drag the file here)')" } catch { }
}
$CrashInfo = $CrashInfo.Trim().Trim('"')
if (-not $CrashInfo -or -not (Test-Path -LiteralPath $CrashInfo -PathType Leaf)) { throw "Crash report not found: '$CrashInfo'" }
$CrashInfo = (Resolve-Path -LiteralPath $CrashInfo).Path

$lines = [IO.File]::ReadAllLines($CrashInfo)

# ---- Which build crashed? ----------------------------------------------------
$build = $null; $compiled = $null; $imageId = $null
foreach ($l in $lines) {
    if (-not $build -and $l -match 'crash report \(build (?<b>[^,]+), (?<c>\d{8} @ [\d:]+)\)') { $build = $Matches.b; $compiled = $Matches.c }
    if (-not $imageId -and $l -match '^Image id: (?<id>[0-9A-Fa-f]+)\s*$') { $imageId = $Matches.id }
}
if (-not $build -and -not $imageId) { throw "This doesn't look like a StepMania/ITGmania crash report: $CrashInfo" }
Write-Host "Crash report: $CrashInfo"
Write-Host ("Build:        {0}, compiled {1}{2}" -f $build, $compiled, $(if ($imageId) { ", image id $imageId" } else { '' }))

$kept = @()
if (Test-Path -LiteralPath $Symbols) {
    foreach ($f in Get-ChildItem -LiteralPath $Symbols -Recurse -Filter 'build-info.json' -File) {
        try {
            $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
            $j | Add-Member -NotePropertyName Dir -NotePropertyValue $f.DirectoryName
            $kept += $j
        } catch { }
    }
}

$pick = $null; $note = $null
if ($imageId) {
    $pick = $kept | Where-Object { $_.ImageId -and $_.ImageId -ieq $imageId } | Select-Object -First 1
} else {
    # No image id (a crash report of a game built before it was added): match by version
    $same = @($kept | Where-Object { $_.Build -eq $build -and $_.Compiled -eq $compiled } | Sort-Object Built -Descending)
    if ($same.Count) {
        $pick = $same[0]
        if ($same.Count -gt 1) {
            $note = "$($same.Count) kept builds have this version and the crash report has no image id: the newest " +
                    "($($pick.Built)) is used. If the game that crashed was an older one, the lines below may be wrong."
        }
    }
}
if (-not $pick) {
    Write-Host ''
    Write-Host 'No debug symbols were kept for this build.' -ForegroundColor Yellow
    Write-Host "    Looked in: $Symbols"
    Write-Host '    Symbols are kept for the builds made with this builder since it started keeping them;'
    Write-Host '    a game built elsewhere (or before that) can only be symbolized with its own .pdb.'
    exit 1
}
Write-Host "Symbols:      $($pick.Dir)"
if ($note) { Write-Host "    $note" -ForegroundColor Yellow }

$exe = Get-ChildItem -LiteralPath $pick.Dir -Filter '*.exe' -File | Select-Object -First 1
if (-not $exe) { throw "The symbols folder has no .exe: $($pick.Dir)" }
$gameModule = [IO.Path]::GetFileNameWithoutExtension($exe.Name)

# ---- Symbol lookups, with Windows' own dbghelp.dll -----------------------------
if (-not ('SmSymbolizer' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class SmSymbolizer
{
    [DllImport("dbghelp.dll", SetLastError = true)]
    static extern uint SymSetOptions(uint options);
    [DllImport("dbghelp.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SymInitializeW(IntPtr hProcess, string searchPath, bool invadeProcess);
    [DllImport("dbghelp.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern ulong SymLoadModuleExW(IntPtr hProcess, IntPtr hFile, string imageName, string moduleName,
        ulong baseOfDll, uint dllSize, IntPtr data, uint flags);
    [DllImport("dbghelp.dll", SetLastError = true)]
    static extern bool SymFromAddrW(IntPtr hProcess, ulong address, out ulong displacement, IntPtr symbol);
    [DllImport("dbghelp.dll", SetLastError = true)]
    static extern bool SymGetLineFromAddrW64(IntPtr hProcess, ulong address, out uint displacement, ref LINE line);
    [DllImport("dbghelp.dll", SetLastError = true)]
    static extern bool SymCleanup(IntPtr hProcess);

    [StructLayout(LayoutKind.Sequential)]
    struct LINE { public uint SizeOfStruct; public IntPtr Key; public uint LineNumber; public IntPtr FileName; public ulong Address; }

    // Not a real process: any unique value works when nothing is read from a live process.
    static readonly IntPtr Session = new IntPtr(0x534D5359);
    static ulong loadedBase;

    // Returns the base the .exe was loaded at for lookups, or 0.
    public static ulong Load(string exePath, string searchPath)
    {
        // UNDNAME | LOAD_LINES | FAIL_CRITICAL_ERRORS | EXACT_SYMBOLS (only the .pdb of this very .exe) | NO_PROMPTS
        SymSetOptions(0x2 | 0x10 | 0x200 | 0x400 | 0x80000);
        if (!SymInitializeW(Session, searchPath, false))
            return 0;
        loadedBase = SymLoadModuleExW(Session, IntPtr.Zero, exePath, null, 0, 0, IntPtr.Zero, 0);
        return loadedBase;
    }

    public static void Unload() { SymCleanup(Session); }

    // "Function + 0x12|C:\path\file.cpp|123" for an offset in the .exe; empty parts when unknown.
    public static string Lookup(ulong rva)
    {
        ulong address = loadedBase + rva;
        const int SymbolInfoSize = 88; // sizeof(SYMBOL_INFOW) on x64, with its 1-character name
        const int MaxName = 2000;
        string name = "", file = "", line = "";
        IntPtr buffer = Marshal.AllocHGlobal(SymbolInfoSize + MaxName * 2);
        try
        {
            for (int i = 0; i < SymbolInfoSize; ++i) Marshal.WriteByte(buffer, i, 0);
            Marshal.WriteInt32(buffer, 0, SymbolInfoSize);  // SizeOfStruct
            Marshal.WriteInt32(buffer, 80, MaxName);        // MaxNameLen
            ulong displacement;
            if (SymFromAddrW(Session, address, out displacement, buffer))
            {
                int len = Math.Min(Marshal.ReadInt32(buffer, 76), MaxName - 1); // NameLen
                name = Marshal.PtrToStringUni(new IntPtr(buffer.ToInt64() + 84), len) + " + 0x" + displacement.ToString("x");
            }
        }
        finally { Marshal.FreeHGlobal(buffer); }

        LINE l = new LINE();
        l.SizeOfStruct = (uint)Marshal.SizeOf(typeof(LINE));
        uint lineDisplacement;
        if (SymGetLineFromAddrW64(Session, address, out lineDisplacement, ref l))
        {
            file = Marshal.PtrToStringUni(l.FileName);
            line = l.LineNumber.ToString();
        }
        return name + "|" + file + "|" + line;
    }
}
'@
}

$base = [SmSymbolizer]::Load($exe.FullName, $pick.Dir)
if ($base -eq 0) { throw "dbghelp could not load $($exe.FullName) with its .pdb (is the .pdb in the same folder?)" }

function Format-SourcePath([string]$p) {
    # D:\...\_work\stepmania-fixes\stage\src\RageDisplay.cpp -> src\RageDisplay.cpp
    if ($p -match '\\(src|extern)\\') { return $p.Substring($p.IndexOf("\$($Matches[1])\") + 1) }
    return $p
}

# ---- Each address of the crash report -----------------------------------------
$out = New-Object Collections.Generic.List[string]
$resolved = 0; $others = 0
Write-Host ''
foreach ($l in $lines) {
    $text = $l
    if ($l -match '^(?<addr>[0-9a-fA-F]{8,16}): (?<rest>.+)$') {
        $addr = [Convert]::ToUInt64($Matches.addr, 16)
        $rest = $Matches.rest.Trim()
        $module = $null; $rva = $null
        if ($rest -match '^(?<mod>[^!\s]+)!(?<base>[0-9a-fA-F]{8,16})$' -or
            $rest -match '^(?<mod>[^!\s]+)!\S.*\[(?<base>[0-9a-fA-F]{8,16})\+') {
            # "Module!base" or "Module!Symbol [base+...]": the offset is the address minus the base
            $module = $Matches.mod
            $rva = $addr - [Convert]::ToUInt64($Matches.base, 16)
        } elseif ($rest -notmatch '!') {
            # Named by the game's own .vdi: the game was at its preferred base
            $module = $gameModule
            $rva = $addr - $base
        }
        # (an address below the base makes a negative offset: not in the game)
        if ($module -and $module -ieq $gameModule -and $rva -ne $null -and $rva -ge 0 -and $rva -lt 0x10000000) {
            $parts = [SmSymbolizer]::Lookup([uint64]$rva) -split '\|', 3
            if ($parts[0] -or $parts[1]) {
                $where = if ($parts[1]) { "  ($(Format-SourcePath $parts[1]):$($parts[2]))" } else { '' }
                $text = "$l   -> $($parts[0])$where"
                $resolved++
            }
        } elseif ($module) {
            $others++   # a DLL (driver, system): not part of the game's symbols
        }
        Write-Host $text
    }
    $out.Add($text)
}
[SmSymbolizer]::Unload()

$outFile = Join-Path (Split-Path $CrashInfo) ([IO.Path]::GetFileNameWithoutExtension($CrashInfo) + '-symbolized.txt')
try { [IO.File]::WriteAllLines($outFile, $out) }
catch {
    $outFile = Join-Path $env:TEMP ([IO.Path]::GetFileNameWithoutExtension($CrashInfo) + '-symbolized.txt')
    [IO.File]::WriteAllLines($outFile, $out)
}
Write-Host ''
if ($resolved) { Write-Host "$resolved address(es) of the game turned into code." -ForegroundColor Green }
else { Write-Host 'No address of the game was found in this crash report.' -ForegroundColor Yellow }
if ($others) { Write-Host "    $others address(es) are in other modules (drivers, Windows DLLs): those stay as they are." }
Write-Host "Saved: $outFile"
