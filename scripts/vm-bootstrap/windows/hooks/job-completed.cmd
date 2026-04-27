@echo off
setlocal

rem Delegate the per-job wipe (workspace, creds, tmp) to the PowerShell
rem sibling — see job-completed.ps1. Best-effort; do not abort the hook
rem on wipe failures (issue #90).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0job-completed.ps1"

if not exist "C:\gh-runner-lifecycle" mkdir "C:\gh-runner-lifecycle"
del /q "C:\gh-runner-lifecycle\job-active" 2>nul
for /f %%t in ('powershell -NoProfile -Command "[int][double]::Parse((Get-Date -UFormat %%s))"') do set TS=%%t
> "C:\gh-runner-lifecycle\last-job-end" echo %TS%
exit /b 0
