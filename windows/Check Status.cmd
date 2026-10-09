@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\CacheCoin-Status.ps1" %*
exit /b %ERRORLEVEL%
