param(
    [switch]$Once,
    [string]$ScreenshotPath,
    [ValidateRange(2, 60)]
    [int]$RefreshSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AppDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:SessionPath = Join-Path $script:AppDirectory '.lanz-session.bin'
$script:ConfigPath = Join-Path $script:AppDirectory '.lanz-config.bin'
$script:LoginWindowOpen = $false
$script:SuppressAutoLogin = $false
$script:LoadHistory = @{}
$script:HistoryPath = Join-Path $script:AppDirectory '.lanz-history.json'
$script:TimelineAges = @(18000.0, 3600.0, 1800.0, 900.0, 50.0, 40.0, 30.0, 20.0, 10.0, 0.0)
$script:TimelineXs = @(0.0, 55.0, 105.0, 155.0, 218.0, 240.0, 262.0, 284.0, 307.0, 330.0)
$script:ModelOrderPath = Join-Path $script:AppDirectory '.lanz-model-order.json'
$script:ModelOrder = [System.Collections.Generic.List[string]]::new()
$script:DisplayedModels = @()
$script:DragStartPoint = $null
$script:DragModelId = $null

try {
    if (Test-Path -LiteralPath $script:ModelOrderPath) {
        foreach ($modelId in @(Get-Content -LiteralPath $script:ModelOrderPath -Raw | ConvertFrom-Json)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$modelId) -and -not $script:ModelOrder.Contains([string]$modelId)) {
                $script:ModelOrder.Add([string]$modelId)
            }
        }
    }
}
catch {
    $script:ModelOrder.Clear()
}

Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Net.Http

function Get-LanZConfiguration {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        throw '未找到连接配置。请先运行 setup-session.cmd。'
    }

    $protectedBytes = [System.IO.File]::ReadAllBytes($script:ConfigPath)
    $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $protectedBytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    $configuration = [System.Text.Encoding]::UTF8.GetString($plainBytes) | ConvertFrom-Json

    foreach ($propertyName in @('ApiEndpoint', 'LoginUrl', 'SessionCookieName', 'RequestTokenHeader', 'RequestTokenPrefix', 'RequestTokenKey', 'RequestTokenIV', 'SuccessCode', 'UnauthorizedCode')) {
        if ($null -eq $configuration.PSObject.Properties[$propertyName]) {
            throw "连接配置缺少 $propertyName，请重新运行 setup-session.cmd。"
        }
    }

    $apiUri = $null
    $loginUri = $null
    if (-not [Uri]::TryCreate([string]$configuration.ApiEndpoint, [UriKind]::Absolute, [ref]$apiUri) -or $apiUri.Scheme -ne 'https') {
        throw 'API 地址必须是有效的 HTTPS URL。'
    }
    if (-not [Uri]::TryCreate([string]$configuration.LoginUrl, [UriKind]::Absolute, [ref]$loginUri) -or $loginUri.Scheme -ne 'https') {
        throw '登录地址必须是有效的 HTTPS URL。'
    }

    return $configuration
}

$script:Configuration = Get-LanZConfiguration
$script:Endpoint = [string]$script:Configuration.ApiEndpoint
$script:LoginUrl = [string]$script:Configuration.LoginUrl
$script:SessionCookieName = [string]$script:Configuration.SessionCookieName

function Get-LanZSessionValue {
    if (-not [string]::IsNullOrWhiteSpace($env:LANZ_SESSION_VALUE)) {
        return $env:LANZ_SESSION_VALUE.Trim()
    }

    if (-not (Test-Path -LiteralPath $script:SessionPath)) {
        throw '未找到会话凭据。请先运行 setup-session.cmd。'
    }

    $protectedBytes = [System.IO.File]::ReadAllBytes($script:SessionPath)
    $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $protectedBytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [System.Text.Encoding]::UTF8.GetString($plainBytes).Trim()
}

function Save-LanZSessionValue {
    param([Parameter(Mandatory)][string]$SessionValue)

    if ([string]::IsNullOrWhiteSpace($SessionValue) -or $SessionValue -eq '0') {
        throw '无效的会话值。'
    }

    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($SessionValue.Trim())
    $protectedBytes = [System.Security.Cryptography.ProtectedData]::Protect(
        $plainBytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    [System.IO.File]::WriteAllBytes($script:SessionPath, $protectedBytes)
}

function New-LanZRequestToken {
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key = [System.Text.Encoding]::UTF8.GetBytes([string]$script:Configuration.RequestTokenKey)
        $aes.IV = [System.Text.Encoding]::UTF8.GetBytes([string]$script:Configuration.RequestTokenIV)

        $plainText = [string]$script:Configuration.RequestTokenPrefix + [guid]::NewGuid().ToString() + '_' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($plainText)
        $encryptor = $aes.CreateEncryptor()
        try {
            $encryptedBytes = $encryptor.TransformFinalBlock($plainBytes, 0, $plainBytes.Length)
            return [Convert]::ToBase64String($encryptedBytes)
        }
        finally {
            $encryptor.Dispose()
        }
    }
    finally {
        $aes.Dispose()
    }
}

function Get-LanZModels {
    param([string]$SessionValue)

    if ([string]::IsNullOrWhiteSpace($SessionValue)) {
        $SessionValue = Get-LanZSessionValue
    }
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.CheckCertificateRevocationList = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $request = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::Get,
        $script:Endpoint
    )

    try {
        [void]$request.Headers.TryAddWithoutValidation('Cookie', "$($script:SessionCookieName)=$SessionValue")
        [void]$request.Headers.TryAddWithoutValidation([string]$script:Configuration.RequestTokenHeader, (New-LanZRequestToken))
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

        if (-not $response.IsSuccessStatusCode) {
            throw "服务返回 HTTP $([int]$response.StatusCode)"
        }

        $payload = $content | ConvertFrom-Json
        if ([int]$payload.code -ne [int]$script:Configuration.SuccessCode) {
            if ([int]$payload.code -eq [int]$script:Configuration.UnauthorizedCode) {
                throw [System.UnauthorizedAccessException]::new('会话已过期，需要重新验证。')
            }
            throw "接口错误：$($payload.msg)"
        }

        return @($payload.data | ForEach-Object {
            $active = [int]$_.routeStatus.total_active
            $capacity = [int]$_.routeStatus.effective_max_concurrent
            $percent = if ($capacity -gt 0) {
                [math]::Min(100, [math]::Floor($active * 100 / $capacity))
            }
            else {
                0
            }

            $color = if ($percent -ge 85) {
                '#F56C6C'
            }
            elseif ($percent -ge 60) {
                '#E6A23C'
            }
            else {
                '#45C391'
            }

            $cardBackground = if ($percent -ge 85) {
                '#FFF0F0'
            }
            elseif ($percent -ge 60) {
                '#FFF7E8'
            }
            else {
                '#EDF9F4'
            }

            $cardBorder = if ($percent -ge 85) {
                '#F5B8B8'
            }
            elseif ($percent -ge 60) {
                '#EFD19B'
            }
            else {
                '#A9DFC9'
            }

            [pscustomobject]@{
                Name      = [string]$_.modelName
                ModelId   = [string]$_.apiInterface
                Active    = $active
                Capacity  = $capacity
                Percent   = [int]$percent
                Available = [bool]$_.routeStatus.available
                Summary   = "$percent%   $active / $capacity"
                Color     = $color
                CardBackground = $cardBackground
                CardBorder = $cardBorder
            }
        })
    }
    finally {
        $request.Dispose()
        $client.Dispose()
        $handler.Dispose()
    }
}

if ($Once) {
    Get-LanZModels | Select-Object Name, ModelId, Active, Capacity, Percent, Available | ConvertTo-Json -Depth 3
    exit 0
}

$createdNew = $false
$singleInstanceMutex = [System.Threading.Mutex]::new(
    $true,
    'Local\LanZLoadMonitorWidget',
    [ref]$createdNew
)
if (-not $createdNew) {
    $singleInstanceMutex.Dispose()
    exit 0
}

try {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

function Initialize-LanZHistory {
    if (-not (Test-Path -LiteralPath $script:HistoryPath)) {
        return
    }

    try {
        $payload = Get-Content -LiteralPath $script:HistoryPath -Raw | ConvertFrom-Json
        $cutoff = [DateTime]::UtcNow.AddHours(-5)
        foreach ($property in $payload.PSObject.Properties) {
            $history = [System.Collections.Generic.List[object]]::new()
            foreach ($sample in @($property.Value)) {
                $timestamp = if ($sample.Timestamp -is [DateTime]) {
                    $sample.Timestamp.ToUniversalTime()
                }
                else {
                    [DateTime]::Parse(
                        [string]$sample.Timestamp,
                        [Globalization.CultureInfo]::InvariantCulture,
                        [Globalization.DateTimeStyles]::RoundtripKind
                    ).ToUniversalTime()
                }
                if ($timestamp -ge $cutoff) {
                    $history.Add([pscustomobject]@{
                        Timestamp = $timestamp
                        Percent = [int]$sample.Percent
                    })
                }
            }
            if ($history.Count -gt 0) {
                $script:LoadHistory[[string]$property.Name] = $history
            }
        }
    }
    catch {
        $script:LoadHistory = @{}
    }
}

function Save-LanZHistory {
    $payload = [ordered]@{}
    foreach ($key in @($script:LoadHistory.Keys)) {
        $payload[$key] = @($script:LoadHistory[$key] | ForEach-Object {
            [ordered]@{
                Timestamp = $_.Timestamp.ToUniversalTime().ToString('o')
                Percent = [int]$_.Percent
            }
        })
    }
    [System.IO.File]::WriteAllText(
        $script:HistoryPath,
        ($payload | ConvertTo-Json -Depth 5 -Compress),
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Get-LanZTimelineX {
    param([Parameter(Mandatory)][double]$AgeSeconds)

    if ($AgeSeconds -ge $script:TimelineAges[0]) {
        return $script:TimelineXs[0]
    }
    if ($AgeSeconds -le 0) {
        return $script:TimelineXs[$script:TimelineXs.Count - 1]
    }

    for ($index = 0; $index -lt ($script:TimelineAges.Count - 1); $index++) {
        $olderAge = $script:TimelineAges[$index]
        $newerAge = $script:TimelineAges[$index + 1]
        if ($AgeSeconds -le $olderAge -and $AgeSeconds -ge $newerAge) {
            $progress = ($olderAge - $AgeSeconds) / ($olderAge - $newerAge)
            return $script:TimelineXs[$index] + ($progress * ($script:TimelineXs[$index + 1] - $script:TimelineXs[$index]))
        }
    }
    return 330.0
}

function Add-LanZChartHistory {
    param([Parameter(Mandatory)][array]$Models)

    $now = [DateTime]::UtcNow
    $cutoff = $now.AddHours(-5)
    foreach ($model in $Models) {
        $key = [string]$model.ModelId
        if (-not $script:LoadHistory.ContainsKey($key)) {
            $script:LoadHistory[$key] = [System.Collections.Generic.List[object]]::new()
        }

        $history = $script:LoadHistory[$key]
        $history.Add([pscustomobject]@{
            Timestamp = $now
            Percent = [int]$model.Percent
        })
        while ($history.Count -gt 0 -and $history[0].Timestamp -lt $cutoff) {
            $history.RemoveAt(0)
        }

        $samples = @($history | Sort-Object Timestamp)
        $values = @($samples | ForEach-Object { [int]$_.Percent })
        $minimum = [int](($values | Measure-Object -Minimum).Minimum)
        $maximum = [int](($values | Measure-Object -Maximum).Maximum)
        $lower = [math]::Max(0, $minimum - 2)
        $upper = [math]::Min(100, $maximum + 2)

        if (($upper - $lower) -lt 10) {
            $center = ($minimum + $maximum) / 2
            $lower = [math]::Floor($center - 5)
            $upper = [math]::Ceiling($center + 5)
            if ($lower -lt 0) {
                $upper = [math]::Min(100, $upper - $lower)
                $lower = 0
            }
            if ($upper -gt 100) {
                $lower = [math]::Max(0, $lower - ($upper - 100))
                $upper = 100
            }
        }

        $range = [math]::Max(1, $upper - $lower)
        $plotHeight = 25.0
        $geometry = [Windows.Media.PathGeometry]::new()
        $previousTimestamp = $null
        $firstPoint = $null
        $lastPoint = $null
        foreach ($sample in $samples) {
            $ageSeconds = [math]::Max(0, ($now - $sample.Timestamp).TotalSeconds)
            $x = Get-LanZTimelineX -AgeSeconds $ageSeconds
            $y = $plotHeight - (([double]$sample.Percent - $lower) / $range * $plotHeight)
            $point = [Windows.Point]::new($x, $y)
            if ($null -eq $firstPoint) {
                $firstPoint = $point
            }

            if ($null -eq $previousTimestamp -or ($sample.Timestamp - $previousTimestamp).TotalSeconds -gt 30) {
                $figure = [Windows.Media.PathFigure]::new()
                $figure.StartPoint = $point
                $figure.IsClosed = $false
                $figure.IsFilled = $false
                $geometry.Figures.Add($figure)
            }
            else {
                $figure.Segments.Add([Windows.Media.LineSegment]::new($point, $true))
            }
            $previousTimestamp = $sample.Timestamp
            $lastPoint = $point
        }

        $backfillPoints = [Windows.Media.PointCollection]::new()
        if ($null -ne $firstPoint -and $firstPoint.X -gt 0.5) {
            [void]$backfillPoints.Add([Windows.Point]::new(0, $firstPoint.Y))
            [void]$backfillPoints.Add($firstPoint)
        }

        $model | Add-Member -NotePropertyName ChartGeometry -NotePropertyValue $geometry -Force
        $model | Add-Member -NotePropertyName BackfillPoints -NotePropertyValue $backfillPoints -Force
        $model | Add-Member -NotePropertyName ChartUpperLabel -NotePropertyValue ("$upper%") -Force
        $model | Add-Member -NotePropertyName ChartLowerLabel -NotePropertyValue ("$lower%") -Force
        $model | Add-Member -NotePropertyName CurrentX -NotePropertyValue ([math]::Max(0, $lastPoint.X - 3)) -Force
        $model | Add-Member -NotePropertyName CurrentY -NotePropertyValue ([math]::Max(0, $lastPoint.Y - 3)) -Force
        $model | Add-Member -NotePropertyName CurrentMargin -NotePropertyValue ([Windows.Thickness]::new(
            [math]::Max(0, $lastPoint.X - 3),
            [math]::Max(0, $lastPoint.Y - 3),
            0,
            0
        )) -Force
    }

    try {
        Save-LanZHistory
    }
    catch {
        # History persistence is optional; a write failure must not stop live monitoring.
    }
    return $Models
}

Initialize-LanZHistory

function Save-LanZModelOrder {
    $json = ConvertTo-Json -InputObject @($script:ModelOrder) -Compress
    [System.IO.File]::WriteAllText($script:ModelOrderPath, $json, [System.Text.UTF8Encoding]::new($false))
}

function Sort-LanZModels {
    param([Parameter(Mandatory)][array]$Models)

    $orderIndex = @{}
    for ($index = 0; $index -lt $script:ModelOrder.Count; $index++) {
        $orderIndex[$script:ModelOrder[$index]] = $index
    }

    $orderChanged = $false
    foreach ($model in $Models) {
        $modelId = [string]$model.ModelId
        if (-not $orderIndex.ContainsKey($modelId)) {
            $orderIndex[$modelId] = $script:ModelOrder.Count
            $script:ModelOrder.Add($modelId)
            $orderChanged = $true
        }
    }
    if ($orderChanged) {
        Save-LanZModelOrder
    }

    return @($Models | Sort-Object @{ Expression = { $orderIndex[[string]$_.ModelId] } })
}

function Get-LanZModelFromVisual {
    param([object]$Visual)

    $current = $Visual
    while ($null -ne $current) {
        if ($current -is [Windows.FrameworkElement]) {
            $context = $current.DataContext
            if ($null -ne $context -and $null -ne $context.PSObject.Properties['ModelId']) {
                return $context
            }
        }
        try {
            $current = [Windows.Media.VisualTreeHelper]::GetParent($current)
        }
        catch {
            break
        }
    }
    return $null
}

function Export-LanZWindowScreenshot {
    param(
        [Parameter(Mandatory)][Windows.Window]$TargetWindow,
        [Parameter(Mandatory)][string]$Path
    )

    $TargetWindow.UpdateLayout()
    $width = [math]::Max(1, [int][math]::Ceiling($TargetWindow.ActualWidth))
    $height = [math]::Max(1, [int][math]::Ceiling($TargetWindow.ActualHeight))
    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new(
        $width,
        $height,
        96,
        96,
        [Windows.Media.PixelFormats]::Pbgra32
    )
    $bitmap.Render($TargetWindow)
    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $parentDirectory = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not [string]::IsNullOrWhiteSpace($parentDirectory)) {
        [System.IO.Directory]::CreateDirectory($parentDirectory) | Out-Null
    }
    $stream = [System.IO.File]::Create($fullPath)
    try {
        $encoder.Save($stream)
    }
    finally {
        $stream.Dispose()
    }
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="LanZ 负载监控"
        Width="410" Height="420"
        WindowStyle="None" ResizeMode="NoResize"
        AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="True"
        WindowStartupLocation="CenterScreen">
    <Window.Resources>
        <Style x:Key="AutoToggleStyle" TargetType="{x:Type ToggleButton}">
            <Setter Property="Background" Value="#EEF2F5"/>
            <Setter Property="Foreground" Value="#6F7F8B"/>
            <Setter Property="BorderBrush" Value="#DDE4EA"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ToggleButton}">
                        <Border x:Name="ToggleBorder" CornerRadius="12"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="ToggleBorder" Property="Background" Value="#E3F6EF"/>
                                <Setter TargetName="ToggleBorder" Property="BorderBrush" Value="#93D9BF"/>
                                <Setter Property="Foreground" Value="#16825E"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <Border CornerRadius="18" Background="#F9FBFD" BorderBrush="#DDE4EA" BorderThickness="1" Padding="18">
        <Border.Effect>
            <DropShadowEffect BlurRadius="24" ShadowDepth="5" Opacity="0.24" Color="#203040"/>
        </Border.Effect>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="58"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <Grid x:Name="DragArea" Grid.Row="0" Background="Transparent">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="76"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="34"/>
                    <ColumnDefinition Width="36"/>
                    <ColumnDefinition Width="36"/>
                </Grid.ColumnDefinitions>
                <StackPanel VerticalAlignment="Top">
                    <TextBlock Text="LanZ 负载" FontSize="17" FontWeight="SemiBold" Foreground="#263746"/>
                    <TextBlock x:Name="UpdatedText" Text="正在连接…" Margin="0,4,0,0" FontSize="11" Foreground="#8694A0" TextTrimming="CharacterEllipsis"/>
                </StackPanel>
                <ToggleButton x:Name="AutoRefreshToggle" Grid.Column="1" Content="自动刷新" IsChecked="True" Width="70" Height="25" FontSize="11" Style="{StaticResource AutoToggleStyle}" ToolTip="开关自动刷新"/>
                <Button x:Name="LoginButton" Grid.Column="2" Content="重新登录" Visibility="Collapsed" Padding="8,3" Margin="4,0" FontSize="11" Foreground="#5A47E5" Background="#F0EEFF" BorderBrush="#D9D3FF" Cursor="Hand"/>
                <ToggleButton x:Name="PinToggle" Grid.Column="3" Content="📌" IsChecked="True" Width="30" Height="25" FontSize="13" Style="{StaticResource AutoToggleStyle}" ToolTip="已置顶，点击取消"/>
                <Button x:Name="RefreshButton" Grid.Column="4" Content="↻" FontSize="18" Foreground="#536675" Background="Transparent" BorderThickness="0" Cursor="Hand" ToolTip="立即刷新"/>
                <Button x:Name="CloseButton" Grid.Column="5" Content="×" FontSize="20" Foreground="#536675" Background="Transparent" BorderThickness="0" Cursor="Hand" ToolTip="关闭"/>
            </Grid>

            <ItemsControl x:Name="ModelsList" Grid.Row="1" AllowDrop="True">
                <ItemsControl.ItemTemplate>
                    <DataTemplate>
                        <Border Background="{Binding CardBackground}" BorderBrush="{Binding CardBorder}" BorderThickness="1" CornerRadius="10" Padding="12,8" Margin="0,0,0,8" Cursor="SizeNS" ToolTip="拖动可调整模型顺序">
                            <Grid>
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="20"/>
                                    <RowDefinition Height="19"/>
                                    <RowDefinition Height="46"/>
                                </Grid.RowDefinitions>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <StackPanel Orientation="Horizontal">
                                    <Ellipse Width="7" Height="7" Fill="{Binding Color}" Margin="0,2,7,0"/>
                                    <TextBlock Text="{Binding Name}" FontSize="13" FontWeight="SemiBold" Foreground="#314452"/>
                                </StackPanel>
                                <TextBlock Grid.Column="1" Text="{Binding Summary}" FontSize="12" Foreground="#61727E"/>
                                <TextBlock Grid.Row="1" Grid.ColumnSpan="2" Text="{Binding ModelId}" FontSize="11" FontWeight="Normal" Foreground="#87949E" TextTrimming="CharacterEllipsis"/>
                                <Grid Grid.Row="2" Grid.ColumnSpan="2" Height="44" ClipToBounds="True">
                                    <Border Background="#F4F7F9" CornerRadius="5"/>
                                    <Canvas Width="330" Height="42" HorizontalAlignment="Left" VerticalAlignment="Center" ClipToBounds="True">
                                        <Line X1="0" Y1="27" X2="330" Y2="27" Stroke="#D8E1E7" StrokeThickness="1"/>
                                        <Line X1="0" Y1="27" X2="0" Y2="30" Stroke="#B9C7D0" StrokeThickness="1"/>
                                        <Line X1="55" Y1="27" X2="55" Y2="30" Stroke="#B9C7D0" StrokeThickness="1"/>
                                        <Line X1="105" Y1="27" X2="105" Y2="30" Stroke="#B9C7D0" StrokeThickness="1"/>
                                        <Line X1="155" Y1="27" X2="155" Y2="30" Stroke="#B9C7D0" StrokeThickness="1"/>
                                        <Line X1="218" Y1="27" X2="218" Y2="30" Stroke="#B9C7D0" StrokeThickness="1"/>
                                        <Line X1="240" Y1="27" X2="240" Y2="30" Stroke="#B9C7D0" StrokeThickness="1"/>
                                        <Line X1="262" Y1="27" X2="262" Y2="30" Stroke="#B9C7D0" StrokeThickness="1"/>
                                        <Line X1="284" Y1="27" X2="284" Y2="30" Stroke="#B9C7D0" StrokeThickness="1"/>
                                        <Line X1="307" Y1="27" X2="307" Y2="30" Stroke="#B9C7D0" StrokeThickness="1"/>
                                        <Line X1="329" Y1="27" X2="329" Y2="30" Stroke="#B9C7D0" StrokeThickness="1"/>
                                        <TextBlock Text="5h" Canvas.Left="0" Canvas.Top="30" FontSize="8" Foreground="#87959F"/>
                                        <TextBlock Text="1h" Canvas.Left="49" Canvas.Top="30" FontSize="8" Foreground="#87959F"/>
                                        <TextBlock Text="30m" Canvas.Left="94" Canvas.Top="30" FontSize="8" Foreground="#87959F"/>
                                        <TextBlock Text="15m" Canvas.Left="145" Canvas.Top="30" FontSize="8" Foreground="#87959F"/>
                                        <TextBlock Text="50s" Canvas.Left="209" Canvas.Top="30" FontSize="7.5" Foreground="#87959F"/>
                                        <TextBlock Text="40" Canvas.Left="235" Canvas.Top="30" FontSize="7.5" Foreground="#9AA6AE"/>
                                        <TextBlock Text="30" Canvas.Left="257" Canvas.Top="30" FontSize="7.5" Foreground="#9AA6AE"/>
                                        <TextBlock Text="20" Canvas.Left="279" Canvas.Top="30" FontSize="7.5" Foreground="#9AA6AE"/>
                                        <TextBlock Text="10" Canvas.Left="302" Canvas.Top="30" FontSize="7.5" Foreground="#9AA6AE"/>
                                        <TextBlock Text="0" Canvas.Left="324" Canvas.Top="30" FontSize="7.5" Foreground="#87959F"/>
                                        <Polyline Points="{Binding BackfillPoints}" Stroke="{Binding Color}" StrokeThickness="1.6" StrokeDashArray="3,3" Opacity="0.3"/>
                                        <Path Data="{Binding ChartGeometry}" Stroke="{Binding Color}" StrokeThickness="2.2" StrokeLineJoin="Round" Fill="Transparent"/>
                                    </Canvas>
                                    <Ellipse Width="6" Height="6" Fill="{Binding Color}" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="{Binding CurrentMargin}" IsHitTestVisible="False"/>
                                    <TextBlock Text="{Binding ChartUpperLabel}" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,1,4,0" Padding="2,0" FontSize="8" Foreground="#84939E" Background="#CCF4F7F9"/>
                                    <TextBlock Text="{Binding ChartLowerLabel}" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,18,4,0" Padding="2,0" FontSize="8" Foreground="#84939E" Background="#CCF4F7F9"/>
                                </Grid>
                            </Grid>
                        </Border>
                    </DataTemplate>
                </ItemsControl.ItemTemplate>
            </ItemsControl>

        </Grid>
    </Border>
</Window>
'@

$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
$modelsList = $window.FindName('ModelsList')
$updatedText = $window.FindName('UpdatedText')
$pinToggle = $window.FindName('PinToggle')
$refreshButton = $window.FindName('RefreshButton')
$closeButton = $window.FindName('CloseButton')
$dragArea = $window.FindName('DragArea')
$autoRefreshToggle = $window.FindName('AutoRefreshToggle')
$loginButton = $window.FindName('LoginButton')

function Show-LanZLogin {
    if ($script:LoginWindowOpen) {
        return
    }

    $script:LoginWindowOpen = $true
    $script:SuppressAutoLogin = $false
    $timer.Stop()

    try {
        $webViewDirectory = Join-Path $script:AppDirectory 'lib\WebView2'
        $coreAssembly = Join-Path $webViewDirectory 'Microsoft.Web.WebView2.Core.dll'
        $wpfAssembly = Join-Path $webViewDirectory 'Microsoft.Web.WebView2.Wpf.dll'
        if (-not (Test-Path -LiteralPath $coreAssembly) -or -not (Test-Path -LiteralPath $wpfAssembly)) {
            throw '缺少 WebView2 登录组件，请重新解压完整项目。'
        }

        $env:PATH = "$webViewDirectory;$env:PATH"
        if ($null -eq ('Microsoft.Web.WebView2.Core.CoreWebView2Environment' -as [type])) {
            Add-Type -Path $coreAssembly
        }
        if ($null -eq ('Microsoft.Web.WebView2.Wpf.WebView2' -as [type])) {
            Add-Type -Path $wpfAssembly
        }

        [xml]$loginXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="LanZ 重新验证" Width="980" Height="720"
        WindowStartupLocation="CenterOwner" Background="#F7F9FB">
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="48"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Grid Grid.Row="0" Background="#FFFFFF">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Margin="16,7,0,0">
                <TextBlock Text="LanZ 身份验证" FontSize="15" FontWeight="SemiBold" Foreground="#293B49"/>
                <TextBlock x:Name="LoginStatusText" Text="正在加载登录页面…" FontSize="11" Foreground="#7E8D98" Margin="0,2,0,0"/>
            </StackPanel>
            <Button x:Name="LoginCloseButton" Grid.Column="1" Content="关闭" Margin="0,9,14,9" Padding="14,0" Background="#F3F5F7" BorderBrush="#DDE3E8" Foreground="#536675" Cursor="Hand"/>
        </Grid>
        <Border Grid.Row="1" Margin="10" Background="#FFFFFF" BorderBrush="#DDE4EA" BorderThickness="1" CornerRadius="8">
            <Grid x:Name="BrowserHost" ClipToBounds="True"/>
        </Border>
    </Grid>
</Window>
'@

        $loginReader = [System.Xml.XmlNodeReader]::new($loginXaml)
        $loginWindow = [Windows.Markup.XamlReader]::Load($loginReader)
        $loginWindow.Owner = $window
        $browserHost = $loginWindow.FindName('BrowserHost')
        $loginStatusText = $loginWindow.FindName('LoginStatusText')
        $loginCloseButton = $loginWindow.FindName('LoginCloseButton')
        $webView = [Microsoft.Web.WebView2.Wpf.WebView2]::new()
        $creationProperties = [Microsoft.Web.WebView2.Wpf.CoreWebView2CreationProperties]::new()
        $creationProperties.UserDataFolder = Join-Path $env:LOCALAPPDATA 'LanZMonitor\WebView2'
        $webView.CreationProperties = $creationProperties
        [void]$browserHost.Children.Add($webView)

        $loginState = @{
            Stage = 'ensure'
            EnsureTask = $null
            CookieTask = $null
            LastCandidate = ''
            LastCookiePoll = [DateTime]::MinValue
            Success = $false
        }
        $loginTimer = [Windows.Threading.DispatcherTimer]::new()
        $loginTimer.Interval = [TimeSpan]::FromMilliseconds(250)

        $loginWindow.Add_Loaded(({
            $loginState.EnsureTask = $webView.EnsureCoreWebView2Async()
            $loginTimer.Start()
        }).GetNewClosure())

        $loginTimer.Add_Tick(({
            try {
                if ($loginState.Stage -eq 'ensure') {
                    if (-not $loginState.EnsureTask.IsCompleted) {
                        return
                    }
                    if ($loginState.EnsureTask.IsFaulted) {
                        throw $loginState.EnsureTask.Exception.GetBaseException()
                    }
                    $webView.CoreWebView2.Settings.AreDevToolsEnabled = $false
                    $webView.CoreWebView2.Settings.AreDefaultContextMenusEnabled = $false
                    $webView.CoreWebView2.Profile.IsPasswordAutosaveEnabled = $true
                    $webView.CoreWebView2.Profile.IsGeneralAutofillEnabled = $true
                    $webView.Source = [Uri]$script:LoginUrl
                    $loginStatusText.Text = '请完成登录；可选择保存密码，成功后会自动保存会话并关闭。'
                    $loginState.Stage = 'cookies'
                    return
                }

                if ($loginState.Stage -ne 'cookies') {
                    return
                }

                if ($null -ne $loginState.CookieTask -and $loginState.CookieTask.IsCompleted) {
                    if ($loginState.CookieTask.IsFaulted) {
                        throw $loginState.CookieTask.Exception.GetBaseException()
                    }
                    $cookies = $loginState.CookieTask.GetAwaiter().GetResult()
                    $loginState.CookieTask = $null
                    $candidate = $cookies | Where-Object { $_.Name -eq $script:SessionCookieName -and $_.Value -ne '0' } | Select-Object -First 1
                    if ($null -ne $candidate -and $candidate.Value -ne $loginState.LastCandidate) {
                        $loginState.LastCandidate = $candidate.Value
                        $loginStatusText.Text = '检测到新会话，正在验证…'
                        try {
                            [void](Get-LanZModels -SessionValue $candidate.Value)
                            Save-LanZSessionValue -SessionValue $candidate.Value
                            $loginState.Success = $true
                            $loginStatusText.Text = '验证成功。'
                            $loginWindow.Close()
                            return
                        }
                        catch [System.UnauthorizedAccessException] {
                            $loginStatusText.Text = '当前会话尚未生效，请继续完成登录。'
                        }
                    }
                }

                if ($null -eq $loginState.CookieTask -and ([DateTime]::UtcNow - $loginState.LastCookiePoll).TotalSeconds -ge 1) {
                    $loginState.LastCookiePoll = [DateTime]::UtcNow
                    $loginState.CookieTask = $webView.CoreWebView2.CookieManager.GetCookiesAsync($script:LoginUrl)
                }
            }
            catch {
                $loginStatusText.Text = '验证窗口异常：' + $_.Exception.Message
                $loginState.Stage = 'error'
            }
        }).GetNewClosure())

        $loginCloseButton.Add_Click(({
            $loginWindow.Close()
        }).GetNewClosure())

        $loginWindow.Add_Closed(({
            $loginTimer.Stop()
            $webView.Dispose()
            $script:LoginWindowOpen = $false
            if ($loginState.Success) {
                $script:SuppressAutoLogin = $false
                $loginButton.Visibility = [Windows.Visibility]::Collapsed
                $autoRefreshToggle.IsChecked = $true
                Update-Widget
                $timer.Start()
            }
            else {
                $script:SuppressAutoLogin = $true
                $autoRefreshToggle.IsChecked = $false
                $updatedText.Text = '登录未完成，点击“重新登录”继续'
            }
        }).GetNewClosure())

        [void]$loginWindow.ShowDialog()
    }
    catch {
        $script:LoginWindowOpen = $false
        $loginButton.Visibility = [Windows.Visibility]::Visible
        $updatedText.Text = $_.Exception.Message
        $updatedText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#F56C6C')
    }
}

function Update-Widget {
    try {
        $models = Get-LanZModels
        $modelsWithHistory = @(Add-LanZChartHistory -Models $models)
        $script:DisplayedModels = @(Sort-LanZModels -Models $modelsWithHistory)
        $modelsList.ItemsSource = $script:DisplayedModels
        $updatedText.Text = '已更新 ' + (Get-Date).ToString('HH:mm:ss')
        $updatedText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#8694A0')
        $loginButton.Visibility = [Windows.Visibility]::Collapsed
    }
    catch {
        $updatedText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#F56C6C')
        $updatedText.Text = $_.Exception.Message
        if ($_.Exception -is [System.UnauthorizedAccessException]) {
            $timer.Stop()
            $loginButton.Visibility = [Windows.Visibility]::Visible
            if (-not $script:SuppressAutoLogin) {
                Show-LanZLogin
            }
        }
    }
}

$timer = [Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromSeconds($RefreshSeconds)
$timer.Add_Tick({ Update-Widget })
$refreshButton.Add_Click({ Update-Widget })
$autoRefreshToggle.Add_Checked({
    $script:SuppressAutoLogin = $false
    Update-Widget
    if ($autoRefreshToggle.IsChecked -and -not $script:LoginWindowOpen) {
        $timer.Start()
    }
})
$autoRefreshToggle.Add_Unchecked({
    $timer.Stop()
    if (-not $script:LoginWindowOpen) {
        $updatedText.Text = '自动刷新已暂停'
        $updatedText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#8694A0')
    }
})
$loginButton.Add_Click({
    $script:SuppressAutoLogin = $false
    Show-LanZLogin
})
$pinToggle.Add_Checked({
    $window.Topmost = $true
    $pinToggle.ToolTip = '已置顶，点击取消'
})
$pinToggle.Add_Unchecked({
    $window.Topmost = $false
    $pinToggle.ToolTip = '未置顶，点击置顶'
})
$modelsList.Add_PreviewMouseLeftButtonDown({
    $model = Get-LanZModelFromVisual -Visual $_.OriginalSource
    if ($null -eq $model) {
        $script:DragStartPoint = $null
        $script:DragModelId = $null
        return
    }
    $script:DragStartPoint = $_.GetPosition($modelsList)
    $script:DragModelId = [string]$model.ModelId
})
$modelsList.Add_PreviewMouseMove({
    if ($_.LeftButton -ne [Windows.Input.MouseButtonState]::Pressed -or $null -eq $script:DragStartPoint -or [string]::IsNullOrWhiteSpace($script:DragModelId)) {
        return
    }

    $position = $_.GetPosition($modelsList)
    $distanceX = [math]::Abs($position.X - $script:DragStartPoint.X)
    $distanceY = [math]::Abs($position.Y - $script:DragStartPoint.Y)
    if ($distanceX -lt [Windows.SystemParameters]::MinimumHorizontalDragDistance -and $distanceY -lt [Windows.SystemParameters]::MinimumVerticalDragDistance) {
        return
    }

    $data = [Windows.DataObject]::new()
    $data.SetData('LanZModelId', $script:DragModelId)
    [void][Windows.DragDrop]::DoDragDrop($modelsList, $data, [Windows.DragDropEffects]::Move)
    $script:DragStartPoint = $null
    $script:DragModelId = $null
})
$modelsList.Add_DragOver({
    if ($_.Data.GetDataPresent('LanZModelId')) {
        $_.Effects = [Windows.DragDropEffects]::Move
        $_.Handled = $true
    }
})
$modelsList.Add_Drop({
    if (-not $_.Data.GetDataPresent('LanZModelId')) {
        return
    }

    $sourceId = [string]$_.Data.GetData('LanZModelId')
    $targetModel = Get-LanZModelFromVisual -Visual $_.OriginalSource
    $visibleOrder = [System.Collections.Generic.List[string]]::new()
    foreach ($model in $script:DisplayedModels) {
        $visibleOrder.Add([string]$model.ModelId)
    }

    $oldIndex = $visibleOrder.IndexOf($sourceId)
    $newIndex = if ($null -eq $targetModel) { $visibleOrder.Count - 1 } else { $visibleOrder.IndexOf([string]$targetModel.ModelId) }
    if ($oldIndex -lt 0 -or $newIndex -lt 0 -or $oldIndex -eq $newIndex) {
        return
    }

    $visibleOrder.RemoveAt($oldIndex)
    $newIndex = [math]::Min($newIndex, $visibleOrder.Count)
    $visibleOrder.Insert($newIndex, $sourceId)

    $script:ModelOrder.Clear()
    foreach ($modelId in $visibleOrder) {
        $script:ModelOrder.Add($modelId)
    }
    Save-LanZModelOrder

    $modelById = @{}
    foreach ($model in $script:DisplayedModels) {
        $modelById[[string]$model.ModelId] = $model
    }
    $script:DisplayedModels = @($visibleOrder | ForEach-Object { $modelById[$_] })
    $modelsList.ItemsSource = $null
    $modelsList.ItemsSource = $script:DisplayedModels
    $_.Handled = $true
})
$closeButton.Add_Click({ $window.Close() })
$window.Add_PreviewMouseLeftButtonDown({
    if ($_.ChangedButton -ne [Windows.Input.MouseButton]::Left) {
        return
    }

    $position = $_.GetPosition($window)
    if ($position.Y -gt 78) {
        return
    }

    $source = $_.OriginalSource
    $isInteractive = $false
    while ($null -ne $source) {
        if ($source -is [Windows.Controls.Primitives.ButtonBase]) {
            $isInteractive = $true
            break
        }
        try {
            $source = [Windows.Media.VisualTreeHelper]::GetParent($source)
        }
        catch {
            break
        }
    }

    if (-not $isInteractive) {
        $_.Handled = $true
        $window.DragMove()
    }
})
$window.Add_Loaded({
    Update-Widget
    if (-not [string]::IsNullOrWhiteSpace($ScreenshotPath)) {
        $screenshotTimer = [Windows.Threading.DispatcherTimer]::new()
        $screenshotTimer.Interval = [TimeSpan]::FromMilliseconds(500)
        $screenshotTimer.Add_Tick({
            $screenshotTimer.Stop()
            Export-LanZWindowScreenshot -TargetWindow $window -Path $ScreenshotPath
            $window.Close()
        }.GetNewClosure())
        $screenshotTimer.Start()
        return
    }
    if ($autoRefreshToggle.IsChecked -and -not $script:LoginWindowOpen) {
        $timer.Start()
    }
})
$window.Add_Closed({ $timer.Stop() })

[void]$window.ShowDialog()
}
finally {
    $singleInstanceMutex.ReleaseMutex()
    $singleInstanceMutex.Dispose()
}
