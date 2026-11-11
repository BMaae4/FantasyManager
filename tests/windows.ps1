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
    $actual = Join-Path $work "$case.json"
    if (Test-Path $actual) { Remove-Item $actual }
    $r = Run-Script (@('-NoGui', '-Offline', '-Fixtures', "`"$fixture`"", '-NoCache', '-Quiet', '-OutFile', "`"$actual`"") + $extra)
    $want = [int]([IO.File]::ReadAllText((Join-Path $Expected "$case.status")).Trim())
    if ($r.Code -ne $want) { Check $case $false "exit $($r.Code), expected $want. $($r.Err)"; continue }
    if ($want -ne 0) { Check $case $true; continue }
    $cmp = & python $compare (Join-Path $Expected "$case.json") $actual
    Check $case ($LASTEXITCODE -eq 0) ([string]$cmp)
}

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

# GUI: builds, lays out and fills from a report without being shown.
$r = Run-Script @('-ReportFile', "`"$(Join-Path $Expected 'locked_players.json')`"", '-GuiSmokeTest')
Check 'GUI builds and loads a report' ($r.Code -eq 0 -and $r.Out -match 'GUI smoke test ok: lineup rows 9') ("$($r.Out) $($r.Err)")
$r = Run-Script @('-ReportFile', "`"$(Join-Path $Expected 'ppr_basic__horizon0.json')`"", '-GuiSmokeTest')
Check 'GUI loads a this-week-only report' ($r.Code -eq 0 -and $r.Out -match 'GUI smoke test ok') ("$($r.Out) $($r.Err)")
$r = Run-Script @('-ReportFile', "`"$(Join-Path $Expected 'ppr_basic__trade.json')`"", '-GuiSmokeTest')
Check 'GUI trade analyzer fills from a report' ($r.Code -eq 0 -and $r.Out -match 'give list 15, get list 12, trade grade A\+, mode league') ("$($r.Out) $($r.Err)")
$r = Run-Script @('-ReportFile', "`"$(Join-Path $Expected 'ppr_basic__value.json')`"", '-GuiSmokeTest')
Check 'GUI any-player mode shows the result and picks players' ($r.Code -eq 0 -and $r.Out -match 'trade grade F, mode open, pool results 40, picked 2') ("$($r.Out) $($r.Err)")
$r = Run-Script @('-GuiSmokeTest')
Check 'GUI builds with no report' ($r.Code -eq 0 -and $r.Out -match 'GUI smoke test ok') ("$($r.Out) $($r.Err)")

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Host ''
Write-Host "passed: $pass   failed: $fail"
foreach ($f in $failed) { Write-Host "  - $f" }
if ($fail -gt 0) { exit 1 }
