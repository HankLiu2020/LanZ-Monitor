param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist'),
    [string]$Version = '1.4.0.0'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectDirectory = $PSScriptRoot
$moduleRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'LanZMonitorTools\PowerShellModules'
$moduleVersion = '1.0.18'
$modulePath = Join-Path $moduleRoot "ps2exe\$moduleVersion\ps2exe.psd1"

if (-not (Test-Path -LiteralPath $modulePath)) {
    [void][IO.Directory]::CreateDirectory($moduleRoot)
    Save-Module -Name ps2exe -RequiredVersion $moduleVersion -Repository PSGallery -Path $moduleRoot -Force
}
Import-Module $modulePath -Force

$buildDirectory = Join-Path $projectDirectory '.build'
[void][IO.Directory]::CreateDirectory($buildDirectory)
[void][IO.Directory]::CreateDirectory($OutputDirectory)

$iconPath = Join-Path $buildDirectory 'LanZ-Monitor.ico'
Add-Type -AssemblyName System.Drawing
if (-not ('LanZMonitor.NativeIconMethods' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
namespace LanZMonitor {
    public static class NativeIconMethods {
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool DestroyIcon(IntPtr handle);
    }
}
'@
}
$bitmap = [Drawing.Bitmap]::new(64, 64)
$graphics = [Drawing.Graphics]::FromImage($bitmap)
try {
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([Drawing.Color]::FromArgb(247, 251, 253))
    $backgroundBrush = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(69, 195, 145))
    $linePen = [Drawing.Pen]::new([Drawing.Color]::White, 5)
    try {
        $graphics.FillEllipse($backgroundBrush, 4, 4, 56, 56)
        $graphics.DrawLines($linePen, [Drawing.Point[]]@(
            [Drawing.Point]::new(14, 42),
            [Drawing.Point]::new(25, 31),
            [Drawing.Point]::new(35, 37),
            [Drawing.Point]::new(50, 20)
        ))
    }
    finally {
        $backgroundBrush.Dispose()
        $linePen.Dispose()
    }
    $iconHandle = $bitmap.GetHicon()
    $icon = [Drawing.Icon]::FromHandle($iconHandle)
    $stream = [IO.File]::Create($iconPath)
    try {
        $icon.Save($stream)
    }
    finally {
        $stream.Dispose()
        $icon.Dispose()
        [void][LanZMonitor.NativeIconMethods]::DestroyIcon($iconHandle)
    }
}
finally {
    $graphics.Dispose()
    $bitmap.Dispose()
}

$webViewDirectory = Join-Path $projectDirectory 'lib\WebView2'
$embeddedFiles = @{
    '%LOCALAPPDATA%\LanZ-Monitor\runtime\WebView2Payload\Microsoft.Web.WebView2.Core.dll' = (Join-Path $webViewDirectory 'Microsoft.Web.WebView2.Core.dll')
    '%LOCALAPPDATA%\LanZ-Monitor\runtime\WebView2Payload\Microsoft.Web.WebView2.Wpf.dll' = (Join-Path $webViewDirectory 'Microsoft.Web.WebView2.Wpf.dll')
    '%LOCALAPPDATA%\LanZ-Monitor\runtime\WebView2Payload\WebView2Loader.dll' = (Join-Path $webViewDirectory 'WebView2Loader.dll')
}
foreach ($sourcePath in $embeddedFiles.Values) {
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "打包缺少文件：$sourcePath"
    }
}

$monitorOutput = Join-Path $OutputDirectory 'LanZ-Monitor.exe'
$obsoleteSetupOutput = Join-Path $OutputDirectory 'LanZ-Setup.exe'
if (Test-Path -LiteralPath $obsoleteSetupOutput) {
    Remove-Item -LiteralPath $obsoleteSetupOutput -Force
}

Invoke-PS2EXE -InputFile (Join-Path $projectDirectory 'LanZMonitor.ps1') `
    -OutputFile $monitorOutput `
    -IconFile $iconPath `
    -EmbedFiles $embeddedFiles `
    -Title 'LanZ Monitor' `
    -Product 'LanZ Monitor' `
    -Description '本地模型负载与额度监控' `
    -Company 'LanZ Monitor Contributors' `
    -Copyright 'MIT License' `
    -Version $Version `
    -NoConsole `
    -NoOutput `
    -STA `
    -X64 `
    -DPIAware `
    -SupportOS

# 发布目录只保留单文件 EXE；登录已内建到程序，不再发布
# setup 脚本、README/LICENSE 副本或 zip 包。
$obsoletePackageOutputs = @(
    'LanZ-Monitor-win-x64.zip',
    'README.md',
    'LICENSE',
    'Set-LanZSession.ps1',
    'setup-session.cmd',
    'start-widget.cmd'
)
foreach ($obsoleteName in $obsoletePackageOutputs) {
    $obsoletePath = Join-Path $OutputDirectory $obsoleteName
    if (Test-Path -LiteralPath $obsoletePath) {
        Remove-Item -LiteralPath $obsoletePath -Force
    }
}

Get-Item -LiteralPath $monitorOutput | Select-Object Name, Length, LastWriteTime
