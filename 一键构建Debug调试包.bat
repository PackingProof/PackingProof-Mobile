@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

echo 正在构建 Debug 调试安装包（使用 Android 调试证书，无需正式签名），请勿关闭窗口...
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0Tools\Build-Debug-Quick.ps1"
if errorlevel 1 (
    echo.
    echo 构建失败，请保留本窗口中的错误信息。
    pause
    exit /b 1
)

echo.
echo 构建成功，正在打开安装包目录。
start "" explorer.exe "%~dp0dist\android"
pause
