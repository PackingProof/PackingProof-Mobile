[CmdletBinding()]
param(
    [string]$VersionName = '0.5.19',
    [int]$VersionCode = 11019,
    [string]$SigningDirectory = '',
    [switch]$ForceClean
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

if ($VersionName -notmatch '^\d+\.\d+\.\d+$') { throw 'VersionName 必须为 x.y.z 格式' }
if ($VersionCode -le 0) { throw 'VersionCode 必须大于 0' }
$supportedAbis = @('arm64-v8a')

function Invoke-SpeechAssetGeneration {
    $generator = Join-Path $repo 'tool/generate_speech_assets.dart'
    if (-not (Test-Path -LiteralPath $generator -PathType Leaf)) {
        throw "找不到固定语音生成器：$generator"
    }
    & dart run $generator
    if ($LASTEXITCODE -ne 0) {
        throw "固定语音生成失败，退出代码：$LASTEXITCODE"
    }
}

function Get-ReleaseBuildInputFingerprint {
    $trackedInputs = @(& git -C $repo ls-files -- 'pubspec.yaml' 'pubspec.lock' 'android')
    if ($LASTEXITCODE -ne 0 -or $trackedInputs.Count -eq 0) {
        throw '无法读取 Android 发布构建输入'
    }

    $flutterVersion = (& flutter --version --machine) -join "`n"
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($flutterVersion)) {
        throw '无法读取 Flutter SDK 版本'
    }

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        foreach ($relativePath in @($trackedInputs | Sort-Object)) {
            $pathBytes = [Text.Encoding]::UTF8.GetBytes($relativePath.Replace('\', '/'))
            $sha.TransformBlock($pathBytes, 0, $pathBytes.Length, $null, 0) | Out-Null
            $separator = [byte[]](0)
            $sha.TransformBlock($separator, 0, $separator.Length, $null, 0) | Out-Null

            $content = [IO.File]::ReadAllBytes((Join-Path $repo $relativePath))
            $sha.TransformBlock($content, 0, $content.Length, $null, 0) | Out-Null
        }
        $versionBytes = [Text.Encoding]::UTF8.GetBytes($flutterVersion)
        $sha.TransformFinalBlock($versionBytes, 0, $versionBytes.Length) | Out-Null
        return [Convert]::ToHexString($sha.Hash).ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-SpeechAssetState {
    param([Parameter(Mandatory)][string]$ManifestPath)
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "缺少内置语音清单：$ManifestPath"
    }
    $manifest = Get-Content -Raw -Encoding UTF8 $ManifestPath | ConvertFrom-Json
    $result = [ordered]@{}
    foreach ($prompt in @($manifest.prompts)) {
        $audioPath = Join-Path (Split-Path -Parent $ManifestPath) $prompt.file
        if (-not (Test-Path -LiteralPath $audioPath -PathType Leaf)) {
            throw "缺少内置语音：$($prompt.file)"
        }
        $file = Get-Item -LiteralPath $audioPath
        if ($file.Length -lt 128 -or $file.Length -ne [long]$prompt.bytes) {
            throw "内置语音大小与清单不一致：$($prompt.file)"
        }
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $audioPath).Hash.ToLowerInvariant()
        if ($hash -ne "$($prompt.sha256)".ToLowerInvariant()) {
            throw "内置语音哈希与清单不一致：$($prompt.file)"
        }
        $cacheInput = "$($prompt.text)|$($prompt.voice)|$($manifest.format)|$($manifest.version)"
        $cacheHash = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($cacheInput))
        ).ToLowerInvariant()
        if ($cacheHash -ne "$($prompt.cacheKey)".ToLowerInvariant()) {
            throw "内置语音缓存键与清单不一致：$($prompt.file)"
        }
        if ($result.Contains($prompt.file)) { throw "内置语音清单包含重复文件：$($prompt.file)" }
        $result[$prompt.file] = $hash
    }
    if ($result.Count -eq 0) { throw '内置语音清单为空' }
    return $result
}

function Assert-SameSpeechAssetState {
    param([Parameter(Mandatory)]$Before, [Parameter(Mandatory)]$After)
    if ($Before.Count -ne $After.Count) { throw '构建过程改变了内置语音文件数量' }
    foreach ($name in $Before.Keys) {
        if (-not $After.Contains($name) -or $Before[$name] -ne $After[$name]) {
            throw "构建过程改变了内置语音：$name"
        }
    }
}

function Assert-ApkContainsSpeechAssets {
    param(
        [Parameter(Mandatory)][string]$ApkPath,
        [Parameter(Mandatory)]$SpeechAssets
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ApkPath)
    try {
        $entries = @{}
        foreach ($entry in $archive.Entries) { $entries[$entry.FullName] = $entry.Length }
        $manifestEntry = 'assets/flutter_assets/assets/audio/tts/manifest.json'
        if (-not $entries.ContainsKey($manifestEntry)) { throw 'APK 缺少内置语音清单' }
        foreach ($name in $SpeechAssets.Keys) {
            $entryName = "assets/flutter_assets/assets/audio/tts/$name"
            if (-not $entries.ContainsKey($entryName) -or $entries[$entryName] -lt 128) {
                throw "APK 缺少有效的内置语音：$name"
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Assert-ApkAbis {
    param(
        [Parameter(Mandatory)][string]$ApkPath,
        [Parameter(Mandatory)][string[]]$ExpectedAbis
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ApkPath)
    try {
        $actualAbis = @(
            $archive.Entries |
                Where-Object { $_.FullName -match '^lib/([^/]+)/[^/]+$' } |
                ForEach-Object { [regex]::Match($_.FullName, '^lib/([^/]+)/').Groups[1].Value } |
                Sort-Object -Unique
        )
        $expected = @($ExpectedAbis | Sort-Object -Unique)
        $difference = @(Compare-Object -ReferenceObject $expected -DifferenceObject $actualAbis)
        if ($difference.Count -ne 0) {
            throw "APK 架构不符合要求：实际 [$($actualAbis -join ', ')]，预期 [$($expected -join ', ')]"
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Resolve-ApkAnalyzer {
    $candidates = @(
        (Join-Path "$env:ANDROID_HOME" 'cmdline-tools/latest/bin/apkanalyzer.bat'),
        (Join-Path "$env:ANDROID_SDK_ROOT" 'cmdline-tools/latest/bin/apkanalyzer.bat'),
        (Join-Path "$env:LOCALAPPDATA" 'Android/Sdk/cmdline-tools/latest/bin/apkanalyzer.bat')
    )
    $resolved = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $resolved) { throw '找不到 apkanalyzer，无法校验 APK 元数据' }
    return $resolved
}

function Resolve-ApkSigner {
    $sdkRoots = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, (Join-Path $env:LOCALAPPDATA 'Android/Sdk')) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    foreach ($root in $sdkRoots) {
        $tool = Get-ChildItem -LiteralPath (Join-Path $root 'build-tools') -Directory -ErrorAction SilentlyContinue |
            Sort-Object { [version]$_.Name } -Descending |
            ForEach-Object { Join-Path $_.FullName 'apksigner.bat' } |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1
        if ($tool) { return $tool }
    }
    throw '找不到 apksigner，无法校验 APK 正式签名'
}

function Resolve-KeyTool {
    $candidates = @()
    if ($env:JAVA_HOME) { $candidates += (Join-Path $env:JAVA_HOME 'bin/keytool.exe') }
    $candidates += @(
        'C:/Program Files/Android/Android Studio/jbr/bin/keytool.exe',
        'C:/Program Files/Android/Android Studio/jre/bin/keytool.exe'
    )
    $javaRoots = Get-ChildItem -LiteralPath 'C:/Program Files/Java' -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending
    $candidates += $javaRoots | ForEach-Object { Join-Path $_.FullName 'bin/keytool.exe' }
    $resolved = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $resolved) { throw '找不到 JDK keytool，无法读取正式签名证书' }
    return $resolved
}

function Get-SigningConfiguration {
    param([Parameter(Mandatory)][string]$Directory)
    $resolved = [IO.Path]::GetFullPath($Directory)
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        throw "签名目录不存在：$resolved"
    }
    $credentialPath = Join-Path $resolved '签名凭据.txt'
    if (-not (Test-Path -LiteralPath $credentialPath -PathType Leaf)) {
        throw "签名目录缺少签名凭据.txt：$resolved"
    }
    $values = @{}
    foreach ($line in [IO.File]::ReadAllLines($credentialPath, [Text.Encoding]::UTF8)) {
        $separator = $line.IndexOf([char]0xFF1A)
        if ($separator -lt 0) { $separator = $line.IndexOf(':') }
        if ($separator -le 0) { continue }
        $label = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        if ($label -in @('密钥文件', '别名', '密钥库密码', '密钥密码')) {
            $values[$label] = $value
        }
    }
    foreach ($label in @('密钥文件', '别名', '密钥库密码', '密钥密码')) {
        if ([string]::IsNullOrWhiteSpace($values[$label])) {
            throw "签名凭据缺少字段：$label"
        }
    }
    $keyStorePath = $values['密钥文件']
    if (-not [IO.Path]::IsPathRooted($keyStorePath)) {
        $keyStorePath = Join-Path $resolved $keyStorePath
    }
    $keyStorePath = [IO.Path]::GetFullPath($keyStorePath)
    if (-not (Test-Path -LiteralPath $keyStorePath -PathType Leaf)) {
        throw "找不到签名密钥文件：$keyStorePath"
    }
    return [ordered]@{
        KeyStorePath = $keyStorePath
        KeyAlias = $values['别名']
        StorePassword = $values['密钥库密码']
        KeyPassword = $values['密钥密码']
    }
}

function Get-KeyStoreCertificateSha256 {
    param(
        [Parameter(Mandatory)]$Signing,
        [Parameter(Mandatory)][string]$KeyTool
    )
    $env:PACKING_PROOF_STORE_PASSWORD = $Signing.StorePassword
    $output = (& $KeyTool -list -v -keystore $Signing.KeyStorePath -alias $Signing.KeyAlias -storepass:env PACKING_PROOF_STORE_PASSWORD) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $output -notmatch 'SHA256:\s*([0-9A-F:]{95})') {
        throw '无法读取正式签名证书，请检查别名和密钥库密码'
    }
    return $matches[1].Replace(':', '').ToLowerInvariant()
}

function Assert-ApkSignature {
    param(
        [Parameter(Mandatory)][string]$ApkPath,
        [Parameter(Mandatory)][string]$ApkSigner,
        [Parameter(Mandatory)][string]$ExpectedSha256
    )
    $output = (& $ApkSigner verify --verbose --print-certs $ApkPath) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "APK 签名校验失败：$ApkPath" }
    if ($output -notmatch 'certificate SHA-256 digest:\s*([0-9a-fA-F]{64})') {
        throw "无法读取 APK 签名证书：$ApkPath"
    }
    if ($matches[1].ToLowerInvariant() -ne $ExpectedSha256) {
        throw "APK 未使用指定的 PackingProof 正式证书：$ApkPath"
    }
}

function Assert-ApkMetadata {
    param(
        [Parameter(Mandatory)][string]$ApkPath,
        [Parameter(Mandatory)][string]$Revision,
        [Parameter(Mandatory)][string]$Timestamp,
        [Parameter(Mandatory)][datetime]$BuildStartedAt,
        [Parameter(Mandatory)][string]$Analyzer
    )
    $file = Get-Item -LiteralPath $ApkPath
    if ($file.LastWriteTimeUtc -lt $BuildStartedAt.AddSeconds(-2)) { throw "APK 不是本次构建产物：$ApkPath" }
    if ((& $Analyzer manifest application-id $ApkPath).Trim() -ne 'app.packingproof.mobile') { throw "APK 包名错误：$ApkPath" }
    if ((& $Analyzer manifest version-name $ApkPath).Trim() -ne $VersionName) { throw "APK 版本名错误：$ApkPath" }
    if ([int](& $Analyzer manifest version-code $ApkPath).Trim() -ne $VersionCode) { throw "APK 版本号错误：$ApkPath" }
    $manifestText = (& $Analyzer manifest print $ApkPath) -join "`n"
    foreach ($expected in @($Revision, $Timestamp)) {
        if (-not $manifestText.Contains($expected)) { throw "APK 缺少构建标识 $expected：$ApkPath" }
    }
}

function Assert-ApkContainsDartBuildIdentity {
    param(
        [Parameter(Mandatory)][string]$ApkPath,
        [Parameter(Mandatory)][string]$Revision,
        [Parameter(Mandatory)][string]$Timestamp
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ApkPath)
    try {
        $entry = $archive.GetEntry('lib/arm64-v8a/libapp.so')
        if ($null -eq $entry) { throw 'APK 缺少 ARM64 Dart AOT 产物 libapp.so' }

        $memory = [IO.MemoryStream]::new()
        $stream = $entry.Open()
        try {
            $stream.CopyTo($memory)
        }
        finally {
            $stream.Dispose()
        }
        $content = [Text.Encoding]::ASCII.GetString($memory.ToArray())
        foreach ($expected in @($Revision, $Timestamp)) {
            if (-not $content.Contains($expected, [StringComparison]::Ordinal)) {
                throw "APK 的 Dart AOT 产物不是本次构建：缺少 $expected"
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

$revision = (git rev-parse --short=8 HEAD).Trim()
if (-not $revision) { throw '无法读取 Git 修订号' }
$buildTimestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$buildStartedAt = [DateTime]::UtcNow
$env:PACKING_PROOF_BUILD_REVISION = $revision
$env:PACKING_PROOF_BUILD_TIMESTAMP = $buildTimestamp
$analyzer = Resolve-ApkAnalyzer
$signing = $null
$signingCertificateSha256 = $null
if (-not [string]::IsNullOrWhiteSpace($SigningDirectory)) {
    $signing = Get-SigningConfiguration -Directory $SigningDirectory
    $env:PACKING_PROOF_KEYSTORE_PATH = $signing.KeyStorePath
    $env:PACKING_PROOF_KEY_ALIAS = $signing.KeyAlias
    $env:PACKING_PROOF_STORE_PASSWORD = $signing.StorePassword
    $env:PACKING_PROOF_KEY_PASSWORD = $signing.KeyPassword
    $env:PACKING_PROOF_REQUIRE_RELEASE_SIGNING = 'true'
    $keyTool = Resolve-KeyTool
    $signingCertificateSha256 = Get-KeyStoreCertificateSha256 -Signing $signing -KeyTool $keyTool
    $apkSigner = Resolve-ApkSigner
}

$resolvedOutput = [IO.Path]::GetFullPath((Join-Path $repo 'dist/android'))
$resolvedRepo = [IO.Path]::GetFullPath($repo).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$outputParent = Split-Path -Parent $resolvedOutput
$temporaryOutput = Join-Path $outputParent ".packing-proof-android-$([Guid]::NewGuid().ToString('N'))"
$buildInputStampPath = Join-Path $repo '.dart_tool/packing_proof_release_inputs.sha256'
if (-not ([IO.Path]::GetFullPath($temporaryOutput)).StartsWith($resolvedRepo, [StringComparison]::OrdinalIgnoreCase)) {
    throw '临时输出目录必须位于当前仓库内'
}
New-Item -ItemType Directory -Force -Path $temporaryOutput | Out-Null

try {
    $buildInputFingerprint = Get-ReleaseBuildInputFingerprint
    $previousBuildInputFingerprint = if (Test-Path -LiteralPath $buildInputStampPath -PathType Leaf) {
        ([IO.File]::ReadAllText($buildInputStampPath, [Text.Encoding]::UTF8)).Trim()
    }
    else {
        ''
    }
    $requiresClean = $ForceClean -or
        -not [string]::Equals(
            $buildInputFingerprint,
            $previousBuildInputFingerprint,
            [StringComparison]::OrdinalIgnoreCase
        )
    if ($requiresClean) {
        Write-Host 'Android、依赖或 Flutter SDK 构建输入已变化，执行完整清理'
        flutter clean
        if ($LASTEXITCODE -ne 0) { throw "Flutter 清理失败，退出代码：$LASTEXITCODE" }
    }
    else {
        Write-Host 'Android 构建输入未变化，复用 Gradle 和原生插件缓存'
    }

    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $repo 'build/app/outputs/flutter-apk/*.apk')
    flutter pub get
    if ($LASTEXITCODE -ne 0) { throw "Flutter 依赖解析失败，退出代码：$LASTEXITCODE" }
    Invoke-SpeechAssetGeneration
    $speechManifestPath = Join-Path $repo 'assets/audio/tts/manifest.json'
    $speechAssetsBefore = Get-SpeechAssetState -ManifestPath $speechManifestPath
    flutter analyze --no-pub --no-fatal-infos
    if ($LASTEXITCODE -ne 0) { throw "Flutter 分析失败，退出代码：$LASTEXITCODE" }
    flutter test --no-pub
    if ($LASTEXITCODE -ne 0) { throw "Flutter 测试失败，退出代码：$LASTEXITCODE" }

    $releaseFlutterOutput = Join-Path $repo 'build/app/intermediates/flutter/release'
    if (Test-Path -LiteralPath $releaseFlutterOutput -PathType Container) {
        Remove-Item -LiteralPath $releaseFlutterOutput -Recurse -Force
    }

    flutter build apk --release `
        --target-platform android-arm64 `
        --build-name $VersionName `
        --build-number $VersionCode `
        --dart-define="BUILD_REVISION=$revision" `
        --dart-define="BUILD_TIMESTAMP=$buildTimestamp"
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter Release 构建失败，退出代码：$LASTEXITCODE"
    }

    $source = Join-Path $repo 'build/app/outputs/flutter-apk/app-release.apk'
    if (-not (Test-Path -LiteralPath $source)) { throw "未找到构建产物：$source" }
    $speechAssetsAfter = Get-SpeechAssetState -ManifestPath $speechManifestPath
    Assert-SameSpeechAssetState -Before $speechAssetsBefore -After $speechAssetsAfter
    Assert-ApkContainsSpeechAssets -ApkPath $source -SpeechAssets $speechAssetsBefore
    Assert-ApkAbis -ApkPath $source -ExpectedAbis $supportedAbis
    Assert-ApkMetadata -ApkPath $source -Revision $revision -Timestamp $buildTimestamp -BuildStartedAt $buildStartedAt -Analyzer $analyzer
    Assert-ApkContainsDartBuildIdentity -ApkPath $source -Revision $revision -Timestamp $buildTimestamp
    if ($signing) {
        Assert-ApkSignature -ApkPath $source -ApkSigner $apkSigner -ExpectedSha256 $signingCertificateSha256
    }
    $fileName = 'PackingProof-Mobile.apk'
    $destination = Join-Path $temporaryOutput $fileName
    Copy-Item -LiteralPath $source -Destination $destination
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash.ToLowerInvariant()
    $artifacts = @([ordered]@{ file = $fileName; sha256 = $hash; bytes = (Get-Item $destination).Length })

    $checksumLines = $artifacts | ForEach-Object { "$($_.sha256)  $($_.file)" }
    [IO.File]::WriteAllLines((Join-Path $temporaryOutput 'SHA256SUMS.txt'), $checksumLines, [Text.UTF8Encoding]::new($false))
    $buildManifest = [ordered]@{
        versionName = $VersionName
        versionCode = $VersionCode
        packageName = 'app.packingproof.mobile'
        revision = $revision
        builtAtUtc = $buildTimestamp
        releaseSigned = [bool]$signing
        signingCertificateSha256 = $signingCertificateSha256
        bundledSpeechAssetCount = $speechAssetsBefore.Count
        supportedAbis = $supportedAbis
        artifacts = $artifacts
    }
    [IO.File]::WriteAllText(
        (Join-Path $temporaryOutput 'build-manifest.json'),
        ($buildManifest | ConvertTo-Json -Depth 5),
        [Text.UTF8Encoding]::new($false)
    )

    New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null
    Get-ChildItem -LiteralPath $resolvedOutput -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'PackingProof-Mobile.apk' -or $_.Name -like 'PackingProof-Mobile-*.apk' -or $_.Name -in @('SHA256SUMS.txt', 'build-manifest.json') } |
        Remove-Item -Force
    Get-ChildItem -LiteralPath $temporaryOutput -File |
        Copy-Item -Destination $resolvedOutput
    $buildInputStampParent = Split-Path -Parent $buildInputStampPath
    New-Item -ItemType Directory -Force -Path $buildInputStampParent | Out-Null
    [IO.File]::WriteAllText(
        $buildInputStampPath,
        $buildInputFingerprint,
        [Text.UTF8Encoding]::new($false)
    )
    Write-Host "Android 安装包已输出到 $resolvedOutput"
}
finally {
    Remove-Item -LiteralPath $temporaryOutput -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:PACKING_PROOF_BUILD_REVISION -ErrorAction SilentlyContinue
    Remove-Item Env:PACKING_PROOF_BUILD_TIMESTAMP -ErrorAction SilentlyContinue
    Remove-Item Env:PACKING_PROOF_KEYSTORE_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:PACKING_PROOF_KEY_ALIAS -ErrorAction SilentlyContinue
    Remove-Item Env:PACKING_PROOF_STORE_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:PACKING_PROOF_KEY_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:PACKING_PROOF_REQUIRE_RELEASE_SIGNING -ErrorAction SilentlyContinue
}
