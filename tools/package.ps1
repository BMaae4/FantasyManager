#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the Windows download: Fantasy Manager with its own Python.

.DESCRIPTION
    Copies the app into dist\FantasyManager, adds Python's official
    "embeddable package" from python.org as the python folder, and zips the
    result as dist\FantasyManager-<version>-windows.zip. Someone who
    downloads that zip needs nothing else installed.

    Python is downloaded over HTTPS from python.org and its python.exe must
    carry a valid signature from the Python Software Foundation.

    Run by .github/workflows (on every push, and for a release on a v* tag).

.EXAMPLE
    .\tools\package.ps1
    Builds dist\FantasyManager-<version>-windows.zip.

.EXAMPLE
    .\tools\package.ps1 -SkipPython
    Lays out the folder without Python (to check what gets copied).
#>
[CmdletBinding()]
param(
    [string]$PythonVersion = '3.13.11',
    [string]$OutDir,
    [switch]$SkipPython
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }

$versionLine = Select-String -LiteralPath (Join-Path $root 'FantasyManager.ps1') -Pattern "^\`$ToolVersion = '([^']+)'" | Select-Object -First 1
if (-not $versionLine) { throw 'Could not read $ToolVersion from FantasyManager.ps1.' }
$version = $versionLine.Matches[0].Groups[1].Value

$app = Join-Path $OutDir 'FantasyManager'
if (Test-Path -LiteralPath $app) { Remove-Item -LiteralPath $app -Recurse -Force }
New-Item -ItemType Directory -Path $app -Force | Out-Null

# The app itself: launchers, the script, the Python modules, the icon, docs.
foreach ($file in 'FantasyManager.ps1', 'FantasyManager.cmd', 'Create Shortcut.cmd', 'README.md', 'CHANGELOG.md') {
    Copy-Item -LiteralPath (Join-Path $root $file) -Destination $app
}
New-Item -ItemType Directory -Path (Join-Path $app 'lib'), (Join-Path $app 'assets') | Out-Null
Copy-Item -Path (Join-Path $root 'lib\*.py') -Destination (Join-Path $app 'lib')
Copy-Item -LiteralPath (Join-Path $root 'assets\FantasyManager.ico') -Destination (Join-Path $app 'assets')

if (-not $SkipPython) {
    $url = "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-embed-amd64.zip"
    $download = Join-Path $OutDir "python-$PythonVersion-embed-amd64.zip"
    Write-Host "Downloading $url"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $download -UseBasicParsing
    $python = Join-Path $app 'python'
    Expand-Archive -LiteralPath $download -DestinationPath $python -Force
    Remove-Item -LiteralPath $download -Force
    $signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $python 'python.exe')
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Python Software Foundation') {
        throw "python.exe is not validly signed by the Python Software Foundation (status $($signature.Status))."
    }
    Write-Host "Python $PythonVersion added (signed by $($signature.SignerCertificate.Subject -replace ',.*$'))"
}

$zip = Join-Path $OutDir "FantasyManager-$version-windows.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path $app -DestinationPath $zip
Write-Host ("Built {0} ({1:N1} MB)" -f $zip, ((Get-Item -LiteralPath $zip).Length / 1MB))
# For the workflow: the version and the zip path.
if ($env:GITHUB_OUTPUT) {
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "version=$version"
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "zip=$zip"
}
