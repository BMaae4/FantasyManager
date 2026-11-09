#Requires -Version 5.1
<#
.SYNOPSIS
    Sleeper weekly decision support (lineup / waivers / trades) for Windows,
    with a WPF window for the report.

.DESCRIPTION
    PowerShell front end for fantasy_manager. It fetches, caches and validates
    Sleeper data exactly like fantasy_manager.sh and runs the same Python
    analysis (lib/fm_analysis.py), so both front ends produce the same report.

    With no arguments it opens the window and loads the current week. Use
    -NoGui to print the JSON report instead.

    Read-only: it cannot submit lineups, waiver claims or trades.

    Requirements: Windows PowerShell 5.1 or PowerShell 7+, Python 3.8+
    (python.org or the "py" launcher). No bash, jq or curl needed.

.EXAMPLE
    .\FantasyManager.ps1
    Opens the window for the default league and user.

.EXAMPLE
    .\FantasyManager.ps1 -NoGui -OutFile report.json
    Writes the JSON report without opening a window.

.EXAMPLE
    .\FantasyManager.ps1 -ReportFile report.json
    Opens a saved report in the window.
#>
[CmdletBinding()]
param(
    [string]$LeagueId,
    [string]$Username,
    [string]$Week,
    [string]$Season,
    [string]$SeasonType,
    [string]$Top,
    [string]$Threshold,
    [string]$Fairness,
    [string]$Horizon,
    [string]$Locked,
    [switch]$SkipWaivers,
    [switch]$SkipTrades,
    [switch]$NoGui,
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
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with progress on 5.1

$ToolName = 'fantasy_manager'
$ToolVersion = '2.3.0'

# --------------------------------------------------------------------------
# Defaults (kept in step with fantasy_manager.sh)
# --------------------------------------------------------------------------
$Defaults = [ordered]@{
    league_id        = '1400680781302525952'
    username         = 'MaTrasaMaae'
    api              = 'https://api.sleeper.app/v1'
    projections_base = 'https://api.sleeper.app/projections/nfl'
    schedule_base    = 'https://api.sleeper.com/schedule/nfl'
    season_type      = 'regular'
    top_n            = '10'
    threshold        = '0.5'
    fairness         = '0.10'
    horizon          = '3'
    players_ttl      = '86400'
    projections_ttl  = '21600'
    trending_ttl     = '21600'
    schedule_ttl     = '300'
    stale_max_age    = '604800'
}

$EX_OK = 0; $EX_USAGE = 2; $EX_DEPENDENCY = 3; $EX_DATA = 4

$IsWindowsHost = ($PSVersionTable.PSVersion.Major -lt 6) -or ((Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue) -eq $true)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AnalysisPy = Join-Path (Join-Path $ScriptDir 'lib') 'fm_analysis.py'
$IoPy = Join-Path (Join-Path $ScriptDir 'lib') 'fm_io.py'
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

# --------------------------------------------------------------------------
# Logging (diagnostics on stderr and optional log file; report on stdout)
# --------------------------------------------------------------------------
$script:LogLevel = 'INFO'
$script:LogPath = $null
$script:Warnings = New-Object System.Collections.ArrayList
$script:Diagnostics = New-Object System.Collections.ArrayList
$script:ExitCode = $EX_OK

function Get-LevelValue([string]$level) {
    switch ($level) {
        'ERROR' { 0 } 'WARN' { 1 } 'INFO' { 2 } 'DEBUG' { 3 } 'QUIET' { 0 } default { 2 }
    }
}

function Write-Log([string]$level, [string]$message) {
    if ((Get-LevelValue $level) -gt (Get-LevelValue $script:LogLevel)) { return }
    $line = '{0} [{1}] {2}' -f ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', $Invariant)), $level, $message
    $line = $line -replace '([?&](access_token|api_key|token|key)=)[^&\s]+', '$1***REDACTED***'
    [Console]::Error.WriteLine($line)
    if ($script:LogPath) {
        [IO.File]::AppendAllText($script:LogPath, $line + "`n", $Utf8NoBom)
    }
}

function Add-Warning([string]$message) {
    [void]$script:Warnings.Add($message)
    Write-Log 'WARN' $message
}

function Stop-Run([int]$code, [string]$message) {
    Write-Log 'ERROR' $message
    $script:ExitCode = $code
    throw 'FM_EXIT'
}

function Get-NowIso { [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', $Invariant) }

# --------------------------------------------------------------------------
# Configuration: CLI > environment (FM_*) > config file > defaults
# --------------------------------------------------------------------------
$script:FileValues = @{}

function Read-ConfigFile([string]$path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Log 'DEBUG' "No config file at $path"
        return
    }
    foreach ($raw in [IO.File]::ReadAllLines($path)) {
        $line = $raw
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        $idx = $line.IndexOf('=')
        if ($idx -lt 0) { continue }
        $key = ($line.Substring(0, $idx) -replace '\s', '').ToLowerInvariant()
        if ($key.StartsWith('fm_')) { $key = $key.Substring(3) }
        $value = $line.Substring($idx + 1).Trim('"').Trim("'")
        $script:FileValues[$key] = $value
    }
    Write-Log 'DEBUG' ("Loaded config file {0} ({1} keys)" -f $path, $script:FileValues.Count)
}

function Resolve-Setting([string]$key, [string]$envName, $cliValue, [bool]$cliSet, [string]$default) {
    if ($cliSet) { return [string]$cliValue }
    $envValue = [Environment]::GetEnvironmentVariable($envName)
    if ($envValue) { return $envValue }
    if ($script:FileValues.ContainsKey($key)) { return $script:FileValues[$key] }
    return $default
}

function Test-UInt([string]$value) { return $value -match '^[0-9]+$' }
function Test-Number([string]$value) { return $value -match '^-?[0-9]+(\.[0-9]+)?$' }

function Initialize-Configuration {
    $bp = $script:BoundParams
    function Test-CliSet([string]$name) { return $bp.ContainsKey($name) }

    $cfgFile = Resolve-Setting 'config_file' 'FM_CONFIG_FILE' $Config (Test-CliSet 'Config') (Join-Path (Get-DefaultDir 'config') 'config.env')
    Read-ConfigFile $cfgFile

    $levelCli = $null
    if (Test-CliSet 'Quiet') { $levelCli = 'QUIET' } elseif (Test-CliSet 'DebugLog') { $levelCli = 'DEBUG' }
    $script:LogLevel = Resolve-Setting 'log_level' 'FM_LOG_LEVEL' $levelCli ($null -ne $levelCli) 'INFO'
    $logPath = Resolve-Setting 'log_file' 'FM_LOG_FILE' $LogFile (Test-CliSet 'LogFile') ''
    if ($logPath) {
        $dir = Split-Path -Parent ([IO.Path]::GetFullPath($logPath))
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $script:LogPath = [IO.Path]::GetFullPath($logPath)
    }

    $c = [ordered]@{}
    $c.config_file      = $cfgFile
    $c.league_id        = Resolve-Setting 'league_id' 'FM_LEAGUE_ID' $LeagueId (Test-CliSet 'LeagueId') $Defaults.league_id
    $c.username         = Resolve-Setting 'username' 'FM_USERNAME' $Username (Test-CliSet 'Username') $Defaults.username
    $c.api              = Resolve-Setting 'api' 'FM_API' $null $false $Defaults.api
    $c.projections_base = Resolve-Setting 'projections_base' 'FM_PROJECTIONS_BASE' $null $false $Defaults.projections_base
    $c.schedule_base    = Resolve-Setting 'schedule_base' 'FM_SCHEDULE_BASE' $null $false $Defaults.schedule_base
    $c.schedule_ttl     = Resolve-Setting 'schedule_ttl' 'FM_SCHEDULE_TTL' $null $false $Defaults.schedule_ttl
    $c.week             = Resolve-Setting 'week' 'FM_WEEK' $Week (Test-CliSet 'Week') ''
    $c.season           = Resolve-Setting 'season' 'FM_SEASON' $Season (Test-CliSet 'Season') ''
    $c.season_type      = Resolve-Setting 'season_type' 'FM_SEASON_TYPE' $SeasonType (Test-CliSet 'SeasonType') $Defaults.season_type
    $c.top_n            = Resolve-Setting 'top_n' 'FM_TOP_N' $Top (Test-CliSet 'Top') $Defaults.top_n
    $c.threshold        = Resolve-Setting 'threshold' 'FM_THRESHOLD' $Threshold (Test-CliSet 'Threshold') $Defaults.threshold
    $c.fairness         = Resolve-Setting 'fairness' 'FM_FAIRNESS' $Fairness (Test-CliSet 'Fairness') $Defaults.fairness
    $c.horizon          = Resolve-Setting 'horizon' 'FM_HORIZON' $Horizon (Test-CliSet 'Horizon') $Defaults.horizon
    $c.locked           = Resolve-Setting 'locked' 'FM_LOCKED' $Locked (Test-CliSet 'Locked') ''
    $c.skip_waivers     = Resolve-Setting 'skip_waivers' 'FM_SKIP_WAIVERS' '1' (Test-CliSet 'SkipWaivers') '0'
    $c.skip_trades      = Resolve-Setting 'skip_trades' 'FM_SKIP_TRADES' '1' (Test-CliSet 'SkipTrades') '0'
    $c.cache_dir        = Resolve-Setting 'cache_dir' 'FM_CACHE_DIR' $CacheDir (Test-CliSet 'CacheDir') ''
    $c.players_ttl      = Resolve-Setting 'players_ttl' 'FM_PLAYERS_TTL' $null $false $Defaults.players_ttl
    $c.projections_ttl  = Resolve-Setting 'projections_ttl' 'FM_PROJECTIONS_TTL' $CacheTtl (Test-CliSet 'CacheTtl') $Defaults.projections_ttl
    $c.trending_ttl     = Resolve-Setting 'trending_ttl' 'FM_TRENDING_TTL' $null $false $Defaults.trending_ttl
    $c.stale_max_age    = Resolve-Setting 'stale_max_age' 'FM_STALE_MAX_AGE' $null $false $Defaults.stale_max_age
    $c.no_cache         = Resolve-Setting 'no_cache' 'FM_NO_CACHE' '1' (Test-CliSet 'NoCache') '0'
    $c.refresh          = Resolve-Setting 'refresh' 'FM_REFRESH' '1' (Test-CliSet 'Refresh') '0'
    $c.offline          = Resolve-Setting 'offline' 'FM_OFFLINE' '1' (Test-CliSet 'Offline') '0'
    $c.fixtures         = Resolve-Setting 'fixtures' 'FM_FIXTURES' $Fixtures (Test-CliSet 'Fixtures') ''
    $c.python           = Resolve-Setting 'python' 'FM_PYTHON' $Python (Test-CliSet 'Python') ''

    # Offline fixture data must never land in (or be read from) the real cache.
    if (-not $c.cache_dir) {
        $c.cache_dir = Get-DefaultDir 'cache'
        if ($c.offline -eq '1') { $c.no_cache = '1' }
    }

    # validation (same rules and messages as fantasy_manager.sh)
    if (-not (Test-UInt $c.league_id)) { Stop-Run $EX_USAGE "League id must be a non-empty numeric string (got '$($c.league_id)')." }
    if (-not $c.username) { Stop-Run $EX_USAGE 'Username must not be empty.' }
    if ($c.week -and (-not (Test-UInt $c.week) -or [int]$c.week -lt 1 -or [int]$c.week -gt 18)) {
        Stop-Run $EX_USAGE "Week must be an integer between 1 and 18 (got '$($c.week)')."
    }
    if ($c.season -and (-not (Test-UInt $c.season) -or $c.season.Length -ne 4)) {
        Stop-Run $EX_USAGE "Season must be a 4 digit year (got '$($c.season)')."
    }
    if (@('regular', 'pre', 'post') -notcontains $c.season_type) {
        Stop-Run $EX_USAGE "Season type must be regular, pre or post (got '$($c.season_type)')."
    }
    if (-not (Test-UInt $c.top_n) -or [int]$c.top_n -lt 1 -or [int]$c.top_n -gt 50) {
        Stop-Run $EX_USAGE "Top N must be an integer between 1 and 50 (got '$($c.top_n)')."
    }
    if (-not (Test-UInt $c.horizon) -or [int]$c.horizon -gt 6) {
        Stop-Run $EX_USAGE "Horizon must be an integer between 0 and 6 (got '$($c.horizon)')."
    }
    if (-not (Test-Number $c.threshold)) { Stop-Run $EX_USAGE "Threshold must be numeric (got '$($c.threshold)')." }
    if (-not (Test-Number $c.fairness)) { Stop-Run $EX_USAGE "Fairness must be numeric (got '$($c.fairness)')." }
    if (-not (Test-UInt $c.projections_ttl)) { Stop-Run $EX_USAGE "Cache TTL must be a non-negative integer (got '$($c.projections_ttl)')." }
    if (@('QUIET', 'ERROR', 'WARN', 'INFO', 'DEBUG') -notcontains $script:LogLevel) {
        Stop-Run $EX_USAGE "Log level must be QUIET, ERROR, WARN, INFO or DEBUG (got '$($script:LogLevel)')."
    }
    if ($c.offline -eq '1') {
        if (-not $c.fixtures) { Stop-Run $EX_USAGE '-Offline requires -Fixtures DIR (or FM_FIXTURES).' }
        if (-not (Test-Path -LiteralPath $c.fixtures -PathType Container)) { Stop-Run $EX_USAGE "Fixture directory '$($c.fixtures)' does not exist." }
    }

    foreach ($k in $c.Keys) { Write-Log 'DEBUG' ("  {0}={1}" -f $k, $c[$k]) }
    return $c
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

function Invoke-Native([string]$exe, [string[]]$arguments) {
    # Runs a program with captured output. Avoids PowerShell pipes and
    # redirection, which re-encode text and turn stderr into errors on 5.1.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = (($arguments | ForEach-Object { ConvertTo-Argument $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = [Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    return [pscustomobject]@{ Code = $proc.ExitCode; Out = $outTask.Result; Err = $errTask.Result }
}

$script:Py = $null

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
            $r = Invoke-Native $exe ($pre + @('-c', 'import sys; print(1 if sys.version_info >= (3, 8) else 0)'))
        } catch { continue }
        # The Microsoft Store "python" stub exits non-zero without running.
        if ($r.Code -eq 0 -and $r.Out.Trim() -eq '1') {
            return [pscustomobject]@{ Exe = (Get-Command $exe).Source; Pre = $pre }
        }
    }
    return $null
}

function Invoke-Python([string[]]$arguments) {
    return Invoke-Native $script:Py.Exe ($script:Py.Pre + $arguments)
}

function Test-Dependencies($c) {
    $script:Py = Find-Python $c.python
    if (-not $script:Py) {
        Stop-Run $EX_DEPENDENCY 'Python 3.8+ not found. Install it from https://www.python.org (tick "Add python.exe to PATH") or pass -Python C:\path\to\python.exe.'
    }
    foreach ($f in @($AnalysisPy, $IoPy)) {
        if (-not (Test-Path -LiteralPath $f)) { Stop-Run $EX_DEPENDENCY "Analysis helper not found at $f" }
    }
    Write-Log 'DEBUG' ("Python: {0} {1}" -f $script:Py.Exe, ($script:Py.Pre -join ' '))
}

# --------------------------------------------------------------------------
# Fetch / cache / validate
# --------------------------------------------------------------------------
function Add-Diagnostic([string]$key, [string]$url, [string]$source, $age, $records, [string]$note) {
    [void]$script:Diagnostics.Add([ordered]@{
        key = $key; url = $url; source = $source; cache_age_seconds = $age
        records = $records; note = $note; at = (Get-NowIso)
    })
}

function Test-JsonFile([string]$path, [string]$want, [string]$shape, [string]$label) {
    # Returns the record count, or $null if invalid.
    $pyArgs = @($IoPy, 'check', $path, $want)
    if ($shape) { $pyArgs += $shape }
    $r = Invoke-Python $pyArgs
    if ($r.Code -ne 0) {
        Write-Log 'DEBUG' ("{0}: {1}" -f $label, $r.Err.Trim())
        return $null
    }
    return [int]$r.Out.Trim()
}

function Get-CacheAge([string]$path) {
    $mtime = (Get-Item -LiteralPath $path).LastWriteTimeUtc
    return [int][Math]::Floor(([DateTime]::UtcNow - $mtime).TotalSeconds)
}

function Save-Cache($c, [string]$name, [string]$src) {
    if ($c.no_cache -eq '1' -or -not $name) { return }
    if (-not (Test-Path -LiteralPath $c.cache_dir)) { New-Item -ItemType Directory -Path $c.cache_dir -Force | Out-Null }
    $dest = Join-Path $c.cache_dir "$name.json"
    $tmp = "$dest.tmp.$PID"
    Copy-Item -LiteralPath $src -Destination $tmp -Force
    Move-Item -LiteralPath $tmp -Destination $dest -Force   # atomic rename
    Write-Log 'DEBUG' "Cached $name -> $dest"
}

function Get-HttpStatus($errorRecord) {
    $resp = $null
    try { $resp = $errorRecord.Exception.Response } catch { }
    if ($null -eq $resp) { return 0 }
    try { return [int]$resp.StatusCode } catch { return 0 }
}

function Invoke-Fetch([string]$url, [string]$dest) {
    # Retries only transient failures (connection errors, 408, 429, 5xx).
    $delay = 1
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 45 `
                -Headers @{ Accept = 'application/json' } -UserAgent "$ToolName/$ToolVersion" | Out-Null
            Write-Log 'DEBUG' ("HTTP 200 {0} ({1} bytes)" -f $url, (Get-Item -LiteralPath $dest).Length)
            return $true
        } catch {
            $status = Get-HttpStatus $_
            if ($status -eq 0 -or $status -eq 408 -or $status -eq 429 -or $status -ge 500) {
                Write-Log 'DEBUG' ("Transient failure for {0} (status {1}, attempt {2}/4): {3}" -f $url, $status, $attempt, $_.Exception.Message)
                if ($attempt -lt 4) { Start-Sleep -Seconds $delay; $delay *= 2 }
            } else {
                Write-Log 'DEBUG' ("HTTP {0} for {1} (not retried)" -f $status, $url)
                return $false
            }
        }
    }
    return $false
}

$script:FetchSource = ''
$script:FetchAge = $null

function Get-Json($c, [string]$key, [string]$url, [string]$want, [string]$cacheName, [int]$ttl, [bool]$allowStale, [string]$shape) {
    # Writes validated JSON to TMP\<key>.json; sets FetchSource / FetchAge.
    $dest = Join-Path $script:Tmp "$key.json"
    $raw = Join-Path $script:Tmp "$key.raw"
    $script:FetchSource = ''
    $script:FetchAge = $null
    $cfile = $null
    if ($cacheName -and $c.no_cache -ne '1') { $cfile = Join-Path $c.cache_dir "$cacheName.json" }

    # 1. fresh cache
    if ($cfile -and (Test-Path -LiteralPath $cfile) -and $c.refresh -ne '1') {
        $age = Get-CacheAge $cfile
        if ($age -le $ttl) {
            $n = Test-JsonFile $cfile $want $shape "cache:$key"
            if ($null -ne $n) {
                Copy-Item -LiteralPath $cfile -Destination $dest -Force
                $script:FetchSource = 'cache'; $script:FetchAge = $age
                Write-Log 'INFO' "Using cached $key (age ${age}s)"
                Add-Diagnostic $key $url 'cache' $age $n 'fresh cache'
                return $true
            }
        }
    }

    # 2. fetch
    $ok = $false
    if ($c.offline -eq '1') {
        $statusFile = Join-Path $c.fixtures "$key.status"
        $src = Join-Path $c.fixtures "$key.json"
        if (Test-Path -LiteralPath $statusFile) {
            Write-Log 'DEBUG' ("Fixture {0} simulates HTTP {1}" -f $key, ([IO.File]::ReadAllText($statusFile).Trim()))
        } elseif (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination $raw -Force
            $ok = $true
        } else {
            Write-Log 'DEBUG' "Fixture $key missing at $src"
        }
    } else {
        Write-Log 'INFO' "Fetching $key from $url"
        $ok = Invoke-Fetch $url $raw
    }
    if ($ok) {
        $n = Test-JsonFile $raw $want $shape $key
        if ($null -ne $n) {
            Copy-Item -LiteralPath $raw -Destination $dest -Force
            Save-Cache $c $cacheName $dest
            $script:FetchSource = if ($c.offline -eq '1') { 'fixture' } else { 'network' }
            $script:FetchAge = 0
            Add-Diagnostic $key $url $script:FetchSource 0 $n 'ok'
            return $true
        }
    }

    # 3. stale cache fallback
    if ($allowStale -and $cfile -and (Test-Path -LiteralPath $cfile)) {
        $age = Get-CacheAge $cfile
        if ($age -le [int]$c.stale_max_age) {
            $n = Test-JsonFile $cfile $want $shape "stale:$key"
            if ($null -ne $n) {
                Copy-Item -LiteralPath $cfile -Destination $dest -Force
                $script:FetchSource = 'stale-cache'; $script:FetchAge = $age
                Add-Warning ("STALE DATA: '{0}' could not be refreshed; using cached copy from {1} minutes ago." -f $key, [int][Math]::Floor($age / 60))
                Add-Diagnostic $key $url 'stale-cache' $age $n 'stale fallback'
                return $true
            }
        }
    }

    Add-Diagnostic $key $url 'unavailable' $null $null 'fetch or validation failed'
    Write-Log 'DEBUG' "Could not obtain valid $want for '$key'"
    return $false
}

function Read-SmallJson([string]$key) {
    # Small documents only (Windows PowerShell 5.1 cannot parse > ~2 MB).
    # -InputObject + return enumerates arrays the same way on 5.1 and 7.
    $obj = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $script:Tmp "$key.json"), $Utf8NoBom))
    return $obj
}

function Write-EmptyArray([string]$key) {
    [IO.File]::WriteAllText((Join-Path $script:Tmp "$key.json"), "[]`n", $Utf8NoBom)
}

# --------------------------------------------------------------------------
# Stages (same order, rules and messages as fantasy_manager.sh)
# --------------------------------------------------------------------------
function Invoke-Pipeline($c) {
    $api = $c.api
    $s = @{}   # run state

    # state + schedule + week
    $stateSeason = ''; $stateWeek = ''
    if (Get-Json $c 'state' "$api/state/nfl" 'object' '' 0 $false '') {
        $state = Read-SmallJson 'state'
        if ($state.PSObject.Properties['season'] -and $state.season) { $stateSeason = [string]$state.season }
        if ($state.PSObject.Properties['week'] -and $null -ne $state.week) { $stateWeek = [string]$state.week }
        if ($state.PSObject.Properties['season_type'] -and $state.season_type -and $state.season_type -ne $c.season_type) {
            Add-Warning ("NFL state reports season type '{0}' but '{1}' was requested." -f $state.season_type, $c.season_type)
        }
    } else {
        if (-not $c.season -or -not $c.week) {
            Stop-Run $EX_DATA 'Could not load /state/nfl and no -Season/-Week supplied. Rerun with -Season YYYY -Week N.'
        }
        Add-Warning 'Could not load NFL state; using supplied season/week.'
    }
    $season = if ($c.season) { $c.season } else { $stateSeason }
    $weekAuto = -not $c.week
    $week = if ($c.week) { $c.week } else { $stateWeek }
    if (-not $season) { Stop-Run $EX_DATA 'Season unavailable from /state/nfl; pass -Season YYYY.' }
    if (-not $week) { Stop-Run $EX_DATA 'Week unavailable from /state/nfl; pass -Week N.' }
    if (-not (Test-UInt $week) -or [int]$week -lt 1 -or [int]$week -gt 18) {
        Stop-Run $EX_DATA "Resolved week '$week' is out of range 1-18; pass -Week N."
    }
    $week = [int]$week

    $scheduleAvailable = $false
    $schedUrl = "$($c.schedule_base)/$($c.season_type)/$season"
    if (Get-Json $c 'schedule' $schedUrl 'array' "schedule_${season}_$($c.season_type)" ([int]$c.schedule_ttl) $false 'schedule') {
        $scheduleAvailable = $true
        Write-Log 'INFO' ("Schedule: {0} games" -f $script:Diagnostics[$script:Diagnostics.Count - 1].records)
    } else {
        Write-EmptyArray 'schedule'
        Add-Warning "Game schedule unavailable; locked players are detected from live points only (use --locked to add more). If this week's games are over, pass --week to analyse the next week."
    }
    $rolledFrom = $null
    if ($weekAuto -and $scheduleAvailable -and $week -lt 18) {
        $ws = (Invoke-Python @($IoPy, 'week-state', (Join-Path $script:Tmp 'schedule.json'), [string]$week)).Out.Trim()
        if ($ws -eq 'complete') {
            $rolledFrom = $week
            $week = $week + 1
            Write-Log 'INFO' "Every week $rolledFrom game is final; analysing week $week instead (pass -Week to override)."
        }
    }
    Write-Log 'INFO' "Season $season, week $week, season type $($c.season_type)"

    # league
    if (-not (Get-Json $c 'league' "$api/league/$($c.league_id)" 'object' '' 0 $false '')) {
        Stop-Run $EX_DATA "League $($c.league_id) could not be loaded or is not a JSON object. Check the league id."
    }
    $league = Read-SmallJson 'league'
    $positions = @(); if ($league.PSObject.Properties['roster_positions'] -and $league.roster_positions) { $positions = @($league.roster_positions) }
    if ($positions.Count -eq 0) { Stop-Run $EX_DATA "League $($c.league_id) has no roster_positions; cannot build a lineup." }
    $hasScoring = $league.PSObject.Properties['scoring_settings'] -and $league.scoring_settings -and @($league.scoring_settings.PSObject.Properties).Count -gt 0
    if (-not $hasScoring) { Add-Warning 'League has no scoring_settings; projections will fall back to provider aggregate points.' }
    if (-not (Get-Json $c 'rosters' "$api/league/$($c.league_id)/rosters" 'array' '' 0 $false '')) {
        Stop-Run $EX_DATA "League rosters unavailable or empty for league $($c.league_id)."
    }
    if (-not (Get-Json $c 'users' "$api/league/$($c.league_id)/users" 'array' '' 0 $false '')) {
        Stop-Run $EX_DATA "League users unavailable or empty for league $($c.league_id)."
    }
    if (-not (Get-Json $c 'matchups' "$api/league/$($c.league_id)/matchups/$week" 'array' '' 0 $false '')) {
        Add-Warning "Week $week matchups unavailable; matchup context omitted."
        Write-EmptyArray 'matchups'
    }

    # user + roster
    if (-not (Get-Json $c 'user' "$api/user/$($c.username)" 'object' '' 0 $false '')) {
        Stop-Run $EX_DATA "Sleeper user '$($c.username)' could not be resolved. Check -Username."
    }
    $user = Read-SmallJson 'user'
    $userId = if ($user.PSObject.Properties['user_id']) { [string]$user.user_id } else { '' }
    if (-not $userId) { Stop-Run $EX_DATA "Sleeper user '$($c.username)' has no user_id in the API response." }
    $rosters = @(Read-SmallJson 'rosters')
    $myRoster = $rosters | Where-Object { $_.PSObject.Properties['owner_id'] -and [string]$_.owner_id -eq $userId } | Select-Object -First 1
    if (-not $myRoster) {
        $myRoster = $rosters | Where-Object { $_.PSObject.Properties['co_owners'] -and @($_.co_owners) -contains $userId } | Select-Object -First 1
    }
    if (-not $myRoster) { Stop-Run $EX_DATA "User '$($c.username)' (id $userId) does not own a roster in league $($c.league_id)." }
    $myRosterId = [int]$myRoster.roster_id
    Write-Log 'INFO' "User $($c.username) -> user_id $userId, roster_id $myRosterId"

    # players
    if (-not (Get-Json $c 'players' "$api/players/nfl" 'object' 'players_nfl' ([int]$c.players_ttl) $true '')) {
        Stop-Run $EX_DATA 'Player database unavailable (network and cache). Retry later or run with -Offline -Fixtures DIR.'
    }
    $playersSource = $script:FetchSource; $playersAge = $script:FetchAge
    Write-Log 'INFO' ("Player database: {0} players (source {1})" -f $script:Diagnostics[$script:Diagnostics.Count - 1].records, $playersSource)

    # projections (this week)
    $projUrl = "$($c.projections_base)/$season/${week}?season_type=$($c.season_type)&order_by=pts_ppr"
    if (-not (Get-Json $c 'projections' $projUrl 'array' "projections_${season}_$($c.season_type)_$week" ([int]$c.projections_ttl) $true '')) {
        Stop-Run $EX_DATA "No valid projections for season $season week $week (source: $projUrl). Lineup and waiver analysis need projections; refusing to rank every player at zero."
    }
    $projSource = $script:FetchSource; $projAge = $script:FetchAge
    $projCount = [int]$script:Diagnostics[$script:Diagnostics.Count - 1].records
    if ($projCount -lt 50) { Add-Warning "Projection feed returned only $projCount records; results may be incomplete." }
    if ($null -eq (Test-JsonFile (Join-Path $script:Tmp 'projections.json') 'array' 'projections' 'projections')) {
        Stop-Run $EX_DATA "Projection feed schema changed: no records with 'player_id' and object 'stats' (source: $projUrl)."
    }
    $projFetchedAt = Get-NowIso
    Write-Log 'INFO' "Projections: $projCount records (source $projSource)"

    # future weeks
    $futureWeeks = New-Object System.Collections.ArrayList
    $missing = @()
    for ($i = 1; $i -le [int]$c.horizon; $i++) {
        $w = $week + $i
        if ($w -gt 18) { break }
        $url = "$($c.projections_base)/$season/${w}?season_type=$($c.season_type)&order_by=pts_ppr"
        if (Get-Json $c "projections_w$w" $url 'array' "projections_${season}_$($c.season_type)_$w" ([int]$c.projections_ttl) $true 'projections') {
            [void]$futureWeeks.Add($w)
        } else {
            $missing += $w
        }
    }
    if ($missing.Count -gt 0) {
        Add-Warning ("Projections for week(s) {0} unavailable; multi-week values use the remaining weeks." -f ($missing -join ', '))
    }
    Write-Log 'INFO' ("Future projection weeks: {0}" -f $(if ($futureWeeks.Count) { $futureWeeks -join ',' } else { 'none' }))

    # activity
    $trendingAvailable = $false
    if (Get-Json $c 'trending_add' "$api/players/nfl/trending/add?lookback_hours=24&limit=100" 'array' 'trending_add' ([int]$c.trending_ttl) $true '') {
        $trendingAvailable = $true
    } else {
        Write-EmptyArray 'trending_add'
        Add-Warning 'Trending add data unavailable; the add-trend component is omitted from waiver scoring.'
    }
    $transactionsAvailable = $false
    if (Get-Json $c 'transactions' "$api/league/$($c.league_id)/transactions/$week" 'array' '' 0 $false '') {
        $transactionsAvailable = $true
    } else {
        Write-EmptyArray 'transactions'
        Write-Log 'DEBUG' "No transactions for week $week"
    }

    # bundle + analysis
    $lockedList = @($c.locked -split ',' | ForEach-Object { $_.Trim(' ') } | Where-Object { $_ })
    $meta = [ordered]@{
        config = [ordered]@{
            tool_version = $ToolVersion; generated_at = (Get-NowIso)
            league_id = $c.league_id; username = $c.username; user_id = $userId
            season = [string]$season; season_type = $c.season_type; week = $week
            my_roster_id = $myRosterId; top_n = [int]$c.top_n
            churn_threshold = [double]::Parse($c.threshold, $Invariant)
            fairness = [double]::Parse($c.fairness, $Invariant)
            skip_waivers = ($c.skip_waivers -eq '1'); skip_trades = ($c.skip_trades -eq '1')
            offline = ($c.offline -eq '1')
            locked = $lockedList
            week_rolled_from = $rolledFrom
            horizon = [int]$c.horizon
        }
        provenance = [ordered]@{
            projections = [ordered]@{ url = $projUrl; source = $projSource; cache_age_seconds = $projAge; fetched_at = $projFetchedAt }
            players = [ordered]@{ source = $playersSource; cache_age_seconds = $playersAge }
            trending_available = $trendingAvailable
            transactions_available = $transactionsAvailable
            schedule_available = $scheduleAvailable
        }
        warnings = @($script:Warnings)
        diagnostics = @($script:Diagnostics)
        future_weeks = @($futureWeeks)
    }
    $metaPath = Join-Path $script:Tmp 'meta.json'
    $metaJson = ConvertTo-Json -InputObject $meta -Depth 10 -Compress
    [IO.File]::WriteAllText($metaPath, $metaJson, $Utf8NoBom)
    $bundlePath = Join-Path $script:Tmp 'bundle.json'
    $r = Invoke-Python @($IoPy, 'bundle', $script:Tmp, $metaPath, $bundlePath)
    if ($r.Code -ne 0) { Stop-Run $EX_DATA ("Could not assemble the analysis bundle: {0}" -f $r.Err.Trim()) }

    $reportPath = Join-Path $script:Tmp 'report.json'
    $r = Invoke-Python @($AnalysisPy, '--in', $bundlePath, '--out', $reportPath)
    if ($r.Code -ne 0) {
        $tail = $r.Err; if ($tail.Length -gt 1000) { $tail = $tail.Substring($tail.Length - 1000) }
        Stop-Run $EX_DATA "Analysis failed: $($tail.Trim())"
    }
    foreach ($line in ($r.Err -split "`n")) { if ($line.Trim()) { Write-Log 'DEBUG' "analysis: $line" } }
    return $reportPath
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
          <TextBlock Text="League" VerticalAlignment="Center" Foreground="{StaticResource Muted}" Margin="0,0,6,0"/>
          <TextBox x:Name="LeagueBox" Width="170" Padding="4,3"/>
          <TextBlock Text="User" VerticalAlignment="Center" Foreground="{StaticResource Muted}" Margin="14,0,6,0"/>
          <TextBox x:Name="UserBox" Width="130" Padding="4,3"/>
          <TextBlock Text="Week" VerticalAlignment="Center" Foreground="{StaticResource Muted}" Margin="14,0,6,0"/>
          <TextBox x:Name="WeekBox" Width="44" Padding="4,3" ToolTip="Blank = current week (next week once every game is final)"/>
          <TextBlock Text="Horizon" VerticalAlignment="Center" Foreground="{StaticResource Muted}" Margin="14,0,6,0"/>
          <ComboBox x:Name="HorizonBox" Width="56" ToolTip="Future weeks valued for waivers, drops and trades">
            <ComboBoxItem Content="0"/><ComboBoxItem Content="1"/><ComboBoxItem Content="2"/>
            <ComboBoxItem Content="3"/><ComboBoxItem Content="4"/><ComboBoxItem Content="5"/><ComboBoxItem Content="6"/>
          </ComboBox>
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
      <TabItem Header="Matchup">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <TextBlock x:Name="MatchupDetail" Margin="4" TextWrapping="Wrap" FontSize="14" LineHeight="24"/>
        </ScrollViewer>
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
        $ui.MatchupDetail.Text = (@(
            ('{0}  vs  {1}' -f $ui.MyTeamText.Text, $ui.OppTeamText.Text),
            ('Live / final points:  {0}  vs  {1}' -f (Format-Points $m.my_points), (Format-Points $m.opponent_points)),
            ('Projected (current lineups):  {0}  vs  {1}   (differential {2})' -f (Format-Points $m.my_projected), (Format-Points $m.opponent_projected), (Format-Points $m.differential)),
            ('Projected final (live + remaining):  {0}  vs  {1}   ({2})' -f (Format-Points (Get-Prop $m 'my_projected_final')), (Format-Points (Get-Prop $m 'opponent_projected_final')), (Format-Points (Get-Prop $m 'final_differential'))),
            '',
            $m.note
        ) -join "`n")
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
    foreach ($name in @('LeagueBox', 'UserBox', 'WeekBox', 'HorizonBox', 'FreshBox', 'RefreshButton', 'OpenButton', 'SaveButton',
            'Busy', 'StatusText', 'TitleText', 'SubtitleText', 'NoticeText', 'MyTeamText', 'MyScoreText', 'MyProjText',
            'OppTeamText', 'OppScoreText', 'OppProjText', 'WarningsExpander', 'WarningsHeader', 'WarningsList',
            'LineupSummary', 'LineupGrid', 'RiskGrid', 'WaiverSummary', 'WaiverGrid', 'TradeSummary', 'TradeGrid',
            'MatchupDetail', 'DiagSummary', 'DiagGrid')) {
        $ui[$name] = $window.FindName($name)
    }
    $script:Ui = $ui
    $script:CurrentReportPath = $null
    $script:RefreshProc = $null

    # Defaults for the inputs follow the normal precedence (CLI > env > config > defaults).
    try {
        $script:LogLevel = 'ERROR'
        $cfg = Initialize-Configuration
        $ui.LeagueBox.Text = $cfg.league_id
        $ui.UserBox.Text = $cfg.username
        $ui.WeekBox.Text = $cfg.week
        $ui.HorizonBox.SelectedIndex = [int]$cfg.horizon
    } catch {
        $ui.LeagueBox.Text = $Defaults.league_id
        $ui.UserBox.Text = $Defaults.username
        $ui.HorizonBox.SelectedIndex = [int]$Defaults.horizon
    }

    $loadReport = {
        param([string]$path)
        $report = Import-ReportFile $path
        Update-ReportView $script:Ui $report
        $script:CurrentReportPath = $path
        $script:Ui.SaveButton.IsEnabled = $true
    }

    $script:LoadReport = $loadReport
    $script:Timer = New-Object Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $script:Timer.Add_Tick({
        $proc = $script:RefreshProc
        if ($null -eq $proc -or -not $proc.HasExited) { return }
        $script:Timer.Stop()
        $script:RefreshProc = $null
        $ui = $script:Ui
        $ui.Busy.Visibility = 'Collapsed'
        $ui.RefreshButton.IsEnabled = $true
        $logText = ''
        if (Test-Path -LiteralPath $script:RefreshLog) { $logText = [IO.File]::ReadAllText($script:RefreshLog) }
        if ($proc.ExitCode -eq 0 -and (Test-Path -LiteralPath $script:RefreshOut)) {
            try {
                & $script:LoadReport $script:RefreshOut
                $ui.StatusText.Text = 'Updated ' + (Get-Date).ToString('h:mm tt')
            } catch {
                $ui.StatusText.Text = 'Could not read the report.'
                [Windows.MessageBox]::Show($_.Exception.Message, 'Fantasy Manager', 'OK', 'Error') | Out-Null
            }
        } else {
            $errors = @($logText -split "`n" | Where-Object { $_ -match '\[ERROR\]' } | ForEach-Object { ($_ -replace '^\S+ \[ERROR\] ', '').Trim() })
            $message = $(if ($errors.Count) { $errors -join "`n" } else { "The update failed (exit code $($proc.ExitCode))." })
            $ui.StatusText.Text = 'Update failed'
            [Windows.MessageBox]::Show($message, 'Fantasy Manager', 'OK', 'Warning') | Out-Null
        }
    })

    $ui.RefreshButton.Add_Click({
        $ui = $script:Ui
        if ($script:RefreshProc) { return }
        $work = Join-Path ([IO.Path]::GetTempPath()) 'fantasy_manager_gui'
        if (-not (Test-Path -LiteralPath $work)) { New-Item -ItemType Directory -Path $work | Out-Null }
        $script:RefreshOut = Join-Path $work ('report_{0}.json' -f [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:RefreshLog = Join-Path $work 'last_refresh.log'
        if (Test-Path -LiteralPath $script:RefreshLog) { Remove-Item -LiteralPath $script:RefreshLog -Force }

        # The data layer runs as a separate process so the window stays responsive.
        $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:ScriptPath, '-NoGui',
            '-OutFile', $script:RefreshOut, '-LogFile', $script:RefreshLog,
            '-LeagueId', $ui.LeagueBox.Text.Trim(), '-Username', $ui.UserBox.Text.Trim())
        if ($ui.WeekBox.Text.Trim()) { $childArgs += @('-Week', $ui.WeekBox.Text.Trim()) }
        if ($ui.HorizonBox.SelectedIndex -ge 0) { $childArgs += @('-Horizon', [string]$ui.HorizonBox.SelectedIndex) }
        if ($ui.FreshBox.IsChecked) { $childArgs += '-Refresh' }
        foreach ($pass in @('Season', 'SeasonType', 'Top', 'Threshold', 'Fairness', 'Locked', 'CacheDir', 'Config', 'Python', 'Fixtures')) {
            if ($script:BoundParams.ContainsKey($pass)) { $childArgs += @("-$pass", [string]$script:BoundParams[$pass]) }
        }
        foreach ($flag in @('Offline', 'NoCache', 'SkipWaivers', 'SkipTrades')) {
            if ($script:BoundParams.ContainsKey($flag)) { $childArgs += "-$flag" }
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-Process -Id $PID).Path
        $psi.Arguments = (($childArgs | ForEach-Object { ConvertTo-Argument $_ }) -join ' ')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $script:RefreshProc = [Diagnostics.Process]::Start($psi)
        $ui.Busy.Visibility = 'Visible'
        $ui.RefreshButton.IsEnabled = $false
        $ui.StatusText.Text = 'Fetching from Sleeper...'
        $script:Timer.Start()
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
        [Console]::Out.WriteLine(('GUI smoke test ok: lineup rows {0}, waiver rows {1}, trade rows {2}, warnings {3}' -f
            @($ui.LineupGrid.ItemsSource).Count, @($ui.WaiverGrid.ItemsSource).Count, @($ui.TradeGrid.ItemsSource).Count,
            @($ui.WarningsList.ItemsSource).Count))
        $window.Close()
        return
    }
    [void]$window.ShowDialog()
    if ($script:RefreshProc -and -not $script:RefreshProc.HasExited) { try { $script:RefreshProc.Kill() } catch { } }
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
$script:Tmp = $null

if ($Version) { [Console]::Out.WriteLine("$ToolName $ToolVersion"); exit $EX_OK }

if ($ReportFile -and -not $NoGui) {
    Show-ReportWindow -InitialReport $ReportFile -SmokeTest:$GuiSmokeTest
    exit $script:ExitCode
}
if (-not $NoGui) {
    Show-ReportWindow -SmokeTest:$GuiSmokeTest
    exit $script:ExitCode
}

try {
    $cfg = Initialize-Configuration
    Test-Dependencies $cfg
    if ($IsWindowsHost -and $PSVersionTable.PSVersion.Major -lt 6) {
        # Windows PowerShell 5.1 on older .NET may not offer TLS 1.2 by default.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ("fantasy_manager." + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:Tmp | Out-Null
    Write-Log 'DEBUG' "Temporary workspace: $($script:Tmp)"

    $reportPath = Invoke-Pipeline $cfg
    if ($OutFile) {
        $full = [IO.Path]::GetFullPath($OutFile)
        $dir = Split-Path -Parent $full
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Copy-Item -LiteralPath $reportPath -Destination $full -Force
        Write-Log 'INFO' "Report written to $full"
    } else {
        [Console]::Out.Write([IO.File]::ReadAllText($reportPath, $Utf8NoBom))
    }
} catch {
    if ($_.Exception.Message -ne 'FM_EXIT') {
        Write-Log 'ERROR' ("Unexpected error: {0}" -f $_.Exception.Message)
        $script:ExitCode = $EX_DATA
    }
} finally {
    if ($script:Tmp -and (Test-Path -LiteralPath $script:Tmp)) { Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
exit $script:ExitCode
