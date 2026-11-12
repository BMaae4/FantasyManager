<#
Windows checks for FantasyManager.ps1, run by CI under both Windows
PowerShell 5.1 and PowerShell 7:
  - every fixture gives the same exit code and report as the bash front end
    (expected reports come from tests/make_expected.sh on Linux)
  - CLI validation and -Version
  - the WPF window builds and fills from a report (-GuiSmokeTest)
Usage: tests/windows.ps1 -Expected DIR
#>
param([Parameter(Mandatory = $true)][string]$Expected)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'FantasyManager.ps1'
$fixtures = Join-Path $root 'tests\fixtures'
$compare = Join-Path $root 'tests\compare_reports.py'
$hostExe = (Get-Process -Id $PID).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ('fm_win_' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null
# No built-in league or user: supply the test league's.
$env:FM_LEAGUE_ID = '100000000000000001'; $env:FM_USERNAME = 'testmanager'
$pass = 0; $fail = 0; $failed = @()

function Run-Script([string[]]$arguments) {
    $out = Join-Path $work 'out.txt'; $err = Join-Path $work 'err.txt'
    $p = Start-Process -FilePath $hostExe -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script`"") + $arguments) `
        -RedirectStandardOutput $out -RedirectStandardError $err -Wait -PassThru -NoNewWindow
    return [pscustomobject]@{ Code = $p.ExitCode; Out = [IO.File]::ReadAllText($out); Err = [IO.File]::ReadAllText($err) }
}
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++; Write-Host "ok   $name" }
    else { $script:fail++; $script:failed += "$name $detail"; Write-Host "FAIL $name $detail" }
}

Write-Host "Host: $hostExe ($($PSVersionTable.PSVersion))"
$cases = @(Get-ChildItem -Path $Expected -Filter '*.status' | ForEach-Object { $_.BaseName })
foreach ($case in $cases) {
    $parts = $case -split '__'
    $fixture = Join-Path $fixtures $parts[0]
    $extra = @()
    if ($parts.Count -gt 1 -and $parts[1] -eq 'horizon0') { $extra = @('-Horizon', '0') }
    if ($parts.Count -gt 1 -and $parts[1] -eq 'locked') { $extra = @('-Locked', '"Wes Charlie"') }
    if ($parts.Count -gt 1 -and $parts[1] -eq 'value') { $extra = @('-ValueTrade', '"Team2 RB1 for Team3 RB2, Team4 WR3; Alpha for Team2 TE1"', '-Scoring', 'half', '-Teams', '4') }
    if ($parts.Count -gt 1 -and $parts[1] -eq 'trade') { $extra = @('-Trade', '"Wes Delta, Ryan Echo for Team2 RB1; Bravo for Team2 TE1"') }
    if ($parts.Count -gt 1 -and $parts[1] -eq 'espn') { $extra = @('-Platform', 'espn', '-LeagueId', '555001', '-Team', '"Test Titans"') }
    $actual = Join-Path $work "$case.json"
    if (Test-Path $actual) { Remove-Item $actual }
    $r = Run-Script (@('-NoGui', '-Offline', '-Fixtures', "`"$fixture`"", '-NoCache', '-Quiet', '-OutFile', "`"$actual`"") + $extra)
    $want = [int]([IO.File]::ReadAllText((Join-Path $Expected "$case.status")).Trim())
    if ($r.Code -ne $want) { Check $case $false "exit $($r.Code), expected $want. $($r.Err)"; continue }
    if ($want -ne 0) { Check $case $true; continue }
    $cmp = & python $compare (Join-Path $Expected "$case.json") $actual
    Check $case ($LASTEXITCODE -eq 0) ([string]$cmp)
}

$r = Run-Script @('-NoGui', '-Offline', '-Fixtures', "`"$(Join-Path $fixtures 'ppr_basic')`"", '-NoCache', '-Quiet', '-Format', 'text')
Check '-Format text prints the text report' ($r.Code -eq 0 -and $r.Out -match 'LINEUP - week 5' -and $r.Out -match 'Test Titans') ("$($r.Err)")
$r = Run-Script @('-NoGui', '-Offline', '-Fixtures', "`"$(Join-Path $fixtures 'ppr_basic')`"", '-NoCache', '-Quiet')
$printed = $null; try { $printed = $r.Out | ConvertFrom-Json } catch { }
Check '-NoGui prints JSON by default' ($r.Code -eq 0 -and $null -ne $printed -and @($printed.lineup.slots).Count -gt 0) ("$($r.Err)")
$r = Run-Script @('-NoGui', '-Offline', '-Fixtures', "`"$(Join-Path $fixtures 'rest_of_season')`"", '-NoCache', '-Quiet', '-Horizon', 'ros', '-SkipWaivers', '-SkipTrades')
$rosReport = $null; try { $rosReport = $r.Out | ConvertFrom-Json } catch { }
Check '-Horizon ros covers the rest of the season' ($r.Code -eq 0 -and $null -ne $rosReport -and @($rosReport.metadata.window_weeks).Count -eq 13) ("$($r.Err)")
$r = Run-Script @('-Version')
Check '-Version' ($r.Code -eq 0 -and $r.Out -match 'fantasy_manager \d')
$r = Run-Script @('-NoGui', '-LeagueId', 'abc', '-Quiet')
Check 'bad league id exits 2 and explains' ($r.Code -eq 2 -and $r.Err -match 'League id')
$r = Run-Script @('-NoGui', '-Horizon', '9', '-Quiet')
Check 'bad horizon exits 2' ($r.Code -eq 2)
$r = Run-Script @('-NoGui', '-Offline', '-Quiet')
Check '-Offline without -Fixtures exits 2' ($r.Code -eq 2)

# Offline fixture runs must not touch the real cache.
$cacheBefore = @(Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'fantasy_manager') -ErrorAction SilentlyContinue).Count
$r = Run-Script @('-NoGui', '-Offline', '-Fixtures', "`"$(Join-Path $fixtures 'ppr_basic')`"", '-Quiet', '-OutFile', "`"$(Join-Path $work 'nc.json')`"")
$cacheAfter = @(Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'fantasy_manager') -ErrorAction SilentlyContinue).Count
Check 'offline run leaves the default cache untouched' ($r.Code -eq 0 -and $cacheBefore -eq $cacheAfter)

# Explicit cache dir: second run is served from cache.
$cache = Join-Path $work 'cache'
$args1 = @('-NoGui', '-Offline', '-Fixtures', "`"$(Join-Path $fixtures 'ppr_basic')`"", '-CacheDir', "`"$cache`"", '-Quiet', '-OutFile', "`"$(Join-Path $work 'c1.json')`"")
$null = Run-Script $args1
$args2 = @('-NoGui', '-Offline', '-Fixtures', "`"$(Join-Path $fixtures 'ppr_basic')`"", '-CacheDir', "`"$cache`"", '-Quiet', '-OutFile', "`"$(Join-Path $work 'c2.json')`"")
$r = Run-Script $args2
$c2 = Get-Content -Raw (Join-Path $work 'c2.json') | ConvertFrom-Json
Check 'second run uses cache' ($r.Code -eq 0 -and @($c2.diagnostics.fetches | Where-Object { $_.key -eq 'projections' -and $_.source -eq 'cache' }).Count -eq 1)

# Hand-written config file: spaces around "=", quotes, CRLF.
$cfgPath = Join-Path $work 'config.env'
[IO.File]::WriteAllText($cfgPath, "# saved from Notepad`r`nleague_id = 100000000000000001`r`n  top_n = 6 `r`nusername = `"TestManager`"`r`n")
$r = Run-Script @('-NoGui', '-Offline', '-Fixtures', "`"$(Join-Path $fixtures 'ppr_basic')`"", '-NoCache', '-Quiet', '-Config', "`"$cfgPath`"", '-OutFile', "`"$(Join-Path $work 'cfg.json')`"")
$cfgReport = $null
if ($r.Code -eq 0) { $cfgReport = Get-Content -Raw (Join-Path $work 'cfg.json') | ConvertFrom-Json }
Check 'config file with spaces and CRLF is read' ($r.Code -eq 0 -and $cfgReport.metadata.top_n -eq 6) ("$($r.Err)")

# Remember: Save-Defaults keeps other settings and the result is read back.
$ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$null)
$fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Save-Defaults' }, $true) | Select-Object -First 1
. ([scriptblock]::Create($fn.Extent.Text))
$savePath = Join-Path $work 'saved\config.env'
[void](New-Item -ItemType Directory -Force (Split-Path $savePath))
[IO.File]::WriteAllText($savePath, "# mine`r`nFM_LEAGUE_ID = 999`r`ntop_n = 6`r`n")
[void](Save-Defaults $savePath ([ordered]@{ league_id = '100000000000000001'; username = 'TestManager'; horizon = '2' }))
$saved = [IO.File]::ReadAllText($savePath)
$r = Run-Script @('-NoGui', '-Offline', '-Fixtures', "`"$(Join-Path $fixtures 'ppr_basic')`"", '-NoCache', '-Quiet', '-Config', "`"$savePath`"", '-OutFile', "`"$(Join-Path $work 'saved.json')`"")
$savedReport = $null
if ($r.Code -eq 0) { $savedReport = Get-Content -Raw (Join-Path $work 'saved.json') | ConvertFrom-Json }
Check 'Remember saves defaults and keeps other settings' ($r.Code -eq 0 -and $saved -match '# mine' -and $saved -notmatch '999' -and
    $savedReport.metadata.top_n -eq 6 -and @($savedReport.metadata.window_weeks).Count -eq 3) ("$saved $($r.Err)")

# GUI: builds, lays out and fills from a report without being shown.
$r = Run-Script @('-ReportFile', "`"$(Join-Path $Expected 'locked_players.json')`"", '-GuiSmokeTest')
Check 'GUI builds and loads a report' ($r.Code -eq 0 -and $r.Out -match 'GUI smoke test ok: lineup rows 9') ("$($r.Out) $($r.Err)")
$r = Run-Script @('-ReportFile', "`"$(Join-Path $Expected 'ppr_basic__horizon0.json')`"", '-GuiSmokeTest')
Check 'GUI loads a this-week-only report' ($r.Code -eq 0 -and $r.Out -match 'GUI smoke test ok') ("$($r.Out) $($r.Err)")
$r = Run-Script @('-ReportFile', "`"$(Join-Path $Expected 'ppr_basic__trade.json')`"", '-GuiSmokeTest')
Check 'GUI trade analyzer fills from a report' ($r.Code -eq 0 -and $r.Out -match 'give list 15, get list 12, trade grade A\+, mode league') ("$($r.Out) $($r.Err)")
$r = Run-Script @('-ReportFile', "`"$(Join-Path $Expected 'ppr_basic__value.json')`"", '-GuiSmokeTest')
Check 'GUI any-player mode shows the result and picks players' ($r.Code -eq 0 -and $r.Out -match 'trade grade F, mode open, pool results 40, picked 2') ("$($r.Out) $($r.Err)")
$r = Run-Script @('-ReportFile', "`"$(Join-Path $Expected 'season_history.json')`"", '-GuiSmokeTest')
Check 'GUI history and trends tabs fill from a report' ($r.Code -eq 0 -and $r.Out -match 'history rows 7, form rows 15, breakouts 1, declining 1') ("$($r.Out) $($r.Err)")
$r = Run-Script @('-ReportFile', "`"$(Join-Path $Expected 'underdog_volatile.json')`"", '-GuiSmokeTest')
Check 'GUI shows the win probability' ($r.Code -eq 0 -and $r.Out -match 'win \d+(\.\d)?\s*$') ("$($r.Out) $($r.Err)")
$espnReport = Join-Path $work 'espn.json'
$null = Run-Script @('-NoGui', '-Offline', '-Fixtures', "`"$(Join-Path $fixtures 'espn_compare')`"", '-NoCache', '-Quiet', '-Projections', 'blend', '-OutFile', "`"$espnReport`"")
$r = Run-Script @('-ReportFile', "`"$espnReport`"", '-GuiSmokeTest')
Check 'GUI sources tab lists disagreements (blend run)' ($r.Code -eq 0 -and $r.Out -match 'sources 2,') ("$($r.Out) $($r.Err)")
$r = Run-Script @('-ReportFile', "`"$(Join-Path $Expected 'espn_league__espn.json')`"", '-GuiSmokeTest')
Check 'GUI loads an ESPN league report' ($r.Code -eq 0 -and $r.Out -match 'GUI smoke test ok: lineup rows 9') ("$($r.Out) $($r.Err)")
$r = Run-Script @('-NoGui', '-Platform', 'espn', '-LeagueId', '555001', '-Quiet')
Check 'ESPN league without -Team exits 2 and explains' ($r.Code -eq 2 -and $r.Err -match 'needs your team')
$r = Run-Script @('-GuiSmokeTest')
Check 'GUI builds with no report' ($r.Code -eq 0 -and $r.Out -match 'GUI smoke test ok.*remember True') ("$($r.Out) $($r.Err)")

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Host ''
Write-Host "passed: $pass   failed: $fail"
foreach ($f in $failed) { Write-Host "  - $f" }
if ($fail -gt 0) { exit 1 }
