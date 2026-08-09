[CmdletBinding()]
param(
    [switch]$ForceClean
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

$pubspecPath = Join-Path $repo 'pubspec.yaml'
$versionLine = (Get-Content -LiteralPath $pubspecPath -Encoding UTF8 |
        Where-Object { $_ -match '^version:\s*\S+' } |
        Select-Object -First 1).Trim()
if (-not $versionLine) {
    throw 'pubspec.yaml 缺少 version 配置'
}
$version = ($versionLine -split ':', 2)[1].Trim()

$revision = (git rev-parse --short=8 HEAD).Trim()
if (-not $revision) { throw '无法读取 Git 修订号' }
$buildTimestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$env:PACKING_PROOF_BUILD_REVISION = $revision
$env:PACKING_PROOF_BUILD_TIMESTAMP = $buildTimestamp

try {
    if ($ForceClean) {
        Write-Host '执行 flutter clean ...'
        flutter clean
        if ($LASTEXITCODE -ne 0) {
            throw "flutter clean 失败，退出代码：$LASTEXITCODE"
        }
    }

    Write-Host "正在构建 Debug 调试安装包：$version"
    flutter pub get
    if ($LASTEXITCODE -ne 0) {
        throw "flutter pub get 失败，退出代码：$LASTEXITCODE"
    }

    flutter build apk --debug --target-platform android-arm64
    if ($LASTEXITCODE -ne 0) {
        throw "flutter build apk --debug 失败，退出代码：$LASTEXITCODE"
    }

    $source = Join-Path $repo 'build/app/outputs/flutter-apk/app-debug.apk'
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "未找到构建产物：$source"
    }

    $outputDir = Join-Path $repo 'dist/android'
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    $destination = Join-Path $outputDir 'PackingProof-Mobile-debug.apk'
    Copy-Item -LiteralPath $source -Destination $destination -Force

    $sizeMb = [Math]::Round((Get-Item -LiteralPath $destination).Length / 1MB, 1)
    $hash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Host "构建成功：$destination" -ForegroundColor Green
    Write-Host "版本：$version"
    Write-Host "大小：${sizeMb} MB"
    Write-Host "SHA256：$hash"
}
finally {
    Remove-Item Env:PACKING_PROOF_BUILD_REVISION -ErrorAction SilentlyContinue
    Remove-Item Env:PACKING_PROOF_BUILD_TIMESTAMP -ErrorAction SilentlyContinue
}
