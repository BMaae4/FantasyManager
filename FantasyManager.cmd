@echo off
rem Opens the Fantasy Manager window (no console). Double-click or run from a shortcut.
rem Arguments are passed through, e.g.  FantasyManager.cmd -Horizon 2
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0FantasyManager.ps1" %*
