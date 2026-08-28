param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist'),
    [string]$Version = '1.3.1.0'
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
    $icon = [Drawing.Icon]::FromHandle($bitmap.GetHicon())
    $stream = [IO.File]::Create($iconPath)
    try {
        $icon.Save($stream)
    }
    finally {
        $stream.Dispose()
        $icon.Dispose()
    }
}
finally {
    $graphics.Dispose()
    $bitmap.Dispose()
}

$webViewDirectory = Join-Path $projectDirectory 'lib\WebView2'
$embeddedFiles = @{
    '%LOCALAPPDATA%\LanZ-Monitor\runtime\WebView2\Microsoft.Web.WebView2.Core.dll' = (Join-Path $webViewDirectory 'Microsoft.Web.WebView2.Core.dll')
    '%LOCALAPPDATA%\LanZ-Monitor\runtime\WebView2\Microsoft.Web.WebView2.Wpf.dll' = (Join-Path $webViewDirectory 'Microsoft.Web.WebView2.Wpf.dll')
    '%LOCALAPPDATA%\LanZ-Monitor\runtime\WebView2\WebView2Loader.dll' = (Join-Path $webViewDirectory 'WebView2Loader.dll')
}
foreach ($sourcePath in $embeddedFiles.Values) {
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "打包缺少文件：$sourcePath"
    }
}

$monitorOutput = Join-Path $OutputDirectory 'LanZ-Monitor.exe'
$setupOutput = Join-Path $OutputDirectory 'LanZ-Setup.exe'

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

Invoke-PS2EXE -InputFile (Join-Path $projectDirectory 'Set-LanZSession.ps1') `
    -OutputFile $setupOutput `
    -IconFile $iconPath `
    -Title 'LanZ Monitor Setup' `
    -Product 'LanZ Monitor' `
    -Description '本地加密连接配置工具' `
    -Company 'LanZ Monitor Contributors' `
    -Copyright 'MIT License' `
    -Version $Version `
    -X64 `
    -SupportOS

Copy-Item -LiteralPath (Join-Path $projectDirectory 'README.md') -Destination (Join-Path $OutputDirectory 'README.md') -Force
Copy-Item -LiteralPath (Join-Path $projectDirectory 'LICENSE') -Destination (Join-Path $OutputDirectory 'LICENSE') -Force

$zipPath = Join-Path $OutputDirectory 'LanZ-Monitor-win-x64.zip'
Compress-Archive -LiteralPath @(
    $monitorOutput,
    $setupOutput,
    (Join-Path $OutputDirectory 'README.md'),
    (Join-Path $OutputDirectory 'LICENSE')
) -DestinationPath $zipPath -Force

Get-Item -LiteralPath $monitorOutput, $setupOutput, $zipPath | Select-Object Name, Length, LastWriteTime
