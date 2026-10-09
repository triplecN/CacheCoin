@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher\CacheCoin.ps1" -Mode node %*
exit /b %ERRORLEVEL%
