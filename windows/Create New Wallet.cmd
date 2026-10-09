@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\CacheCoin-NewWallet.ps1" %*
exit /b %ERRORLEVEL%
