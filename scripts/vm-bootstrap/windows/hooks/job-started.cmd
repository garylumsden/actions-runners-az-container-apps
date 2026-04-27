@echo off
setlocal
if not exist "C:\gh-runner-lifecycle" mkdir "C:\gh-runner-lifecycle"
copy /y NUL "C:\gh-runner-lifecycle\job-active" >nul
exit /b 0
