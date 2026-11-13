#Requires -Version 5.1
<#
.SYNOPSIS
    Weekly decision support (lineup / waivers / trades) for Sleeper and ESPN
    fantasy football leagues on Windows,
    with a WPF window for the report.

.DESCRIPTION
    Windows front end for fantasy_manager. The application itself is the
    Python module lib/fm_app.py, shared with fantasy_manager.sh, so both front
    ends accept the same settings and produce the same report.

    With no arguments it opens the window and loads the current week. Use
    -NoGui to print the report instead (JSON unless -Format says otherwise).

    Read-only: it cannot submit lineups, waiver claims or trades.

    Requirements: Windows PowerShell 5.1 or PowerShell 7+, Python 3.8+
    (python.org or the "py" launcher). No bash, jq or curl needed.

.EXAMPLE
    .\FantasyManager.ps1
    Opens the window for the league saved in your config file (blank the first time).

.EXAMPLE
    .\FantasyManager.ps1 -Platform espn -LeagueId 12345678 -Team "My Team Name"
    Opens the window for an ESPN league (the league must be viewable to the public).

.EXAMPLE
    .\FantasyManager.ps1 -NoGui -OutFile report.json
    Writes the JSON report without opening a window.

.EXAMPLE
    .\FantasyManager.ps1 -NoGui -Trade "Josh Allen for Kenneth Walker III" -OutFile trade.json
    Grades a trade you are considering (also available in the window's Trade Analyzer tab).

.EXAMPLE
    .\FantasyManager.ps1 -NoGui -ValueTrade "Bijan Robinson for Ja'Marr Chase, Jaylen Waddle" -Scoring half -OutFile t.json
    Grades any players for any players, e.g. a friend's offer in another league.

.EXAMPLE
    .\FantasyManager.ps1 -ReportFile report.json
    Opens a saved report in the window.
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$LeagueId,
    [string]$Username,
    [string]$Team,
    [string]$Week,
    [string]$Season,
    [string]$SeasonType,
    [string]$Top,
    [string]$Threshold,
    [string]$Fairness,
    [string]$Horizon,
    [string]$Locked,
    [string]$Trade,
    [string]$ValueTrade,
    [string]$Scoring,
    [string]$Teams,
    [switch]$SkipWaivers,
    [switch]$SkipTrades,
    [switch]$NoHistory,
    [string]$Compare,
    [string]$Projections,
    [string]$HistoryDb,
    [switch]$NoGui,
    [string]$Format,
    [string]$OutFile,
    [string]$ReportFile,
    [string]$CacheDir,
    [string]$CacheTtl,
    [switch]$NoCache,
    [switch]$Refresh,
    [switch]$Offline,
    [string]$Fixtures,
    [string]$Config,
    [string]$LogFile,
    [switch]$Quiet,
    [switch]$DebugLog,
    [string]$Python,
    [switch]$Version,
    [switch]$GuiSmokeTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ToolName = 'fantasy_manager'
$ToolVersion = '3.1.0'

# --------------------------------------------------------------------------
# Shared application: lib/fm_app.py does configuration, fetching, caching,
# validation, analysis and rendering for both front ends. This script maps
# its parameters onto that module and shows the report in a window.
# --------------------------------------------------------------------------
$Defaults = [ordered]@{
    platform  = 'sleeper'
    league_id = ''
    username  = ''
    horizon   = '3'
}

$EX_OK = 0; $EX_USAGE = 2; $EX_DEPENDENCY = 3; $EX_DATA = 4

$IsWindowsHost = ($PSVersionTable.PSVersion.Major -lt 6) -or ((Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue) -eq $true)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppPy = Join-Path (Join-Path $ScriptDir 'lib') 'fm_app.py'
$Invariant = [Globalization.CultureInfo]::InvariantCulture
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Get-DefaultDir([string]$kind) {
    if ($IsWindowsHost) {
        if ($kind -eq 'cache') { return Join-Path $env:LOCALAPPDATA $ToolName }
        return Join-Path $env:APPDATA $ToolName
    }
    if ($kind -eq 'cache') {
        $base = if ($env:XDG_CACHE_HOME) { $env:XDG_CACHE_HOME } else { Join-Path $HOME '.cache' }
    } else {
        $base = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
    }
    return Join-Path $base $ToolName
}

$script:ExitCode = $EX_OK

function Write-Log([string]$level, [string]$message) {
    # Messages from this script itself (Python not found, window errors);
    # everything else is logged by fm_app.py in the same format.
    if ($Quiet -and $level -ne 'ERROR') { return }
    [Console]::Error.WriteLine(('{0} [{1}] {2}' -f ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', $Invariant)), $level, $message))
}

function Save-Defaults([string]$path, $values) {
    # Writes key=value settings into a config file, keeping everything else
    # in it (comments, other keys). Existing lines for the same key, with or
    # without the FM_ prefix, are replaced; duplicates are dropped; new keys
    # are appended. A key whose value is $null is removed. Written atomically
    # as UTF-8 without a BOM.
    $full = [IO.Path]::GetFullPath($path)
    $dir = Split-Path -Parent $full
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $existing = @()
    if (Test-Path -LiteralPath $full -PathType Leaf) { $existing = @([IO.File]::ReadAllLines($full)) }
    $written = @{}
    $out = New-Object System.Collections.ArrayList
    foreach ($line in $existing) {
        $idx = $line.IndexOf('=')
        if ($idx -gt 0 -and -not $line.TrimStart().StartsWith('#')) {
            $key = ($line.Substring(0, $idx) -replace '\s', '').ToLowerInvariant()
            if ($key.StartsWith('fm_')) { $key = $key.Substring(3) }
            if ($values.Contains($key)) {
                if ($null -eq $values[$key]) { continue }
                if (-not $written.ContainsKey($key)) { [void]$out.Add("$key=$($values[$key])"); $written[$key] = $true }
                continue
            }
        }
        [void]$out.Add($line)
    }
    if ($existing.Count -eq 0) { [void]$out.Add('# Saved by FantasyManager (Remember). Any setting from the README can go here.') }
    foreach ($key in $values.Keys) {
        if ($null -ne $values[$key] -and -not $written.ContainsKey($key)) { [void]$out.Add("$key=$($values[$key])") }
    }
    $tmp = "$full.tmp.$PID"
    [IO.File]::WriteAllText($tmp, (($out -join [Environment]::NewLine) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $full -Force
    return $full
}

# --------------------------------------------------------------------------
# Python
# --------------------------------------------------------------------------
function ConvertTo-Argument([string]$arg) {
    # Quote one argument for a Windows command line (CommandLineToArgvW rules).
    if ($arg -ne '' -and $arg -notmatch '[\s"]') { return $arg }
    $result = '"'
    $backslashes = 0
    foreach ($ch in $arg.ToCharArray()) {
        if ($ch -eq '\') { $backslashes++; continue }
        if ($ch -eq '"') { $result += ('\' * ($backslashes * 2 + 1)) + '"' }
        else { $result += ('\' * $backslashes) + $ch }
        $backslashes = 0
    }
    return $result + ('\' * ($backslashes * 2)) + '"'
}

function Start-Native([string]$exe, [string[]]$arguments, [bool]$capture) {
    # Runs a program. Avoids PowerShell pipes and redirection, which re-encode
    # text and turn stderr into errors on 5.1. Without capture the child
    # writes straight to this console (live log lines).
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = (($arguments | ForEach-Object { ConvertTo-Argument $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    if ($capture) {
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = $Utf8NoBom
        $psi.StandardErrorEncoding = $Utf8NoBom
    }
    $proc = [Diagnostics.Process]::Start($psi)
    if ($capture) {
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        return [pscustomobject]@{ Code = $proc.ExitCode; Out = $outTask.Result; Err = $errTask.Result }
    }
    $proc.WaitForExit()
    return [pscustomobject]@{ Code = $proc.ExitCode; Out = ''; Err = '' }
}

function Get-PythonSetting {
    # -Python > FM_PYTHON > "python" in the config file.
    if ($Python) { return $Python }
    if ($env:FM_PYTHON) { return $env:FM_PYTHON }
    $cfg = if ($Config) { $Config } elseif ($env:FM_CONFIG_FILE) { $env:FM_CONFIG_FILE } else { Join-Path (Get-DefaultDir 'config') 'config.env' }
    if (Test-Path -LiteralPath $cfg -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($cfg)) {
            if ($line -match '^\s*(fm_)?python\s*=(.*)$') { return $Matches[2].Trim().Trim('"').Trim("'") }
        }
    }
    return ''
}

function Find-Python([string]$preferred) {
    $candidates = @()
    if ($preferred) { $candidates += , @($preferred) }
    if ($IsWindowsHost) { $candidates += , @('py', '-3'); $candidates += , @('python'); $candidates += , @('python3') }
    else { $candidates += , @('python3'); $candidates += , @('python') }
    foreach ($cand in $candidates) {
        $exe = $cand[0]
        $pre = @(); if ($cand.Count -gt 1) { $pre = $cand[1..($cand.Count - 1)] }
        if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { continue }
        try {
            $r = Start-Native $exe ($pre + @('-c', 'import sys; print(1 if sys.version_info >= (3, 8) else 0)')) $true
        } catch { continue }
        # The Microsoft Store "python" stub exits non-zero without running.
        if ($r.Code -eq 0 -and $r.Out.Trim() -eq '1') {
            return [pscustomobject]@{ Exe = (Get-Command $exe).Source; Pre = $pre }
        }
    }
    return $null
}

$script:Py = $null
function Get-Python {
    if ($script:Py) { return $script:Py }
    $script:Py = Find-Python (Get-PythonSetting)
    if (-not $script:Py) {
        Write-Log 'ERROR' 'Python 3.8+ not found. Install it from https://www.python.org (tick "Add python.exe to PATH") or pass -Python C:\path\to\python.exe.'
        $script:ExitCode = $EX_DEPENDENCY
        return $null
    }
    if (-not (Test-Path -LiteralPath $AppPy)) {
        Write-Log 'ERROR' "Application module not found at $AppPy"
        $script:ExitCode = $EX_DEPENDENCY
        return $null
    }
    return $script:Py
}

function ConvertTo-AppArgs($bound, [string[]]$skip = @()) {
    # PowerShell parameters -> fm_app.py options. Settings not given here fall
    # back to FM_* variables, the config file and defaults inside fm_app.py.
    $map = [ordered]@{
        Platform = '--platform'; LeagueId = '--league-id'; Username = '--username'; Team = '--team'; Week = '--week'; Season = '--season'
        SeasonType = '--season-type'; Top = '--top'; Threshold = '--threshold'; Fairness = '--fairness'
        Horizon = '--horizon'; Locked = '--locked'; Trade = '--trade'; ValueTrade = '--value-trade'
        Scoring = '--scoring'; Teams = '--teams'; Format = '--format'; CacheDir = '--cache-dir'
        CacheTtl = '--cache-ttl'; Fixtures = '--fixtures'; Config = '--config'; LogFile = '--log-file'
        HistoryDb = '--history-db'; Compare = '--compare'; Projections = '--projections'
    }
    $flags = [ordered]@{
        SkipWaivers = '--skip-waivers'; SkipTrades = '--skip-trades'; NoCache = '--no-cache'; Refresh = '--refresh'
        Offline = '--offline'; Quiet = '--quiet'; DebugLog = '--debug'; NoHistory = '--no-history'
    }
    $out = @()
    foreach ($k in $map.Keys) {
        if ($bound.ContainsKey($k) -and $skip -notcontains $k) { $out += @($map[$k], [string]$bound[$k]) }
    }
    foreach ($k in $flags.Keys) {
        if ($bound.ContainsKey($k) -and $skip -notcontains $k -and [bool]$bound[$k]) { $out += $flags[$k] }
    }
    return , $out
}

function Invoke-App([string[]]$appArgs, [bool]$capture = $false) {
    $py = Get-Python
    if (-not $py) { return $null }
    return Start-Native $py.Exe ($py.Pre + @($AppPy) + $appArgs) $capture
}

function Get-EffectiveConfig {
    # The settings fm_app.py would use (CLI > FM_* > config file > defaults),
    # used to pre-fill the window.
    $r = Invoke-App ((ConvertTo-AppArgs $script:BoundParams @('LogFile', 'Quiet', 'DebugLog')) + @('--quiet', '--print-config')) $true
    if (-not $r -or $r.Code -ne 0) { return $null }
    return ConvertFrom-Json -InputObject $r.Out
}

# --------------------------------------------------------------------------
# GUI is defined below; the data layer above runs without it.
# --------------------------------------------------------------------------
# --------------------------------------------------------------------------
# GUI (WPF, Windows only)
# --------------------------------------------------------------------------
$script:WindowXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Fantasy Manager" Width="1180" Height="800" MinWidth="900" MinHeight="600"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="13" Background="#F4F6F8">
  <Window.Resources>
    <SolidColorBrush x:Key="Accent" Color="#1F6FEB"/>
    <SolidColorBrush x:Key="Ink" Color="#1B1F24"/>
    <SolidColorBrush x:Key="Muted" Color="#5B6570"/>
    <Style TargetType="DataGrid">
      <Setter Property="AutoGenerateColumns" Value="False"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="GridLinesVisibility" Value="Horizontal"/>
      <Setter Property="HorizontalGridLinesBrush" Value="#E3E7EB"/>
      <Setter Property="BorderBrush" Value="#D5DAE0"/>
      <Setter Property="Background" Value="White"/>
      <Setter Property="RowBackground" Value="White"/>
      <Setter Property="CanUserAddRows" Value="False"/>
      <Setter Property="SelectionMode" Value="Single"/>
      <Setter Property="RowHeight" Value="26"/>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="#EEF1F4"/>
      <Setter Property="Foreground" Value="#3A434C"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="BorderBrush" Value="#D5DAE0"/>
      <Setter Property="BorderThickness" Value="0,0,1,1"/>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="#D5DAE0"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="6"/>
      <Setter Property="Padding" Value="14,10"/>
    </Style>
    <Style x:Key="ActionRows" TargetType="DataGridRow">
      <Style.Triggers>
        <DataTrigger Binding="{Binding Action}" Value="START"><Setter Property="Background" Value="#E6F4EA"/></DataTrigger>
        <DataTrigger Binding="{Binding Action}" Value="MOVE"><Setter Property="Background" Value="#E8F0FE"/></DataTrigger>
        <DataTrigger Binding="{Binding Action}" Value="BENCH"><Setter Property="Background" Value="#FEF7E0"/></DataTrigger>
        <DataTrigger Binding="{Binding Action}" Value="EMPTY SLOT"><Setter Property="Background" Value="#FCE8E6"/></DataTrigger>
        <DataTrigger Binding="{Binding Action}" Value="LOCKED"><Setter Property="Foreground" Value="#8A939C"/></DataTrigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="GroupRows" TargetType="DataGridRow">
      <Style.Triggers>
        <DataTrigger Binding="{Binding Group}" Value="Priority"><Setter Property="Background" Value="#E6F4EA"/></DataTrigger>
        <DataTrigger Binding="{Binding Group}" Value="Avoid"><Setter Property="Foreground" Value="#8A939C"/></DataTrigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>

  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- toolbar -->
    <Border Grid.Row="0" Style="{StaticResource Card}" Padding="12,8">
      <DockPanel LastChildFill="True">
        <StackPanel Orientation="Horizontal" DockPanel.Dock="Left" VerticalAlignment="Center">
          <ComboBox x:Name="PlatformBox" Width="84" Margin="0,0,10,0" ToolTip="Where the league is hosted. Each platform remembers its own league and user or team">
            <ComboBoxItem Content="Sleeper"/><ComboBoxItem Content="ESPN"/>
          </ComboBox>
          <TextBlock Text="League" VerticalAlignment="Center" Foreground="{StaticResource Muted}" Margin="0,0,6,0"/>
          <TextBox x:Name="LeagueBox" Width="150" Padding="4,3" ToolTip="League id: the number in the league's web address"/>
          <TextBlock x:Name="UserLabel" Text="User" VerticalAlignment="Center" Foreground="{StaticResource Muted}" Margin="14,0,6,0"/>
          <TextBox x:Name="UserBox" Width="130" Padding="4,3" ToolTip="Sleeper: your username. ESPN: your team's name, abbreviation or id"/>
          <TextBlock Text="Week" VerticalAlignment="Center" Foreground="{StaticResource Muted}" Margin="14,0,6,0"/>
          <TextBox x:Name="WeekBox" Width="44" Padding="4,3" ToolTip="Blank = current week (next week once every game is final)"/>
          <TextBlock Text="Horizon" VerticalAlignment="Center" Foreground="{StaticResource Muted}" Margin="14,0,6,0"/>
          <ComboBox x:Name="HorizonBox" Width="64" ToolTip="Future weeks valued for waivers, drops and trades (ROS = rest of the fantasy season)">
            <ComboBoxItem Content="0"/><ComboBoxItem Content="1"/><ComboBoxItem Content="2"/>
            <ComboBoxItem Content="3"/><ComboBoxItem Content="4"/><ComboBoxItem Content="5"/><ComboBoxItem Content="6"/>
            <ComboBoxItem Content="ROS"/>
          </ComboBox>
          <CheckBox x:Name="RememberBox" Content="Remember" VerticalAlignment="Center" Margin="14,0,0,0" IsChecked="True"
                    ToolTip="After a successful refresh, save this platform's league and user or team, and the horizon, as your defaults (config.env). Sleeper and ESPN are saved separately"/>
          <CheckBox x:Name="FreshBox" Content="Bypass cache" VerticalAlignment="Center" Margin="14,0,0,0"/>
          <Button x:Name="RefreshButton" Content="Refresh" Margin="14,0,0,0" Padding="16,4"
                  Background="{StaticResource Accent}" Foreground="White" BorderThickness="0" FontWeight="SemiBold"/>
          <Button x:Name="OpenButton" Content="Open report..." Margin="8,0,0,0" Padding="10,4"/>
          <Button x:Name="SaveButton" Content="Save report..." Margin="8,0,0,0" Padding="10,4" IsEnabled="False"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <ProgressBar x:Name="Busy" Width="90" Height="6" IsIndeterminate="True" Visibility="Collapsed" Margin="0,0,10,0"/>
          <TextBlock x:Name="StatusText" Foreground="{StaticResource Muted}" TextTrimming="CharacterEllipsis" MaxWidth="260"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- header -->
    <Grid Grid.Row="1" Margin="0,12,0,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <StackPanel Grid.Column="0" VerticalAlignment="Center">
        <TextBlock x:Name="TitleText" Text="Fantasy Manager" FontSize="24" FontWeight="SemiBold" Foreground="{StaticResource Ink}"/>
        <TextBlock x:Name="SubtitleText" Text="Press Refresh to load the current week." Foreground="{StaticResource Muted}" Margin="0,2,0,0"/>
        <TextBlock x:Name="NoticeText" Foreground="#9A6700" Margin="0,4,0,0" TextWrapping="Wrap" Visibility="Collapsed"/>
      </StackPanel>
      <Border Grid.Column="1" Style="{StaticResource Card}" MinWidth="380">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <StackPanel Grid.Column="0" HorizontalAlignment="Center">
            <TextBlock x:Name="MyTeamText" Text="-" FontWeight="SemiBold" HorizontalAlignment="Center" TextTrimming="CharacterEllipsis" MaxWidth="160"/>
            <TextBlock x:Name="MyScoreText" Text="-" FontSize="30" FontWeight="SemiBold" HorizontalAlignment="Center" Foreground="{StaticResource Accent}"/>
            <TextBlock x:Name="MyProjText" Text="" Foreground="{StaticResource Muted}" HorizontalAlignment="Center"/>
          </StackPanel>
          <TextBlock Grid.Column="1" Text="vs" VerticalAlignment="Center" Margin="16,0" Foreground="{StaticResource Muted}"/>
          <StackPanel Grid.Column="2" HorizontalAlignment="Center">
            <TextBlock x:Name="OppTeamText" Text="-" FontWeight="SemiBold" HorizontalAlignment="Center" TextTrimming="CharacterEllipsis" MaxWidth="160"/>
            <TextBlock x:Name="OppScoreText" Text="-" FontSize="30" FontWeight="SemiBold" HorizontalAlignment="Center"/>
            <TextBlock x:Name="OppProjText" Text="" Foreground="{StaticResource Muted}" HorizontalAlignment="Center"/>
          </StackPanel>
        </Grid>
      </Border>
    </Grid>

    <!-- warnings -->
    <Expander x:Name="WarningsExpander" Grid.Row="2" Margin="0,10,0,0" Visibility="Collapsed" IsExpanded="False">
      <Expander.Header>
        <TextBlock x:Name="WarningsHeader" Foreground="#9A6700" FontWeight="SemiBold"/>
      </Expander.Header>
      <Border Background="#FFF8E1" BorderBrush="#F2D488" BorderThickness="1" CornerRadius="4" Padding="10,6" Margin="0,4,0,0">
        <ItemsControl x:Name="WarningsList">
          <ItemsControl.ItemTemplate>
            <DataTemplate><TextBlock Text="{Binding}" TextWrapping="Wrap" Margin="0,2"/></DataTemplate>
          </ItemsControl.ItemTemplate>
        </ItemsControl>
      </Border>
    </Expander>

    <!-- tabs -->
    <TabControl x:Name="Tabs" Grid.Row="3" Margin="0,10,0,0" Padding="10" Background="White">
      <TabItem x:Name="LineupTab" Header="Lineup">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="2*"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <TextBlock x:Name="LineupSummary" Grid.Row="0" Margin="2,0,0,8" TextWrapping="Wrap"/>
          <DataGrid x:Name="LineupGrid" Grid.Row="1" RowStyle="{StaticResource ActionRows}">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Slot" Binding="{Binding Slot}" Width="80"/>
              <DataGridTextColumn Header="Current" Binding="{Binding Current}" Width="*"/>
              <DataGridTextColumn Header="Recommended" Binding="{Binding Recommended}" Width="*"/>
              <DataGridTextColumn Header="Action" Binding="{Binding Action}" Width="100"/>
              <DataGridTextColumn Header="Gain" Binding="{Binding Gain}" Width="70"/>
              <DataGridTextColumn Header="Note" Binding="{Binding Note}" Width="90"/>
            </DataGrid.Columns>
          </DataGrid>
          <TextBlock Grid.Row="2" Text="Risk / availability" FontWeight="SemiBold" Margin="2,12,0,6"/>
          <DataGrid x:Name="RiskGrid" Grid.Row="3">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Player" Binding="{Binding Player}" Width="200"/>
              <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="220"/>
              <DataGridTextColumn Header="Excluded" Binding="{Binding Excluded}" Width="80"/>
              <DataGridTextColumn Header="Notes" Binding="{Binding Notes}" Width="*"/>
            </DataGrid.Columns>
          </DataGrid>
        </Grid>
      </TabItem>
      <TabItem Header="Waivers">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <TextBlock x:Name="WaiverSummary" Grid.Row="0" Margin="2,0,0,8" TextWrapping="Wrap"/>
          <DataGrid x:Name="WaiverGrid" Grid.Row="1" RowStyle="{StaticResource GroupRows}">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Group" Binding="{Binding Group}" Width="120"/>
              <DataGridTextColumn Header="Player" Binding="{Binding Player}" Width="180"/>
              <DataGridTextColumn Header="Pos" Binding="{Binding Pos}" Width="48"/>
              <DataGridTextColumn Header="Team" Binding="{Binding Team}" Width="52"/>
              <DataGridTextColumn Header="Proj" Binding="{Binding Proj}" Width="56"/>
              <DataGridTextColumn Header="Net" Binding="{Binding Net}" Width="56"/>
              <DataGridTextColumn Header="Window" Binding="{Binding Window}" Width="66"/>
              <DataGridTextColumn Header="Score" Binding="{Binding Score}" Width="56"/>
              <DataGridTextColumn Header="Bid" Binding="{Binding Bid}" Width="90"/>
              <DataGridTextColumn Header="Drop" Binding="{Binding Drop}" Width="150"/>
              <DataGridTextColumn Header="Notes" Binding="{Binding Notes}" Width="*"/>
            </DataGrid.Columns>
          </DataGrid>
        </Grid>
      </TabItem>
      <TabItem Header="Trades">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <TextBlock x:Name="TradeSummary" Grid.Row="0" Margin="2,0,0,8" TextWrapping="Wrap"/>
          <DataGrid x:Name="TradeGrid" Grid.Row="1">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Partner" Binding="{Binding Partner}" Width="150"/>
              <DataGridTextColumn Header="Give" Binding="{Binding Give}" Width="*"/>
              <DataGridTextColumn Header="Get" Binding="{Binding Get}" Width="*"/>
              <DataGridTextColumn Header="My gain" Binding="{Binding MyGain}" Width="72"/>
              <DataGridTextColumn Header="Their gain" Binding="{Binding TheirGain}" Width="80"/>
              <DataGridTextColumn Header="My gain this wk" Binding="{Binding ThisWeek}" Width="110"/>
              <DataGridTextColumn Header="Fairness gap" Binding="{Binding Gap}" Width="96"/>
              <DataGridTextColumn Header="Partner needs" Binding="{Binding Needs}" Width="140"/>
            </DataGrid.Columns>
          </DataGrid>
        </Grid>
      </TabItem>
      <TabItem x:Name="AnalyzerTab" Header="Trade Analyzer">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="3*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="2*"/>
          </Grid.ColumnDefinitions>
          <Grid Grid.Column="0">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
              <RadioButton x:Name="LeagueModeRadio" Content="My league (real rosters)" GroupName="TradeMode" IsChecked="True" VerticalAlignment="Center"/>
              <RadioButton x:Name="OpenModeRadio" Content="Any players (e.g. a friend's league)" GroupName="TradeMode" Margin="18,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>

            <Grid x:Name="LeaguePanel" Grid.Row="1">
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,8">
                <TextBlock Text="Team A" VerticalAlignment="Center" Margin="0,0,6,0"/>
                <ComboBox x:Name="FromBox" Width="200" DisplayMemberPath="Label"/>
                <TextBlock Text="trades with" VerticalAlignment="Center" Margin="10,0,6,0"/>
                <ComboBox x:Name="PartnerBox" Width="200" DisplayMemberPath="Label"/>
              </StackPanel>
              <Grid Grid.Row="1" Margin="0,0,0,4">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="10"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <TextBlock x:Name="GiveHeader" Grid.Column="0" Text="You give" FontWeight="SemiBold"/>
                <TextBlock x:Name="GetHeader" Grid.Column="2" Text="You get" FontWeight="SemiBold"/>
              </Grid>
              <Grid Grid.Row="2">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="10"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <ListBox x:Name="GiveList" Grid.Column="0" SelectionMode="Multiple" DisplayMemberPath="Label" BorderBrush="#D5DAE0"/>
                <ListBox x:Name="GetList" Grid.Column="2" SelectionMode="Multiple" DisplayMemberPath="Label" BorderBrush="#D5DAE0"/>
              </Grid>
            </Grid>

            <Grid x:Name="OpenPanel" Grid.Row="1" Visibility="Collapsed">
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,8">
                <TextBlock Text="Scoring" VerticalAlignment="Center" Margin="0,0,6,0"/>
                <ComboBox x:Name="ScoringBox" Width="120" SelectedIndex="0">
                  <ComboBoxItem Content="PPR"/><ComboBoxItem Content="Half-PPR"/><ComboBoxItem Content="Standard"/><ComboBoxItem Content="My league's"/>
                </ComboBox>
                <TextBlock Text="League size" VerticalAlignment="Center" Margin="14,0,6,0"/>
                <TextBox x:Name="TeamsBox" Width="40" Padding="4,3" Text="12" ToolTip="Number of teams in that league (4-32)"/>
                <TextBlock Text="Search, click to add; click a picked player to remove." VerticalAlignment="Center" Margin="14,0,0,0" Foreground="{StaticResource Muted}"/>
              </StackPanel>
              <Grid Grid.Row="1" Margin="0,0,0,4">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="10"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Side A gives" FontWeight="SemiBold"/>
                <TextBlock Grid.Column="2" Text="Side B gives" FontWeight="SemiBold"/>
              </Grid>
              <Grid Grid.Row="2">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="10"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <Grid Grid.Column="0">
                  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="110"/></Grid.RowDefinitions>
                  <TextBox x:Name="SearchA" Grid.Row="0" Padding="4,3" ToolTip="Type part of a name, a team (BUF) or a position (WR)"/>
                  <ListBox x:Name="ResultsA" Grid.Row="1" DisplayMemberPath="Label" BorderBrush="#D5DAE0" Margin="0,4,0,0"/>
                  <TextBlock Grid.Row="2" Text="Picked" Foreground="{StaticResource Muted}" Margin="0,6,0,2"/>
                  <ListBox x:Name="PickedA" Grid.Row="3" DisplayMemberPath="Label" BorderBrush="#D5DAE0" Background="#F6F8FA"/>
                </Grid>
                <Grid Grid.Column="2">
                  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="110"/></Grid.RowDefinitions>
                  <TextBox x:Name="SearchB" Grid.Row="0" Padding="4,3" ToolTip="Type part of a name, a team (BUF) or a position (WR)"/>
                  <ListBox x:Name="ResultsB" Grid.Row="1" DisplayMemberPath="Label" BorderBrush="#D5DAE0" Margin="0,4,0,0"/>
                  <TextBlock Grid.Row="2" Text="Picked" Foreground="{StaticResource Muted}" Margin="0,6,0,2"/>
                  <ListBox x:Name="PickedB" Grid.Row="3" DisplayMemberPath="Label" BorderBrush="#D5DAE0" Background="#F6F8FA"/>
                </Grid>
              </Grid>
            </Grid>

            <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,10,0,0">
              <Button x:Name="GradeButton" Content="Grade trade" Padding="16,4"
                      Background="{StaticResource Accent}" Foreground="White" BorderThickness="0" FontWeight="SemiBold"/>
              <Button x:Name="ClearTradeButton" Content="Clear" Margin="8,0,0,0" Padding="10,4"/>
              <TextBlock x:Name="TradePickSummary" Margin="14,0,0,0" VerticalAlignment="Center" Foreground="{StaticResource Muted}"/>
            </StackPanel>
          </Grid>
          <Border Grid.Column="2" Style="{StaticResource Card}">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
              <StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <StackPanel Grid.Column="0" HorizontalAlignment="Center">
                    <TextBlock x:Name="YouLabel" Text="Your grade" Foreground="{StaticResource Muted}" HorizontalAlignment="Center"/>
                    <TextBlock x:Name="YouGrade" Text="-" FontSize="46" FontWeight="Bold" HorizontalAlignment="Center"/>
                  </StackPanel>
                  <StackPanel Grid.Column="1" HorizontalAlignment="Center">
                    <TextBlock x:Name="ThemLabel" Text="Their grade" Foreground="{StaticResource Muted}" HorizontalAlignment="Center"/>
                    <TextBlock x:Name="ThemGrade" Text="-" FontSize="46" FontWeight="Bold" HorizontalAlignment="Center"/>
                  </StackPanel>
                </Grid>
                <TextBlock x:Name="AcceptText" HorizontalAlignment="Center" Foreground="{StaticResource Muted}" Margin="0,2,0,8"/>
                <TextBlock x:Name="VerdictText" TextWrapping="Wrap" FontWeight="SemiBold" FontSize="14" Margin="0,0,0,8"
                           Text="Pick the players on each side, then press Grade trade."/>
                <TextBlock x:Name="TradeDetail" TextWrapping="Wrap" LineHeight="20"/>
                <TextBlock x:Name="GradeScaleText" TextWrapping="Wrap" Foreground="{StaticResource Muted}" FontSize="11" Margin="0,12,0,0"
                           Text="Grades are projected points gained per week across the window (this week plus the horizon): A+ 4 or more, A 3, A- 2.25, B+ 1.5, B 1, B- 0.5, C+ 0.25, C about even, C- -0.5, D+ -1, D -1.5, F worse. My league: starting-lineup points with real rosters and roster limits. Any players: points above a replacement-level starter for that league size and scoring."/>
              </StackPanel>
            </ScrollViewer>
          </Border>
        </Grid>
      </TabItem>
      <TabItem Header="Matchup">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <TextBlock x:Name="MatchupDetail" Margin="4" TextWrapping="Wrap" FontSize="14" LineHeight="24"/>
        </ScrollViewer>
      </TabItem>
      <TabItem Header="Sources">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <TextBlock x:Name="SourcesSummary" Grid.Row="0" Margin="2,0,0,8" TextWrapping="Wrap"/>
          <DataGrid x:Name="SourcesGrid" Grid.Row="1">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Player" Binding="{Binding Player}" Width="200"/>
              <DataGridTextColumn Header="Pos" Binding="{Binding Pos}" Width="50"/>
              <DataGridTextColumn Header="Team" Binding="{Binding Team}" Width="60"/>
              <DataGridTextColumn Header="Where" Binding="{Binding Where}" Width="100"/>
              <DataGridTextColumn Header="Sleeper (PPR)" Binding="{Binding Sleeper}" Width="100"/>
              <DataGridTextColumn Header="ESPN (PPR)" Binding="{Binding Espn}" Width="90"/>
              <DataGridTextColumn Header="Difference" Binding="{Binding Diff}" Width="*"/>
            </DataGrid.Columns>
          </DataGrid>
        </Grid>
      </TabItem>
      <TabItem Header="Trends">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <TextBlock x:Name="TrendsSummary" Grid.Row="0" Margin="2,0,0,8" TextWrapping="Wrap"/>
          <TextBlock Grid.Row="1" Margin="2,4,0,6" FontWeight="SemiBold" Text="Breakout watch: free agents whose role is growing"/>
          <DataGrid x:Name="BreakoutGrid" Grid.Row="2" MaxHeight="260">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Player" Binding="{Binding Player}" Width="200"/>
              <DataGridTextColumn Header="Pos" Binding="{Binding Pos}" Width="50"/>
              <DataGridTextColumn Header="Team" Binding="{Binding Team}" Width="60"/>
              <DataGridTextColumn Header="Snaps" Binding="{Binding Snaps}" Width="110"/>
              <DataGridTextColumn Header="Targets + carries" Binding="{Binding Opp}" Width="*"/>
            </DataGrid.Columns>
          </DataGrid>
          <TextBlock Grid.Row="3" Margin="2,12,0,6" FontWeight="SemiBold" Text="Your players losing role"/>
          <DataGrid x:Name="DecliningGrid" Grid.Row="4">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Player" Binding="{Binding Player}" Width="200"/>
              <DataGridTextColumn Header="Pos" Binding="{Binding Pos}" Width="50"/>
              <DataGridTextColumn Header="Team" Binding="{Binding Team}" Width="60"/>
              <DataGridTextColumn Header="Snaps" Binding="{Binding Snaps}" Width="110"/>
              <DataGridTextColumn Header="Targets + carries" Binding="{Binding Opp}" Width="*"/>
            </DataGrid.Columns>
          </DataGrid>
        </Grid>
      </TabItem>
      <TabItem Header="History">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <TextBlock x:Name="HistorySummary" Grid.Row="0" Margin="2,0,0,8" TextWrapping="Wrap"/>
          <DataGrid x:Name="HistoryAccGrid" Grid.Row="1" MaxHeight="230">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Position" Binding="{Binding Position}" Width="80"/>
              <DataGridTextColumn Header="Player-weeks" Binding="{Binding N}" Width="95"/>
              <DataGridTextColumn Header="Avg miss" Binding="{Binding Mae}" Width="80"/>
              <DataGridTextColumn Header="Bias" Binding="{Binding Bias}" Width="70"/>
              <DataGridTextColumn Header="Within 5 pts" Binding="{Binding Within}" Width="*"/>
            </DataGrid.Columns>
          </DataGrid>
          <TextBlock Grid.Row="2" Margin="2,12,0,6" FontWeight="SemiBold" Text="Your roster: recent form (last 4 weeks played)"/>
          <DataGrid x:Name="HistoryFormGrid" Grid.Row="3">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Player" Binding="{Binding Player}" Width="200"/>
              <DataGridTextColumn Header="Pos" Binding="{Binding Pos}" Width="50"/>
              <DataGridTextColumn Header="GP" Binding="{Binding Games}" Width="45"/>
              <DataGridTextColumn Header="Avg" Binding="{Binding Avg}" Width="60"/>
              <DataGridTextColumn Header="Proj" Binding="{Binding Proj}" Width="60"/>
              <DataGridTextColumn Header="Beat proj" Binding="{Binding Beat}" Width="75"/>
              <DataGridTextColumn Header="Weekly (actual)" Binding="{Binding Weekly}" Width="*"/>
            </DataGrid.Columns>
          </DataGrid>
        </Grid>
      </TabItem>
      <TabItem Header="Diagnostics">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <TextBlock x:Name="DiagSummary" Grid.Row="0" Margin="2,0,0,8" TextWrapping="Wrap"/>
          <DataGrid x:Name="DiagGrid" Grid.Row="1">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Source" Binding="{Binding Key}" Width="130"/>
              <DataGridTextColumn Header="Origin" Binding="{Binding Origin}" Width="100"/>
              <DataGridTextColumn Header="Cache age" Binding="{Binding Age}" Width="80"/>
              <DataGridTextColumn Header="Records" Binding="{Binding Records}" Width="70"/>
              <DataGridTextColumn Header="Note" Binding="{Binding Note}" Width="150"/>
              <DataGridTextColumn Header="URL" Binding="{Binding Url}" Width="*"/>
            </DataGrid.Columns>
          </DataGrid>
        </Grid>
      </TabItem>
    </TabControl>

    <TextBlock Grid.Row="4" Margin="2,8,0,0" Foreground="{StaticResource Muted}" FontSize="12"
               Text="Read-only: this tool cannot submit lineups, waiver claims or trades. Projections are advisory; correlation and game script are not modelled."/>
  </Grid>
</Window>
'@

function Format-Points($value) {
    if ($null -eq $value) { return 'n/a' }
    return ([double]$value).ToString('0.#', $Invariant)
}

function Get-Prop($obj, [string]$name) {
    # Safe property access under StrictMode (missing -> $null).
    if ($null -eq $obj) { return $null }
    $p = $obj.PSObject.Properties[$name]
    if ($p) { return $p.Value }
    return $null
}

function Format-Time($value) {
    # PowerShell 7 turns ISO timestamps into DateTime on import; 5.1 keeps strings.
    if ($null -eq $value -or $value -eq '') { return 'n/a' }
    $dt = $value
    if ($dt -isnot [DateTime]) {
        $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
        $parsed = [DateTime]::MinValue
        if (-not [DateTime]::TryParse([string]$value, $Invariant, $styles, [ref]$parsed)) { return [string]$value }
        $dt = [DateTime]::SpecifyKind($parsed, [DateTimeKind]::Utc)
    }
    return $dt.ToLocalTime().ToString('ddd MMM d, h:mm tt', $Invariant)
}

function Format-Player($ref) {
    if ($null -eq $ref) { return '(empty)' }
    $team = Get-Prop $ref 'team'; if (-not $team) { $team = 'FA' }
    $pos = Get-Prop $ref 'position'; if (-not $pos) { $pos = '?' }
    return ('{0} ({1}/{2})' -f (Get-Prop $ref 'name'), $pos, $team)
}

function Update-ReportView($ui, $report) {
    $meta = $report.metadata
    $week = Get-Prop $meta 'week'
    $ui.TitleText.Text = ('{0} - Week {1}' -f $(if (Get-Prop $meta 'league_name') { $meta.league_name } else { 'League' }), $week)
    $ui.SubtitleText.Text = ('{0} ({1})   |   {2} {3}   |   generated {4}   |   {5}' -f `
        $(if (Get-Prop $meta 'team_name') { $meta.team_name } else { 'n/a' }), $meta.username, $meta.season, $meta.season_type,
        (Format-Time $meta.generated_at), ('scoring: ' + $meta.scoring.mode))
    $notices = @()
    if ($null -ne (Get-Prop $meta 'week_rolled_from')) {
        $notices += ('Every week {0} game is final, so this is week {1}.' -f $meta.week_rolled_from, $week)
    }
    if (Get-Prop $meta.projections 'stale') { $notices += 'STALE projection data - see warnings.' }
    $ui.NoticeText.Text = ($notices -join '  ')
    $ui.NoticeText.Visibility = $(if ($notices.Count) { 'Visible' } else { 'Collapsed' })

    # warnings
    $warnings = @($report.warnings)
    $ui.WarningsList.ItemsSource = $warnings
    $ui.WarningsHeader.Text = ('{0} warning(s)' -f $warnings.Count)
    $ui.WarningsExpander.Visibility = $(if ($warnings.Count) { 'Visible' } else { 'Collapsed' })

    # matchup card + tab
    $m = $report.matchup
    if ($m) {
        $ui.MyTeamText.Text = $(if ($m.my_team) { $m.my_team } else { 'Me' })
        $ui.OppTeamText.Text = $(if ($m.opponent_team) { $m.opponent_team } else { 'Opponent' })
        $ui.MyScoreText.Text = Format-Points $m.my_points
        $ui.OppScoreText.Text = Format-Points $m.opponent_points
        $ui.MyProjText.Text = 'proj. final ' + (Format-Points (Get-Prop $m 'my_projected_final'))
        $ui.OppProjText.Text = 'proj. final ' + (Format-Points (Get-Prop $m 'opponent_projected_final'))
        $wpLines = @(Get-WinProbabilityLines (Get-Prop $m 'win_probability'))
        $wp = Get-Prop $m 'win_probability'
        if ($wp) { $ui.MyProjText.Text += ('  -  win {0}%' -f (Format-Points $wp.recommended_lineup_pct)) }
        $ui.MatchupDetail.Text = (@(
            ('{0}  vs  {1}' -f $ui.MyTeamText.Text, $ui.OppTeamText.Text),
            ('Live / final points:  {0}  vs  {1}' -f (Format-Points $m.my_points), (Format-Points $m.opponent_points)),
            ('Projected (current lineups):  {0}  vs  {1}   (differential {2})' -f (Format-Points $m.my_projected), (Format-Points $m.opponent_projected), (Format-Points $m.differential)),
            ('Projected final (live + remaining):  {0}  vs  {1}   ({2})' -f (Format-Points (Get-Prop $m 'my_projected_final')), (Format-Points (Get-Prop $m 'opponent_projected_final')), (Format-Points (Get-Prop $m 'final_differential'))),
            ''
        ) + $wpLines + @($m.note)) -join "`n"

    } else {
        foreach ($n in 'MyTeamText', 'OppTeamText', 'MyScoreText', 'OppScoreText') { $ui[$n].Text = '-' }
        $ui.MyProjText.Text = ''; $ui.OppProjText.Text = ''
        $ui.MatchupDetail.Text = 'Matchup data unavailable.'
    }

    # lineup
    $l = $report.lineup
    $locks = Get-Prop $l 'locks'
    $lockedNames = @()
    if ($locks) { $lockedNames = @(@($locks.locked_starters) + @($locks.locked_bench) | Where-Object { $_ } | ForEach-Object { $_.name }) }
    $summary = 'Current {0}   Optimal {1}   Potential gain {2}' -f (Format-Points $l.current_points), (Format-Points $l.optimal_points), (Format-Points $l.gain)
    if ($lockedNames.Count) { $summary += ('      Locked (game started): {0}' -f ($lockedNames -join ', ')) }
    $ui.LineupSummary.Text = $summary
    $ui.LineupGrid.ItemsSource = @($l.slots | ForEach-Object {
        [pscustomobject]@{
            Slot = $_.slot; Current = Format-Player $_.current; Recommended = Format-Player $_.recommended
            Action = $_.action; Gain = Format-Points $_.gain
            Note = $(if ($_.below_threshold) { 'optional' } else { '' })
        }
    })
    $ui.RiskGrid.ItemsSource = @($l.risk | Where-Object { $_ } | ForEach-Object {
        [pscustomobject]@{
            Player = ('{0} ({1})' -f $_.name, $_.position)
            Status = (@($_.status, $_.injury_status, $_.practice_participation) | Where-Object { $_ }) -join ', '
            Excluded = $(if ($_.excluded_from_recommendations) { 'yes' } else { '' })
            Notes = $_.note
        }
    })

    # waivers
    $wv = $report.waivers
    if ($wv) {
        $w = $wv.waiver
        $budget = ''
        if ($null -ne (Get-Prop $w 'budget')) { $budget = ('  (budget {0}, remaining {1})' -f $w.budget, (Format-Points $w.remaining)) }
        $windowWeeks = @(Get-Prop $wv 'window_weeks')
        $windowText = $(if ($windowWeeks.Count -gt 1) { 'weeks ' + ($windowWeeks -join ', ') + ' ("Window" = gain over all of them)' } else { 'this week only' })
        $ui.WaiverSummary.Text = ('Waiver type: {0}{1}     Window: {2}     Omitted: {3}' -f $w.type, $budget, $windowText,
            $(if (@($wv.omitted_components).Count) { @($wv.omitted_components) -join ', ' } else { 'none' }))
        $rows = New-Object System.Collections.ArrayList
        foreach ($g in @(@('priority', 'Priority'), @('bench_upgrades', 'Stash / upgrade'), @('streamers', 'Streamer'), @('avoid', 'Avoid'))) {
            foreach ($r in @($wv.groups.($g[0]))) {
                if (-not $r) { continue }
                $bid = ''
                if ($null -ne (Get-Prop $r 'suggested_bid')) { $bid = ('${0} ({1}%)' -f $r.suggested_bid, $r.suggested_bid_pct) }
                elseif (Get-Prop $r 'use_priority') { $bid = 'use priority' }
                $drop = Get-Prop $r 'drop_candidate'
                [void]$rows.Add([pscustomobject]@{
                    Group = $g[1]; Player = $r.name; Pos = $r.position; Team = $(if ($r.team) { $r.team } else { 'FA' })
                    Proj = Format-Points $r.projection; Net = Format-Points $r.net_gain
                    Window = Format-Points (Get-Prop $r 'window_gain'); Score = Format-Points $r.score
                    Bid = $bid; Drop = $(if ($drop) { $drop.name } else { '' })
                    Notes = (@($r.notes) -join '; ')
                })
            }
        }
        $ui.WaiverGrid.ItemsSource = $rows
    } else {
        $ui.WaiverSummary.Text = 'Waiver analysis skipped.'
        $ui.WaiverGrid.ItemsSource = @()
    }

    # trades
    $t = $report.trades
    if ($t) {
        $needs = @($t.my_needs | Where-Object { $_ } | ForEach-Object { '{0} ({1} vs league {2})' -f $_.position, (Format-Points $_.starter_points), (Format-Points $_.league_average) })
        $surplus = @($t.my_surplus | Where-Object { $_ } | ForEach-Object { $_.name })
        $ui.TradeSummary.Text = ('My needs: {0}      My surplus: {1}' -f $(if ($needs.Count) { $needs -join ', ' } else { 'none identified' }),
            $(if ($surplus.Count) { $surplus -join ', ' } else { 'none identified' }))
        $rows = New-Object System.Collections.ArrayList
        foreach ($p in @($t.partners)) {
            if (-not $p) { continue }
            foreach ($pkg in @($p.packages)) {
                [void]$rows.Add([pscustomobject]@{
                    Partner = $(if ($p.team) { $p.team } else { 'roster ' + $p.roster_id })
                    Give = (@($pkg.give | ForEach-Object { '{0} ({1})' -f $_.name, $_.position }) -join ' + ')
                    Get = (@($pkg.get | ForEach-Object { '{0} ({1})' -f $_.name, $_.position }) -join ' + ')
                    MyGain = Format-Points $pkg.my_gain; TheirGain = Format-Points $pkg.their_gain
                    ThisWeek = Format-Points (Get-Prop $pkg 'my_gain_this_week'); Gap = Format-Points $pkg.fairness_gap
                    Needs = (@($p.needs | Where-Object { $_ } | ForEach-Object { $_.position }) -join ', ')
                })
            }
        }
        if ($rows.Count -eq 0) { $ui.TradeSummary.Text += "`nNo balanced packages found within the fairness tolerance." }
        $ui.TradeGrid.ItemsSource = $rows
    } else {
        $ui.TradeSummary.Text = 'Trade analysis skipped.'
        $ui.TradeGrid.ItemsSource = @()
    }

    # history (reports from 2.8.0 on) and usage trends (2.10.0 on)
    Update-HistoryView $ui (Get-Prop $report 'history')
    Update-TrendsView $ui (Get-Prop $report 'opportunity')
    Update-SourcesView $ui (Get-Prop $report 'projection_sources')

    # diagnostics
    $proj = $meta.projections
    $ui.DiagSummary.Text = ('Projections: {0} ({1} records{2})     Lock source: {3}     Tool {4}' -f $proj.source, $proj.record_count,
        $(if ($proj.stale) { ', STALE' } else { '' }), (Get-Prop $report.diagnostics 'lock_source'), $meta.tool_version)
    $ui.DiagGrid.ItemsSource = @($report.diagnostics.fetches | Where-Object { $_ } | ForEach-Object {
        [pscustomobject]@{
            Key = $_.key; Origin = $_.source
            Age = $(if ($null -eq $_.cache_age_seconds) { '' } else { '{0}m' -f [Math]::Floor($_.cache_age_seconds / 60) })
            Records = $_.records; Note = $_.note; Url = $_.url
        }
    })
    Update-TradeAnalyzer $ui $report
}

function Get-WinProbabilityLines($wp) {
    # Matchup simulation (reports from 2.9.0 on).
    if ($null -eq $wp) { return @() }
    $lines = @(
        ('Win probability:  {0}% with your current lineup,  {1}% with the recommended one  ({2} simulations)' -f
            (Format-Points $wp.current_lineup_pct), (Format-Points $wp.recommended_lineup_pct), $wp.simulations),
        ('Likely range (10th-90th percentile):  you {0}-{1},  them {2}-{3}' -f
            (Format-Points ([Math]::Round([double]$wp.my_range.p10))), (Format-Points ([Math]::Round([double]$wp.my_range.p90))),
            (Format-Points ([Math]::Round([double]$wp.opponent_range.p10))), (Format-Points ([Math]::Round([double]$wp.opponent_range.p90))))
    )
    foreach ($mv in @($wp.moves)) {
        if ($null -eq $mv) { continue }
        $lines += ('To raise your chances: start {0} over {1} ({2}): {3}% ({4}), {5} projected points' -f
            $mv.in.name, $mv.out.name, $mv.slot, (Format-Points $mv.win_pct), (Format-Signed $mv.win_gain), (Format-Signed $mv.points_change))
    }
    $lines += ('Score spreads: ' + $wp.spread_source)
    return $lines + @('')
}

function Update-SourcesView($ui, $p) {
    # Second projection source (reports from 2.12.0 on).
    if ($null -eq $p) {
        $ui.SourcesSummary.Text = 'No second projection source in this report (from version 2.12.0, or turned off with -Compare none).'
        $ui.SourcesGrid.ItemsSource = @()
        return
    }
    if (-not $p.available) {
        $ui.SourcesSummary.Text = 'ESPN unavailable: ' + $p.reason
        $ui.SourcesGrid.ItemsSource = @()
        return
    }
    $using = $(if ($p.mode -eq 'blend' -and @($p.blended_weeks).Count) { 'a 50/50 Sleeper + ESPN blend for weeks ' + (@($p.blended_weeks) -join ', ') }
               else { "Sleeper's projections (-Projections blend for a 50/50 consensus)" })
    $ui.SourcesSummary.Text = ('Sleeper vs ESPN, week {0} (PPR points). Using {1}. Matched {2} players ({3} not matched); typical gap {4} points. Listed: 4+ points and 30%+ apart.' -f
        $p.week, $using, $p.matched, $p.unmatched, (Format-Points $p.mean_abs_diff))
    $ui.SourcesGrid.ItemsSource = @(@($p.disagreements) | Where-Object { $_ } | ForEach-Object {
        [pscustomobject]@{ Player = $_.name; Pos = $_.position; Team = $_.team; Where = $_.where
            Sleeper = (Format-Points $_.sleeper_ppr); Espn = (Format-Points $_.espn_ppr); Diff = (Format-Signed $_.difference) }
    })
}

function ConvertTo-TrendRows($entries) {
    return @(@($entries) | Where-Object { $_ } | ForEach-Object {
        [pscustomobject]@{
            Player = $_.name; Pos = $_.position; Team = $_.team
            Snaps = $(if ($null -eq $_.snap_then) { 'n/a' } else { '{0}% -> {1}%' -f $_.snap_then, $_.snap_now })
            Opp = ('{0} -> {1} a game' -f (Format-Points $_.opportunities_then), (Format-Points $_.opportunities_now))
        }
    })
}

function Update-TrendsView($ui, $o) {
    if ($null -eq $o) {
        $ui.TrendsSummary.Text = 'No usage trends in this report (from version 2.10.0, or turned off with --no-history).'
        $ui.BreakoutGrid.ItemsSource = @(); $ui.DecliningGrid.ItemsSource = @()
        return
    }
    if (-not $o.available) {
        $ui.TrendsSummary.Text = 'Usage trends unavailable: ' + $o.reason
        $ui.BreakoutGrid.ItemsSource = @(); $ui.DecliningGrid.ItemsSource = @()
        return
    }
    $sources = @($o.sources.PSObject.Properties | ForEach-Object { '{0} {1} wk' -f $(if ($_.Name -eq 'sleeper') { 'Sleeper stats' } else { $_.Name }), $_.Value }) -join ', '
    $ui.TrendsSummary.Text = ('Snap share and targets + carries, weeks {0} ({1}). Earlier weeks compared with the last two.' -f (@($o.weeks) -join ', '), $sources)
    $ui.BreakoutGrid.ItemsSource = @(ConvertTo-TrendRows $o.breakouts)
    $ui.DecliningGrid.ItemsSource = @(ConvertTo-TrendRows $o.declining)
}

function ConvertTo-HorizonIndex($horizon) {
    # Horizon box: items 0-6, then ROS (rest of season).
    if ([string]$horizon -eq 'ros') { return 7 }
    $n = 0
    if ([int]::TryParse([string]$horizon, [ref]$n) -and $n -ge 0 -and $n -le 6) { return $n }
    return 3
}

function ConvertFrom-HorizonIndex([int]$index) {
    if ($index -eq 7) { return 'ros' }
    return [string]$index
}

function Format-Signed($value) {
    if ($null -eq $value) { return 'n/a' }
    $text = Format-Points $value
    if ($text -eq '0' -or $text -eq '-0') { return '0' }
    if ($text.StartsWith('-')) { return $text }
    return '+' + $text
}

function Update-HistoryView($ui, $h) {
    if ($null -eq $h) {
        $ui.HistorySummary.Text = 'No history in this report (recorded from version 2.8.0, or turned off with --no-history).'
        $ui.HistoryAccGrid.ItemsSource = @(); $ui.HistoryFormGrid.ItemsSource = @()
        return
    }
    if (-not $h.available) {
        $ui.HistorySummary.Text = 'History unavailable: ' + $h.reason
        $ui.HistoryAccGrid.ItemsSource = @(); $ui.HistoryFormGrid.ItemsSource = @()
        return
    }
    $weeks = @($h.weeks)
    $src = $h.projection_sources
    $summary = ('Projected vs actual points in your league''s scoring, weeks {0}-{1}. {2} projections recorded before kickoff, {3} fetched afterwards. Bias above 0 means players beat their projections.' -f
        $weeks[0], $weeks[-1], $src.snapshot, $src.backfill)
    $missing = @(Get-Prop $h 'stats_missing_weeks' | Where-Object { $null -ne $_ })
    if ($missing.Count) { $summary += ' No stats feed for week ' + ($missing -join ', ') + ': only rostered players have results there.' }
    $ui.HistorySummary.Text = $summary
    $rows = New-Object System.Collections.ArrayList
    foreach ($prop in $h.accuracy.by_position.PSObject.Properties) {
        $st = $prop.Value
        if ($null -eq $st) { continue }
        [void]$rows.Add([pscustomobject]@{ Position = $prop.Name; N = $st.n; Mae = (Format-Points $st.mae); Bias = (Format-Signed $st.bias); Within = ('{0}%' -f $st.within_5_pct) })
    }
    $all = $h.accuracy.overall
    if ($all) { [void]$rows.Add([pscustomobject]@{ Position = 'All'; N = $all.n; Mae = (Format-Points $all.mae); Bias = (Format-Signed $all.bias); Within = ('{0}%' -f $all.within_5_pct) }) }
    $ui.HistoryAccGrid.ItemsSource = $rows
    $form = New-Object System.Collections.ArrayList
    foreach ($playerId in @($h.my_roster)) {
        if ($null -eq $playerId) { continue }
        $p = Get-Prop $h.players ([string]$playerId)
        if ($null -eq $p) { continue }
        [void]$form.Add([pscustomobject]@{
            Player = $p.name; Pos = $p.position; Games = $p.games; Avg = (Format-Points $p.avg_points)
            Proj = (Format-Points $p.avg_projection); Beat = ('{0}/{1}' -f $p.beat, $p.compared)
            Weekly = (@($p.last | ForEach-Object { Format-Points $_.actual }) -join '  ')
        })
    }
    $ui.HistoryFormGrid.ItemsSource = $form
}

function Get-GradeBrush([string]$grade) {
    $color = switch -Regex ($grade) { '^A' { '#1A7F37' } '^B' { '#1F6FEB' } '^C' { '#5B6570' } '^D' { '#BC4C00' } '^F' { '#CF222E' } default { '#1B1F24' } }
    $converterType = 'Windows.Media.BrushConverter' -as [type]
    if ($null -eq $converterType) { return $null }
    return (New-Object Windows.Media.BrushConverter).ConvertFromString($color)
}

function Set-GradeText($block, [string]$grade) {
    $block.Text = $(if ($grade) { $grade } else { '-' })
    $brush = Get-GradeBrush $grade
    if ($null -ne $brush) { $block.Foreground = $brush }
}

function Format-TradeLabel($p, [int]$weeks) {
    $team = $(if ($p.team) { $p.team } else { 'FA' })
    $label = '{0}   {1}/{2}   {3} this wk' -f $p.name, $p.position, $team, (Format-Points $p.projection)
    if ($weeks -gt 1) { $label += (' / {0} over {1} wks' -f (Format-Points $p.window_projection), $weeks) }
    if (Get-Prop $p 'injury_status') { $label += '   [' + $p.injury_status + ']' }
    return $label
}

function Test-OpenMode($ui) { return [bool]$ui.OpenModeRadio.IsChecked }

function Set-TradeMode($ui, [bool]$open) {
    $ui.LeaguePanel.Visibility = $(if ($open) { 'Collapsed' } else { 'Visible' })
    $ui.OpenPanel.Visibility = $(if ($open) { 'Visible' } else { 'Collapsed' })
    if ([bool]$ui.OpenModeRadio.IsChecked -ne $open) { $ui.OpenModeRadio.IsChecked = $open; $ui.LeagueModeRadio.IsChecked = -not $open }
    Update-TradePickSummary $ui
}

function Update-TradeAnalyzer($ui, $report) {
    $rosters = @(Get-Prop $report 'rosters' | Where-Object { $_ })
    $script:TradeRosters = $rosters
    $script:PlayerPool = @(Get-Prop $report 'player_pool' | Where-Object { $_ })
    $script:TradeWeeks = [Math]::Max(1, @(Get-Prop $report.metadata 'window_weeks').Count)
    if ($null -eq (Get-Variable -Name OpenPicks -Scope Script -ErrorAction SilentlyContinue)) { $script:OpenPicks = @{ A = @(); B = @() } }

    $previous = $null
    if ($ui.FromBox.SelectedItem) { $previous = $ui.FromBox.SelectedItem.RosterId }
    $teams = @($rosters | ForEach-Object {
        $name = $(if ($_.team) { $_.team } else { 'Roster ' + $_.roster_id })
        [pscustomobject]@{ Label = $(if ($_.is_me) { $name + ' (you)' } else { $name }); Name = $name; RosterId = $_.roster_id; IsMe = [bool]$_.is_me }
    })
    $ui.FromBox.ItemsSource = $teams
    $index = -1
    for ($i = 0; $i -lt $teams.Count; $i++) {
        if ($null -ne $previous -and $teams[$i].RosterId -eq $previous) { $index = $i }
        elseif ($index -lt 0 -and $null -eq $previous -and $teams[$i].IsMe) { $index = $i }
    }
    if ($index -lt 0 -and $teams.Count) { $index = 0 }
    $ui.FromBox.SelectedIndex = $index
    Update-TradeSides $ui

    Update-OpenResults $ui 'A'
    Update-OpenResults $ui 'B'
    Update-OpenPicked $ui

    $values = @(Get-Prop $report 'value_trades' | Where-Object { $_ })
    $custom = @(Get-Prop $report 'custom_trades' | Where-Object { $_ })
    if ($values.Count) { Set-TradeMode $ui $true; Show-TradeResult $ui $values[0] }
    elseif ($custom.Count) { Set-TradeMode $ui $false; Show-TradeResult $ui $custom[0] }
    else { Show-TradeResult $ui $null }
}

function Update-TradeSides($ui) {
    $from = $ui.FromBox.SelectedItem
    $fromRoster = $null
    if ($from) { $fromRoster = @($script:TradeRosters) | Where-Object { $_.roster_id -eq $from.RosterId } | Select-Object -First 1 }
    $ui.GiveList.ItemsSource = @(if ($fromRoster) { @($fromRoster.players) | ForEach-Object {
        [pscustomobject]@{ Label = (Format-TradeLabel $_ $script:TradeWeeks); Id = $_.player_id; Name = $_.name; Window = $_.window_projection }
    } })
    $previous = $null
    if ($ui.PartnerBox.SelectedItem) { $previous = $ui.PartnerBox.SelectedItem.RosterId }
    $partners = @(@($script:TradeRosters) | Where-Object { -not $from -or $_.roster_id -ne $from.RosterId } | ForEach-Object {
        [pscustomobject]@{ Label = $(if ($_.team) { $_.team } else { 'Roster ' + $_.roster_id }); RosterId = $_.roster_id; IsMe = [bool]$_.is_me }
    })
    $ui.PartnerBox.ItemsSource = $partners
    $index = 0
    for ($i = 0; $i -lt $partners.Count; $i++) { if ($partners[$i].RosterId -eq $previous) { $index = $i } }
    $ui.PartnerBox.SelectedIndex = $(if ($partners.Count) { $index } else { -1 })
    Update-TradeGetList $ui
}

function Update-TradeGetList($ui) {
    $partner = $null
    $selected = $ui.PartnerBox.SelectedItem
    if ($selected) { $partner = @($script:TradeRosters) | Where-Object { $_.roster_id -eq $selected.RosterId } | Select-Object -First 1 }
    $ui.GetList.ItemsSource = @(if ($partner) { @($partner.players) | ForEach-Object {
        [pscustomobject]@{ Label = (Format-TradeLabel $_ $script:TradeWeeks); Id = $_.player_id; Name = $_.name; Window = $_.window_projection }
    } })
    $from = $ui.FromBox.SelectedItem
    if ($from -and -not $from.IsMe) {
        $ui.GiveHeader.Text = $from.Name + ' gives'
        $ui.GetHeader.Text = $(if ($selected) { $selected.Label + ' gives' } else { 'Team B gives' })
    } else {
        $ui.GiveHeader.Text = 'You give'
        $ui.GetHeader.Text = 'You get'
    }
    Update-TradePickSummary $ui
}

function Get-OpenScoring($ui) {
    $index = $ui.ScoringBox.SelectedIndex
    if ($index -lt 0) { $index = 0 }
    return @('ppr', 'half', 'std', 'league')[$index]
}

function Format-PoolLabel($entry, [string]$scoring, [int]$weeks) {
    $pts = Get-Prop $entry.window_points $scoring
    $label = '{0}   {1}/{2}   {3} pts' -f $entry.name, $entry.position, $(if ($entry.team) { $entry.team } else { 'FA' }), (Format-Points $pts)
    if ($weeks -gt 1) { $label += (' over {0} wks' -f $weeks) }
    if (Get-Prop $entry 'injury_status') { $label += '   [' + $entry.injury_status + ']' }
    return $label
}

function Get-PoolMatches([string]$text, [string]$scoring, [int]$limit = 40) {
    $terms = @(($text.ToLowerInvariant() -replace '[^a-z0-9 ]', ' ') -split '\s+' | Where-Object { $_ })
    $found = New-Object System.Collections.ArrayList
    foreach ($entry in @($script:PlayerPool)) {
        if ($terms.Count) {
            $hay = ' ' + (($entry.name.ToLowerInvariant() -replace '[^a-z0-9 ]', ' ') + ' ' + ([string]$entry.position).ToLowerInvariant() + ' ' + ([string]$entry.team).ToLowerInvariant()) + ' '
            $ok = $true
            foreach ($t in $terms) { if ($hay.IndexOf($t, [StringComparison]::Ordinal) -lt 0) { $ok = $false; break } }
            if (-not $ok) { continue }
        }
        [void]$found.Add($entry)
    }
    $sorted = @($found | Sort-Object -Property @{ Expression = { [double](Get-Prop $_.window_points $scoring) }; Descending = $true }, @{ Expression = { $_.name } })
    return @($sorted | Select-Object -First $limit)
}

function Update-OpenResults($ui, [string]$side) {
    $scoring = Get-OpenScoring $ui
    $search = $ui["Search$side"].Text
    if ($null -eq $search) { $search = '' }
    $ui["Results$side"].ItemsSource = @(Get-PoolMatches $search $scoring | ForEach-Object {
        [pscustomobject]@{ Label = (Format-PoolLabel $_ $scoring $script:TradeWeeks); Id = $_.player_id; Entry = $_ }
    })
}

function Update-OpenPicked($ui) {
    $scoring = Get-OpenScoring $ui
    foreach ($side in 'A', 'B') {
        $ui["Picked$side"].ItemsSource = @($script:OpenPicks[$side] | ForEach-Object {
            [pscustomobject]@{ Label = (Format-PoolLabel $_ $scoring $script:TradeWeeks); Id = $_.player_id; Entry = $_ }
        })
    }
    Update-TradePickSummary $ui
}

function Add-OpenPick($ui, [string]$side, $item) {
    if ($null -eq $item) { return }
    $other = $(if ($side -eq 'A') { 'B' } else { 'A' })
    $id = $item.Entry.player_id
    if (@($script:OpenPicks.A + $script:OpenPicks.B | Where-Object { $_.player_id -eq $id }).Count) { return }
    $script:OpenPicks[$side] = @($script:OpenPicks[$side]) + @($item.Entry)
    Update-OpenPicked $ui
}

function Remove-OpenPick($ui, [string]$side, $item) {
    if ($null -eq $item) { return }
    $script:OpenPicks[$side] = @($script:OpenPicks[$side] | Where-Object { $_.player_id -ne $item.Entry.player_id })
    Update-OpenPicked $ui
}

function Update-TradePickSummary($ui) {
    $sum = { param($values) $t = 0.0; foreach ($v in $values) { if ($null -ne $v) { $t += [double]$v } }; $t }
    if (Test-OpenMode $ui) {
        $scoring = Get-OpenScoring $ui
        $a = @($script:OpenPicks.A); $b = @($script:OpenPicks.B)
        $ui.TradePickSummary.Text = $(if ($a.Count -or $b.Count) {
            'Side A gives {0} ({1} pts)   Side B gives {2} ({3} pts)' -f $a.Count, (Format-Points (& $sum @($a | ForEach-Object { Get-Prop $_.window_points $scoring }))),
                $b.Count, (Format-Points (& $sum @($b | ForEach-Object { Get-Prop $_.window_points $scoring })))
        } else { '' })
        return
    }
    $give = @($ui.GiveList.SelectedItems | Where-Object { $_ })
    $get = @($ui.GetList.SelectedItems | Where-Object { $_ })
    $ui.TradePickSummary.Text = $(if ($give.Count -or $get.Count) {
        'Give {0} ({1} pts)   Get {2} ({3} pts)   over {4} wk(s)' -f $give.Count, (Format-Points (& $sum @($give | ForEach-Object { $_.Window }))),
            $get.Count, (Format-Points (& $sum @($get | ForEach-Object { $_.Window }))), $script:TradeWeeks
    } else { '' })
}

function Get-TradeText($ui) {
    if (Test-OpenMode $ui) {
        $give = @($script:OpenPicks.A | ForEach-Object { 'id:' + $_.player_id })
        $get = @($script:OpenPicks.B | ForEach-Object { 'id:' + $_.player_id })
    } else {
        $give = @($ui.GiveList.SelectedItems | Where-Object { $_ } | ForEach-Object { 'id:' + $_.Id })
        $get = @($ui.GetList.SelectedItems | Where-Object { $_ } | ForEach-Object { 'id:' + $_.Id })
    }
    if ($give.Count -eq 0 -or $get.Count -eq 0) { return $null }
    return ($give -join ', ') + ' for ' + ($get -join ', ')
}

function Clear-TradePicks($ui) {
    $script:OpenPicks = @{ A = @(); B = @() }
    Update-OpenPicked $ui
    Show-TradeResult $ui $null
}

function Show-TradeResult($ui, $t) {
    if ($null -eq $t) {
        Set-GradeText $ui.YouGrade ''; Set-GradeText $ui.ThemGrade ''
        $ui.AcceptText.Text = ''
        $ui.VerdictText.Text = 'Pick the players on each side, then press Grade trade.'
        $ui.TradeDetail.Text = ''
        return
    }
    if (Get-Prop $t 'error') {
        Set-GradeText $ui.YouGrade ''; Set-GradeText $ui.ThemGrade ''
        $ui.AcceptText.Text = ''
        $ui.VerdictText.Text = 'Could not grade this trade: ' + $t.error
        $ui.TradeDetail.Text = ''
        return
    }
    $open = (Get-Prop $t 'mode') -eq 'open'
    $sideA = Get-Prop $t 'side_a'
    $isMe = (-not $open) -and ($null -eq $sideA -or $sideA.is_me)
    if ($open) { $aName = 'Side A'; $bName = 'Side B' }
    elseif ($isMe) { $aName = 'You'; $bName = $(if ($t.partner.team) { $t.partner.team } else { 'Them' }) }
    else { $aName = $(if ($sideA.team) { $sideA.team } else { 'Team A' }); $bName = $(if ($t.partner.team) { $t.partner.team } else { 'Team B' }) }

    Set-GradeText $ui.YouGrade $t.my_grade
    Set-GradeText $ui.ThemGrade $t.their_grade
    $ui.YouLabel.Text = $(if ($open) { 'Side A' } elseif ($isMe) { 'Your grade' } else { $aName + "'s grade" })
    $ui.ThemLabel.Text = $(if ($open) { 'Side B' } else { $bName + "'s grade" })
    $ui.AcceptText.Text = 'Chance ' + $(if ($open) { 'side B' } elseif ($isMe) { 'they' } else { $bName }) + ' accept' + $(if ($isMe) { '' } else { 's' }) + ': ' + $t.acceptance
    $ui.VerdictText.Text = $t.verdict
    $weeks = @($t.window_weeks)
    $lines = @()
    $grades = Get-Prop $t 'grades'
    if ($grades -and $weeks.Count -gt 1) {
        $tw = $grades.this_week; $win = $grades.window
        $lines += ('This week (week {0}):  {1} {2},  {3} {4}      {5}:  {1} {6},  {3} {7}' -f $tw.week, $aName, $tw.my_grade,
            $bName, $tw.their_grade, $win.label, $win.my_grade, $win.their_grade)
        $lines += ''
    }
    if ($open) {
        $scoringLabel = @{ ppr = 'PPR'; half = 'half-PPR'; std = 'standard'; league = "your league's scoring" }[[string]$t.scoring]
        $lines += ('{0}, {1}-team league, weeks {2}' -f $scoringLabel, $t.teams, ($weeks -join ', '))
        $lines += ('Value above replacement per week:  side A {0},  side B {1}' -f (Format-Points $t.my_gain_per_week), (Format-Points $t.their_gain_per_week))
        $lines += ''
        $lines += 'Side A gives:'
        foreach ($p in @($t.give)) { $lines += ('   {0} ({1}/{2}) - {3} pts, {4} above replacement' -f $p.name, $p.position, $(if ($p.team) { $p.team } else { 'FA' }), (Format-Points $p.window_points), (Format-Points $p.value_over_replacement)) }
        $lines += 'Side B gives:'
        foreach ($p in @($t.get)) { $lines += ('   {0} ({1}/{2}) - {3} pts, {4} above replacement' -f $p.name, $p.position, $(if ($p.team) { $p.team } else { 'FA' }), (Format-Points $p.window_points), (Format-Points $p.value_over_replacement)) }
    } else {
        $a = $(if ($isMe) { 'you' } else { $aName }); $b = $(if ($isMe) { 'them' } else { $bName })
        $lines += ('Gain per week:  {0} {1},  {2} {3}' -f $a, (Format-Points $t.my_gain_per_week), $b, (Format-Points $t.their_gain_per_week))
        $lines += ('Over weeks {0}:  {1} {2},  {3} {4}' -f ($weeks -join ', '), $a, (Format-Points $t.my_gain), $b, (Format-Points $t.their_gain))
        if ($weeks.Count -gt 1) {
            $parts = @(); for ($i = 0; $i -lt $weeks.Count; $i++) { $parts += ('wk {0}: {1}' -f $weeks[$i], (Format-Points @($t.my_weekly_gains)[$i])) }
            $lines += ('{0} gain by week:  ' -f $(if ($isMe) { 'Your' } else { $aName })) + ($parts -join ',  ')
        }
        $lines += ''
        $lines += $(if ($isMe) { 'You give:' } else { $aName + ' gives:' })
        foreach ($p in @($t.give)) { $lines += ('   {0} ({1}) - started {2} of {3} wks' -f $p.name, $p.position, $p.weeks_started_before, $weeks.Count) }
        $lines += $(if ($isMe) { 'You get:' } else { $bName + ' gives:' })
        foreach ($p in @($t.get)) { $lines += ('   {0} ({1}) - would start {2} of {3} wks' -f $p.name, $p.position, $p.weeks_started_after, $weeks.Count) }
    }
    $extra = @(@($t.notes) + @($t.flags) | Where-Object { $_ })
    if ($extra.Count) { $lines += ''; foreach ($e in $extra) { $lines += ('- ' + $e) } }
    $ui.TradeDetail.Text = ($lines -join "`n")
}

function Import-ReportFile([string]$path) {
    return ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path, $Utf8NoBom))
}

function Show-ReportWindow([string]$InitialReport, [switch]$SmokeTest) {
    if (-not $IsWindowsHost) {
        Write-Log 'ERROR' 'The window needs Windows. Use -NoGui for the JSON report on this system.'
        $script:ExitCode = $EX_DEPENDENCY
        return
    }
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        # WPF needs a single-threaded apartment; relaunch this script with -STA.
        $hostExe = (Get-Process -Id $PID).Path
        $relaunch = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $script:ScriptPath) + $script:OriginalArgs
        $p = Start-Process -FilePath $hostExe -ArgumentList ($relaunch | ForEach-Object { ConvertTo-Argument $_ }) -Wait -PassThru -NoNewWindow
        $script:ExitCode = $p.ExitCode
        return
    }
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    [xml]$xaml = $script:WindowXaml
    $window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
    $ui = @{ Window = $window }
    foreach ($name in @('PlatformBox', 'UserLabel', 'LeagueBox', 'UserBox', 'WeekBox', 'HorizonBox', 'FreshBox', 'RememberBox', 'RefreshButton', 'OpenButton', 'SaveButton',
            'Busy', 'StatusText', 'TitleText', 'SubtitleText', 'NoticeText', 'MyTeamText', 'MyScoreText', 'MyProjText',
            'OppTeamText', 'OppScoreText', 'OppProjText', 'WarningsExpander', 'WarningsHeader', 'WarningsList',
            'LineupSummary', 'LineupGrid', 'RiskGrid', 'WaiverSummary', 'WaiverGrid', 'TradeSummary', 'TradeGrid',
            'MatchupDetail', 'HistorySummary', 'HistoryAccGrid', 'HistoryFormGrid', 'TrendsSummary', 'BreakoutGrid', 'DecliningGrid', 'SourcesSummary', 'SourcesGrid', 'DiagSummary', 'DiagGrid', 'Tabs', 'AnalyzerTab', 'PartnerBox', 'GiveList', 'GetList',
            'GradeButton', 'ClearTradeButton', 'TradePickSummary', 'YouGrade', 'ThemGrade', 'ThemLabel', 'AcceptText',
            'VerdictText', 'TradeDetail', 'YouLabel', 'LeagueModeRadio', 'OpenModeRadio', 'LeaguePanel', 'OpenPanel',
            'FromBox', 'GiveHeader', 'GetHeader', 'ScoringBox', 'TeamsBox', 'SearchA', 'SearchB', 'ResultsA', 'ResultsB',
            'PickedA', 'PickedB')) {
        $ui[$name] = $window.FindName($name)
    }
    $script:Ui = $ui
    $script:CurrentReportPath = $null

    # Each platform keeps its own league and user/team; switching the
    # platform box swaps them in and out of the toolbar.
    $script:Leagues = @{ sleeper = @{ League = ''; Who = '' }; espn = @{ League = ''; Who = '' } }

    # Defaults for the inputs follow the normal precedence (CLI > env > config > defaults).
    $cfg = $null
    try { $cfg = Get-EffectiveConfig } catch { $cfg = $null }
    if ($cfg) {
        $script:ConfigPath = $cfg.config_file
        $ui.LeagueBox.Text = $cfg.league_id
        $isEspn = ((Get-Prop $cfg 'platform') -eq 'espn')
        $ui.PlatformBox.SelectedIndex = $(if ($isEspn) { 1 } else { 0 })
        $ui.UserBox.Text = $(if ($isEspn) { [string](Get-Prop $cfg 'team') } else { $cfg.username })
        $savedCfg = Get-Prop $cfg 'saved'
        if ($savedCfg) {
            $script:Leagues.sleeper.League = [string]$savedCfg.sleeper.league_id; $script:Leagues.sleeper.Who = [string]$savedCfg.sleeper.username
            $script:Leagues.espn.League = [string]$savedCfg.espn.league_id; $script:Leagues.espn.Who = [string]$savedCfg.espn.team
        }
        $ui.WeekBox.Text = $cfg.week
        $ui.HorizonBox.SelectedIndex = ConvertTo-HorizonIndex $cfg.horizon
    } else {
        $script:ConfigPath = Join-Path (Get-DefaultDir 'config') 'config.env'
        if ($script:BoundParams.ContainsKey('Config')) { $script:ConfigPath = [string]$script:BoundParams['Config'] }
        $ui.LeagueBox.Text = $Defaults.league_id
        $ui.PlatformBox.SelectedIndex = 0
        $ui.UserBox.Text = $Defaults.username
        $ui.HorizonBox.SelectedIndex = [int]$Defaults.horizon
    }

    # The second box is a Sleeper username or an ESPN team, by platform.
    $ui.UserLabel.Text = $(if ($ui.PlatformBox.SelectedIndex -eq 1) { 'Team' } else { 'User' })
    $script:PlatformName = $(if ($ui.PlatformBox.SelectedIndex -eq 1) { 'espn' } else { 'sleeper' })
    $ui.PlatformBox.Add_SelectionChanged({
        $ui = $script:Ui
        $now = $(if ($ui.PlatformBox.SelectedIndex -eq 1) { 'espn' } else { 'sleeper' })
        if ($now -eq $script:PlatformName) { return }
        # Keep what was typed for the platform being left, show the other one's.
        $script:Leagues[$script:PlatformName].League = $ui.LeagueBox.Text.Trim()
        $script:Leagues[$script:PlatformName].Who = $ui.UserBox.Text.Trim()
        $script:PlatformName = $now
        $ui.LeagueBox.Text = $script:Leagues[$now].League
        $ui.UserBox.Text = $script:Leagues[$now].Who
        $ui.UserLabel.Text = $(if ($now -eq 'espn') { 'Team' } else { 'User' })
    })

    $loadReport = {
        param([string]$path)
        $report = Import-ReportFile $path
        Update-ReportView $script:Ui $report
        $script:CurrentReport = $report
        $script:CurrentReportPath = $path
        $script:Ui.SaveButton.IsEnabled = $true
    }
    $script:LoadReport = $loadReport
    $script:CurrentReport = $null

    # One background job at a time (refresh or trade grade). The data layer
    # runs as a separate process so the window stays responsive.
    $script:Job = $null
    $script:StartJob = {
        param([string[]]$extraArgs, [scriptblock]$onSuccess, [string]$busyText, [string]$failText)
        $ui = $script:Ui
        if ($script:Job) { return }
        $work = Join-Path ([IO.Path]::GetTempPath()) 'fantasy_manager_gui'
        if (-not (Test-Path -LiteralPath $work)) { New-Item -ItemType Directory -Path $work | Out-Null }
        $out = Join-Path $work ('report_{0}.json' -f [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $log = Join-Path $work 'last_run.log'
        if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }
        $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:ScriptPath, '-NoGui',
            '-OutFile', $out, '-LogFile', $log) + $extraArgs
        foreach ($pass in @('Season', 'SeasonType', 'Top', 'Threshold', 'Fairness', 'Locked', 'CacheDir', 'Config', 'Python', 'Fixtures', 'HistoryDb', 'Compare', 'Projections')) {
            if ($script:BoundParams.ContainsKey($pass)) { $childArgs += @("-$pass", [string]$script:BoundParams[$pass]) }
        }
        foreach ($flag in @('Offline', 'NoCache', 'SkipWaivers', 'SkipTrades', 'NoHistory')) {
            if ($script:BoundParams.ContainsKey($flag) -and $childArgs -notcontains "-$flag") { $childArgs += "-$flag" }
        }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-Process -Id $PID).Path
        $psi.Arguments = (($childArgs | ForEach-Object { ConvertTo-Argument $_ }) -join ' ')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $script:Job = @{ Proc = [Diagnostics.Process]::Start($psi); Out = $out; Log = $log; OnSuccess = $onSuccess; FailText = $failText }
        $ui.Busy.Visibility = 'Visible'
        $ui.RefreshButton.IsEnabled = $false
        $ui.GradeButton.IsEnabled = $false
        $ui.StatusText.Text = $busyText
        $script:Timer.Start()
    }

    $script:Timer = New-Object Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $script:Timer.Add_Tick({
        $job = $script:Job
        if ($null -eq $job -or -not $job.Proc.HasExited) { return }
        $script:Timer.Stop()
        $script:Job = $null
        $ui = $script:Ui
        $ui.Busy.Visibility = 'Collapsed'
        $ui.RefreshButton.IsEnabled = $true
        $ui.GradeButton.IsEnabled = $true
        $logText = ''
        if (Test-Path -LiteralPath $job.Log) { $logText = [IO.File]::ReadAllText($job.Log) }
        if ($job.Proc.ExitCode -eq 0 -and (Test-Path -LiteralPath $job.Out)) {
            try {
                & $job.OnSuccess $job.Out
            } catch {
                $ui.StatusText.Text = 'Could not read the report.'
                [Windows.MessageBox]::Show($_.Exception.Message, 'Fantasy Manager', 'OK', 'Error') | Out-Null
            }
        } else {
            $errors = @($logText -split "`n" | Where-Object { $_ -match '\[ERROR\]' } | ForEach-Object { ($_ -replace '^\S+ \[ERROR\] ', '').Trim() })
            $message = $(if ($errors.Count) { $errors -join "`n" } else { "$($job.FailText) (exit code $($job.Proc.ExitCode))." })
            $ui.StatusText.Text = $job.FailText
            [Windows.MessageBox]::Show($message, 'Fantasy Manager', 'OK', 'Warning') | Out-Null
        }
    })

    $ui.RefreshButton.Add_Click({
        $ui = $script:Ui
        $espn = ($ui.PlatformBox.SelectedIndex -eq 1)
        $who = $ui.UserBox.Text.Trim()
        $extra = @('-Platform', $(if ($espn) { 'espn' } else { 'sleeper' }), '-LeagueId', $ui.LeagueBox.Text.Trim())
        if ($who) { $extra += @($(if ($espn) { '-Team' } else { '-Username' }), $who) }
        if ($ui.WeekBox.Text.Trim()) { $extra += @('-Week', $ui.WeekBox.Text.Trim()) }
        if ($ui.HorizonBox.SelectedIndex -ge 0) { $extra += @('-Horizon', (ConvertFrom-HorizonIndex $ui.HorizonBox.SelectedIndex)) }
        if ($ui.FreshBox.IsChecked) { $extra += '-Refresh' }
        # Saved only after the refresh succeeds, so a typo is never remembered.
        $script:PendingDefaults = $null
        if ($ui.RememberBox.IsChecked) {
            # Each platform's league is saved under its own keys, so both are
            # kept. The plain keys from earlier versions are folded into them.
            $name = $(if ($espn) { 'espn' } else { 'sleeper' })
            $script:Leagues[$name].League = $ui.LeagueBox.Text.Trim(); $script:Leagues[$name].Who = $who
            $script:PendingDefaults = [ordered]@{ platform = $name; league_id = $null; username = $null; team = $null }
            foreach ($entry in @(@('sleeper_league_id', $script:Leagues.sleeper.League), @('sleeper_username', $script:Leagues.sleeper.Who),
                                 @('espn_league_id', $script:Leagues.espn.League), @('espn_team', $script:Leagues.espn.Who))) {
                if ($entry[1]) { $script:PendingDefaults[$entry[0]] = $entry[1] }
            }
            $script:PendingDefaults['horizon'] = ConvertFrom-HorizonIndex ([Math]::Max(0, $ui.HorizonBox.SelectedIndex))
        }
        & $script:StartJob $extra {
            param($path)
            & $script:LoadReport $path
            $status = 'Updated ' + (Get-Date).ToString('h:mm tt')
            if ($script:PendingDefaults) {
                try {
                    [void](Save-Defaults $script:ConfigPath $script:PendingDefaults)
                    $status += ' - saved as default'
                } catch {
                    $status += ' - could not save defaults'
                    [Windows.MessageBox]::Show("Could not save your defaults to $($script:ConfigPath): $($_.Exception.Message)", 'Fantasy Manager', 'OK', 'Warning') | Out-Null
                }
            }
            $script:Ui.StatusText.Text = $status
        } 'Fetching league data...' 'Update failed'
    })

    # Trade Analyzer state before any report is loaded.
    $script:OpenPicks = @{ A = @(); B = @() }
    $script:PlayerPool = @()
    $script:TradeRosters = @()
    $script:TradeWeeks = 1
    $ui.FromBox.Add_SelectionChanged({ Update-TradeSides $script:Ui })
    $ui.PartnerBox.Add_SelectionChanged({ Update-TradeGetList $script:Ui })
    $ui.GiveList.Add_SelectionChanged({ Update-TradePickSummary $script:Ui })
    $ui.GetList.Add_SelectionChanged({ Update-TradePickSummary $script:Ui })
    $ui.LeagueModeRadio.Add_Checked({ Set-TradeMode $script:Ui $false })
    $ui.OpenModeRadio.Add_Checked({ Set-TradeMode $script:Ui $true })
    $ui.ScoringBox.Add_SelectionChanged({ Update-OpenResults $script:Ui 'A'; Update-OpenResults $script:Ui 'B'; Update-OpenPicked $script:Ui })
    $ui.SearchA.Add_TextChanged({ Update-OpenResults $script:Ui 'A' })
    $ui.SearchB.Add_TextChanged({ Update-OpenResults $script:Ui 'B' })
    foreach ($side in 'A', 'B') {
        # A click adds a result to the side; clicking a picked player removes it.
        $ui["Results$side"].Tag = $side
        $ui["Picked$side"].Tag = $side
        $ui["Results$side"].Add_SelectionChanged({
            param($sender, $e)
            $item = $sender.SelectedItem
            if ($null -eq $item) { return }
            Add-OpenPick $script:Ui ([string]$sender.Tag) $item
            $sender.SelectedIndex = -1
        })
        $ui["Picked$side"].Add_SelectionChanged({
            param($sender, $e)
            $item = $sender.SelectedItem
            if ($null -eq $item) { return }
            Remove-OpenPick $script:Ui ([string]$sender.Tag) $item
        })
    }
    $ui.ClearTradeButton.Add_Click({
        $script:Ui.GiveList.UnselectAll(); $script:Ui.GetList.UnselectAll()
        Clear-TradePicks $script:Ui
    })
    $ui.GradeButton.Add_Click({
        $ui = $script:Ui
        $report = $script:CurrentReport
        if (-not $report) { $ui.VerdictText.Text = 'Load a report first (Refresh).'; return }
        $text = Get-TradeText $ui
        if (-not $text) { $ui.VerdictText.Text = 'Pick at least one player on each side.'; return }
        # Grade against the same league, week and window as the loaded report.
        $meta = $report.metadata
        $gradeHorizon = $(if ((Get-Prop $meta 'horizon_mode') -eq 'ros') { 'ros' } else { [string]([Math]::Max(0, [Math]::Min(6, @($meta.window_weeks).Count - 1))) })
        $extra = @('-LeagueId', [string]$meta.league_id, '-Week', [string]$meta.week,
            '-Horizon', $gradeHorizon, '-SkipWaivers', '-SkipTrades')
        if ((Get-Prop $meta 'platform') -eq 'espn') { $extra += @('-Platform', 'espn', '-Team', [string]$meta.roster_id) }
        else { $extra += @('-Platform', 'sleeper', '-Username', [string]$meta.username) }
        if (Test-OpenMode $ui) {
            $teams = $ui.TeamsBox.Text.Trim()
            if ($teams -notmatch '^\d+$' -or [int]$teams -lt 4 -or [int]$teams -gt 32) { $ui.VerdictText.Text = 'League size must be 4 to 32.'; return }
            $extra += @('-ValueTrade', $text, '-Scoring', (Get-OpenScoring $ui), '-Teams', $teams)
            $section = 'value_trades'
        } else {
            $extra += @('-Trade', $text)
            $section = 'custom_trades'
        }
        $script:GradeSection = $section
        $ui.VerdictText.Text = 'Grading...'
        & $script:StartJob $extra {
            param($path)
            $result = Import-ReportFile $path
            $trades = @(Get-Prop $result $script:GradeSection | Where-Object { $_ })
            Show-TradeResult $script:Ui $(if ($trades.Count) { $trades[0] } else { $null })
            $script:Ui.StatusText.Text = 'Trade graded ' + (Get-Date).ToString('h:mm tt')
        } 'Grading trade...' 'Grading failed'
    })

    $ui.OpenButton.Add_Click({
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = 'Report JSON (*.json)|*.json|All files (*.*)|*.*'
        if ($dlg.ShowDialog()) {
            try {
                & $script:LoadReport $dlg.FileName
                $script:Ui.StatusText.Text = 'Opened ' + [IO.Path]::GetFileName($dlg.FileName)
            } catch {
                [Windows.MessageBox]::Show("Not a fantasy_manager report: $($_.Exception.Message)", 'Fantasy Manager', 'OK', 'Warning') | Out-Null
            }
        }
    })

    $ui.SaveButton.Add_Click({
        if (-not $script:CurrentReportPath) { return }
        $dlg = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.Filter = 'Report JSON (*.json)|*.json'
        $dlg.FileName = 'fantasy_report.json'
        if ($dlg.ShowDialog()) {
            Copy-Item -LiteralPath $script:CurrentReportPath -Destination $dlg.FileName -Force
            $script:Ui.StatusText.Text = 'Saved ' + [IO.Path]::GetFileName($dlg.FileName)
        }
    })

    if ($InitialReport) {
        try {
            & $loadReport ([IO.Path]::GetFullPath($InitialReport))
            $ui.StatusText.Text = 'Opened ' + [IO.Path]::GetFileName($InitialReport)
        } catch {
            Write-Log 'ERROR' "Could not load report '$InitialReport': $($_.Exception.Message)"
            $script:ExitCode = $EX_DATA
            if ($SmokeTest) { return }
        }
    } elseif (-not $SmokeTest) {
        $window.Add_ContentRendered({ $script:Ui.RefreshButton.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent))) })
    }

    if ($SmokeTest) {
        # Build and lay out the window without showing it (used by CI).
        $window.Measure((New-Object Windows.Size 1180, 800))
        $window.Arrange((New-Object Windows.Rect 0, 0, 1180, 800))
        $window.UpdateLayout()
        # Exercise the any-player picker too: search, add one player per side.
        $ui.SearchA.Text = ''
        Update-OpenResults $ui 'A'; Update-OpenResults $ui 'B'
        $firstA = @($ui.ResultsA.ItemsSource) | Select-Object -First 1
        $secondB = @($ui.ResultsB.ItemsSource) | Select-Object -Skip 1 -First 1
        $savedPicks = $script:OpenPicks
        Add-OpenPick $ui 'A' $firstA; Add-OpenPick $ui 'B' $secondB
        $openText = Get-TradeText $ui
        $pickedCount = @($ui.PickedA.ItemsSource).Count + @($ui.PickedB.ItemsSource).Count
        $script:OpenPicks = $savedPicks; Update-OpenPicked $ui
        # Switch the platform and back: each one shows its own league and user/team.
        $startIndex = $ui.PlatformBox.SelectedIndex
        $ui.PlatformBox.SelectedIndex = 1 - $startIndex
        $toggled = '{0} {1}/{2}' -f $script:PlatformName, $ui.LeagueBox.Text, $ui.UserBox.Text
        $ui.PlatformBox.SelectedIndex = $startIndex
        $toggled += ', back {0} {1}/{2}' -f $script:PlatformName, $ui.LeagueBox.Text, $ui.UserBox.Text
        [Console]::Out.WriteLine('platform toggle: ' + $toggled)
        [Console]::Out.WriteLine(('GUI smoke test ok: lineup rows {0}, waiver rows {1}, trade rows {2}, warnings {3}, give list {4}, get list {5}, trade grade {6}, mode {7}, pool results {8}, picked {9}' -f
            @($ui.LineupGrid.ItemsSource).Count, @($ui.WaiverGrid.ItemsSource).Count, @($ui.TradeGrid.ItemsSource).Count,
            @($ui.WarningsList.ItemsSource).Count, @($ui.GiveList.ItemsSource).Count, @($ui.GetList.ItemsSource).Count, $ui.YouGrade.Text,
            $(if (Test-OpenMode $ui) { 'open' } else { 'league' }), @($ui.ResultsA.ItemsSource).Count, $pickedCount) +
            (', remember {0}, history rows {1}, form rows {2}, breakouts {4}, declining {5}, sources {6}, win {3}' -f [bool]$ui.RememberBox.IsChecked,
                @($ui.HistoryAccGrid.ItemsSource).Count, @($ui.HistoryFormGrid.ItemsSource).Count,
                $(if ($ui.MyProjText.Text -match 'win ([\d.]+)%') { $Matches[1] } else { 'n/a' }),
                @($ui.BreakoutGrid.ItemsSource).Count, @($ui.DecliningGrid.ItemsSource).Count, @($ui.SourcesGrid.ItemsSource).Count))
        $window.Close()
        return
    }
    [void]$window.ShowDialog()
    if ($script:Job -and -not $script:Job.Proc.HasExited) { try { $script:Job.Proc.Kill() } catch { } }
}


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
$script:BoundParams = $PSBoundParameters
$script:OriginalArgs = @()
foreach ($kv in $PSBoundParameters.GetEnumerator()) {
    if ($kv.Value -is [System.Management.Automation.SwitchParameter]) {
        if ($kv.Value.IsPresent) { $script:OriginalArgs += "-$($kv.Key)" }
    } else {
        $script:OriginalArgs += @("-$($kv.Key)", [string]$kv.Value)
    }
}
$script:ScriptPath = $MyInvocation.MyCommand.Path

if ($Version) { [Console]::Out.WriteLine("$ToolName $ToolVersion"); exit $EX_OK }

if ($ReportFile -and -not $NoGui) {
    Show-ReportWindow -InitialReport $ReportFile -SmokeTest:$GuiSmokeTest
    exit $script:ExitCode
}
if (-not $NoGui) {
    Show-ReportWindow -SmokeTest:$GuiSmokeTest
    exit $script:ExitCode
}

# -NoGui: run fm_app.py. The report goes to a file and is printed from there,
# so console code pages never touch it. JSON is the default format here.
# Diagnostics are captured and relayed as UTF-8: Windows PowerShell 5.1 does
# not pass a redirected stderr on to the Python process.
$appArgs = ConvertTo-AppArgs $script:BoundParams
if (-not $script:BoundParams.ContainsKey('Format')) { $appArgs += @('--format', 'json') }
$tmpReport = $null
if ($OutFile) {
    $appArgs += @('--output', [IO.Path]::GetFullPath($OutFile))
} else {
    $tmpReport = Join-Path ([IO.Path]::GetTempPath()) ('fantasy_manager_{0}.out' -f [Guid]::NewGuid().ToString('N').Substring(0, 8))
    $appArgs += @('--output', $tmpReport)
}
try {
    $r = Invoke-App $appArgs $true
    if ($r) {
        $script:ExitCode = $r.Code
        if ($r.Err) {
            $stderr = [Console]::OpenStandardError()
            $errBytes = $Utf8NoBom.GetBytes($r.Err)
            $stderr.Write($errBytes, 0, $errBytes.Length)
            $stderr.Flush()
        }
        if ($tmpReport -and $r.Code -eq 0 -and (Test-Path -LiteralPath $tmpReport)) {
            $stdout = [Console]::OpenStandardOutput()
            $bytes = [IO.File]::ReadAllBytes($tmpReport)
            $stdout.Write($bytes, 0, $bytes.Length)
            $stdout.Flush()
        }
    }
} finally {
    if ($tmpReport -and (Test-Path -LiteralPath $tmpReport)) { Remove-Item -LiteralPath $tmpReport -Force -ErrorAction SilentlyContinue }
}
exit $script:ExitCode
