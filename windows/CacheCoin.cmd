@echo off
setlocal
set "ARGS=%*"
if /i "%ARGS%"=="/silent" set "ARGS=-Silent"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher\CacheCoin.ps1" %ARGS%
