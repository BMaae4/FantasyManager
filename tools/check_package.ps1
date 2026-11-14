#Requires -Version 5.1
<#
.SYNOPSIS
    Checks the Windows download built by tools\package.ps1.

.DESCRIPTION
    Runs the packaged app with no other Python reachable (PATH cut down to
    Windows itself), against a test league: a JSON report from the command
    line, the window built from that report, and the shortcut option.
#>
[CmdletBinding()]
param([string]$App)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $App) { $App = Join-Path $root 'dist\FantasyManager' }
$script = Join-Path $App 'FantasyManager.ps1'
$fixture = Join-Path $root 'tests\fixtures\ppr_basic'
$work = Join-Path ([IO.Path]::GetTempPath()) ('fm_pkg_' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null
$failed = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { Write-Host "ok   $name"; return }
    $script:failed++
    Write-Host "FAIL $name $detail"
    # On GitHub Actions, also show the failure as an annotation on the run.
    if ($env:GITHUB_ACTIONS) {
        $text = ("$name $detail" -replace '\s+', ' ')
        Write-Host ('::error title=Windows download::{0}' -f $text.Substring(0, [Math]::Min(400, $text.Length)))
    }
}

foreach ($file in 'FantasyManager.cmd', 'Create Shortcut.cmd', 'lib\fm_app.py', 'assets\FantasyManager.ico', 'python\python.exe') {
    Check "package contains $file" (Test-Path -LiteralPath (Join-Path $App $file))
}

# No Python but the bundled one: PATH holds Windows only, and no overrides.
$savedPath = $env:PATH
# (The Windows folder itself is left out: the "py" launcher installs there.)
$env:PATH = (Join-Path $env:SystemRoot 'System32') + ';' + (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0')
$env:FM_PYTHON = ''; $env:FM_LEAGUE_ID = '100000000000000001'; $env:FM_USERNAME = 'TestManager'
$env:FM_CONFIG_FILE = Join-Path $work 'none.env'
# Anything the app writes to stderr is part of the captured output, not an error here.
$ErrorActionPreference = 'Continue'
try {
    Check 'no other Python is reachable' (-not (Get-Command python, python3, py -ErrorAction SilentlyContinue))
    $report = Join-Path $work 'report.json'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -NoGui -Offline -Fixtures $fixture -NoCache -Quiet -OutFile $report 2>&1
    $parsed = $null
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $report)) { $parsed = Get-Content -Raw -LiteralPath $report | ConvertFrom-Json }
    Check 'report produced with the bundled Python' ($null -ne $parsed -and @($parsed.lineup.slots).Count -gt 0) ("exit $LASTEXITCODE $out")
    $smoke = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -ReportFile $report -GuiSmokeTest 2>&1
    Check 'window builds from that report' ($LASTEXITCODE -eq 0 -and "$smoke" -match 'GUI smoke test ok: lineup rows 9') ("$smoke")
    $ver = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Version 2>&1
    Check 'version prints' ($LASTEXITCODE -eq 0 -and "$ver" -match 'fantasy_manager \d+\.\d+\.\d+') ("$ver")
} finally {
    $env:PATH = $savedPath
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
if ($failed) { Write-Host "$failed check(s) failed"; exit 1 }
Write-Host 'package ok'
