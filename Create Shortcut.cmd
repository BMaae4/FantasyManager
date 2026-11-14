@echo off
rem Adds Fantasy Manager shortcuts to the Desktop and the Start menu.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0FantasyManager.ps1" -CreateShortcut
echo.
pause
