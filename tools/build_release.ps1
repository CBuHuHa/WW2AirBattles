# build_release.ps1
# Release-сборка APK/AAB с release-keystore. Пароль не хранится в репозитории:
# он читается из %USERPROFILE%\.android-keys\ww2airbattles-release.credentials.txt,
# подставляется в export_presets.cfg только на время сборки, затем файл восстанавливается.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tools\build_release.ps1 -Target apk
#   powershell -ExecutionPolicy Bypass -File tools\build_release.ps1 -Target aab
#   powershell -ExecutionPolicy Bypass -File tools\build_release.ps1 -Target all
#   powershell -ExecutionPolicy Bypass -File tools\build_release.ps1 -Target all -KeepAndroidCache
#
# Сборка AAB идёт через Gradle и оставляет в android\build до ~1.3 GB промежуточных
# файлов (libgodot_android.so во всех 4 ABI дважды, копии godot-lib .aar, черновики AAB).
# После экспорта они вычищаются, чтобы дерево проекта оставалось ~120 MB.
# -KeepAndroidCache сохраняет их (быстрее повторная сборка, но +1.3 GB на диске).

param(
    [ValidateSet("apk", "aab", "all")]
    [string]$Target = "all",
    [switch]$KeepAndroidCache
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$godot = "C:\Users\cvin\tools\godot\Godot_v4.7.2-stable_win64\Godot_v4.7.2-stable_win64_console.exe"
$credsPath = Join-Path $env:USERPROFILE ".android-keys\ww2airbattles-release.credentials.txt"
$presetPath = Join-Path $root "export_presets.cfg"
$backupPath = Join-Path $root "export_presets.cfg.buildbak"
$templates = Join-Path $env:APPDATA "Godot\export_templates\4.7.2.stable"
$androidBuild = Join-Path $root "android\build"

if (-not (Test-Path $godot)) { throw "Non-mono Godot not found: $godot" }
if (-not (Test-Path $credsPath)) { throw "Release credentials not found: $credsPath" }
if (-not (Test-Path $templates)) { throw "Non-mono export templates not installed: $templates" }

$creds = @{}
Get-Content $credsPath | ForEach-Object {
    $line = $_.Trim()
    if ($line -and $line.Contains("=")) {
        $key, $value = $line.Split("=", 2)
        $creds[$key.Trim()] = $value.Trim()
    }
}
foreach ($required in @("password", "alias", "keystore")) {
    if (-not $creds.ContainsKey($required) -or -not $creds[$required]) {
        throw "Missing '$required' in $credsPath"
    }
}

# Gradle-каталог AAB-сборки. Всё, что здесь лежит, пересоздаётся следующей сборкой
# (шаблон — из android_source.zip, .aar — из export templates, остальное — Gradle).
function Clear-AndroidBuildCache {
    $paths = @(
        (Join-Path $androidBuild "build"),
        (Join-Path $androidBuild "libs"),
        (Join-Path $androidBuild "assetPackInstallTime")
    )
    $freed = 0
    foreach ($path in $paths) {
        if (-not (Test-Path $path)) { continue }
        $sum = (Get-ChildItem $path -Recurse -File -Force -ErrorAction SilentlyContinue |
            Measure-Object -Sum Length).Sum
        if ($sum) { $freed += $sum }
        Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($freed -gt 0) {
        Write-Host ("Cleaned android build cache: {0:N1} MB freed" -f ($freed / 1MB))
    }
}

Copy-Item $presetPath $backupPath -Force
try {
    $text = [IO.File]::ReadAllText($presetPath)
    $text = $text.Replace("__RELEASE_PASSWORD__", $creds["password"])
    $text = $text.Replace("C:/Users/cvin/.android-keys/ww2airbattles-release.keystore", ($creds["keystore"] -replace "\\", "/"))
    $text = $text.Replace('keystore/release_user="ww2airbattles"', ('keystore/release_user="' + $creds["alias"] + '"'))
    [IO.File]::WriteAllText($presetPath, $text, [Text.UTF8Encoding]::new($false))

    New-Item -ItemType Directory -Force (Join-Path $root "build") | Out-Null

    if ($Target -in @("apk", "all")) {
        Write-Host "Building release APK..."
        & $godot --headless --path $root --export-release "Android Release" (Join-Path $root "build\ww2airbattles-release.apk")
        if ($LASTEXITCODE -ne 0) { throw "APK export failed with exit code $LASTEXITCODE" }
    }

    if ($Target -in @("aab", "all")) {
        Write-Host "Building release AAB..."
        & $godot --headless --path $root --install-android-build-template --export-release "Android AAB" (Join-Path $root "build\ww2airbattles-release.aab")
        if ($LASTEXITCODE -ne 0) { throw "AAB export failed with exit code $LASTEXITCODE" }
    }
}
finally {
    if (Test-Path $backupPath) {
        Copy-Item $backupPath $presetPath -Force
        Remove-Item $backupPath -Force
    }
    if (-not $KeepAndroidCache) {
        Clear-AndroidBuildCache
    }
}

Get-ChildItem (Join-Path $root "build\ww2airbattles-release.*") |
    Select-Object Name, Length, LastWriteTime
