@echo off
chcp 65001 >nul
title ANSYS Solve Monitor
cd /d "%~dp0"

rem 支持把 .wbpj 文件直接拖到本 bat 上，用它所在的目录作为工程目录
if "%~1"=="" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0monitor.ps1"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0monitor.ps1" -Root "%~1"
)
set RC=%ERRORLEVEL%

echo.
if "%RC%"=="0" (
    echo Monitor exited.
) else (
    echo Monitor exited with code %RC%
)
echo.
pause
