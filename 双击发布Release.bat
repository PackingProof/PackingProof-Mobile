@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

rem Android Release 在 Windows 编译机上创建：APK 与发布笔记已经在 dist\android\ 下，
rem 不需要跨机拷贝，也不需要 bash，直接用 PowerShell 7 跑 Tools\Publish-Releases.ps1。

if "%~1"=="" (
    echo 用法：双击发布Release.bat dist\android\RELEASE_NOTES-v版本号.md --title "一句话内容" [--prerelease]
    pause
    exit /b 1
)

echo 正在创建 GitHub 与 Gitee Release，请勿关闭窗口...
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0Tools\Publish-Releases.ps1" %*
if errorlevel 1 (
    echo.
    echo 发布失败，请保留本窗口中的错误信息。
    pause
    exit /b 1
)

echo.
echo 发布完成。
pause
