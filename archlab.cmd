@echo off
rem archlab - atalho de linha de comando para archlab.ps1
rem Uso: archlab.cmd [comando] [opcoes]   (veja archlab.cmd -h)
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0archlab.ps1" %*
set "RC=%ERRORLEVEL%"
if "%~1"=="" pause
exit /b %RC%
