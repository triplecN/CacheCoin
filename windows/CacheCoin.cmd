@echo off
setlocal
set "ARGS=%*"
set "ARGS=%ARGS:/silent=-Silent%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher\CacheCoin.ps1" %ARGS%
