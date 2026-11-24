<#
.SYNOPSIS
  StepMania Windows Builder - graphical interface.

.DESCRIPTION
  A window on top of the same scripts the .bat files use. It runs them in the background with the
  options you pick and turns their output into a progress bar, a status line and a log:
    - build.ps1            (Build)
    - get-source.ps1       (Download source...)
    - setup-toolchain.ps1  (Toolchain: Install / Repair)
    - verify-toolchain.ps1 (Toolchain: Verify)
    - update-source.ps1    (Check updates / Update)
    - update-app.ps1       (updates of the builder itself: checked at start, and from Help)
  Light and dark themes (Auto follows Windows).
  Compact mode shows only what you need to build; Advanced shows everything else.
  Nothing new is installed: it uses WPF, which is part of Windows.

  Start it with "StepMania Windows Builder.bat" (or: powershell -STA -File scripts\gui.ps1).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scriptsDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$root         = Split-Path -Parent $scriptsDir
$sourceRoot   = Join-Path $root 'source'
$settingsFile = Join-Path $scriptsDir '.gui-settings.json'
$lastFile     = Join-Path $scriptsDir '.last-source'
$readmeFile   = Join-Path $root 'README.md'
$iconFile     = Join-Path $scriptsDir 'builder.ico'
$firstRun     = -not (Test-Path -LiteralPath $settingsFile)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing, Microsoft.VisualBasic
. (Join-Path $scriptsDir 'progress.ps1')      # shared helpers (Get-BuildPlan, Find-GitExe...)

# ---------------------------------------------------------------- background process runner
# Runs a program without a console window and queues every output line. The window reads the queue
# with a timer, so it never freezes while a task runs for minutes. (Compiled in memory by Windows'
# own .NET; no file is written.)
if (-not ('SmbRunner' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;

public class SmbRunner {
    public Process Proc;
    public ConcurrentQueue<string> Lines = new ConcurrentQueue<string>();
    private volatile bool outDone, errDone;

    public bool Finished { get { return Proc != null && Proc.HasExited && outDone && errDone; } }
    public int ExitCode  { get { return Proc.ExitCode; } }

    public void Start(string exe, string args, string workDir, Encoding enc) {
        var si = new ProcessStartInfo(exe, args);
        si.UseShellExecute = false;
        si.CreateNoWindow = true;
        si.RedirectStandardOutput = true;
        si.RedirectStandardError = true;
        si.RedirectStandardInput = true;
        si.WorkingDirectory = workDir;
        si.StandardOutputEncoding = enc;
        si.StandardErrorEncoding = enc;
        Proc = new Process();
        Proc.StartInfo = si;
        Proc.OutputDataReceived += (s, e) => { if (e.Data == null) outDone = true; else Lines.Enqueue(e.Data); };
        Proc.ErrorDataReceived  += (s, e) => { if (e.Data == null) errDone = true; else Lines.Enqueue(e.Data); };
        Proc.Start();
        Proc.StandardInput.Close();      // no console: any question gets "no answer" (the safe default)
        Proc.BeginOutputReadLine();
        Proc.BeginErrorReadLine();
    }

    // Stops the task and everything it started (cmake, ninja, the compiler, git...)
    public void KillTree() {
        if (Proc == null || Proc.HasExited) return;
        var k = new ProcessStartInfo("taskkill.exe", "/T /F /PID " + Proc.Id);
        k.UseShellExecute = false;
        k.CreateNoWindow = true;
        using (var p = Process.Start(k)) { p.WaitForExit(15000); }
    }
}
'@
}

# ---------------------------------------------------------------- helpers
function Get-GameName([string]$dir) {
    $n = 'StepMania'
    $core = Join-Path $dir 'StepmaniaCore.cmake'
    if (Test-Path -LiteralPath $core) {
        $m = Select-String -LiteralPath $core -Pattern 'set\(SM_EXE_NAME\s+"([^"]+)"' | Select-Object -First 1
        if ($m) { $n = $m.Matches[0].Groups[1].Value }
    }
    return $n
}

function Get-Sources {
    # Same rules as build.ps1: a source pasted directly in source\, or one per subfolder.
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) { return @() }
    if (Test-Path -LiteralPath (Join-Path $sourceRoot 'CMakeLists.txt')) {
        $g = Get-GameName $sourceRoot
        return @([pscustomobject]@{ Name = ($g.ToLower() -replace '[^a-z0-9]+', '-').Trim('-'); Path = $sourceRoot; Game = $g })
    }
    return @(Get-ChildItem -LiteralPath $sourceRoot -Directory -ErrorAction SilentlyContinue |
             Where-Object { (Test-Path -LiteralPath (Join-Path $_.FullName 'CMakeLists.txt')) -and (Test-Path -LiteralPath (Join-Path $_.FullName 'src')) } |
             Sort-Object Name |
             ForEach-Object { [pscustomobject]@{ Name = $_.Name; Path = $_.FullName; Game = (Get-GameName $_.FullName) } })
}

function Test-HasFiles([string]$dir) {
    return [bool](Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Get-Builds {
    # Finished clean builds: folders next to the scripts with portable.ini and Program\<game>.exe
    # Each build remembers its source and commit (.builder-build.json); builds from older versions of the
    # builder are recognized by their name (<source>-<commit> / -MMDDYYYY / -MMDDYYYY-HHMM).
    $sources = @(Get-Sources)
    $names = @($sources | ForEach-Object { $_.Name } | Sort-Object Length -Descending)
    $srcCommit = @{}
    foreach ($s in $sources) { $srcCommit[$s.Name] = Get-SourceCommit -BuilderRoot $root -SourcePath $s.Path }
    $skip = 'source', 'toolchain', 'tools', 'scripts', '_work', 'cli', 'source-backups'
    $list = foreach ($d in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) {
        if ($skip -contains $d.Name) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $d.FullName 'portable.ini'))) { continue }
        $exe = Get-ChildItem -LiteralPath (Join-Path $d.FullName 'Program') -Filter '*.exe' -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -ne 'mapconv.exe' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $exe) { continue }
        $info = Read-BuildInfo $d.FullName
        $src = $null; $commit = ''; $built = $exe.LastWriteTime
        if ($info -and $info.Source) { $src = [string]$info.Source; $commit = [string]$info.Commit }
        else {
            $src = $names | Where-Object { $d.Name -ieq $_ -or $d.Name.StartsWith("$_-", 'OrdinalIgnoreCase') } | Select-Object -First 1
            if (-not $src) { $src = if ($d.Name -match '^(.+)-\d{8}(-\d{4})?$') { $Matches[1] } else { $d.Name -replace '-[^-]+$', '' } }
            if ($d.Name -notmatch '-\d{8}(-\d{4})?$' -and $d.Name -match '-([0-9a-f]{7,12})$') { $commit = $Matches[1] }
        }
        if ($info -and $info.Built) {
            try { $built = [datetime]::ParseExact([string]$info.Built, 'MM/dd/yyyy HH:mm', [Globalization.CultureInfo]::InvariantCulture) } catch { }
        }
        $known = $srcCommit.ContainsKey($src)
        $now = if ($known) { $srcCommit[$src] } else { '' }
        [pscustomobject]@{
            Name = $d.Name; Path = $d.FullName; Exe = $exe.FullName; Time = $built
            Source = $src; SourceExists = $known; HasSave = (Test-HasFiles (Join-Path $d.FullName 'Save'))
            Commit = $commit; SourceCommit = $now
            Outdated = [bool]($known -and $commit -and $now -and $commit -ne $now)
            Latest = $false
        }
    }
    $list = @($list | Sort-Object Time -Descending)
    $seen = @{}
    # the current build of each source: the one with the fixed name (= source name), or else the newest
    foreach ($b in $list) { if ($b.Name -ieq $b.Source) { $b.Latest = $true; $seen[$b.Source] = $true } }
    foreach ($b in $list) { if (-not $seen.ContainsKey($b.Source)) { $b.Latest = $true; $seen[$b.Source] = $true } }
    return $list
}

function Read-Settings {
    $s = @{ Launch = $false; KeepWork = $true; Notify = $true; ShowLog = $false; Advanced = $false
            CopySave = $false; Defender = $false; Config = 'Release'; VerifiedAt = ''; Theme = 'auto'; AutoUpdate = $true }
    try {
        if (Test-Path -LiteralPath $settingsFile) {
            $j = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
            foreach ($k in @($s.Keys)) {
                if ($null -ne $j.$k) { $s[$k] = if ($s[$k] -is [bool]) { [bool]$j.$k } else { [string]$j.$k } }
            }
        }
    } catch { }
    return $s
}

function Save-Settings {
    try {
        [pscustomobject]@{
            Launch     = [bool]$ui.ChkLaunch.IsChecked
            KeepWork   = [bool]$ui.ChkKeep.IsChecked
            Notify     = [bool]$ui.ChkNotify.IsChecked
            ShowLog    = [bool]$ui.LogExpander.IsExpanded
            Advanced   = [bool]$ui.ChkAdvanced.IsChecked
            CopySave   = [bool]$ui.ChkCopySave.IsChecked
            Defender   = [bool]$ui.ChkDefender.IsChecked
            Config     = [string]$ui.CmbConfig.Text
            VerifiedAt = [string]$state.VerifiedAt
            Theme      = $(if ($ui.CmbTheme.SelectedItem) { [string]$ui.CmbTheme.SelectedItem.Tag } else { 'auto' })
            AutoUpdate = [bool]$settings.AutoUpdate
        } | ConvertTo-Json | Set-Content -LiteralPath $settingsFile -Encoding ascii
    } catch { }
}

function New-Window([string]$x) {
    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml($x)
    return [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $doc))
}

# ---------------------------------------------------------------- theme (light / dark)
# Every color of the windows comes from these palettes (XAML uses {DynamicResource <key>}, so a theme
# change repaints everything at once).
$palettes = @{
    light = @{
        Bg = '#F7F7F5'; Card = '#FFFFFF'; CardBorder = '#DCDCD6'; Text = '#1F1F1C'; Muted = '#8A8A84'; Label = '#55554F'
        LogBg = '#FBFBFA'; InputBg = '#FFFFFF'; InputBorder = '#C9C9C2'; BtnBg = '#F3F3F1'; BtnBorder = '#C9C9C2'
        BtnHover = '#E9E9E5'; BtnPressed = '#DDDDD7'; Accent = '#E2512A'; Track = '#E6E6E1'; Selection = '#FBE4DA'
        AccentHover = '#C93E17'; AccentText = '#FFFFFF'; RowHover = '#F3F3F0'
        # the icon's orange-red arrow: gradient of the main buttons (top -> bottom) and their outline
        AccentTop = '#F58552'; AccentBottom = '#D23A16'; AccentTopHover = '#F79766'; AccentBottomHover = '#DD4A22'; AccentBorder = '#A8300F'
        BannerBg = '#FFF4DD'; BannerBorder = '#E8C77A'; BannerText = '#6B4A00'
        Ok = '#2E7D32'; Bad = '#C62828'; Warn = '#8A6A00'
        OkBg = '#E3F1E4'; OkFg = '#24602A'; BadBg = '#FCE8E6'; BadFg = '#9B2C22'; InfoBg = '#E8EEF8'; InfoFg = '#284A7A'
        NeutralBg = '#F1EFE8'; NeutralFg = '#5F5E5A'; WarnBg = '#FFF4DD'; WarnFg = '#6B4A00'
    }
    dark = @{
        Bg = '#1C1C1A'; Card = '#272725'; CardBorder = '#3A3A37'; Text = '#ECECE8'; Muted = '#9C9C95'; Label = '#BDBDB6'
        LogBg = '#20201E'; InputBg = '#20201E'; InputBorder = '#4A4A46'; BtnBg = '#33332F'; BtnBorder = '#4A4A46'
        BtnHover = '#3D3D39'; BtnPressed = '#474742'; Accent = '#F0643A'; Track = '#3A3A37'; Selection = '#5A2E1F'
        AccentHover = '#F47A4F'; AccentText = '#FFFFFF'; RowHover = '#2F2F2C'
        AccentTop = '#F7915F'; AccentBottom = '#D9441E'; AccentTopHover = '#F9A274'; AccentBottomHover = '#E4532A'; AccentBorder = '#1A1A1C'
        BannerBg = '#3A3020'; BannerBorder = '#6B5520'; BannerText = '#F2D58A'
        Ok = '#7FD08A'; Bad = '#F28B82'; Warn = '#E8C56A'
        OkBg = '#233A26'; OkFg = '#8FD497'; BadBg = '#4A2522'; BadFg = '#F5A39B'; InfoBg = '#233249'; InfoFg = '#9DBDF0'
        NeutralBg = '#35352F'; NeutralFg = '#C4C3BB'; WarnBg = '#3A3020'; WarnFg = '#F2D58A'
    }
}
$brushes = New-Object System.Windows.Media.BrushConverter
function Get-Brush([string]$c) { return $brushes.ConvertFromString($c) }
function Get-PalBrush([string]$key) { return Get-Brush $script:pal[$key] }

function Get-WindowsTheme {
    # "Choose your app mode" in Windows settings: AppsUseLightTheme = 0 means dark
    try {
        $v = Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop
        if ($v -eq 0) { return 'dark' }
    } catch { }
    return 'light'
}

if (-not ('SmbDwm' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SmbDwm {
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
    // Dark or light title bar (Windows 10 2004+ uses attribute 20, older builds 19)
    public static void SetDark(IntPtr h, bool dark) {
        int v = dark ? 1 : 0;
        if (DwmSetWindowAttribute(h, 20, ref v, 4) != 0) DwmSetWindowAttribute(h, 19, ref v, 4);
    }
}
'@
}

function Set-WindowTheme($w) {
    # Puts the current palette into a window's resources and colors its title bar
    foreach ($k in $script:pal.Keys) { $w.Resources[$k] = Get-Brush $script:pal[$k] }
    # vertical gradients for the main buttons, like the arrow of the icon
    # (created with ::new and stored as the bare .NET object: a PowerShell-wrapped value would not be a Brush for WPF)
    $cc = [Windows.Media.ColorConverter]
    foreach ($pair in @(@('AccentFill', 'AccentTop', 'AccentBottom'), @('AccentFillHover', 'AccentTopHover', 'AccentBottomHover'))) {
        $c1 = [Windows.Media.Color]$cc::ConvertFromString($script:pal[$pair[1]])
        $c2 = [Windows.Media.Color]$cc::ConvertFromString($script:pal[$pair[2]])
        $brush = [System.Windows.Media.LinearGradientBrush]::new($c1, $c2, 90.0)
        $w.Resources[$pair[0]] = $brush.psobject.BaseObject
    }
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper $w).EnsureHandle()
        [SmbDwm]::SetDark($h, $script:themeName -eq 'dark')
    } catch { }
}

$script:themeName = Get-WindowsTheme
$script:pal = $palettes[$script:themeName]

# ---------------------------------------------------------------- main window
# Shared look, also used by the dialogs. Colors are {DynamicResource <palette key>}.
$resources = @'
    <Style TargetType="Border" x:Key="CardBox">
      <Setter Property="Background" Value="{DynamicResource Card}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource CardBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="14,12"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Padding" Value="12,5"/>
      <Setter Property="MinWidth" Value="80"/>
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Background" Value="{DynamicResource BtnBg}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource BtnBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5" SnapsToDevicePixels="True">
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{DynamicResource BtnHover}"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Background" Value="{DynamicResource BtnPressed}"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="Button" x:Key="AccentButton">
      <Setter Property="Padding" Value="14,5"/>
      <Setter Property="MinWidth" Value="80"/>
      <Setter Property="Foreground" Value="{DynamicResource AccentText}"/>
      <Setter Property="Background" Value="{DynamicResource AccentFill}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource AccentBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" SnapsToDevicePixels="True">
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{DynamicResource AccentFillHover}"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="Button" x:Key="IconButton" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="MinWidth" Value="0"/>
      <Setter Property="Width" Value="34"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="Padding" Value="0"/>
      <Setter Property="FontFamily" Value="Segoe Fluent Icons, Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="14"/>
    </Style>
    <Style TargetType="TextBlock" x:Key="Glyph">
      <Setter Property="FontFamily" Value="Segoe Fluent Icons, Segoe MDL2 Assets"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="0,1,7,0"/>
    </Style>
    <Style TargetType="Border" x:Key="BuildRow">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="CornerRadius" Value="7"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="Margin" Value="0,0,0,3"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{DynamicResource RowHover}"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Margin" Value="0,0,18,0"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
    </Style>
    <Style TargetType="RadioButton">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{DynamicResource InputBg}"/>
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource InputBorder}"/>
      <Setter Property="CaretBrush" Value="{DynamicResource Text}"/>
      <Setter Property="SelectionBrush" Value="{DynamicResource Accent}"/>
    </Style>
    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="{DynamicResource Card}"/>
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource CardBorder}"/>
      <Setter Property="MaxWidth" Value="360"/>
      <Setter Property="ContentTemplate">
        <Setter.Value><DataTemplate><TextBlock Text="{Binding}" TextWrapping="Wrap"/></DataTemplate></Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ProgressBar">
      <Setter Property="Foreground" Value="{DynamicResource Accent}"/>
      <Setter Property="Background" Value="{DynamicResource Track}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Track}"/>
    </Style>
    <Style TargetType="Expander">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Padding" Value="8,4"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="Bd" Background="Transparent" Padding="{TemplateBinding Padding}"><ContentPresenter/></Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource Selection}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="Bd" Background="{DynamicResource InputBg}" BorderBrush="{DynamicResource InputBorder}" BorderThickness="1" CornerRadius="5">
                      <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,10,0" Data="M 0 0 L 4 4 L 8 0"
                            Stroke="{DynamicResource Muted}" StrokeThickness="1.5"/>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter IsHitTestVisible="False" Margin="9,0,26,0" VerticalAlignment="Center" HorizontalAlignment="Left"
                                Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
              <Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False">
                <Border Background="{DynamicResource Card}" BorderBrush="{DynamicResource CardBorder}" BorderThickness="1" CornerRadius="5"
                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}" MaxHeight="{TemplateBinding MaxDropDownHeight}">
                  <ScrollViewer><ItemsPresenter/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBlock" x:Key="InfoMark">
      <Setter Property="Text" Value=" (?)"/>
      <Setter Property="Foreground" Value="{DynamicResource Muted}"/>
      <Setter Property="Cursor" Value="Help"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="ToolTipService.InitialShowDelay" Value="150"/>
      <Setter Property="ToolTipService.ShowDuration" Value="30000"/>
    </Style>
    <Style TargetType="TextBlock" x:Key="LabelText">
      <Setter Property="Foreground" Value="{DynamicResource Label}"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style TargetType="TextBlock" x:Key="MutedText">
      <Setter Property="Foreground" Value="{DynamicResource Muted}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
'@

# Tooltip texts (shown on the (?) marks)
$tips = @{
    Keep     = "_work is the build cache (about 700 MB per source).`n`nKept: the next build only recompiles what you changed (seconds to a minute).`nDeleted: the folder stays tidy, but the next build compiles everything again (a few minutes)."
    Notify   = 'Shows a Windows notification when a task finishes or fails, so you can do something else meanwhile. Click it to open the build folder.'
    Config   = "Release: the normal game. Use this one if you are not sure.`nDebug: much slower, only for finding bugs with a debugger.`nRelWithDebInfo: like Release, plus debugging information.`nMinSizeRel: like Release, optimized for size."
    Name     = "Empty: the build folder has the same name as the source folder (e.g. stepmania-fixes). Each source has one build folder: building again refreshes it and keeps its Save and the files you added.`n`nWith a name (e.g. test): the folder is stepmania-fixes-test instead."
    Clean    = 'Throws away the build cache of this source and compiles everything from zero. Only needed if something behaves strangely, or once after moving or renaming the builder folder. Takes a few minutes.'
    CopySave = 'Copies the Save folder (preferences, profiles, scores) of your newest previous build of this same source into the new build, so you keep playing with your data. Your old build is not changed.'
    Defender = "Scans the toolchain with Microsoft Defender after installing or verifying it (about 3 minutes).`nSkipping it is less secure: the files are still checked by their hashes and Microsoft signatures, but not scanned for malware."
    Toolchain= 'The compilers used to build the game: Microsoft MSVC, the Windows SDK, CMake and Ninja. They are installed once inside this folder; nothing is installed on Windows.'
    Builds   = "Your finished builds (folders next to the scripts), with the commit each one was built from.`nOutdated: the source is now at a newer commit; press Build to update the build.`nOlder copy: a build made by an older version of the builder; usually safe to delete.`nSource deleted: its source folder no longer exists.`nHas Save: it has preferences, profiles or scores; deleting it deletes them too."
    Check    = "Compares the selected source with the latest commits of its repository on GitHub, without downloading anything. You see what changed and decide whether to update.`n`nOnly for sources downloaded with Download... or git (not pasted copies or ZIPs)."
    Theme    = "Light or dark look. Auto follows the app mode chosen in Windows settings."
}
# They go inside XAML attributes: escape them, and keep their line breaks (&#10;)
foreach ($k in @($tips.Keys)) { $tips[$k] = [Security.SecurityElement]::Escape($tips[$k]) -replace "`n", '&#10;' }

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="StepMania Windows Builder" Width="700" SizeToContent="Height" MinWidth="560"
        WindowStartupLocation="CenterScreen" ResizeMode="CanResizeWithGrip"
        FontFamily="Segoe UI" FontSize="13" Background="{DynamicResource Bg}" Foreground="{DynamicResource Text}">
  <Window.Resources>
$resources
  </Window.Resources>

  <StackPanel Margin="16">
    <DockPanel Margin="0,0,0,12">
      <TextBlock Text="StepMania Windows Builder" FontSize="18" FontWeight="SemiBold" VerticalAlignment="Center"/>
      <Button x:Name="BtnHelp" DockPanel.Dock="Right" Content="Help" MinWidth="0" Margin="10,0,0,0"
              ToolTip="How to use the builder, and what every option does."/>
      <CheckBox x:Name="ChkAdvanced" DockPanel.Dock="Right" Content="Advanced" Margin="12,0,0,0" VerticalAlignment="Center"
                ToolTip="Shows the toolchain, downloading sources, build options and the list of finished builds."/>
      <ComboBox x:Name="CmbTheme" DockPanel.Dock="Right" Width="86" Height="26" ToolTip="$($tips.Theme)">
        <ComboBoxItem Content="Auto" Tag="auto"/>
        <ComboBoxItem Content="Light" Tag="light"/>
        <ComboBoxItem Content="Dark" Tag="dark"/>
      </ComboBox>
      <TextBlock DockPanel.Dock="Right" Text="Theme" Style="{StaticResource LabelText}" Margin="0,0,6,0"/>
      <TextBlock x:Name="RootText" Foreground="{DynamicResource Muted}" FontSize="11" Margin="12,0,12,0"
                 VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
    </DockPanel>

    <Border x:Name="AppUpdateBar" Visibility="Collapsed" Background="{DynamicResource Card}" BorderBrush="{DynamicResource Accent}"
            BorderThickness="1" CornerRadius="8" Padding="12,6" Margin="0,0,0,10">
      <DockPanel>
        <Button x:Name="BtnAppUpdateHide" DockPanel.Dock="Right" Style="{StaticResource IconButton}" Content="&#xE711;" Margin="6,0,0,0"
                ToolTip="Hide until the next start" AutomationProperties.Name="Hide"/>
        <Button x:Name="BtnAppUpdate" DockPanel.Dock="Right" Style="{StaticResource AccentButton}" Margin="10,0,0,0" AutomationProperties.Name="Update"
                ToolTip="Downloads the new version of the builder and restarts it. Your toolchain, sources, builds and settings are not touched.">
          <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Glyph}" Text="&#xE896;"/><TextBlock Text="Update"/></StackPanel>
        </Button>
        <TextBlock Style="{StaticResource Glyph}" Text="&#xE895;" FontSize="16" Foreground="{DynamicResource Accent}"/>
        <TextBlock x:Name="AppUpdateText" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
      </DockPanel>
    </Border>

    <Border x:Name="Banner" Visibility="Collapsed" Background="{DynamicResource BannerBg}" BorderBrush="{DynamicResource BannerBorder}"
            BorderThickness="1" CornerRadius="8" Padding="12,10" Margin="0,0,0,10">
      <StackPanel>
        <TextBlock x:Name="BannerText" TextWrapping="Wrap" Foreground="{DynamicResource BannerText}"/>
        <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
          <Button x:Name="BtnBannerInstall" Content="Install toolchain" FontWeight="SemiBold" Margin="0,0,8,0" Visibility="Collapsed"/>
          <Button x:Name="BtnBannerDownload" Content="Download a source..." FontWeight="SemiBold" Visibility="Collapsed"/>
        </StackPanel>
      </StackPanel>
    </Border>

    <Border x:Name="ToolchainCard" Style="{StaticResource CardBox}" Visibility="Collapsed">
      <DockPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
          <CheckBox x:Name="ChkDefender" Content="Defender scan" Margin="0"/>
          <TextBlock Style="{StaticResource InfoMark}" Margin="0,0,12,0" ToolTip="$($tips.Defender)"/>
          <Button x:Name="BtnInstall" Content="Install" Margin="0,0,8,0"/>
          <Button x:Name="BtnVerify" Content="Verify"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock Text="Toolchain" FontWeight="SemiBold"/>
          <TextBlock Style="{StaticResource InfoMark}" ToolTip="$($tips.Toolchain)"/>
          <Border x:Name="TcPill" CornerRadius="6" Padding="8,1" Margin="10,0,0,0" VerticalAlignment="Center">
            <TextBlock x:Name="TcText" FontSize="12"/>
          </Border>
        </StackPanel>
      </DockPanel>
    </Border>

    <Border Style="{StaticResource CardBox}">
      <StackPanel>
        <DockPanel>
          <TextBlock Text="Source" Style="{StaticResource LabelText}" Width="60"/>
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
            <Button x:Name="BtnRefresh" Content="Refresh" MinWidth="0" Margin="8,0,0,0"
                    ToolTip="Look again for sources in the source folder (e.g. after pasting one)."/>
            <Button x:Name="BtnCheck" Content="Check updates" MinWidth="0" Margin="8,0,0,0" ToolTip="$($tips.Check)"/>
            <Button x:Name="BtnDownload" Content="Download..." MinWidth="0" Margin="8,0,0,0" Visibility="Collapsed"
                    ToolTip="Download StepMania, ITGmania or a fork into its own folder inside source\."/>
            <Button x:Name="BtnOpenSource" Content="Open" MinWidth="0" Margin="8,0,0,0" Visibility="Collapsed"
                    ToolTip="Open the selected source folder (to edit the code)."/>
          </StackPanel>
          <ComboBox x:Name="CmbSource" Height="28" VerticalContentAlignment="Center"/>
        </DockPanel>
        <TextBlock x:Name="SourceInfo" Margin="60,4,0,0" Style="{StaticResource MutedText}"/>

        <Grid x:Name="AdvancedOptions" Margin="0,12,0,0" Visibility="Collapsed">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="60"/>
            <ColumnDefinition Width="150"/>
            <ColumnDefinition Width="20"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Column="0" Orientation="Horizontal">
            <TextBlock Text="Config" Style="{StaticResource LabelText}"/>
            <TextBlock Style="{StaticResource InfoMark}" ToolTip="$($tips.Config)"/>
          </StackPanel>
          <ComboBox x:Name="CmbConfig" Grid.Column="1" Height="26" VerticalContentAlignment="Center">
            <ComboBoxItem Content="Release"/>
            <ComboBoxItem Content="Debug"/>
            <ComboBoxItem Content="RelWithDebInfo"/>
            <ComboBoxItem Content="MinSizeRel"/>
          </ComboBox>
          <StackPanel Grid.Column="3" Orientation="Horizontal">
            <TextBlock Text="Name" Style="{StaticResource LabelText}"/>
            <TextBlock Style="{StaticResource InfoMark}" ToolTip="$($tips.Name)" Margin="0,0,8,0"/>
          </StackPanel>
          <TextBox x:Name="TxtName" Grid.Column="4" Height="26" VerticalContentAlignment="Center"
                   ToolTip="Empty = the source's commit (or the date the source was added)"/>
          <WrapPanel Grid.Row="1" Grid.ColumnSpan="5" Margin="0,10,0,0">
            <CheckBox x:Name="ChkClean" Content="Clean (rebuild everything)" Margin="0"/>
            <TextBlock Style="{StaticResource InfoMark}" ToolTip="$($tips.Clean)" Margin="0,0,18,0"/>
            <CheckBox x:Name="ChkCopySave" Content="Copy Save from the last build" Margin="0"/>
            <TextBlock Style="{StaticResource InfoMark}" ToolTip="$($tips.CopySave)"/>
          </WrapPanel>
        </Grid>

        <WrapPanel Margin="0,12,0,12">
          <CheckBox x:Name="ChkLaunch" Content="Launch the game when done"/>
          <CheckBox x:Name="ChkKeep" Content="Keep __work" Margin="0"/>
          <TextBlock Style="{StaticResource InfoMark}" ToolTip="$($tips.Keep)" Margin="0,0,18,0"/>
          <CheckBox x:Name="ChkNotify" Content="Notify me when done" Margin="0"/>
          <TextBlock Style="{StaticResource InfoMark}" ToolTip="$($tips.Notify)"/>
        </WrapPanel>

        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Button x:Name="BtnBuild" Grid.Column="0" Style="{StaticResource AccentButton}" Height="36" FontSize="14"
                  AutomationProperties.Name="Build">
            <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Glyph}" Text="&#xE90F;"/><TextBlock Text="Build"/></StackPanel>
          </Button>
          <Button x:Name="BtnCancel" Grid.Column="1" Content="Stop" Margin="8,0,0,0" Height="36" IsEnabled="False"
                  ToolTip="Stops the running task. Your source is not affected."/>
        </Grid>
      </StackPanel>
    </Border>

    <Border Style="{StaticResource CardBox}">
      <StackPanel>
        <DockPanel>
          <TextBlock x:Name="ElapsedText" DockPanel.Dock="Right" Foreground="{DynamicResource Muted}" Margin="8,0,0,0"/>
          <TextBlock x:Name="StatusText" Text="Ready" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
        </DockPanel>
        <ProgressBar x:Name="Progress" Height="10" Margin="0,8,0,4" Minimum="0" Maximum="100" Value="0"/>
        <TextBlock x:Name="DetailText" Foreground="{DynamicResource Muted}" FontSize="12" TextTrimming="CharacterEllipsis"/>

        <StackPanel x:Name="ResultPanel" Orientation="Horizontal" Margin="0,10,0,0" Visibility="Collapsed">
          <Button x:Name="BtnPlay" Style="{StaticResource AccentButton}" Margin="0,0,8,0" AutomationProperties.Name="Play">
            <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Glyph}" Text="&#xE768;"/><TextBlock Text="Play"/></StackPanel>
          </Button>
          <Button x:Name="BtnOpen" AutomationProperties.Name="Open folder">
            <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Glyph}" Text="&#xE838;"/><TextBlock Text="Open folder"/></StackPanel>
          </Button>
        </StackPanel>

        <Expander x:Name="LogExpander" Header="Details (log)" Margin="0,10,0,0">
          <TextBox x:Name="LogBox" Height="200" Margin="0,6,0,0" IsReadOnly="True" FontFamily="Consolas" FontSize="11"
                   VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap"
                   Background="{DynamicResource LogBg}"/>
        </Expander>
      </StackPanel>
    </Border>

    <Border x:Name="BuildsCard" Style="{StaticResource CardBox}" Visibility="Collapsed">
      <StackPanel>
        <DockPanel Margin="0,0,0,6">
          <Button x:Name="BtnRefreshBuilds" DockPanel.Dock="Right" Content="Refresh" MinWidth="0"/>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock Text="Builds" FontWeight="SemiBold"/>
            <TextBlock Style="{StaticResource InfoMark}" ToolTip="$($tips.Builds)"/>
          </StackPanel>
        </DockPanel>
        <TextBlock x:Name="BuildsMsg" Visibility="Collapsed" Margin="0,0,0,6" FontSize="12" TextWrapping="Wrap"/>
        <ScrollViewer MaxHeight="230" VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="BuildsList"/>
        </ScrollViewer>
      </StackPanel>
    </Border>
  </StackPanel>
</Window>
"@

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in 'RootText', 'Banner', 'BannerText', 'BtnBannerInstall', 'BtnBannerDownload', 'BtnHelp', 'ChkAdvanced', 'CmbTheme', 'ToolchainCard', 'ChkDefender', 'BtnInstall', 'BtnVerify',
               'TcPill', 'TcText', 'CmbSource', 'BtnRefresh', 'BtnCheck', 'BtnDownload', 'BtnOpenSource', 'SourceInfo', 'AdvancedOptions',
               'CmbConfig', 'TxtName', 'ChkClean', 'ChkCopySave', 'ChkLaunch', 'ChkKeep', 'ChkNotify', 'BtnBuild', 'BtnCancel',
               'StatusText', 'ElapsedText', 'Progress', 'DetailText', 'ResultPanel', 'BtnPlay', 'BtnOpen', 'LogExpander',
               'LogBox', 'BuildsCard', 'BtnRefreshBuilds', 'BuildsMsg', 'BuildsList', 'AppUpdateBar', 'AppUpdateText', 'BtnAppUpdate', 'BtnAppUpdateHide') {
    $ui[$n] = $window.FindName($n)
}
$ui.RootText.Text = $root
$ui.RootText.ToolTip = $root
# US date format with '/', whatever the Windows language (es-CL would write 11-19-2026)
$inv = [Globalization.CultureInfo]::InvariantCulture
function Format-Date([datetime]$d, [switch]$Time) {
    if ($Time) { return $d.ToString('MM/dd/yyyy HH:mm', $inv) } else { return $d.ToString('MM/dd/yyyy', $inv) }
}

# ---------------------------------------------------------------- state
$state = @{
    Task = $null; Clock = $null; OutDir = $null; Exe = $null; SourceName = $null; Stopped = $false
    ErrorSummary = $null; ErrorLines = New-Object System.Collections.Generic.List[string]
    Problems = New-Object System.Collections.Generic.List[string]; NewSource = $null
    Notify = $null; VerifiedAt = ''; StatusRole = 'Text'; BuildsMsgRole = 'OkFg'; UpdateJson = $null
}

$settings = Read-Settings
$ui.ChkLaunch.IsChecked    = $settings.Launch
$ui.ChkKeep.IsChecked      = $settings.KeepWork
$ui.ChkNotify.IsChecked    = $settings.Notify
$ui.LogExpander.IsExpanded = $settings.ShowLog
$ui.ChkAdvanced.IsChecked  = $settings.Advanced
$ui.ChkCopySave.IsChecked  = $settings.CopySave
$ui.ChkDefender.IsChecked  = $settings.Defender
foreach ($it in $ui.CmbConfig.Items) { if ($it.Content -eq $settings.Config) { $ui.CmbConfig.SelectedItem = $it } }
if (-not $ui.CmbConfig.SelectedItem) { $ui.CmbConfig.SelectedIndex = 0 }
$state.VerifiedAt          = $settings.VerifiedAt
foreach ($it in $ui.CmbTheme.Items) { if ($it.Tag -eq $settings.Theme) { $ui.CmbTheme.SelectedItem = $it } }
if (-not $ui.CmbTheme.SelectedItem) { $ui.CmbTheme.SelectedIndex = 0 }

function Add-Log([string]$line) {
    $ui.LogBox.AppendText($line + "`r`n")
    $ui.LogBox.ScrollToEnd()
}

function Set-Status([string]$text, [string]$role = 'Text') {
    # $role: a palette key (Text, Ok, Bad, Warn), so the color follows the theme
    $state.StatusRole = $role
    $ui.StatusText.Text = $text
    $ui.StatusText.Foreground = Get-PalBrush $role
}

function Set-Theme {
    # Auto = the Windows app mode; repaints every window and every color set from code
    $choice = if ($ui.CmbTheme.SelectedItem) { [string]$ui.CmbTheme.SelectedItem.Tag } else { 'auto' }
    $script:themeName = if ($choice -eq 'auto') { Get-WindowsTheme } else { $choice }
    $script:pal = $palettes[$script:themeName]
    Set-WindowTheme $window
    $ui.StatusText.Foreground = Get-PalBrush $state.StatusRole
    $ui.BuildsMsg.Foreground = Get-PalBrush $state.BuildsMsgRole
    Update-Toolchain
    if ($ui.ChkAdvanced.IsChecked) { Update-Builds }
}

function Show-Message([string]$text, [string]$icon = 'Information', [string]$buttons = 'OK') {
    return [string][System.Windows.MessageBox]::Show($window, $text, 'StepMania Windows Builder', $buttons, $icon)
}

function Update-AdvancedView {
    $adv = [bool]$ui.ChkAdvanced.IsChecked
    $v = if ($adv) { 'Visible' } else { 'Collapsed' }
    foreach ($n in 'ToolchainCard', 'AdvancedOptions', 'BuildsCard', 'BtnDownload', 'BtnOpenSource') { $ui[$n].Visibility = $v }
    if ($adv) { Update-Builds }
}

function Update-Sources([string]$select = '') {
    $sel = $select
    $cur = Get-SelectedSource
    if (-not $sel -and $cur) { $sel = $cur.Name }
    if (-not $sel -and (Test-Path -LiteralPath $lastFile)) { $sel = "$(Get-Content -LiteralPath $lastFile -ErrorAction SilentlyContinue | Select-Object -First 1)".Trim() }
    $state.FillingSources = $true
    $ui.CmbSource.Items.Clear()
    $list = @(Get-Sources)
    foreach ($s in $list) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = '{0}   ({1})' -f $s.Name, $s.Game
        $item.Tag = $s
        [void]$ui.CmbSource.Items.Add($item)
        if ($s.Name -ieq $sel) { $ui.CmbSource.SelectedItem = $item }
    }
    $state.SourceCount = $list.Count
    if (-not $ui.CmbSource.SelectedItem -and $list.Count) { $ui.CmbSource.SelectedIndex = 0 }
    # Last entry of the list: download another source (also in compact mode)
    $dl = New-Object System.Windows.Controls.ComboBoxItem
    $dl.Content = if ($list.Count) { '+ Download another source...' } else { '+ Download a source...' }
    $dl.Tag = 'download'
    $dl.FontStyle = 'Italic'
    [void]$ui.CmbSource.Items.Add($dl)
    $state.LastSourceItem = $ui.CmbSource.SelectedItem
    $state.FillingSources = $false
    Update-Readiness
}

function Get-SelectedSource {
    # The selected source object, or $null (nothing selected, or the "+ Download..." entry)
    $it = $ui.CmbSource.SelectedItem
    if ($it -and $it.Tag -isnot [string]) { return $it.Tag }
    return $null
}

function Test-Toolchain {
    return (Test-Path -LiteralPath (Join-Path $root 'toolchain\cmake\bin\cmake.exe')) -and
           (Test-Path -LiteralPath (Join-Path $root 'toolchain\msvc\VC\Tools\MSVC')) -and
           (Test-Path -LiteralPath (Join-Path $root 'toolchain\inventory.json'))
}

function Update-Toolchain {
    if (Test-Toolchain) {
        $ui.BtnInstall.Content = 'Repair'
        $ui.BtnInstall.ToolTip = 'Downloads again only what is missing or damaged, then re-checks everything.'
        if ($state.VerifiedAt) { $ui.TcText.Text = "Verified $($state.VerifiedAt)"; $kind = 'Ok' }
        else { $ui.TcText.Text = 'Installed'; $kind = 'Info' }
    } else {
        $ui.BtnInstall.Content = 'Install'
        $ui.BtnInstall.ToolTip = 'Downloads the toolchain (about 600 MB, once) and checks every file.'
        $ui.TcText.Text = 'Not installed'; $kind = 'Bad'
    }
    $ui.TcPill.Background = Get-PalBrush "${kind}Bg"
    $ui.TcText.Foreground = Get-PalBrush "${kind}Fg"
}

function Update-Readiness {
    # Can we build? Shows a note explaining what is missing.
    $msgs = @()
    $hasToolchain = Test-Toolchain
    $hasSource = [int]$state.SourceCount -gt 0
    if (-not $hasToolchain) {
        $msgs += 'Before the first build, the builder needs its toolchain: the compilers that turn the source code into the game (Microsoft MSVC, the Windows SDK, CMake and Ninja). It is downloaded once into this folder (about 600 MB, a few minutes) and every file is checked. Nothing is installed on Windows.'
    }
    if (-not $hasSource) {
        $msgs += 'There is no source code yet. Download StepMania, ITGmania or a fork (or paste a source into its own folder inside source\ and press Refresh).'
    }
    if ($msgs.Count) { $ui.BannerText.Text = $msgs -join "`n`n"; $ui.Banner.Visibility = 'Visible' }
    else { $ui.Banner.Visibility = 'Collapsed' }
    $ui.BtnBannerInstall.Visibility  = if ($hasToolchain) { 'Collapsed' } else { 'Visible' }
    $ui.BtnBannerDownload.Visibility = if ($hasSource) { 'Collapsed' } else { 'Visible' }

    $busy = $null -ne $state.Task
    $ui.BtnBuild.IsEnabled      = (-not $busy) -and $hasToolchain -and $hasSource
    foreach ($n in 'CmbSource', 'BtnRefresh', 'BtnDownload', 'BtnInstall', 'AdvancedOptions', 'BtnRefreshBuilds',
                   'BtnBannerInstall', 'BtnBannerDownload') { $ui[$n].IsEnabled = -not $busy }
    $ui.BtnVerify.IsEnabled     = (-not $busy) -and $hasToolchain
    $ui.BtnCancel.IsEnabled     = $busy
    $sel = Get-SelectedSource
    $ui.BtnCheck.IsEnabled      = (-not $busy) -and [bool]$sel
    $ui.SourceInfo.Text = if ($sel) { $sel.Path } else { '' }
    $ui.BtnOpenSource.IsEnabled = [bool]$sel
    Update-Toolchain
}

function Show-Notification([string]$title, [string]$text, [bool]$ok) {
    if (-not $ui.ChkNotify.IsChecked) { return }
    try {
        if ($state.Notify) { $state.Notify.Dispose() }
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon = $(try { New-Object System.Drawing.Icon $iconFile, 32, 32 } catch { [System.Drawing.SystemIcons]::Application })
        $ni.Text = 'StepMania Windows Builder'
        $ni.Visible = $true
        $ni.add_BalloonTipClicked({
            if ($state.OutDir -and (Test-Path -LiteralPath $state.OutDir)) { Start-Process explorer.exe -ArgumentList "`"$($state.OutDir)`"" }
            else { $window.Activate() | Out-Null }
        })
        $icon = if ($ok) { [System.Windows.Forms.ToolTipIcon]::Info } else { [System.Windows.Forms.ToolTipIcon]::Error }
        $ni.ShowBalloonTip(8000, $title, $text, $icon)
        $state.Notify = $ni
    } catch { }
}

# ---------------------------------------------------------------- builds list
function Remove-Build($b) {
    $mb = [math]::Round((Get-ChildItem -LiteralPath $b.Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB)
    $msg = "Delete this build?`n`n$($b.Name)`nBuilt: $(Format-Date $b.Time -Time)   Size: $mb MB"
    if (-not $b.Latest) { $msg += "`nThis is an older copy: '$($b.Source)' has another, current build." } else { $msg += "`nThis is the CURRENT build of '$($b.Source)' (the next Build creates it again)." }
    if ($b.HasSave) { $msg += "`n`nIts Save folder has data (preferences, profiles, scores). It will be deleted too." }
    $msg += "`n`nIt goes to the Recycle Bin, so you can still restore it from there."
    if ((Show-Message $msg 'Warning' 'YesNo') -ne 'Yes') { return }
    try {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($b.Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
        $ui.BuildsMsg.Text = "Deleted: $($b.Name) (moved to the Recycle Bin)"
        $state.BuildsMsgRole = 'OkFg'; $ui.BuildsMsg.Foreground = Get-PalBrush 'OkFg'
    } catch {
        $ui.BuildsMsg.Text = "Could not delete $($b.Name): is the game running from it? ($($_.Exception.Message))"
        $state.BuildsMsgRole = 'BadFg'; $ui.BuildsMsg.Foreground = Get-PalBrush 'BadFg'
    }
    $ui.BuildsMsg.Visibility = 'Visible'
    if ($state.OutDir -and -not (Test-Path -LiteralPath $state.OutDir)) { $ui.ResultPanel.Visibility = 'Collapsed' }
    Update-Builds
}

function New-Tag([string]$text, [string]$kind) {
    # $kind: Ok, Bad, Info, Neutral, Warn (palette keys <kind>Bg / <kind>Fg)
    $b = New-Object System.Windows.Controls.Border
    $b.CornerRadius = 5; $b.Padding = '6,0,6,1'; $b.Margin = '6,0,0,0'; $b.Background = Get-PalBrush "${kind}Bg"
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $text; $t.FontSize = 11; $t.Foreground = Get-PalBrush "${kind}Fg"
    $b.Child = $t
    return $b
}

function Update-Builds {
    $ui.BuildsList.Children.Clear()
    $builds = @(Get-Builds)
    if (-not $builds.Count) {
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = 'No finished builds yet. They appear here after you press Build.'
        $t.Foreground = Get-PalBrush 'Muted'; $t.FontSize = 12
        [void]$ui.BuildsList.Children.Add($t)
        return
    }
    $iconFont = New-Object System.Windows.Media.FontFamily 'Segoe Fluent Icons, Segoe MDL2 Assets'
    foreach ($b in $builds) {
        $card = New-Object System.Windows.Controls.Border
        $card.Style = $window.FindResource('BuildRow')
        $row = New-Object System.Windows.Controls.DockPanel
        $card.Child = $row
        $btns = New-Object System.Windows.Controls.StackPanel
        $btns.Orientation = 'Horizontal'
        $btns.VerticalAlignment = 'Center'
        [System.Windows.Controls.DockPanel]::SetDock($btns, 'Right')

        # Play: the main action (accent color, icon + text)
        $play = New-Object System.Windows.Controls.Button
        $play.Style = $window.FindResource('AccentButton')
        $play.MinWidth = 0; $play.Height = 30; $play.Padding = '12,0'; $play.Tag = $b
        $pc = New-Object System.Windows.Controls.StackPanel
        $pc.Orientation = 'Horizontal'
        $g = New-Object System.Windows.Controls.TextBlock
        $g.Text = [string][char]0xE768; $g.FontFamily = $iconFont; $g.VerticalAlignment = 'Center'; $g.Margin = '0,1,7,0'
        $tx = New-Object System.Windows.Controls.TextBlock
        $tx.Text = 'Play'
        [void]$pc.Children.Add($g); [void]$pc.Children.Add($tx)
        $play.Content = $pc
        $play.ToolTip = "Start $([IO.Path]::GetFileName($b.Exe))"
        [System.Windows.Automation.AutomationProperties]::SetName($play, 'Play')
        $play.add_Click({ param($s) $x = $s.Tag; Start-Process -FilePath $x.Exe -WorkingDirectory $x.Path })
        [void]$btns.Children.Add($play)

        # Open folder / Delete: icon-only buttons
        foreach ($act in 'Open', 'Delete') {
            $btn = New-Object System.Windows.Controls.Button
            $btn.Style = $window.FindResource('IconButton')
            $btn.Margin = '6,0,0,0'; $btn.Tag = $b
            if ($act -eq 'Open') {
                $btn.Content = [string][char]0xE838
                $btn.ToolTip = 'Open the folder'
                $btn.add_Click({ param($s) Start-Process explorer.exe -ArgumentList "`"$($s.Tag.Path)`"" })
            } else {
                $btn.Content = [string][char]0xE74D
                $btn.Foreground = Get-PalBrush 'BadFg'
                $btn.ToolTip = 'Delete this build (it goes to the Recycle Bin; you are asked first)'
                $btn.add_Click({ param($s) Remove-Build $s.Tag })
            }
            [System.Windows.Automation.AutomationProperties]::SetName($btn, $(if ($act -eq 'Open') { 'Open' } else { 'Delete' }))
            [void]$btns.Children.Add($btn)
        }
        [void]$row.Children.Add($btns)

        $info = New-Object System.Windows.Controls.StackPanel
        $line1 = New-Object System.Windows.Controls.StackPanel
        $line1.Orientation = 'Horizontal'
        $name = New-Object System.Windows.Controls.TextBlock
        $name.Text = $b.Name; $name.FontWeight = 'SemiBold'
        [void]$line1.Children.Add($name)
        if (-not $b.Latest) { [void]$line1.Children.Add((New-Tag 'Older copy' 'Neutral')) }
        if ($b.Outdated) {
            $t = New-Tag 'Outdated' 'Warn'
            $t.ToolTip = "Built from commit $($b.Commit); the source is now at $($b.SourceCommit). Select the source and press Build to update it."
            [void]$line1.Children.Add($t)
        }
        if (-not $b.SourceExists) { [void]$line1.Children.Add((New-Tag 'Source deleted' 'Bad')) }
        if ($b.HasSave) { [void]$line1.Children.Add((New-Tag 'Has Save' 'Info')) }
        $line2 = New-Object System.Windows.Controls.TextBlock
        $parts = @()
        $parts += if ($b.Commit) { "commit $($b.Commit)" } else { 'no git information' }
        $parts += "built $(Format-Date $b.Time -Time)"
        if ($b.Name -ine $b.Source) { $parts += "source: $($b.Source)" }
        $line2.Text = $parts -join '   '
        $line2.Foreground = Get-PalBrush 'Muted'; $line2.FontSize = 12
        [void]$info.Children.Add($line1)
        [void]$info.Children.Add($line2)
        $info.VerticalAlignment = 'Center'
        [void]$row.Children.Add($info)
        [void]$ui.BuildsList.Children.Add($card)
    }
}

# ---------------------------------------------------------------- reading the task output
$reStep    = '^==> \[(\d+)/(\d+)\] (.+)$'
$reBar     = '^\s{4}(\S.*?)\s+\[[#\-]{10,}\]\s+(\d{1,3})%\s*(.*)$'
$reSpinner = '^\s{4}[|/\\-] (.+?)\s+\(in progress, (\d\d:\d\d)\)'
$reCurl    = '^[#\s]*?(\d{1,3}(?:\.\d)?)%\s*$'
$reGit     = '^\s*(Receiving objects|Resolving deltas|Updating files|Checking out files|Counting objects|Compressing objects|remote: [A-Za-z ]+):\s+(\d{1,3})%'

function Read-TaskLine([string]$line) {
    if ($line -match $reBar) {
        $ui.Progress.IsIndeterminate = $false
        $ui.Progress.Value = [int]$Matches[2]
        $ui.DetailText.Text = ('{0}  {1}%  {2}' -f $Matches[1], $Matches[2], $Matches[3].Trim())
        return
    }
    if ($line -match $reSpinner) {
        $ui.Progress.IsIndeterminate = $true
        $ui.DetailText.Text = $Matches[1] + '...'
        return
    }
    if ($line -match $reCurl) {                                   # curl's download bar (toolchain, MinGit)
        $ui.Progress.IsIndeterminate = $false
        $ui.Progress.Value = [double]$Matches[1]
        $ui.DetailText.Text = 'Downloading  ' + $Matches[1] + '%'
        return
    }
    if ($line -match $reGit) {                                    # git clone progress
        $ui.Progress.IsIndeterminate = $false
        $ui.Progress.Value = [int]$Matches[2]
        $ui.DetailText.Text = ('{0}  {1}%' -f ($Matches[1] -replace '^remote: ', ''), $Matches[2])
        return
    }
    if (-not $line.Trim()) { return }                             # blank line / erased spinner
    if ($line.StartsWith('##JSON ')) { $state.UpdateJson = $line.Substring(7); return }   # result of update-source.ps1

    if ($line -match $reStep) {
        $ui.Progress.IsIndeterminate = $false
        $ui.Progress.Value = 0
        # "Syncing source: C:\...\source\x -> C:\...\stage" -> "Syncing source" (the paths go to the detail line)
        $stepNum = $Matches[1]; $stepTotal = $Matches[2]; $stepText = $Matches[3]; $stepPath = ''
        if ($stepText -match '^(.+?):\s+([A-Za-z]:\\.*)$') { $stepText = $Matches[1]; $stepPath = $Matches[2] }
        Set-Status ('{0} - step {1} of {2}: {3}' -f $state.Task.Title, $stepNum, $stepTotal, $stepText)
        $ui.DetailText.Text = $stepPath
    }
    elseif ($line -match '^==> (.+)$') {                          # get-source steps have no numbers
        Set-Status ('{0}: {1}' -f $state.Task.Title, $Matches[1])
    }
    elseif ($line -match '^(Cloning into .+|Submodule path .+: checked out .+)$') { $ui.DetailText.Text = $Matches[1] }
    elseif ($line -match '^Clean build ready: (.+?)\s+\(\d+ MB\)\s*$') { $state.OutDir = $Matches[1] }
    elseif ($line -match '^Executable: (.+)$') { $state.Exe = $Matches[1].Trim() }
    elseif ($line -match ' source ready in (.+?)\s+\(commit ') { $state.NewSource = $Matches[1] }
    elseif ($line -match '^\s+- (NEW|MODIFIED|MISSING|INVALID SIGNATURE)') { $state.Problems.Add($line.Trim()) }
    elseif ($line -match '(?i)(: (fatal )?error [A-Z]+\d+|^CMake Error|^FAILED:|^fatal: )') {
        if ($state.ErrorLines.Count -lt 400) { $state.ErrorLines.Add($line.Trim()) }
    }
    elseif ($line -match 'FullyQualifiedErrorId : (.+)$') {
        # PowerShell's error record: its id is the first line of the script's message (same in every language)
        if (-not $state.ErrorSummary) { $state.ErrorSummary = $Matches[1].Trim() }
    }
    if ($line -match '^\s*(\+ |\+$|~)') { return }                # PowerShell's error decoration
    Add-Log $line
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(120)
$timer.add_Tick({
    $t = $state.Task
    if (-not $t) { return }
    $line = $null
    $n = 0
    while ($n -lt 400 -and $t.Runner.Lines.TryDequeue([ref]$line)) { Read-TaskLine $line; $n++ }
    if ($state.Clock) { $ui.ElapsedText.Text = '{0:mm\:ss}' -f $state.Clock.Elapsed }
    if ($t.Runner.Finished -and $t.Runner.Lines.IsEmpty) { Complete-Task $t.Runner.ExitCode }
})

function Start-Task([string]$kind, [string]$title, [string]$script, [string[]]$taskArgs) {
    $state.OutDir = $null; $state.Exe = $null; $state.Stopped = $false; $state.ErrorSummary = $null; $state.NewSource = $null
    $state.UpdateJson = $null
    $state.ErrorLines.Clear(); $state.Problems.Clear()
    $ui.LogBox.Clear()
    $ui.ResultPanel.Visibility = 'Collapsed'
    $ui.DetailText.ToolTip = $null
    $ui.Progress.Value = 0
    $ui.ElapsedText.Text = '00:00'
    Set-Status "$($title): starting"
    $ui.DetailText.Text = ''

    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f (Join-Path $scriptsDir $script))) + $taskArgs
    Add-Log ("> $script " + ($taskArgs -join ' '))
    $enc = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
    $r = New-Object SmbRunner
    try {
        $r.Start('powershell.exe', ($all -join ' '), $root, $enc)
    } catch {
        Set-Status "Could not start: $title" 'Bad'
        Add-Log $_.Exception.Message
        return
    }
    $state.Task = @{ Kind = $kind; Title = $title; Runner = $r }
    $state.Clock = [Diagnostics.Stopwatch]::StartNew()
    Update-Readiness
    Save-Settings
    $timer.Start()
}

function Show-Failure([string]$what, [int]$code) {
    Set-Status "$what failed" 'Bad'
    $first = @($state.ErrorLines | Where-Object { $_ -notmatch '^FAILED:' } | Select-Object -First 1)
    $ui.DetailText.Text = if ($first) { $first[0] }
                          elseif ($state.ErrorSummary) { $state.ErrorSummary }
                          else { "Exit code $code. Open Details (log) to see why." }
    $ui.DetailText.ToolTip = $ui.DetailText.Text
    $ui.LogExpander.IsExpanded = $true
}

function Complete-Task([int]$code) {
    $timer.Stop()
    $state.Clock.Stop()
    $t = $state.Task
    $state.Task = $null
    $ui.Progress.IsIndeterminate = $false
    $elapsed = '{0:mm\:ss}' -f $state.Clock.Elapsed

    if ($state.Stopped) {
        Set-Status 'Stopped' 'Warn'
        $ui.Progress.Value = 0
        $ui.DetailText.Text = "$($t.Title) was stopped. Your source is not affected."
    }
    elseif ($code -eq 2 -and $t.Kind -eq 'download') {
        Set-Status 'Download cancelled' 'Warn'
        $ui.DetailText.Text = 'Nothing was changed.'
    }
    else {
        switch ($t.Kind) {
            'build' {
                if ($code -eq 0 -and $state.OutDir) {
                    $ui.Progress.Value = 100
                    Set-Status "Done in $elapsed" 'Ok'
                    $ui.DetailText.Text = $state.OutDir
                    $ui.ResultPanel.Visibility = 'Visible'
                    Show-Notification 'Build finished' ("{0}  ({1})" -f (Split-Path $state.OutDir -Leaf), $elapsed) $true
                    if ($ui.ChkLaunch.IsChecked -and $state.Exe -and (Test-Path -LiteralPath $state.Exe)) {
                        Start-Process -FilePath $state.Exe -WorkingDirectory $state.OutDir
                    }
                    $ui.ChkClean.IsChecked = $false        # Clean is a one-time option
                } else {
                    Show-Failure 'Build' $code
                    Show-Notification 'Build failed' ("{0}: see the log in the builder window" -f $state.SourceName) $false
                }
            }
            'download' {
                if ($code -eq 0) {
                    $ui.Progress.Value = 100
                    $leaf = if ($state.NewSource) { Split-Path $state.NewSource -Leaf } else { '' }
                    Set-Status "Source downloaded in $elapsed" 'Ok'
                    $ui.DetailText.Text = if ($state.NewSource) { $state.NewSource } else { '' }
                    Update-Sources $leaf
                    Show-Notification 'Download finished' "source\$leaf is ready to build" $true
                } else {
                    Show-Failure 'Download' $code
                    Show-Notification 'Download failed' 'See the log in the builder window' $false
                }
            }
            'setup' {
                if ($code -eq 0) {
                    $ui.Progress.Value = 100
                    $state.VerifiedAt = Format-Date (Get-Date)   # setup checks every file and signature
                    Set-Status "Toolchain ready ($elapsed)" 'Ok'
                    $ui.DetailText.Text = 'Installed and checked (hashes and Microsoft signatures).'
                    Show-Notification 'Toolchain ready' 'You can build now' $true
                } else {
                    Show-Failure 'Toolchain install' $code
                    Show-Notification 'Toolchain install failed' 'See the log in the builder window' $false
                }
            }
            'verify' {
                if ($code -eq 0) {
                    $ui.Progress.Value = 100
                    $state.VerifiedAt = Format-Date (Get-Date)
                    Set-Status 'Toolchain OK' 'Ok'
                    $ui.DetailText.Text = 'Every file matches the inventory and the signatures are valid.'
                    Show-Notification 'Toolchain OK' 'Every file matches the inventory' $true
                } else {
                    $state.VerifiedAt = ''
                    Set-Status 'Toolchain NOT verified' 'Bad'
                    $ui.DetailText.Text = if ($state.Problems.Count) { "$($state.Problems.Count) problem(s), e.g. $($state.Problems[0]). Press Repair, or see the log." }
                                          else { 'See the log. Press Repair to download the damaged files again.' }
                    $ui.DetailText.ToolTip = $ui.DetailText.Text
                    $ui.LogExpander.IsExpanded = $true
                    Show-Notification 'Toolchain NOT verified' 'See the log in the builder window' $false
                }
            }
            'check' {
                $info = $null
                if ($state.UpdateJson) { try { $info = $state.UpdateJson | ConvertFrom-Json } catch { } }
                if (-not $info) { Show-Failure 'Check for updates' $code }
                else {
                    $ui.Progress.Value = 100
                    switch ($info.Status) {
                        'available'   { Set-Status "$($info.NewCount) update(s) available for $($info.Source)" 'Ok' }
                        'uptodate'    { Set-Status "$($info.Source) is up to date" 'Ok' }
                        default       { Set-Status "Cannot check $($info.Source)" 'Warn' }
                    }
                    $ui.DetailText.Text = if ($info.RemoteSha) { "Latest commit: $($info.RemoteSha.Substring(0,7)) ($($info.RemoteDate)) on $($info.Branch)" } else { $info.Message }
                    if ($info.Status -in 'available', 'uptodate', 'local-ahead', 'diverged') { $state.PendingUpdate = $info }
                    else { [void](Show-Message $info.Message 'Information') }
                }
            }
            'update' {
                $info = $null
                if ($state.UpdateJson) { try { $info = $state.UpdateJson | ConvertFrom-Json } catch { } }
                if ($info -and $info.Status -eq 'updated') {
                    $ui.Progress.Value = 100
                    Set-Status "Updated $($info.Source) in $elapsed" 'Ok'
                    $ui.DetailText.Text = $info.Message
                    Update-Sources $info.Source
                    Show-Notification 'Source updated' $info.Message $true
                    $conf = @($info.Conflicts)
                    if ($conf.Count) {
                        [void](Show-Message ("Updated. You AND the update changed the same lines in $($conf.Count) file(s); the updated version was kept:`n`n" +
                                             (($conf | Select-Object -First 15) -join "`n") +
                                             "`n`nYour version of each one is in:`n$($info.Backup)`n`nCopy back what you need, then build.") 'Warning')
                    } elseif ($info.Backup) {
                        $ui.DetailText.Text = "$($info.Message). Your changes were re-applied (a copy is in source-backups)."
                    }
                } elseif ($info -and $info.Message) {
                    Set-Status "Update of $($info.Source) not done" 'Warn'
                    $ui.DetailText.Text = $info.Message
                    $ui.LogExpander.IsExpanded = $true
                    [void](Show-Message $info.Message 'Warning')
                } else {
                    Show-Failure 'Update' $code
                }
            }
            'appupdate' {
                $info = $null
                if ($state.UpdateJson) { try { $info = $state.UpdateJson | ConvertFrom-Json } catch { } }
                if ($info -and $info.Status -eq 'updated') {
                    $ui.Progress.Value = 100
                    Set-Status "StepMania Windows Builder updated ($elapsed)" 'Ok'
                    $ui.DetailText.Text = $info.Message
                    $state.RestartInfo = $info
                } elseif ($info -and $info.Status -eq 'uptodate') {
                    $ui.Progress.Value = 100
                    Set-Status 'StepMania Windows Builder is up to date' 'Ok'
                    $ui.DetailText.Text = $info.Message
                } elseif ($info -and $info.Message) {
                    Set-Status 'The builder was not updated' 'Warn'
                    $ui.DetailText.Text = $info.Message
                    $ui.DetailText.ToolTip = $info.Message
                    $ui.LogExpander.IsExpanded = $true
                    [void](Show-Message $info.Message 'Warning')
                } else {
                    Show-Failure 'Builder update' $code
                }
            }
        }
    }
    if ($state.RestartInfo) {
        # the new files are in place: the window restarts to load them
        $info = $state.RestartInfo
        $state.RestartInfo = $null
        $msg = "$($info.Message)`n`nThe builder will now restart to use the new version."
        if ($info.Backup) { $msg += "`n`nYou had changed some of the builder's own files; your versions were copied to:`n$($info.Backup)" }
        [void](Show-Message $msg 'Information')
        Restart-App
        return
    }
    Update-Readiness
    if ($ui.ChkAdvanced.IsChecked) { Update-Builds }
    Save-Settings
    # The updates window opens after the main window is refreshed (and may start the update task)
    if ($state.PendingUpdate) {
        $info = $state.PendingUpdate
        $state.PendingUpdate = $null
        if ((Show-UpdatesDialog $info) -eq 'update') { Start-Update $info }
    }
}

# ---------------------------------------------------------------- actions
function Start-Check {
    $sel = Get-SelectedSource
    if (-not $sel) { return }
    Start-Task 'check' "Checking $($sel.Name) for updates" 'update-source.ps1' @('-Source', ('"{0}"' -f $sel.Path), '-Check', '-Json')
}

function Start-Update($info) {
    Start-Task 'update' "Updating $($info.Source)" 'update-source.ps1' @('-Source', ('"{0}"' -f $info.Path), '-Json')
}

# ---------------------------------------------------------------- updates of the builder itself
# The check runs in its own background process (not as a task), so it never blocks a build and
# the window stays responsive. Its result: the bar at the top, and the Updates box in Help.
function Get-AppVersion {
    $f = Join-Path $scriptsDir '.app-version.json'
    try { if (Test-Path -LiteralPath $f) { $v = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json; if ($v.Commit -match '^[0-9a-f]{40}$') { return $v } } } catch { }
    return $null
}

$appTimer = New-Object System.Windows.Threading.DispatcherTimer
$appTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$appTimer.add_Tick({
    $c = $state.AppCheck
    if (-not $c) { $appTimer.Stop(); return }
    $line = $null
    while ($c.Runner.Lines.TryDequeue([ref]$line)) { if ($line.StartsWith('##JSON ')) { $c.Json = $line.Substring(7) } }
    if ($c.Runner.Finished -and $c.Runner.Lines.IsEmpty) {
        $appTimer.Stop()
        $state.AppCheck = $null
        $info = $null
        if ($c.Json) { try { $info = $c.Json | ConvertFrom-Json } catch { } }
        $state.AppInfo = $info
        $state.AppChecked = $true
        if ($info -and $info.Status -eq 'available') { Show-AppUpdateBar $info }
        elseif ($info -and $info.Status -eq 'uptodate') { $ui.AppUpdateBar.Visibility = 'Collapsed' }
        Update-HelpVersion
    }
})

function Start-AppCheck {
    if ($state.AppCheck) { return }
    $r = New-Object SmbRunner
    $a = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $scriptsDir 'update-app.ps1')`" -Check -Json"
    try { $r.Start('powershell.exe', $a, $root, [Text.Encoding]::ASCII) } catch { return }
    $state.AppCheck = @{ Runner = $r; Json = $null }
    $appTimer.Start()
    Update-HelpVersion
}

function Show-AppUpdateBar($info) {
    $date = if ($info.Latest.Date) { ([string]$info.Latest.Date).Substring(0, 10) } else { '' }
    $ui.AppUpdateText.Text = if ($info.Known -and [int]$info.NewCount -gt 0) {
        "New version available: $($info.NewCount) new change(s), the latest from $date"
    } else {
        "New version available (latest change $date)"
    }
    $tip = @("Latest: $($info.Latest.Message)")
    if (@($info.Changes).Count) { $tip += ''; $tip += @($info.Changes) }
    $ui.AppUpdateText.ToolTip = $tip -join "`n"
    $ui.AppUpdateBar.Visibility = 'Visible'
}

function Start-AppUpdate {
    if ($state.Task) {
        [void](Show-Message "Wait until '$($state.Task.Title)' finishes, then press Update again." 'Information')
        return
    }
    $info = $state.AppInfo
    $msg = "Update StepMania Windows Builder to the latest version?`n`n"
    if ($info -and @($info.Changes).Count) { $msg += "What is new:`n" + ((@($info.Changes) | Select-Object -First 10 | ForEach-Object { "- $_" }) -join "`n") + "`n`n" }
    $msg += "The builder restarts when it is done. The toolchain, your sources, builds and settings are not touched. " +
            "If you changed any of the builder's own files, they are copied to app-backups\ first."
    if ((Show-Message $msg 'Question' 'YesNo') -ne 'Yes') { return }
    $ui.AppUpdateBar.Visibility = 'Collapsed'
    Start-Task 'appupdate' 'Updating StepMania Windows Builder' 'update-app.ps1' @('-Json')
}

function Restart-App {
    Save-Settings
    Start-Process powershell.exe -WorkingDirectory $root -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden',
                                                                         '-File', ('"{0}"' -f (Join-Path $scriptsDir 'gui.ps1')))
    $window.Close()
}

function Update-HelpVersion {
    # Refreshes the Updates box of the Help window, if it is open
    if (-not $script:help) { return }
    $c = $script:help.C
    $v = Get-AppVersion
    $c.VersionText.Text = if ($v) { "This copy: commit $($v.Commit.Substring(0, 7))$(if ($v.Date) { " ($($v.Date))" })" }
                          else { 'This copy: unknown version' }
    $c.BtnCheckApp.IsEnabled = -not $state.AppCheck
    $c.BtnHelpUpdate.Visibility = 'Collapsed'
    $s = $c.AppUpdateStatus
    $s.Foreground = Get-PalBrush 'Text'
    $s.Visibility = 'Visible'
    $i = $state.AppInfo
    if ($state.AppCheck) { $s.Text = 'Checking GitHub...' }
    elseif (-not $state.AppChecked) { $s.Visibility = 'Collapsed' }
    elseif (-not $i) { $s.Text = 'Could not check for updates (no answer from GitHub). Try again later.'; $s.Foreground = Get-PalBrush 'Warn' }
    elseif ($i.Status -eq 'uptodate') { $s.Text = 'You have the latest version.'; $s.Foreground = Get-PalBrush 'Ok' }
    elseif ($i.Status -eq 'available') { $s.Text = $i.Message; $c.BtnHelpUpdate.Visibility = 'Visible' }
    else { $s.Text = $i.Message; $s.Foreground = Get-PalBrush 'Warn' }
}

function Show-UpdatesDialog($info) {
    # Shows what changed between your copy and GitHub. Returns 'update' if the user presses Update.
    $ux = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Updates for $([Security.SecurityElement]::Escape($info.Source))" Width="640" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" FontSize="13"
        Background="{DynamicResource Bg}" Foreground="{DynamicResource Text}">
  <Window.Resources>
$resources
  </Window.Resources>
  <StackPanel Margin="16">
    <TextBlock x:Name="Head" FontSize="15" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,0,0,8"/>
    <TextBlock x:Name="Versions" TextWrapping="Wrap" Margin="0,0,0,4"/>
    <TextBlock x:Name="Summary" Style="{StaticResource MutedText}" Margin="0,0,0,10"/>
    <Border x:Name="ListBox" BorderBrush="{DynamicResource CardBorder}" BorderThickness="1" CornerRadius="6"
            Background="{DynamicResource Card}" Margin="0,0,0,10" Visibility="Collapsed">
      <ScrollViewer MaxHeight="260" VerticalScrollBarVisibility="Auto">
        <StackPanel x:Name="Commits" Margin="10,6"/>
      </ScrollViewer>
    </Border>
    <Border x:Name="Warn" Background="{DynamicResource WarnBg}" CornerRadius="6" Padding="10,8" Margin="0,0,0,12" Visibility="Collapsed">
      <TextBlock x:Name="WarnText" TextWrapping="Wrap" Foreground="{DynamicResource WarnFg}"/>
    </Border>
    <DockPanel>
      <Button x:Name="BtnWeb" Content="View on GitHub" DockPanel.Dock="Left"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="BtnLater" Content="Not now" IsCancel="True" Margin="0,0,8,0"/>
        <Button x:Name="BtnUpdate" Content="Update" FontWeight="SemiBold" IsDefault="True"/>
      </StackPanel>
    </DockPanel>
  </StackPanel>
</Window>
"@
    $script:upd = @{ Win = (New-Window $ux); Answer = ''; Url = $info.CompareUrl }
    $w = $script:upd.Win
    $w.Owner = $window
    $w.Icon = $window.Icon
    Set-WindowTheme $w
    $f = @{}
    foreach ($n in 'Head', 'Versions', 'Summary', 'ListBox', 'Commits', 'Warn', 'WarnText', 'BtnWeb', 'BtnLater', 'BtnUpdate') { $f[$n] = $w.FindName($n) }

    $f.Versions.Text = "Your copy:  $($info.LocalSha.Substring(0,7))  ($($info.LocalDate))`nLatest:  $($info.RemoteSha.Substring(0,7))  ($($info.RemoteDate))  on branch $($info.Branch) of github.com/$($info.Owner)/$($info.Repo)"
    $canUpdate = $false
    switch ($info.Status) {
        'available' {
            $f.Head.Text = "$($info.NewCount) new commit(s) available"
            $parts = @("$($info.FileCount) file(s) changed")
            $areas = @($info.Areas | Select-Object -First 5 | ForEach-Object { "$($_.Name) $($_.Count)" })
            if ($areas.Count) { $parts[0] += " ($($areas -join ', '))" }
            if (@($info.Submodules).Count) { $parts += "submodules updated: $(@($info.Submodules) -join ', ')" }
            $f.Summary.Text = $parts -join '  -  '
            $canUpdate = $true
        }
        'uptodate'    { $f.Head.Text = 'You are up to date'; $f.Summary.Text = 'Your copy already has the latest commit of this branch.' }
        'local-ahead' { $f.Head.Text = 'Nothing to download'; $f.Summary.Text = 'Your copy has commits that are not on GitHub (it is ahead). There is nothing new to get.' }
        default       { $f.Head.Text = 'Cannot update automatically'; $f.Summary.Text = 'Your copy and GitHub have both changed (your copy has commits that are not on GitHub). Download it again with Download... if you want the GitHub version.' }
    }

    foreach ($c in @($info.Commits)) {
        $g = New-Object System.Windows.Controls.DockPanel
        $g.Margin = '0,3,0,3'
        $sha = New-Object System.Windows.Controls.TextBlock
        $sha.Text = $c.Sha; $sha.FontFamily = 'Consolas'; $sha.Width = 64; $sha.Foreground = Get-PalBrush 'Muted'
        $when = New-Object System.Windows.Controls.TextBlock
        $when.Text = "$($c.Date)  $($c.Author)"; $when.Foreground = Get-PalBrush 'Muted'; $when.FontSize = 12; $when.Margin = '10,0,0,0'
        [System.Windows.Controls.DockPanel]::SetDock($sha, 'Left'); [System.Windows.Controls.DockPanel]::SetDock($when, 'Right')
        $msg = New-Object System.Windows.Controls.TextBlock
        $msg.Text = $c.Message; $msg.TextWrapping = 'Wrap'
        [void]$g.Children.Add($sha); [void]$g.Children.Add($when); [void]$g.Children.Add($msg)
        [void]$f.Commits.Children.Add($g)
    }
    if (@($info.Commits).Count) { $f.ListBox.Visibility = 'Visible' }

    $mine = @($info.LocalChanges)
    if ($canUpdate -and $mine.Count) {
        $list = ($mine | Select-Object -First 6) -join ', '
        if ($mine.Count -gt 6) { $list += ", ... ($($mine.Count) in total)" }
        $f.WarnText.Text = "You changed $($mine.Count) file(s) in this source: $list.`n`nThey are copied to source-backups\ first, then re-applied after the update. If the update changed the same lines, the updated file is kept and you are told which ones (your version stays in the backup)."
        $f.Warn.Visibility = 'Visible'
    } elseif ($canUpdate -and $null -eq $info.LocalChanges) {
        $f.WarnText.Text = 'git was not found, so your own changes could not be checked. The update needs git: download any source once with Download... (it installs a portable git if needed).'
        $f.Warn.Visibility = 'Visible'
        $canUpdate = $false
    }

    if ($canUpdate) { $f.BtnLater.Content = 'Not now' } else { $f.BtnUpdate.Visibility = 'Collapsed'; $f.BtnLater.Content = 'Close' }
    $f.BtnWeb.add_Click({ if ($script:upd.Url) { Start-Process $script:upd.Url } })
    $f.BtnUpdate.add_Click({ $script:upd.Answer = 'update'; $script:upd.Win.Close() })
    [void]$w.ShowDialog()
    return $script:upd.Answer
}

function Start-Build {
    $src = Get-SelectedSource
    if (-not $src) { return }
    $name = $ui.TxtName.Text.Trim()
    if ($name -and $name -notmatch '^[A-Za-z0-9][A-Za-z0-9._\-]*$') {
        [void](Show-Message "The name '$name' cannot be used in a folder name.`nUse letters, numbers, '.', '-' or '_' (no spaces)." 'Warning')
        return
    }
    $state.SourceName = $src.Name

    # One build folder per source: if the source moved to another commit, ask before updating its build
    $useName = if ($ui.ChkAdvanced.IsChecked) { $name } else { '' }
    $plan = Get-BuildPlan -BuilderRoot $root -SourcePath $src.Path -SourceName $src.Name -Name $useName
    if ($plan.NeedsUpdate) {
        $old = Get-Item -LiteralPath $plan.Existing
        $info = Read-BuildInfo $plan.Existing
        $built = if ($info -and $info.Built) { $info.Built } else { Format-Date $old.LastWriteTime -Time }
        $lines = @("There is already a build of '$($src.Name)': $($old.Name)   (built $built)", '')
        if ($plan.Changed) { $lines += "It was built from commit $($plan.OldCommit); the source is now at commit $($plan.Commit)." }
        if ($plan.Rename)  { $lines += "It has the name an older version of the builder used; it will be renamed to '$($plan.Folder)'." }
        $lines += '', 'Update that build?', '',
                  'Yes: it is refreshed. Its Save (preferences, profiles, scores) and the files you added (themes, noteskins, songs...) are kept.',
                  'No: nothing is built and the build stays as it is.'
        if ((Show-Message ($lines -join "`n") 'Question' 'YesNo') -ne 'Yes') { Set-Status 'Build cancelled' 'Warn'; $ui.DetailText.Text = "$($old.Name) was left as it is."; return }
    }

    $a = @()
    if ($src.Path -ine $sourceRoot) { $a += @('-Source', ('"{0}"' -f $src.Path)) }    # a single source pasted in source\ needs no -Source
    $a += @('-DeleteWork', $(if ($ui.ChkKeep.IsChecked) { 'no' } else { 'yes' }))
    $a += @('-UpdateBuild', 'yes')         # already asked above
    if ($ui.ChkAdvanced.IsChecked) {
        $a += @('-Config', $ui.CmbConfig.Text)
        if ($name) { $a += @('-Name', $name) }
        if ($ui.ChkClean.IsChecked) { $a += '-Clean' }
        if ($ui.ChkCopySave.IsChecked) { $a += '-CopySave' }
    }
    Start-Task 'build' "Building $($src.Name)" 'build.ps1' $a
}

function Start-Toolchain([string]$which) {
    $def = if ($ui.ChkDefender.IsChecked) { 'scan' } else { 'skip' }
    if ($which -eq 'setup') {
        Start-Task 'setup' 'Installing the toolchain' 'setup-toolchain.ps1' @('-Defender', $def)
    } else {
        Start-Task 'verify' 'Verifying the toolchain' 'verify-toolchain.ps1' @('-Defender', $def)
    }
}

function Show-WelcomeDialog {
    # First start: explains the toolchain and lets the user pick the optional Defender scan (off by default)
    $wx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="StepMania Windows Builder" Width="520" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" FontSize="13" Background="{DynamicResource Bg}" Foreground="{DynamicResource Text}">
  <Window.Resources>
$resources
  </Window.Resources>
  <StackPanel Margin="18">
    <TextBlock x:Name="Heading" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,10"/>
    <TextBlock TextWrapping="Wrap" Margin="0,0,0,10"
               Text="The builder needs its toolchain: the compilers that turn the source code into the game (Microsoft MSVC, the Windows SDK, CMake and Ninja)."/>
    <TextBlock TextWrapping="Wrap" Margin="0,0,0,10" FontWeight="SemiBold" Foreground="{DynamicResource Warn}"
               Text="Installing it is required: without the toolchain the builder cannot build anything."/>
    <TextBlock TextWrapping="Wrap" Margin="0,0,0,2" Text="&#8226; It is downloaded once into this folder: about 600 MB, a few minutes."/>
    <TextBlock TextWrapping="Wrap" Margin="0,0,0,2" Text="&#8226; Every file is checked (SHA-256 hashes and Microsoft signatures)."/>
    <TextBlock TextWrapping="Wrap" Margin="0,0,0,14" Text="&#8226; Nothing is installed on Windows."/>
    <Border Style="{StaticResource CardBox}" Padding="12,10" Margin="0,0,0,16">
      <StackPanel>
        <CheckBox x:Name="ChkScan" Content="Also scan the toolchain with Microsoft Defender (about 3 more minutes)" Margin="0"/>
        <TextBlock Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="22,4,0,0"
                   Text="Optional. Without it the files are still checked by their hashes and Microsoft signatures, but not scanned for malware. You can change it later in Advanced &gt; Defender scan."/>
      </StackPanel>
    </Border>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="BtnInstall" Content="Install now" Style="{StaticResource AccentButton}" IsDefault="True" Margin="0,0,8,0"/>
      <Button x:Name="BtnClose" Content="Close app" IsCancel="True"/>
    </StackPanel>
  </StackPanel>
</Window>
"@
    $script:wel = @{ Win = (New-Window $wx); Result = @{ Install = $false; Defender = $false } }
    $d = $script:wel.Win
    $d.Owner = $window
    $d.Icon = $window.Icon
    Set-WindowTheme $d
    $d.FindName('Heading').Text = if ($firstRun) { 'Welcome to StepMania Windows Builder!' } else { 'The toolchain is not installed' }
    $script:wel.Chk = $d.FindName('ChkScan')
    $script:wel.Chk.IsChecked = [bool]$ui.ChkDefender.IsChecked
    $d.FindName('BtnInstall').add_Click({ $script:wel.Result.Install = $true; $script:wel.Win.Close() })
    [void]$d.ShowDialog()
    $script:wel.Result.Defender = [bool]$script:wel.Chk.IsChecked
    return $script:wel.Result
}

function Show-DownloadDialog {
    $dx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Download source" Width="500" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" FontSize="13" Background="{DynamicResource Bg}" Foreground="{DynamicResource Text}">
  <Window.Resources>
$resources
  </Window.Resources>
  <StackPanel Margin="16">
    <TextBlock Text="What do you want to download?" FontWeight="SemiBold" Margin="0,0,0,10"/>
    <RadioButton x:Name="RbSM" GroupName="g" IsChecked="True" Margin="0,0,0,6">
      <TextBlock><Run Text="StepMania"/><Run Text="   github.com/stepmania/stepmania" Foreground="{DynamicResource Muted}"/></TextBlock>
    </RadioButton>
    <RadioButton x:Name="RbITG" GroupName="g" Margin="0,0,0,6">
      <TextBlock><Run Text="ITGmania"/><Run Text="   github.com/itgmania/itgmania" Foreground="{DynamicResource Muted}"/></TextBlock>
    </RadioButton>
    <RadioButton x:Name="RbUrl" GroupName="g" Content="Another repository (e.g. a fork)" Margin="0,0,0,6"/>
    <TextBox x:Name="TxtUrl" Height="26" Margin="22,0,0,4" VerticalContentAlignment="Center" IsEnabled="False"
             ToolTip="The HTTPS address of a public repository, e.g. https://github.com/SomeUser/stepmania-fork"/>
    <TextBlock Margin="22,0,0,10" Style="{StaticResource MutedText}"
               Text="Public repositories over HTTPS only. The builder checks the toolchain, not the source code: only use repositories you trust."/>
    <DockPanel Margin="0,4,0,4">
      <StackPanel Orientation="Horizontal" Width="110">
        <TextBlock Text="Folder name" Style="{StaticResource LabelText}"/>
        <TextBlock Style="{StaticResource InfoMark}" ToolTip="The folder inside source\ for this download. Empty = the repository name (stepmania, itgmania, or the fork's name)."/>
      </StackPanel>
      <TextBox x:Name="TxtFolder" Height="26" VerticalContentAlignment="Center"/>
    </DockPanel>
    <TextBlock x:Name="FolderHint" Margin="110,0,0,8" Style="{StaticResource MutedText}"/>
    <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
      <CheckBox x:Name="ChkFull" Content="Download the whole history" Margin="0"/>
      <TextBlock Style="{StaticResource InfoMark}" ToolTip="Off (recommended): only the latest version, about 600 MB, all that is needed to build. On: also every past commit; slower and much bigger."/>
    </StackPanel>
    <TextBlock x:Name="ErrText" Foreground="{DynamicResource Bad}" TextWrapping="Wrap" Margin="0,0,0,8" Visibility="Collapsed"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="BtnOk" Content="Download" IsDefault="True" FontWeight="SemiBold" Margin="0,0,8,0"/>
      <Button x:Name="BtnNo" Content="Cancel" IsCancel="True"/>
    </StackPanel>
  </StackPanel>
</Window>
"@
    # The dialog's state lives in $script:dl, so its button handlers always find it
    $script:dl = @{ Win = (New-Window $dx); C = @{}; Result = @{ Ok = $false } }
    $d = $script:dl.Win
    $d.Owner = $window
    $d.Icon = $window.Icon
    Set-WindowTheme $d
    foreach ($n in 'RbSM', 'RbITG', 'RbUrl', 'TxtUrl', 'TxtFolder', 'FolderHint', 'ChkFull', 'ErrText', 'BtnOk') { $script:dl.C[$n] = $d.FindName($n) }

    $script:dl.GetDefault = {
        $c = $script:dl.C
        if ($c.RbSM.IsChecked) { 'stepmania' }
        elseif ($c.RbITG.IsChecked) { 'itgmania' }
        else { (($c.TxtUrl.Text.Trim().TrimEnd('/') -split '/')[-1]) -replace '\.git$', '' }
    }
    $script:dl.Refresh = {
        $c = $script:dl.C
        $c.TxtUrl.IsEnabled = [bool]$c.RbUrl.IsChecked
        $c.ErrText.Visibility = 'Collapsed'
        $f = $c.TxtFolder.Text.Trim()
        if (-not $f) { $f = & $script:dl.GetDefault }
        $c.FolderHint.Text = if ($f) { "Will be downloaded to source\$f" } else { '' }
    }
    foreach ($rb in 'RbSM', 'RbITG', 'RbUrl') { $script:dl.C[$rb].add_Checked({ & $script:dl.Refresh }) }
    $script:dl.C.TxtUrl.add_TextChanged({ & $script:dl.Refresh })
    $script:dl.C.TxtFolder.add_TextChanged({ & $script:dl.Refresh })
    & $script:dl.Refresh

    $script:dl.C.BtnOk.add_Click({
        $c = $script:dl.C; $result = $script:dl.Result
        $err = ''
        $url = $c.TxtUrl.Text.Trim().Trim('"').TrimEnd('/')
        if ($c.RbUrl.IsChecked) {
            if (-not $url) { $err = 'Paste the address of the repository.' }
            elseif ($url -notmatch '^https://[A-Za-z0-9.\-]+(:\d+)?/[A-Za-z0-9._~%/\-]+$') { $err = 'That does not look like an HTTPS repository address (e.g. https://github.com/SomeUser/stepmania-fork).' }
        }
        $folder = $c.TxtFolder.Text.Trim()
        if (-not $err -and $folder -and ($folder -notmatch '^[A-Za-z0-9][A-Za-z0-9._ \-]*$' -or $folder -match '\.\.')) {
            $err = "The folder name can only have letters, numbers, '.', '-', '_' or spaces."
        }
        if ($err) { $c.ErrText.Text = $err; $c.ErrText.Visibility = 'Visible'; return }
        $result.Ok = $true
        $result.Game = if ($c.RbSM.IsChecked) { 'stepmania' } elseif ($c.RbITG.IsChecked) { 'itgmania' } else { '' }
        $result.Url = if ($c.RbUrl.IsChecked) { $url } else { '' }
        $result.Folder = if ($folder) { $folder } else { & $script:dl.GetDefault }
        $result.Custom = [bool]$folder
        $result.Full = [bool]$c.ChkFull.IsChecked
        $script:dl.Win.Close()
    })
    [void]$d.ShowDialog()
    return $script:dl.Result
}

function Start-Download {
    $r = Show-DownloadDialog
    if (-not $r.Ok) { return }
    $a = @()
    if ($r.Url) { $a += @('-Url', ('"{0}"' -f $r.Url)) } else { $a += @('-Game', $r.Game) }
    if ($r.Custom) { $a += @('-FolderName', ('"{0}"' -f $r.Folder)) }
    if ($r.Full) { $a += '-FullHistory' }

    # A source pasted directly in source\ (older layout) has to move into its own folder first
    $legacyName = $null
    if (Test-Path -LiteralPath (Join-Path $sourceRoot 'CMakeLists.txt')) {
        $legacyName = ((Get-GameName $sourceRoot).ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
        $ans = Show-Message ("Your source is pasted directly in the source folder.`n`nTo keep several sources side by side, each one needs its own folder, so it will be MOVED (not changed) to:`nsource\$legacyName`n`nContinue?") 'Question' 'YesNo'
        if ($ans -ne 'Yes') { return }
        $a += @('-MoveOld', 'yes')
    }

    # A source with that name already exists: keep it (new name) or replace it
    $target = Join-Path $sourceRoot $r.Folder
    $exists = ($legacyName -and $legacyName -ieq $r.Folder) -or
              ((Test-Path -LiteralPath $target) -and (Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue | Select-Object -First 1))
    if ($exists) {
        $n = 2; while (Test-Path -LiteralPath (Join-Path $sourceRoot "$($r.Folder)-$n")) { $n++ }
        $free = "$($r.Folder)-$n"
        $ans = Show-Message ("A source named '$($r.Folder)' already exists.`n`nYes: keep it, and download the new one as '$free'.`nNo: DELETE it and download it again (any change you made in it is lost).`nCancel: do nothing.") 'Question' 'YesNoCancel'
        if ($ans -eq 'Cancel') { return }
        if ($ans -eq 'No') {
            if ((Show-Message "Delete source\$($r.Folder) for good and download it again?`n`nAny change you made to its code will be lost." 'Warning' 'YesNo') -ne 'Yes') { return }
            $a += @('-IfExists', 'replace')
        } else {
            $a += @('-IfExists', 'rename')
        }
    }
    $what = if ($r.Url) { $r.Url } else { $r.Game }
    Start-Task 'download' "Downloading $what" 'get-source.ps1' $a
}

function Show-Help {
    $hx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="StepMania Windows Builder - Help" Width="620" Height="700" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{DynamicResource Bg}" Foreground="{DynamicResource Text}">
  <Window.Resources>
$resources
    <Style TargetType="TextBlock" x:Key="H"><Setter Property="FontSize" Value="15"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Margin" Value="0,14,0,6"/></Style>
    <Style TargetType="TextBlock" x:Key="P"><Setter Property="TextWrapping" Value="Wrap"/><Setter Property="Margin" Value="0,0,0,6"/><Setter Property="LineHeight" Value="19"/></Style>
  </Window.Resources>
  <DockPanel>
    <DockPanel DockPanel.Dock="Bottom" Margin="16,8,16,14">
      <Button x:Name="BtnShortcut" Content="Create desktop shortcut" DockPanel.Dock="Left"
              ToolTip="Puts a 'StepMania Windows Builder' icon on your desktop that opens this window. Create it again if you move this folder."/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="BtnReadme" Content="Open the full README" Margin="0,0,8,0"/>
        <Button x:Name="BtnClose" Content="Close" IsCancel="True"/>
      </StackPanel>
    </DockPanel>
    <Border DockPanel.Dock="Bottom" Style="{StaticResource CardBox}" Padding="12,10" Margin="16,8,16,0">
      <StackPanel>
        <DockPanel>
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="BtnHelpUpdate" Style="{StaticResource AccentButton}" Margin="0,0,8,0" Visibility="Collapsed" AutomationProperties.Name="Update now">
              <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Glyph}" Text="&#xE896;"/><TextBlock Text="Update now"/></StackPanel>
            </Button>
            <Button x:Name="BtnCheckApp" Content="Check for updates"
                    ToolTip="Compares this copy of the builder with the latest version on GitHub. Nothing is downloaded until you press Update."/>
          </StackPanel>
          <StackPanel VerticalAlignment="Center">
            <TextBlock Text="Builder updates" FontWeight="SemiBold"/>
            <TextBlock x:Name="VersionText" Style="{StaticResource MutedText}"/>
          </StackPanel>
        </DockPanel>
        <TextBlock x:Name="AppUpdateStatus" TextWrapping="Wrap" Margin="0,8,0,0" Visibility="Collapsed"/>
        <CheckBox x:Name="ChkAutoUpdate" Content="Check for updates when the app starts" Margin="0,8,0,0"/>
      </StackPanel>
    </Border>
    <ScrollViewer VerticalScrollBarVisibility="Auto">
      <StackPanel Margin="20,10,20,10">
        <TextBlock Style="{StaticResource H}" Text="How to use it" Margin="0,4,0,6"/>
        <TextBlock Style="{StaticResource P}">1. <Bold>Toolchain</Bold> (once): the first time, the builder offers to install it (or press Install toolchain in the yellow note). It downloads the compilers (about 600 MB) into this folder and checks every file. Nothing is installed on Windows. To check it again later, turn on Advanced and press Verify.</TextBlock>
        <TextBlock Style="{StaticResource P}">2. <Bold>Source</Bold>: press Download a source... (or choose + Download another source... at the end of the Source list) and pick StepMania, ITGmania or the address of a fork. Each source goes into its own folder inside source\. You can also paste a source there yourself and press Refresh.</TextBlock>
        <TextBlock Style="{StaticResource P}">3. <Bold>Build</Bold>: pick the source and press Build. The finished game appears in a folder next to the scripts with the same name as the source (e.g. stepmania-fixes). Press Play to start it.</TextBlock>
        <TextBlock Style="{StaticResource P}">Each source has <Bold>one</Bold> build folder. Building again refreshes it and keeps its Save (preferences, profiles, scores) and everything you added yourself (custom themes, noteskins, songs...): only the files that come from the source are updated. The build remembers the commit it was made from: after the source is updated to another commit, the Builds list marks it Outdated and Build asks whether to update it.</TextBlock>
        <TextBlock Style="{StaticResource P}">To change the game's code, edit the files in its folder inside source\ (press Open) and build again. The builder never modifies your source.</TextBlock>

        <TextBlock Style="{StaticResource H}" Text="Options"/>
        <TextBlock Style="{StaticResource P}"><Bold>Keep _work</Bold>: keeps the build cache, so the next build only recompiles what you changed. Without it, every build compiles everything again (a few minutes).</TextBlock>
        <TextBlock Style="{StaticResource P}"><Bold>Notify me when done</Bold>: a Windows notification when a task finishes or fails.</TextBlock>
        <TextBlock Style="{StaticResource P}"><Bold>Config</Bold> (Advanced): Release is the normal game. Debug is much slower and only useful with a debugger.</TextBlock>
        <TextBlock Style="{StaticResource P}"><Bold>Name</Bold> (Advanced): empty = the build folder has the same name as the source. With a name, it is source-name instead.</TextBlock>
        <TextBlock Style="{StaticResource P}"><Bold>Clean</Bold> (Advanced): throws away the build cache and compiles everything from zero. Only when something behaves strangely, or after moving the builder folder.</TextBlock>
        <TextBlock Style="{StaticResource P}"><Bold>Copy Save from the last build</Bold> (Advanced): copies preferences, profiles and scores from your newest previous build of the same source into the new one.</TextBlock>
        <TextBlock Style="{StaticResource P}"><Bold>Defender scan</Bold> (Advanced): scans the toolchain with Microsoft Defender after Install or Verify (about 3 minutes). Off by default; skipping it is less secure.</TextBlock>

        <TextBlock Style="{StaticResource H}" Text="Check updates"/>
        <TextBlock Style="{StaticResource P}">Compares the selected source with the latest commits of its repository on GitHub, without downloading anything. A window shows the new commits, the files and submodules they change, and the files you changed yourself. Press Update to get them, or Not now.</TextBlock>
        <TextBlock Style="{StaticResource P}">Updating never loses your work: the files you changed are first copied to source-backups\, then re-applied on top of the update. If the update changed the same lines, the updated file is kept and you are told which ones. Files you added (e.g. songs) are not touched.</TextBlock>
        <TextBlock Style="{StaticResource P}">It works for sources downloaded with Download... (or git) from GitHub. GitHub allows 60 checks per hour.</TextBlock>

        <TextBlock Style="{StaticResource H}" Text="Builder updates"/>
        <TextBlock Style="{StaticResource P}">When the app starts, it checks GitHub for a newer version of the builder itself (you can turn that off below). If there is one, a bar appears at the top: press Update. It downloads the new version, replaces the launcher, cli\, scripts\ and README.md, and restarts the app.</TextBlock>
        <TextBlock Style="{StaticResource P}">The toolchain, your sources, builds, _work and settings are never touched. If you changed one of the builder's own files, your version is copied to app-backups\ first.</TextBlock>
        <TextBlock Style="{StaticResource P}">Changes to the documentation alone (README) are not offered as an update: they arrive with the next one.</TextBlock>

        <TextBlock Style="{StaticResource H}" Text="Theme"/>
        <TextBlock Style="{StaticResource P}">Auto follows the app mode chosen in Windows settings (light or dark). Light and Dark force one of them.</TextBlock>

        <TextBlock Style="{StaticResource H}" Text="Builds list (Advanced)"/>
        <TextBlock Style="{StaticResource P}">Each build shows the commit it was built from. <Bold>Outdated</Bold>: the source is now at a newer commit (press Build to update it). <Bold>Older copy</Bold>: a build made by an older version of the builder, usually safe to delete. <Bold>Source deleted</Bold>: its source folder is gone. <Bold>Has Save</Bold>: it has your preferences, profiles or scores.</TextBlock>
        <TextBlock Style="{StaticResource P}">Delete always asks first, tells you what you would lose, and moves the folder to the Recycle Bin.</TextBlock>

        <TextBlock Style="{StaticResource H}" Text="If something fails"/>
        <TextBlock Style="{StaticResource P}">The window shows the first error and opens Details (log). The most common causes:</TextBlock>
        <TextBlock Style="{StaticResource P}">- <Bold>The source is missing git submodules</Bold>: it was downloaded with GitHub's Download ZIP. Download it again with Download... instead.</TextBlock>
        <TextBlock Style="{StaticResource P}">- <Bold>C1083 ... Invalid argument</Bold>: the builder folder path is too long for the compiler. Move it to a shorter path (e.g. D:\SMBuilder) and build with Clean.</TextBlock>
        <TextBlock Style="{StaticResource P}">- <Bold>Toolchain NOT verified</Bold>: a toolchain file changed or is missing. Press Repair.</TextBlock>
        <TextBlock Style="{StaticResource P}">- Prefer a console? The cli folder has the same steps as .bat files (1. setup-toolchain, 2. get-source, 3. build, verify-toolchain), with their options in a SETTINGS section at the top.</TextBlock>
      </StackPanel>
    </ScrollViewer>
  </DockPanel>
</Window>
"@
    $script:helpWin = New-Window $hx
    $script:helpWin.Owner = $window
    Set-WindowTheme $script:helpWin
    $script:helpWin.FindName('BtnClose').add_Click({ $script:helpWin.Close() })
    $script:helpWin.FindName('BtnReadme').add_Click({ if (Test-Path -LiteralPath $readmeFile) { Start-Process notepad.exe -ArgumentList "`"$readmeFile`"" } })
    $script:helpWin.FindName('BtnShortcut').add_Click({ New-DesktopShortcut })
    $script:helpWin.Icon = $window.Icon
    $script:help = @{ C = @{} }
    foreach ($n in 'VersionText', 'AppUpdateStatus', 'BtnHelpUpdate', 'BtnCheckApp', 'ChkAutoUpdate') { $script:help.C[$n] = $script:helpWin.FindName($n) }
    $script:help.C.ChkAutoUpdate.IsChecked = [bool]$settings.AutoUpdate
    $script:help.C.ChkAutoUpdate.add_Checked({ $settings.AutoUpdate = $true; Save-Settings })
    $script:help.C.ChkAutoUpdate.add_Unchecked({ $settings.AutoUpdate = $false; Save-Settings })
    $script:help.C.BtnCheckApp.add_Click({ Start-AppCheck })
    $script:help.C.BtnHelpUpdate.add_Click({
        $script:helpWin.Close()
        [void]$window.Dispatcher.BeginInvoke([Action]{ Start-AppUpdate })
    })
    $script:helpWin.add_Closed({ $script:help = $null })
    Update-HelpVersion
    [void]$script:helpWin.ShowDialog()
}

if (-not ('SmbShell' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SmbShell {
    [DllImport("shell32.dll")] static extern void SHChangeNotify(int eventId, uint flags, IntPtr item1, IntPtr item2);
    // Tells Explorer that icons changed, so a shortcut shows the current builder.ico (not a cached old one)
    public static void RefreshIcons() { SHChangeNotify(0x08000000, 0, IntPtr.Zero, IntPtr.Zero); }
}
'@
}

function New-BuilderShortcut([string]$LnkPath) {
    # A normal Windows shortcut (made on this PC, so nothing to unblock) that opens this window, with the
    # builder's icon. An existing one is replaced, so it never keeps an older icon or folder.
    if (Test-Path -LiteralPath $LnkPath) { Remove-Item -LiteralPath $LnkPath -Force }
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($LnkPath)
    $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$(Join-Path $scriptsDir 'gui.ps1')`""
    $lnk.WorkingDirectory = $root
    $lnk.WindowStyle = 7                    # start minimized: no console flash
    if (Test-Path -LiteralPath $iconFile) { $lnk.IconLocation = "$iconFile,0" }
    $lnk.Description = 'Build StepMania / ITGmania from source'
    $lnk.Save()
    try { [SmbShell]::RefreshIcons() } catch { }
}

function New-DesktopShortcut {
    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $lnkPath = Join-Path $desktop 'StepMania Windows Builder.lnk'
        # the shortcut made by older versions had another name: replace it instead of leaving two
        $oldLnk = Join-Path $desktop 'StepMania Builder.lnk'
        if (Test-Path -LiteralPath $oldLnk) { Remove-Item -LiteralPath $oldLnk -Force -ErrorAction SilentlyContinue }
        New-BuilderShortcut $lnkPath
        [void](Show-Message "Shortcut created on your desktop, with the builder's icon:`n$lnkPath`n`nIf you move or rename this folder, create it again." 'Information')
    } catch {
        [void](Show-Message "Could not create the shortcut: $($_.Exception.Message)" 'Warning')
    }
}

# ---------------------------------------------------------------- events
# Checked/Unchecked (not Click): they also fire for the keyboard (Space) and accessibility tools
$ui.ChkAdvanced.add_Checked({ Update-AdvancedView; Update-Readiness; Save-Settings })
$ui.ChkAdvanced.add_Unchecked({ Update-AdvancedView; Update-Readiness; Save-Settings })
$ui.BtnHelp.add_Click({ Show-Help })
$ui.BtnRefresh.add_Click({ Update-Sources })
$ui.BtnCheck.add_Click({ Start-Check })
$ui.CmbTheme.add_SelectionChanged({ if ($window.IsLoaded) { Set-Theme; Save-Settings } })
# Auto theme: if Windows switched between light and dark meanwhile, follow it when the window gets focus
$window.add_Activated({
    if ($ui.CmbTheme.SelectedItem -and $ui.CmbTheme.SelectedItem.Tag -eq 'auto' -and (Get-WindowsTheme) -ne $script:themeName) { Set-Theme }
})
$ui.BtnDownload.add_Click({ Start-Download })
$ui.BtnOpenSource.add_Click({ $s = Get-SelectedSource; if ($s) { Start-Process explorer.exe -ArgumentList "`"$($s.Path)`"" } })
$ui.CmbSource.add_SelectionChanged({
    if ($state.FillingSources) { return }
    $it = $ui.CmbSource.SelectedItem
    if ($it -and $it.Tag -is [string] -and $it.Tag -eq 'download') {
        # "+ Download..." is an action, not a source: go back to the previous choice, then open the dialog
        $ui.CmbSource.SelectedItem = $state.LastSourceItem
        $ui.CmbSource.IsDropDownOpen = $false
        [void]$window.Dispatcher.BeginInvoke([Action]{ Start-Download })
        return
    }
    $state.LastSourceItem = $it
    Update-Readiness
})
$ui.BtnAppUpdate.add_Click({ Start-AppUpdate })
$ui.BtnAppUpdateHide.add_Click({ $ui.AppUpdateBar.Visibility = 'Collapsed' })
$ui.BtnBannerInstall.add_Click({ Start-Toolchain 'setup' })
$ui.BtnBannerDownload.add_Click({ Start-Download })
$ui.BtnInstall.add_Click({ Start-Toolchain 'setup' })
$ui.BtnVerify.add_Click({ Start-Toolchain 'verify' })
$ui.BtnRefreshBuilds.add_Click({ $ui.BuildsMsg.Visibility = 'Collapsed'; Update-Builds })
$ui.BtnBuild.add_Click({ Start-Build })
$ui.BtnCancel.add_Click({
    if (-not $state.Task) { return }
    if ((Show-Message "Stop '$($state.Task.Title)' now?" 'Question' 'YesNo') -eq 'Yes' -and $state.Task) {
        $state.Stopped = $true
        Set-Status 'Stopping...' 'Warn'
        $state.Task.Runner.KillTree()
    }
})
$ui.BtnPlay.add_Click({ if ($state.Exe -and (Test-Path -LiteralPath $state.Exe)) { Start-Process -FilePath $state.Exe -WorkingDirectory $state.OutDir } })
$ui.BtnOpen.add_Click({ if ($state.OutDir -and (Test-Path -LiteralPath $state.OutDir)) { Start-Process explorer.exe -ArgumentList "`"$($state.OutDir)`"" } })
$window.add_Closing({
    param($s, $e)
    if ($state.Task) {
        if ((Show-Message "'$($state.Task.Title)' is still running. Stop it and close?" 'Warning' 'YesNo') -ne 'Yes') { $e.Cancel = $true; return }
        $state.Task.Runner.KillTree()
    }
    if ($state.AppCheck) { try { $state.AppCheck.Runner.KillTree() } catch { } }
    Save-Settings
    if ($state.Notify) { $state.Notify.Dispose() }
})

$window.add_SourceInitialized({ Set-Theme })      # the title bar color needs the window handle
# Loaded from memory: reading it straight from the file would keep builder.ico locked while the window
# is open, and the builder's own update could not replace it
try {
    $iconStream = New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($iconFile))
    $window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create($iconStream, 'None', 'OnLoad')
} catch { }

# No toolchain (first start, or it was never installed): it is required, so install it now or close the app
$window.add_ContentRendered({
    if ($script:welcomeDone) { return }
    $script:welcomeDone = $true
    if (-not (Test-Toolchain) -and -not $state.Task) {
        $w = Show-WelcomeDialog
        $ui.ChkDefender.IsChecked = $w.Defender      # the choice is kept (Advanced > Defender scan)
        Save-Settings
        if (-not $w.Install) { $window.Close(); return }
        Start-Toolchain 'setup'
    }
    # Is there a newer version of the builder? (in the background; a bar appears only if there is)
    if ($settings.AutoUpdate) { Start-AppCheck }
})
Update-AdvancedView
Update-Sources
[void]$window.ShowDialog()
