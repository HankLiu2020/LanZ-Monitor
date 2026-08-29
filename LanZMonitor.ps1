param(
    [switch]$Once,
    [string]$ScreenshotPath,
    [string]$SettingsScreenshotPath,
    [ValidateRange(2, 60)]
    [int]$RefreshSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRootValue = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $PSScriptRoot
}
else {
    Get-Variable -Name ScriptRoot -ValueOnly -ErrorAction SilentlyContinue
}
$script:AppDirectory = if (-not [string]::IsNullOrWhiteSpace([string]$scriptRootValue)) {
    [string]$scriptRootValue
}
else {
    Split-Path -Parent ([Environment]::GetCommandLineArgs()[0])
}
$script:StateRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'LanZ-Monitor'
$script:SecretsDirectory = Join-Path $script:StateRoot 'secrets'
$script:DataDirectory = Join-Path $script:StateRoot 'data'
$script:SettingsDirectory = Join-Path $script:StateRoot 'settings'
$script:RuntimeDirectory = Join-Path $script:StateRoot 'runtime'
foreach ($directory in @($script:SecretsDirectory, $script:DataDirectory, $script:SettingsDirectory, $script:RuntimeDirectory)) {
    [void][IO.Directory]::CreateDirectory($directory)
}
$script:SessionPath = Join-Path $script:SecretsDirectory 'session.bin'
$script:ConfigPath = Join-Path $script:SecretsDirectory 'connection.bin'
$script:LoginWindowOpen = $false
$script:SuppressAutoLogin = $false
$script:LoadHistory = @{}
$script:HistoryPath = Join-Path $script:DataDirectory 'chart-history.json'
$script:LatestStatusPath = Join-Path $script:DataDirectory 'latest-status.json'
$script:StatusLogPath = Join-Path $script:DataDirectory 'load-history.jsonl'
$script:UiPreferencesPath = Join-Path $script:SettingsDirectory 'ui.json'
$script:BillingRulesPath = Join-Path $script:SettingsDirectory 'billing-rules.json'
$script:BillingRules = $null
$script:CachedStatusSnapshot = $null
$script:StatusLogWriteCount = 0
$script:LastArchivedStatusTime = [DateTime]::MinValue
$script:StatusRetentionDays = 30
$script:UiPreferences = [ordered]@{ AutoRefresh = $true; ShowExternalQuota = $false; ShowInternalQuota = $true; ChartMode = 'bar' }
$script:ChartWidth = 330.0
$script:ChartPixelBucketWidth = 4.0
$script:TimelineAges = @(18000.0, 3600.0, 1800.0, 900.0, 600.0, 300.0, 180.0, 120.0, 60.0, 50.0, 40.0, 30.0, 20.0, 10.0, 0.0)
$script:TimelineXs = @(0.0, 24.0, 52.0, 110.0, 130.0, 150.0, 170.0, 190.0, 210.0, 228.0, 250.0, 270.0, 290.0, 310.0, 330.0)
$script:ModelOrderPath = Join-Path $script:SettingsDirectory 'model-order.json'
$script:ModelOrder = [System.Collections.Generic.List[string]]::new()
$script:DisplayedModels = @()
$script:DragStartPoint = $null
$script:DragModelId = $null
$script:RefreshInProgress = $false
$script:RefreshWorker = $null

$legacyStateFiles = [ordered]@{
    '.lanz-session.bin' = $script:SessionPath
    '.lanz-config.bin' = $script:ConfigPath
    '.lanz-history.json' = $script:HistoryPath
    '.lanz-status.jsonl' = $script:StatusLogPath
    '.lanz-ui.json' = $script:UiPreferencesPath
    '.lanz-billing-rules.json' = $script:BillingRulesPath
    '.lanz-model-order.json' = $script:ModelOrderPath
}
foreach ($legacyName in $legacyStateFiles.Keys) {
    $legacyPath = Join-Path $script:AppDirectory $legacyName
    $newPath = [string]$legacyStateFiles[$legacyName]
    if ((Test-Path -LiteralPath $legacyPath) -and -not (Test-Path -LiteralPath $newPath)) {
        try {
            [IO.File]::Move($legacyPath, $newPath)
        }
        catch {
            # A read-only install directory must not prevent the application from using new storage.
            [IO.File]::Copy($legacyPath, $newPath, $false)
        }
    }
}

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

try {
    if (Test-Path -LiteralPath $script:UiPreferencesPath) {
        $savedUiPreferences = Get-Content -LiteralPath $script:UiPreferencesPath -Raw | ConvertFrom-Json
        foreach ($propertyName in @('AutoRefresh', 'ShowExternalQuota', 'ShowInternalQuota')) {
            if ($null -ne $savedUiPreferences.PSObject.Properties[$propertyName]) {
                $script:UiPreferences[$propertyName] = [bool]$savedUiPreferences.$propertyName
            }
        }
        if ($null -ne $savedUiPreferences.PSObject.Properties['ChartMode'] -and [string]$savedUiPreferences.ChartMode -in @('bar', 'line')) {
            $script:UiPreferences.ChartMode = [string]$savedUiPreferences.ChartMode
        }
    }
}
catch {
    $script:UiPreferences = [ordered]@{ AutoRefresh = $true; ShowExternalQuota = $false; ShowInternalQuota = $true; ChartMode = 'bar' }
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

    foreach ($propertyName in @('ApiEndpoint', 'UsageEndpoint', 'UsageDashboardUrl', 'LoginUrl', 'SessionCookieName', 'RequestTokenHeader', 'RequestTokenPrefix', 'RequestTokenKey', 'RequestTokenIV', 'SuccessCode', 'UnauthorizedCode')) {
        if ($null -eq $configuration.PSObject.Properties[$propertyName]) {
            throw "连接配置缺少 $propertyName，请重新运行 setup-session.cmd。"
        }
    }

    $apiUri = $null
    $loginUri = $null
    if (-not [Uri]::TryCreate([string]$configuration.ApiEndpoint, [UriKind]::Absolute, [ref]$apiUri) -or $apiUri.Scheme -ne 'https') {
        throw 'API 地址必须是有效的 HTTPS URL。'
    }
    $usageUri = $null
    if (-not [Uri]::TryCreate([string]$configuration.UsageEndpoint, [UriKind]::Absolute, [ref]$usageUri) -or $usageUri.Scheme -ne 'https') {
        throw '用量 API 地址必须是有效的 HTTPS URL。'
    }
    $usageDashboardUri = $null
    if (-not [Uri]::TryCreate([string]$configuration.UsageDashboardUrl, [UriKind]::Absolute, [ref]$usageDashboardUri) -or $usageDashboardUri.Scheme -ne 'https') {
        throw '资源看板地址必须是有效的 HTTPS URL。'
    }
    if (-not [Uri]::TryCreate([string]$configuration.LoginUrl, [UriKind]::Absolute, [ref]$loginUri) -or $loginUri.Scheme -ne 'https') {
        throw '登录地址必须是有效的 HTTPS URL。'
    }

    return $configuration
}

$script:Configuration = Get-LanZConfiguration
$script:Endpoint = [string]$script:Configuration.ApiEndpoint
$script:UsageEndpoint = [string]$script:Configuration.UsageEndpoint
$script:UsageDashboardUrl = [string]$script:Configuration.UsageDashboardUrl
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
    $handler.UseCookies = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(8)
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

function Get-LanZUsageOverview {
    param([string]$SessionValue)

    if ([string]::IsNullOrWhiteSpace($SessionValue)) {
        $SessionValue = Get-LanZSessionValue
    }
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.CheckCertificateRevocationList = $false
    $handler.UseCookies = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(8)
    $request = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::Get,
        $script:UsageEndpoint
    )

    try {
        [void]$request.Headers.TryAddWithoutValidation('Cookie', "$($script:SessionCookieName)=$SessionValue")
        [void]$request.Headers.TryAddWithoutValidation([string]$script:Configuration.RequestTokenHeader, (New-LanZRequestToken))
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw "用量服务返回 HTTP $([int]$response.StatusCode)"
        }

        $payload = $content | ConvertFrom-Json
        if ([int]$payload.code -ne [int]$script:Configuration.SuccessCode) {
            if ([int]$payload.code -eq [int]$script:Configuration.UnauthorizedCode) {
                throw [System.UnauthorizedAccessException]::new('会话已过期，需要重新验证。')
            }
            throw "用量接口错误：$($payload.msg)"
        }
        return $payload.data.overview
    }
    finally {
        $request.Dispose()
        $client.Dispose()
        $handler.Dispose()
    }
}

function Get-LanZAuthenticatedText {
    param(
        [Parameter(Mandatory)][Uri]$Uri,
        [Parameter(Mandatory)][string]$SessionValue
    )

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.CheckCertificateRevocationList = $false
    $handler.UseCookies = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(8)
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Uri)
    try {
        [void]$request.Headers.TryAddWithoutValidation('Cookie', "$($script:SessionCookieName)=$SessionValue")
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if ([int]$response.StatusCode -in @(401, 403)) {
            throw [System.UnauthorizedAccessException]::new('会话已过期，需要重新验证。')
        }
        if (-not $response.IsSuccessStatusCode) {
            throw "规则页面返回 HTTP $([int]$response.StatusCode)"
        }
        return $content
    }
    finally {
        $request.Dispose()
        $client.Dispose()
        $handler.Dispose()
    }
}

function Import-LanZBillingRulesCache {
    if ($null -ne $script:BillingRules) {
        return $script:BillingRules
    }
    try {
        if (Test-Path -LiteralPath $script:BillingRulesPath) {
            $cached = Get-Content -LiteralPath $script:BillingRulesPath -Raw | ConvertFrom-Json
            if (@($cached.Intervals).Count -gt 0) {
                $script:BillingRules = $cached
            }
        }
    }
    catch {
        $script:BillingRules = $null
    }
    return $script:BillingRules
}

function Get-LanZBillingRules {
    param([Parameter(Mandatory)][string]$SessionValue)

    $cached = Import-LanZBillingRulesCache
    if ($null -ne $cached) {
        try {
            $fetchedAt = [DateTime]::Parse(
                [string]$cached.FetchedAt,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind
            ).ToUniversalTime()
            if (([DateTime]::UtcNow - $fetchedAt).TotalMinutes -lt 30) {
                return $cached
            }
        }
        catch {
            # An old cache is still a safe fallback if refreshing the source fails.
        }
    }

    try {
        $dashboardUri = [Uri]$script:UsageDashboardUrl
        $dashboardHtml = Get-LanZAuthenticatedText -Uri $dashboardUri -SessionValue $SessionValue
        $scriptMatches = [regex]::Matches(
            $dashboardHtml,
            '<script\b[^>]*\bsrc\s*=\s*(?:"(?<src>[^"]+)"|''(?<src>[^'']+)''|(?<src>[^\s>]+))',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        $scriptUris = @($scriptMatches | ForEach-Object {
            [Uri]::new($dashboardUri, $_.Groups['src'].Value)
        })
        $runtimeUri = $scriptUris | Where-Object { [IO.Path]::GetFileName($_.AbsolutePath) -match '^runtime\.' } | Select-Object -First 1
        $appUri = $scriptUris | Where-Object { [IO.Path]::GetFileName($_.AbsolutePath) -match '^app\.' } | Select-Object -First 1
        if ($null -eq $runtimeUri -or $null -eq $appUri) {
            throw '资源看板的前端入口未找到。'
        }

        $runtimeText = Get-LanZAuthenticatedText -Uri $runtimeUri -SessionValue $SessionValue
        $appText = Get-LanZAuthenticatedText -Uri $appUri -SessionValue $SessionValue
        $routePath = $dashboardUri.AbsolutePath
        $chunkIds = [System.Collections.Generic.HashSet[string]]::new()
        $preferredChunkIds = [System.Collections.Generic.List[string]]::new()
        foreach ($routeMatch in [regex]::Matches($appText, [regex]::Escape($routePath))) {
            $start = [math]::Max(0, $routeMatch.Index - 8000)
            $length = [math]::Min(16000, $appText.Length - $start)
            $context = $appText.Substring($start, $length)
            foreach ($chunkMatch in [regex]::Matches($context, '\.e\((?<id>\d+)\)')) {
                [void]$chunkIds.Add($chunkMatch.Groups['id'].Value)
            }
        }
        $routeSegment = $routePath.TrimEnd('/').Split('/')[-1]
        if (-not [string]::IsNullOrWhiteSpace($routeSegment)) {
            $routeEntryPattern = 'path\s*:\s*["'']{0}["'']' -f [regex]::Escape($routeSegment)
            foreach ($routeEntryMatch in [regex]::Matches($appText, $routeEntryPattern)) {
                $start = [math]::Max(0, $routeEntryMatch.Index - 500)
                $length = [math]::Min(2500, $appText.Length - $start)
                $context = $appText.Substring($start, $length)
                foreach ($chunkMatch in [regex]::Matches($context, '\.e\((?<id>\d+)\)')) {
                    $candidateId = $chunkMatch.Groups['id'].Value
                    if (-not $preferredChunkIds.Contains($candidateId)) {
                        $preferredChunkIds.Add($candidateId)
                    }
                    [void]$chunkIds.Add($candidateId)
                }
            }
        }
        if ($chunkIds.Count -eq 0) {
            throw '无法定位资源看板的动态脚本。'
        }

        $ruleText = $null
        $timeRangePattern = '(?<start>\d{1,2}:\d{2})\s*(?:-|~|–|—|至)\s*(?<next>次日)?\s*(?<end>\d{1,2}:\d{2})'
        $candidateChunkIds = @($preferredChunkIds) + @($chunkIds) | Select-Object -Unique
        foreach ($chunkId in $candidateChunkIds) {
            $hashPattern = '(?<!\d){0}:"(?<hash>[a-f0-9]+)"' -f [regex]::Escape($chunkId)
            $hashMatch = [regex]::Match($runtimeText, $hashPattern)
            if (-not $hashMatch.Success) {
                continue
            }
            $chunkUri = [Uri]::new($runtimeUri, "$chunkId.$($hashMatch.Groups['hash'].Value).js")
            $chunkText = Get-LanZAuthenticatedText -Uri $chunkUri -SessionValue $SessionValue
            $descriptionMatch = [regex]::Match(
                $chunkText,
                'billingFreeDesc\s*:\s*function\(\)\s*\{\s*return\s*"(?<text>(?:\\.|[^"\\])*)"'
            )
            $encodedCandidates = [System.Collections.Generic.List[string]]::new()
            if ($descriptionMatch.Success) {
                $encodedCandidates.Add($descriptionMatch.Groups['text'].Value)
            }
            foreach ($stringMatch in [regex]::Matches($chunkText, '"(?<text>(?:\\.|[^"\\])*)"')) {
                $candidateText = $stringMatch.Groups['text'].Value
                if ($candidateText.Length -ge 20 -and $candidateText.Length -le 1200 -and $candidateText -match '\d{1,2}:\d{2}') {
                    $encodedCandidates.Add($candidateText)
                }
            }
            foreach ($encoded in $encodedCandidates) {
                try {
                    $decodedCandidate = ('"' + $encoded + '"') | ConvertFrom-Json
                }
                catch {
                    $decodedCandidate = $encoded -replace '\\n', ' ' -replace '\\"', '"' -replace '\\\\', '\'
                }
                $plainCandidate = [Net.WebUtility]::HtmlDecode(([regex]::Replace($decodedCandidate, '<[^>]+>', ' ')))
                if ([regex]::Matches($plainCandidate, $timeRangePattern).Count -ge 2 -and $plainCandidate -match '积分|免费|扣减') {
                    $ruleText = $decodedCandidate
                    break
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($ruleText)) {
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace($ruleText)) {
            throw '资源看板未提供可解析的积分时段说明。'
        }

        $plainRuleText = [Net.WebUtility]::HtmlDecode(([regex]::Replace($ruleText, '<[^>]+>', ' ')))
        $plainRuleText = [regex]::Replace($plainRuleText, '\s+', ' ').Trim()
        $intervals = @([regex]::Matches(
            $plainRuleText,
            $timeRangePattern
        ) | ForEach-Object {
            $startParts = $_.Groups['start'].Value.Split(':')
            $endParts = $_.Groups['end'].Value.Split(':')
            $startMinutes = ([int]$startParts[0] * 60) + [int]$startParts[1]
            $endMinutes = ([int]$endParts[0] * 60) + [int]$endParts[1]
            [pscustomobject]@{
                StartMinutes = $startMinutes
                EndMinutes = $endMinutes
                Overnight = $_.Groups['next'].Success -or $endMinutes -le $startMinutes
            }
        })
        if ($intervals.Count -eq 0) {
            throw '积分时段说明中没有可用的时间区间。'
        }

        $rules = [pscustomobject]@{
            FetchedAt = [DateTime]::UtcNow.ToString('o')
            ScheduleText = $plainRuleText
            WeekendFree = [bool]($plainRuleText -match '周(?:六周日|末).*?全天')
            Intervals = $intervals
        }
        [IO.File]::WriteAllText(
            $script:BillingRulesPath,
            ($rules | ConvertTo-Json -Depth 5 -Compress),
            [Text.UTF8Encoding]::new($false)
        )
        $script:BillingRules = $rules
        return $rules
    }
    catch [System.UnauthorizedAccessException] {
        throw
    }
    catch {
        if ($null -ne $cached) {
            return $cached
        }
        return $null
    }
}

function Get-LanZBillingWindowStatus {
    param([object]$Rules)

    if ($null -eq $Rules -or @($Rules.Intervals).Count -eq 0) {
        return [pscustomobject]@{ IsFree = $null; Status = '计费状态未知'; Detail = '规则同步中' }
    }

    function Test-LanZFreeTime {
        param([Parameter(Mandatory)][DateTime]$LocalTime)

        if ([bool]$Rules.WeekendFree -and $LocalTime.DayOfWeek -in @([DayOfWeek]::Saturday, [DayOfWeek]::Sunday)) {
            return $true
        }
        $minutes = ($LocalTime.Hour * 60) + $LocalTime.Minute
        foreach ($interval in @($Rules.Intervals)) {
            $start = [int]$interval.StartMinutes
            $end = [int]$interval.EndMinutes
            if ([bool]$interval.Overnight) {
                if ($minutes -ge $start -or $minutes -lt $end) {
                    return $true
                }
            }
            elseif ($minutes -ge $start -and $minutes -lt $end) {
                return $true
            }
        }
        return $false
    }

    $timeZone = [TimeZoneInfo]::FindSystemTimeZoneById('China Standard Time')
    $now = [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $timeZone)
    $isFree = Test-LanZFreeTime -LocalTime $now
    $switchTime = $null
    $cursor = [DateTime]::new($now.Year, $now.Month, $now.Day, $now.Hour, $now.Minute, 0).AddMinutes(1)
    for ($offset = 0; $offset -lt (8 * 24 * 60); $offset++) {
        if ((Test-LanZFreeTime -LocalTime $cursor) -ne $isFree) {
            $switchTime = $cursor
            break
        }
        $cursor = $cursor.AddMinutes(1)
    }

    $detail = '规则已同步'
    if ($null -ne $switchTime) {
        $dayPrefix = if ($switchTime.Date -eq $now.Date) {
            ''
        }
        elseif ($switchTime.Date -eq $now.Date.AddDays(1)) {
            '明天 '
        }
        else {
            @('周日 ', '周一 ', '周二 ', '周三 ', '周四 ', '周五 ', '周六 ')[[int]$switchTime.DayOfWeek]
        }
        $detail = $dayPrefix + $switchTime.ToString('HH:mm') + $(if ($isFree) { ' 后计费' } else { ' 起免费' })
    }
    return [pscustomobject]@{
        IsFree = $isFree
        Status = if ($isFree) { '当前是积分免费时段' } else { '当前是积分计费时段' }
        Detail = $detail
    }
}

function New-LanZQuotaViewModel {
    param(
        [Parameter(Mandatory)][object]$Overview,
        [object]$BillingRules
    )

    function Get-QuotaDisplay {
        param([int]$Used, [int]$Limit)

        $unlimited = $Limit -eq -1
        $percent = if ($unlimited -or $Limit -le 0) { 0 } else { [math]::Min(100, [math]::Round($Used * 100 / $Limit)) }
        $remaining = if ($unlimited) { '不限额' } elseif ($Used -gt $Limit) { '超 ' + ($Used - $Limit) } else { '余 ' + ($Limit - $Used) }
        return [pscustomobject]@{
            Usage = if ($unlimited) { "$Used / 不限额" } else { "$Used / $Limit" }
            Percent = "$percent%"
            ProgressWidth = [double](3.32 * $percent)
            Remaining = $remaining
            Color = if (-not $unlimited -and $percent -ge 80) { '#F56C6C' } else { '#45C391' }
            Warning = if (-not $unlimited -and $percent -ge 80) { '⚠ 已达 80%' } else { '' }
        }
    }

    $external = Get-QuotaDisplay -Used ([int]$Overview.externalDailyUsed) -Limit ([int]$Overview.externalDailyLimit)
    $internal = Get-QuotaDisplay -Used ([int]$Overview.internalDailyUsed) -Limit ([int]$Overview.internalDailyLimit)
    $billing = Get-LanZBillingWindowStatus -Rules $BillingRules
    return [pscustomobject]@{
        RequestCount = ([int]$Overview.dailyRequestCount).ToString('N0')
        ExternalUsage = $external.Usage
        ExternalPercent = $external.Percent
        ExternalProgressWidth = $external.ProgressWidth
        ExternalRemaining = $external.Remaining
        ExternalColor = $external.Color
        ExternalWarning = $external.Warning
        InternalUsage = $internal.Usage
        InternalPercent = $internal.Percent
        InternalProgressWidth = $internal.ProgressWidth
        InternalRemaining = $internal.Remaining
        InternalColor = $internal.Color
        InternalWarning = $internal.Warning
        BillingStatus = $billing.Status
        BillingDetail = $billing.Detail
        BillingBackground = if ($null -eq $billing.IsFree) { '#EEF2F5' } elseif ($billing.IsFree) { '#E6F7F0' } else { '#FFF2D8' }
        BillingForeground = if ($null -eq $billing.IsFree) { '#6F7F8B' } elseif ($billing.IsFree) { '#178A63' } else { '#A86812' }
        BillingSource = if ($null -eq $BillingRules) { '计费规则尚未同步' } else { '计费规则已从资源看板同步' }
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
                $endTimestamp = $timestamp
                if ($null -ne $sample.PSObject.Properties['EndTimestamp'] -and -not [string]::IsNullOrWhiteSpace([string]$sample.EndTimestamp)) {
                    $endTimestamp = if ($sample.EndTimestamp -is [DateTime]) {
                        $sample.EndTimestamp.ToUniversalTime()
                    }
                    else {
                        [DateTime]::Parse(
                            [string]$sample.EndTimestamp,
                            [Globalization.CultureInfo]::InvariantCulture,
                            [Globalization.DateTimeStyles]::RoundtripKind
                        ).ToUniversalTime()
                    }
                    if ($endTimestamp -lt $timestamp) {
                        $endTimestamp = $timestamp
                    }
                }
                if ($endTimestamp -ge $cutoff) {
                    $history.Add([pscustomobject]@{
                        Timestamp = $timestamp
                        EndTimestamp = $endTimestamp
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

function Initialize-LanZStatusSnapshot {
    try {
        if (Test-Path -LiteralPath $script:LatestStatusPath) {
            $script:CachedStatusSnapshot = Get-Content -LiteralPath $script:LatestStatusPath -Raw | ConvertFrom-Json
        }
        $lastLine = if (Test-Path -LiteralPath $script:StatusLogPath) {
            [IO.File]::ReadLines($script:StatusLogPath) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Last 1
        }
        else {
            $null
        }
        if (-not [string]::IsNullOrWhiteSpace($lastLine)) {
            $lastArchived = $lastLine | ConvertFrom-Json
            $script:LastArchivedStatusTime = [DateTime]::Parse(
                [string]$lastArchived.Timestamp,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind
            ).ToUniversalTime()
            if ($null -eq $script:CachedStatusSnapshot) {
                $script:CachedStatusSnapshot = $lastArchived
            }
        }
    }
    catch {
        $script:CachedStatusSnapshot = $null
    }
}

function Save-LanZStatusSnapshot {
    param(
        [Parameter(Mandatory)][array]$Models,
        [Parameter(Mandatory)][object]$Overview
    )

    $snapshot = [ordered]@{
        Timestamp = [DateTime]::UtcNow.ToString('o')
        Models = @($Models | ForEach-Object {
            [ordered]@{
                Name = [string]$_.Name
                ModelId = [string]$_.ModelId
                Active = [int]$_.Active
                Capacity = [int]$_.Capacity
                Percent = [int]$_.Percent
                Available = [bool]$_.Available
                Summary = [string]$_.Summary
                Color = [string]$_.Color
                CardBackground = [string]$_.CardBackground
                CardBorder = [string]$_.CardBorder
            }
        })
        Usage = [ordered]@{
            dailyRequestCount = [int]$Overview.dailyRequestCount
            externalDailyUsed = [int]$Overview.externalDailyUsed
            externalDailyLimit = [int]$Overview.externalDailyLimit
            internalDailyUsed = [int]$Overview.internalDailyUsed
            internalDailyLimit = [int]$Overview.internalDailyLimit
        }
    }
    $snapshotJson = $snapshot | ConvertTo-Json -Depth 6 -Compress
    [IO.File]::WriteAllText($script:LatestStatusPath, $snapshotJson, [Text.UTF8Encoding]::new($false))
    $script:CachedStatusSnapshot = $snapshotJson | ConvertFrom-Json

    $snapshotTime = [DateTime]::Parse(
        [string]$snapshot.Timestamp,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    ).ToUniversalTime()
    if (($snapshotTime - $script:LastArchivedStatusTime).TotalSeconds -lt 60) {
        return
    }

    [IO.File]::AppendAllText(
        $script:StatusLogPath,
        $snapshotJson + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
    $script:LastArchivedStatusTime = $snapshotTime
    $script:StatusLogWriteCount++

    $logSize = (Get-Item -LiteralPath $script:StatusLogPath).Length
    if ($script:StatusLogWriteCount % 60 -ne 0 -and $logSize -lt 32MB) {
        return
    }

    try {
        $cutoff = [DateTime]::UtcNow.AddDays(-$script:StatusRetentionDays)
        $retained = [System.Collections.Generic.List[string]]::new()
        foreach ($existingLine in [IO.File]::ReadLines($script:StatusLogPath)) {
            if ([string]::IsNullOrWhiteSpace($existingLine)) {
                continue
            }
            try {
                $existing = $existingLine | ConvertFrom-Json
                $timestamp = [DateTime]::Parse(
                    [string]$existing.Timestamp,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind
                ).ToUniversalTime()
                if ($timestamp -ge $cutoff) {
                    $retained.Add($existingLine)
                }
            }
            catch {
                # Ignore a partial/corrupt log line; later valid samples remain usable.
            }
        }
        if ($retained.Count -gt 50000) {
            $lastLines = @($retained | Select-Object -Last 50000)
            $retained.Clear()
            foreach ($lastLine in $lastLines) {
                $retained.Add($lastLine)
            }
        }
        $content = if ($retained.Count -gt 0) { ($retained -join [Environment]::NewLine) + [Environment]::NewLine } else { '' }
        [IO.File]::WriteAllText($script:StatusLogPath, $content, [Text.UTF8Encoding]::new($false))
    }
    catch {
        # Snapshot logging is best effort and must never interrupt live monitoring.
    }
}

function Save-LanZHistory {
    $payload = [ordered]@{}
    $now = [DateTime]::UtcNow
    foreach ($key in @($script:LoadHistory.Keys)) {
        $storedSamples = @(Get-LanZChartDisplaySamples -Samples @($script:LoadHistory[$key]) -Now $now)
        $payload[$key] = @($storedSamples | ForEach-Object {
            [ordered]@{
                Timestamp = $_.Timestamp.ToUniversalTime().ToString('o')
                EndTimestamp = if ($null -ne $_.PSObject.Properties['EndTimestamp'] -and $_.EndTimestamp -is [DateTime]) {
                    $_.EndTimestamp.ToUniversalTime().ToString('o')
                }
                else {
                    $_.Timestamp.ToUniversalTime().ToString('o')
                }
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
    return $script:ChartWidth
}

function Get-LanZChartDisplaySamples {
    param(
        [Parameter(Mandatory)][array]$Samples,
        [Parameter(Mandatory)][DateTime]$Now
    )

    # The chart is 330 px wide. Keep at most one representative segment per
    # four pixels, similar to the pixel-aware decimation used by common JS
    # chart libraries. The first timestamp positions the segment; EndTimestamp
    # preserves the covered raw interval so a compacted bucket is not mistaken
    # for a data gap after a restart.
    $pixelBucketWidth = $script:ChartPixelBucketWidth
    $maxBucketIndex = [int][math]::Ceiling($script:ChartWidth / $pixelBucketWidth) - 1
    $buckets = @{}
    foreach ($sample in @($Samples | Sort-Object Timestamp)) {
        $timestamp = ([DateTime]$sample.Timestamp).ToUniversalTime()
        $ageSeconds = [math]::Max(0, ($Now - $timestamp).TotalSeconds)
        $x = [double](Get-LanZTimelineX -AgeSeconds $ageSeconds)
        $bucketIndex = [int][math]::Floor($x / $pixelBucketWidth)
        if ($bucketIndex -lt 0) {
            $bucketIndex = 0
        }
        elseif ($bucketIndex -gt $maxBucketIndex) {
            $bucketIndex = $maxBucketIndex
        }
        $endTimestamp = if ($null -ne $sample.PSObject.Properties['EndTimestamp'] -and $sample.EndTimestamp -is [DateTime]) {
            $sample.EndTimestamp.ToUniversalTime()
        }
        elseif ($null -ne $sample.PSObject.Properties['EndTimestamp'] -and -not [string]::IsNullOrWhiteSpace([string]$sample.EndTimestamp)) {
            [DateTime]::Parse(
                [string]$sample.EndTimestamp,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind
            ).ToUniversalTime()
        }
        else {
            $timestamp
        }
        if ($endTimestamp -lt $timestamp) {
            $endTimestamp = $timestamp
        }

        if (-not $buckets.ContainsKey($bucketIndex)) {
            $buckets[$bucketIndex] = [pscustomobject]@{
                Timestamp = $timestamp
                EndTimestamp = $endTimestamp
                Percent = [int]$sample.Percent
            }
        }
        else {
            $bucket = $buckets[$bucketIndex]
            if ($endTimestamp -gt $bucket.EndTimestamp) {
                $bucket.EndTimestamp = $endTimestamp
            }
            if ([int]$sample.Percent -gt [int]$bucket.Percent) {
                $bucket.Percent = [int]$sample.Percent
            }
        }
    }

    $displaySamples = @($buckets.Values | Sort-Object Timestamp)
    for ($index = 0; $index -lt $displaySamples.Count; $index++) {
        $gapAfterSeconds = 10.0
        if ($index -lt ($displaySamples.Count - 1)) {
            $gapAfterSeconds = [math]::Max(0, ($displaySamples[$index + 1].Timestamp - $displaySamples[$index].EndTimestamp).TotalSeconds)
        }
        $displaySamples[$index] | Add-Member -NotePropertyName GapAfterSeconds -NotePropertyValue $gapAfterSeconds -Force
    }
    return $displaySamples
}

function Get-LanZLoadColor {
    param([Parameter(Mandatory)][int]$Percent)

    if ($Percent -ge 85) {
        return '#F56C6C'
    }
    if ($Percent -ge 60) {
        return '#E6A23C'
    }
    return '#45C391'
}

function Add-LanZChartHistory {
    param(
        [Parameter(Mandatory)][array]$Models,
        [DateTime]$SampleTimestamp = [DateTime]::UtcNow,
        [switch]$SkipPersistence,
        [switch]$SkipSample
    )

    $now = [DateTime]::UtcNow
    $sampleTime = $SampleTimestamp.ToUniversalTime()
    $cutoff = $now.AddHours(-5)
    if ($sampleTime -lt $cutoff) {
        $sampleTime = $cutoff
    }
    foreach ($model in $Models) {
        $key = [string]$model.ModelId
        if (-not $script:LoadHistory.ContainsKey($key)) {
            $script:LoadHistory[$key] = [System.Collections.Generic.List[object]]::new()
        }

        $history = $script:LoadHistory[$key]
        $lastSample = if ($history.Count -gt 0) { $history[$history.Count - 1] } else { $null }
        if (-not $SkipSample -and ($null -eq $lastSample -or [math]::Abs(($lastSample.Timestamp - $sampleTime).TotalSeconds) -gt 2)) {
            $history.Add([pscustomobject]@{
                Timestamp = $sampleTime
                EndTimestamp = $sampleTime
                Percent = [int]$model.Percent
            })
        }
        while ($history.Count -gt 0) {
            $oldestEndTimestamp = if ($null -ne $history[0].PSObject.Properties['EndTimestamp']) {
                $history[0].EndTimestamp
            }
            else {
                $history[0].Timestamp
            }
            if ($oldestEndTimestamp -ge $cutoff) {
                break
            }
            $history.RemoveAt(0)
        }

        $samples = @(Get-LanZChartDisplaySamples -Samples @($history) -Now $now)
        $values = @($samples | ForEach-Object { [int]$_.Percent })
        if ($values.Count -eq 0) {
            $minimum = 0
            $maximum = 100
        }
        else {
            $minimum = [int](($values | Measure-Object -Minimum).Minimum)
            $maximum = [int](($values | Measure-Object -Maximum).Maximum)
        }
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
        $barSegments = [System.Collections.Generic.List[object]]::new()
        $previousTimestamp = $null
        $firstPoint = $null
        $lastPoint = $null
        for ($sampleIndex = 0; $sampleIndex -lt $samples.Count; $sampleIndex++) {
            $sample = $samples[$sampleIndex]
            $ageSeconds = [math]::Max(0, ($now - $sample.Timestamp).TotalSeconds)
            $x = Get-LanZTimelineX -AgeSeconds $ageSeconds
            $y = $plotHeight - (([double]$sample.Percent - $lower) / $range * $plotHeight)
            $point = [Windows.Point]::new($x, $y)
            if ($null -eq $firstPoint) {
                $firstPoint = $point
            }

            $gapBeforeSeconds = if ($sampleIndex -eq 0) {
                0.0
            }
            elseif ($null -ne $samples[$sampleIndex - 1].PSObject.Properties['GapAfterSeconds']) {
                [double]$samples[$sampleIndex - 1].GapAfterSeconds
            }
            else {
                ($sample.Timestamp - $samples[$sampleIndex - 1].Timestamp).TotalSeconds
            }
            if ($null -eq $previousTimestamp -or $gapBeforeSeconds -gt 30) {
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

            $gapAfterSeconds = if ($null -ne $sample.PSObject.Properties['GapAfterSeconds']) {
                [double]$sample.GapAfterSeconds
            }
            elseif ($sampleIndex -lt ($samples.Count - 1)) {
                ($samples[$sampleIndex + 1].Timestamp - $sample.Timestamp).TotalSeconds
            }
            else {
                10.0
            }

            $nextX = if ($sampleIndex -lt ($samples.Count - 1)) {
                $nextAge = [math]::Max(0, ($now - $samples[$sampleIndex + 1].Timestamp).TotalSeconds)
                Get-LanZTimelineX -AgeSeconds $nextAge
            }
            else {
                $script:ChartWidth
            }
            $barWidth = [math]::Max(1.0, [math]::Round($nextX - $x - 1.0, 2))
            $barColor = if ($gapAfterSeconds -gt 30) { '#C8D4DC' } else { Get-LanZLoadColor -Percent ([int]$sample.Percent) }
            $barOpacity = if ($gapAfterSeconds -gt 30) { 0.45 } else { 0.92 }
            $barHeight = [math]::Max(1.5, [math]::Round($plotHeight - $y, 2))
            $barSegments.Add([pscustomobject]@{
                X = [math]::Round($x + 0.5, 2)
                Y = [math]::Round($plotHeight - $barHeight, 2)
                Width = $barWidth
                Height = $barHeight
                Color = $barColor
                Opacity = $barOpacity
            })
        }

        $backfillPoints = [Windows.Media.PointCollection]::new()
        if ($null -ne $firstPoint -and $firstPoint.X -gt 0.5) {
            [void]$backfillPoints.Add([Windows.Point]::new(0, $firstPoint.Y))
            [void]$backfillPoints.Add($firstPoint)
        }
        if ($null -ne $firstPoint -and $firstPoint.X -gt 0.5) {
            $barSegments.Insert(0, [pscustomobject]@{
                X = 0.0
                Y = $plotHeight - 2.0
                Width = [math]::Round($firstPoint.X, 2)
                Height = 2.0
                Color = '#C8D4DC'
                Opacity = 0.5
            })
        }
        if ($barSegments.Count -eq 0) {
            $barSegments.Add([pscustomobject]@{
                X = 0.0
                Y = $plotHeight - 2.0
                Width = $script:ChartWidth
                Height = 2.0
                Color = '#C8D4DC'
                Opacity = 0.5
            })
        }

        $lineVisibility = if ($script:UiPreferences.ChartMode -eq 'line') { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
        $barVisibility = if ($script:UiPreferences.ChartMode -eq 'bar') { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
        $currentPointVisibility = $lineVisibility

        $model | Add-Member -NotePropertyName ChartGeometry -NotePropertyValue $geometry -Force
        $model | Add-Member -NotePropertyName BackfillPoints -NotePropertyValue $backfillPoints -Force
        $model | Add-Member -NotePropertyName BarSegments -NotePropertyValue @($barSegments) -Force
        $model | Add-Member -NotePropertyName LineVisibility -NotePropertyValue $lineVisibility -Force
        $model | Add-Member -NotePropertyName BarVisibility -NotePropertyValue $barVisibility -Force
        $model | Add-Member -NotePropertyName CurrentPointVisibility -NotePropertyValue $currentPointVisibility -Force
        $model | Add-Member -NotePropertyName ChartUpperLabel -NotePropertyValue ("$upper%") -Force
        $model | Add-Member -NotePropertyName ChartLowerLabel -NotePropertyValue ("$lower%") -Force
        $currentX = if ($null -ne $lastPoint) { [math]::Max(0, $lastPoint.X - 3) } else { 327 }
        $currentY = if ($null -ne $lastPoint) { [math]::Max(0, $lastPoint.Y - 3) } else { $plotHeight - 3 }
        $model | Add-Member -NotePropertyName CurrentX -NotePropertyValue $currentX -Force
        $model | Add-Member -NotePropertyName CurrentY -NotePropertyValue $currentY -Force
        $model | Add-Member -NotePropertyName CurrentMargin -NotePropertyValue ([Windows.Thickness]::new(
            $currentX,
            $currentY,
            0,
            0
        )) -Force
    }

    if (-not $SkipPersistence) {
        try {
            Save-LanZHistory
        }
        catch {
            # History persistence is optional; a write failure must not stop live monitoring.
        }
    }
    return $Models
}

Initialize-LanZHistory
Initialize-LanZStatusSnapshot

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
        [Parameter(Mandatory)][Windows.FrameworkElement]$TargetWindow,
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
        Width="430" Height="560"
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
                <RowDefinition Height="52"/>
                <RowDefinition x:Name="UsageRowDefinition" Height="138"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <Grid x:Name="DragArea" Grid.Row="0" Background="Transparent">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="34"/>
                    <ColumnDefinition Width="36"/>
                    <ColumnDefinition Width="36"/>
                    <ColumnDefinition Width="36"/>
                </Grid.ColumnDefinitions>
                <StackPanel VerticalAlignment="Top">
                    <TextBlock Text="LanZ 负载" FontSize="17" FontWeight="SemiBold" Foreground="#263746"/>
                    <TextBlock x:Name="UpdatedText" Text="正在连接…" Margin="0,4,0,0" FontSize="11" Foreground="#8694A0" TextTrimming="CharacterEllipsis"/>
                </StackPanel>
                <ToggleButton x:Name="PinToggle" Grid.Column="1" Content="📌" IsChecked="True" Width="30" Height="25" FontSize="13" Style="{StaticResource AutoToggleStyle}" ToolTip="已置顶，点击取消"/>
                <Button x:Name="RefreshButton" Grid.Column="2" Content="↻" FontSize="18" Foreground="#536675" Background="Transparent" BorderThickness="0" Cursor="Hand" ToolTip="立即刷新"/>
                <ToggleButton x:Name="SettingsButton" Grid.Column="3" Content="⚙" Width="30" Height="25" FontSize="15" Style="{StaticResource AutoToggleStyle}" ToolTip="设置"/>
                <Button x:Name="CloseButton" Grid.Column="4" Content="×" FontSize="20" Foreground="#536675" Background="Transparent" BorderThickness="0" Cursor="Hand" ToolTip="关闭"/>
            </Grid>

            <Border x:Name="UsageCard" Grid.Row="1" Background="#FFFFFF" BorderBrush="#E2E8ED" BorderThickness="1" CornerRadius="11" Padding="12,8" Margin="0,0,0,8">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="32"/>
                        <RowDefinition x:Name="ExternalQuotaRowDefinition" Height="30"/>
                        <RowDefinition x:Name="InternalQuotaRowDefinition" Height="30"/>
                        <RowDefinition Height="18"/>
                    </Grid.RowDefinitions>
                    <Grid Grid.Row="0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Text="当日请求数" FontSize="12" Foreground="#61727E" VerticalAlignment="Center"/>
                        <TextBlock Grid.Column="1" Text="{Binding RequestCount}" FontSize="22" FontWeight="SemiBold" Foreground="#263746" Margin="8,-2,0,0"/>
                        <Border Grid.Column="3" Background="{Binding BillingBackground}" CornerRadius="8" Padding="8,3">
                            <StackPanel>
                                <TextBlock Text="{Binding BillingStatus}" FontSize="10" FontWeight="SemiBold" Foreground="{Binding BillingForeground}" HorizontalAlignment="Center"/>
                                <TextBlock Text="{Binding BillingDetail}" FontSize="8.5" Foreground="{Binding BillingForeground}" HorizontalAlignment="Center"/>
                            </StackPanel>
                        </Border>
                    </Grid>
                    <Grid x:Name="ExternalQuotaRow" Grid.Row="1">
                        <Grid.RowDefinitions><RowDefinition Height="20"/><RowDefinition Height="6"/></Grid.RowDefinitions>
                        <Grid Grid.Row="0">
                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                            <TextBlock Text="外网模型" FontSize="11" FontWeight="SemiBold" Foreground="#435663"/>
                            <TextBlock Grid.Column="1" Text="{Binding ExternalUsage}" FontSize="10.5" Foreground="#61727E" Margin="8,0,0,0"/>
                            <TextBlock Grid.Column="2" Text="{Binding ExternalPercent}" FontSize="10" Foreground="{Binding ExternalColor}" Margin="7,0,0,0"/>
                            <TextBlock Grid.Column="3" Text="{Binding ExternalWarning}" FontSize="9.5" Foreground="#F56C6C" Margin="8,0,0,0"/>
                            <TextBlock Grid.Column="4" Text="{Binding ExternalRemaining}" FontSize="10.5" FontWeight="SemiBold" Foreground="{Binding ExternalColor}"/>
                        </Grid>
                        <Border Grid.Row="1" Height="5" Background="#EDF2F5" CornerRadius="3">
                            <Border Width="{Binding ExternalProgressWidth}" HorizontalAlignment="Left" Background="{Binding ExternalColor}" CornerRadius="3"/>
                        </Border>
                    </Grid>
                    <Grid x:Name="InternalQuotaRow" Grid.Row="2">
                        <Grid.RowDefinitions><RowDefinition Height="20"/><RowDefinition Height="6"/></Grid.RowDefinitions>
                        <Grid Grid.Row="0">
                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                            <TextBlock Text="内网模型" FontSize="11" FontWeight="SemiBold" Foreground="#435663"/>
                            <TextBlock Grid.Column="1" Text="{Binding InternalUsage}" FontSize="10.5" Foreground="#61727E" Margin="8,0,0,0"/>
                            <TextBlock Grid.Column="2" Text="{Binding InternalPercent}" FontSize="10" Foreground="{Binding InternalColor}" Margin="7,0,0,0"/>
                            <TextBlock Grid.Column="3" Text="{Binding InternalWarning}" FontSize="9.5" Foreground="#F56C6C" Margin="8,0,0,0"/>
                            <TextBlock Grid.Column="4" Text="{Binding InternalRemaining}" FontSize="10.5" FontWeight="SemiBold" Foreground="{Binding InternalColor}"/>
                        </Grid>
                        <Border Grid.Row="1" Height="5" Background="#EDF2F5" CornerRadius="3">
                            <Border Width="{Binding InternalProgressWidth}" HorizontalAlignment="Left" Background="{Binding InternalColor}" CornerRadius="3"/>
                        </Border>
                    </Grid>
                    <TextBlock Grid.Row="3" Text="{Binding BillingSource}" FontSize="8.5" Foreground="#8A98A3" VerticalAlignment="Bottom"/>
                </Grid>
            </Border>

            <ItemsControl x:Name="ModelsList" Grid.Row="2" AllowDrop="True">
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
                                        <Line X1="24" Y1="27" X2="24" Y2="30" Stroke="#B9C7D0" StrokeThickness="1"/>
                                        <Line X1="52" Y1="27" X2="52" Y2="30" Stroke="#B9C7D0" StrokeThickness="1"/>
                                        <Line X1="110" Y1="27" X2="110" Y2="30" Stroke="#B9C7D0" StrokeThickness="1"/>
                                        <Line X1="130" Y1="27" X2="130" Y2="30" Stroke="#D3DDE3" StrokeThickness="1"/>
                                        <Line X1="150" Y1="27" X2="150" Y2="30" Stroke="#D3DDE3" StrokeThickness="1"/>
                                        <Line X1="170" Y1="27" X2="170" Y2="30" Stroke="#D3DDE3" StrokeThickness="1"/>
                                        <Line X1="190" Y1="27" X2="190" Y2="30" Stroke="#D3DDE3" StrokeThickness="1"/>
                                        <Line X1="210" Y1="27" X2="210" Y2="30" Stroke="#D3DDE3" StrokeThickness="1"/>
                                        <Line X1="228" Y1="27" X2="228" Y2="30" Stroke="#D3DDE3" StrokeThickness="1"/>
                                        <Line X1="250" Y1="27" X2="250" Y2="30" Stroke="#D3DDE3" StrokeThickness="1"/>
                                        <Line X1="270" Y1="27" X2="270" Y2="30" Stroke="#D3DDE3" StrokeThickness="1"/>
                                        <Line X1="290" Y1="27" X2="290" Y2="30" Stroke="#D3DDE3" StrokeThickness="1"/>
                                        <Line X1="310" Y1="27" X2="310" Y2="30" Stroke="#D3DDE3" StrokeThickness="1"/>
                                        <Line X1="329" Y1="27" X2="329" Y2="30" Stroke="#B9C7D0" StrokeThickness="1"/>
                                        <TextBlock Text="5h" Canvas.Left="0" Canvas.Top="30" FontSize="8" Foreground="#87959F"/>
                                        <TextBlock Text="1h" Canvas.Left="18" Canvas.Top="30" FontSize="8" Foreground="#87959F"/>
                                        <TextBlock Text="30m" Canvas.Left="41" Canvas.Top="30" FontSize="8" Foreground="#87959F"/>
                                        <TextBlock Text="15m" Canvas.Left="101" Canvas.Top="30" FontSize="8" Foreground="#87959F"/>
                                        <TextBlock Text="10m" Canvas.Left="122" Canvas.Top="30" FontSize="7.5" Foreground="#9AA6AE"/>
                                        <TextBlock Text="5m" Canvas.Left="144" Canvas.Top="30" FontSize="7.5" Foreground="#9AA6AE"/>
                                        <TextBlock Text="2m" Canvas.Left="165" Canvas.Top="30" FontSize="7.5" Foreground="#9AA6AE"/>
                                        <TextBlock Text="1m" Canvas.Left="204" Canvas.Top="30" FontSize="7.5" Foreground="#9AA6AE"/>
                                        <TextBlock Text="50" Canvas.Left="219" Canvas.Top="30" FontSize="7.5" Foreground="#87959F"/>
                                        <TextBlock Text="40" Canvas.Left="245" Canvas.Top="30" FontSize="7.5" Foreground="#9AA6AE"/>
                                        <TextBlock Text="30" Canvas.Left="265" Canvas.Top="30" FontSize="7.5" Foreground="#9AA6AE"/>
                                        <TextBlock Text="20" Canvas.Left="285" Canvas.Top="30" FontSize="7.5" Foreground="#9AA6AE"/>
                                        <TextBlock Text="10" Canvas.Left="305" Canvas.Top="30" FontSize="7.5" Foreground="#9AA6AE"/>
                                        <TextBlock Text="0s" Canvas.Left="322" Canvas.Top="30" FontSize="7.5" Foreground="#87959F"/>
                                        <ItemsControl ItemsSource="{Binding BarSegments}" Visibility="{Binding BarVisibility}" Width="330" Height="27" Canvas.Left="0" Canvas.Top="0">
                                            <ItemsControl.ItemsPanel>
                                                <ItemsPanelTemplate><Canvas/></ItemsPanelTemplate>
                                            </ItemsControl.ItemsPanel>
                                            <ItemsControl.ItemContainerStyle>
                                                <Style TargetType="{x:Type ContentPresenter}">
                                                    <Setter Property="Canvas.Left" Value="{Binding X}"/>
                                                    <Setter Property="Canvas.Top" Value="{Binding Y}"/>
                                                </Style>
                                            </ItemsControl.ItemContainerStyle>
                                            <ItemsControl.ItemTemplate>
                                                <DataTemplate>
                                                    <Rectangle Width="{Binding Width}" Height="{Binding Height}" Fill="{Binding Color}" Opacity="{Binding Opacity}" RadiusX="1" RadiusY="1"/>
                                                </DataTemplate>
                                            </ItemsControl.ItemTemplate>
                                        </ItemsControl>
                                        <Polyline Points="{Binding BackfillPoints}" Stroke="{Binding Color}" StrokeThickness="1.6" StrokeDashArray="3,3" Opacity="0.3" Visibility="{Binding LineVisibility}"/>
                                        <Path Data="{Binding ChartGeometry}" Stroke="{Binding Color}" StrokeThickness="2.2" StrokeLineJoin="Round" Fill="Transparent" Visibility="{Binding LineVisibility}"/>
                                    </Canvas>
                                    <Ellipse Width="6" Height="6" Fill="{Binding Color}" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="{Binding CurrentMargin}" Visibility="{Binding CurrentPointVisibility}" IsHitTestVisible="False"/>
                                    <TextBlock Text="{Binding ChartUpperLabel}" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,1,4,0" Padding="2,0" FontSize="8" Foreground="#84939E" Background="#CCF4F7F9"/>
                                    <TextBlock Text="{Binding ChartLowerLabel}" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,18,4,0" Padding="2,0" FontSize="8" Foreground="#84939E" Background="#CCF4F7F9"/>
                                </Grid>
                            </Grid>
                        </Border>
                    </DataTemplate>
                </ItemsControl.ItemTemplate>
            </ItemsControl>

            <Popup x:Name="SettingsPopup" PlacementTarget="{Binding ElementName=SettingsButton}" Placement="Bottom" HorizontalOffset="-160" VerticalOffset="4" StaysOpen="False" AllowsTransparency="True">
                <Border Width="196" Background="#FFFFFF" BorderBrush="#DCE4EA" BorderThickness="1" CornerRadius="10" Padding="12">
                    <Border.Effect><DropShadowEffect BlurRadius="14" ShadowDepth="3" Opacity="0.22" Color="#203040"/></Border.Effect>
                    <StackPanel>
                        <TextBlock Text="显示与刷新" FontSize="11" FontWeight="SemiBold" Foreground="#314452" Margin="2,0,0,7"/>
                        <CheckBox x:Name="AutoRefreshToggle" Content="自动刷新（10 秒）" IsChecked="True" FontSize="11" Foreground="#536675" Margin="2,4" Cursor="Hand"/>
                        <CheckBox x:Name="ShowExternalQuotaToggle" Content="显示外网模型额度" IsChecked="False" FontSize="11" Foreground="#536675" Margin="2,4" Cursor="Hand"/>
                        <CheckBox x:Name="ShowInternalQuotaToggle" Content="显示内网模型额度" IsChecked="True" FontSize="11" Foreground="#536675" Margin="2,4" Cursor="Hand"/>
                        <StackPanel Orientation="Horizontal" Margin="2,5,0,0">
                            <TextBlock Text="图表模式" FontSize="11" Foreground="#536675" VerticalAlignment="Center" Margin="0,0,8,0"/>
                            <RadioButton x:Name="BarChartToggle" Content="柱状图" GroupName="ChartMode" IsChecked="True" FontSize="11" Foreground="#536675" Margin="0,0,9,0" Cursor="Hand"/>
                            <RadioButton x:Name="LineChartToggle" Content="折线图" GroupName="ChartMode" IsChecked="False" FontSize="11" Foreground="#536675" Cursor="Hand"/>
                        </StackPanel>
                        <Separator Margin="0,7,0,7" Background="#E7ECEF"/>
                        <Button x:Name="LoginButton" Content="重新登录 / 切换凭据" Height="29" FontSize="11" Foreground="#5A47E5" Background="#F0EEFF" BorderBrush="#D9D3FF" Cursor="Hand"/>
                    </StackPanel>
                </Border>
            </Popup>

        </Grid>
    </Border>
</Window>
'@

$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
$modelsList = $window.FindName('ModelsList')
$usageCard = $window.FindName('UsageCard')
$usageRowDefinition = $window.FindName('UsageRowDefinition')
$externalQuotaRow = $window.FindName('ExternalQuotaRow')
$internalQuotaRow = $window.FindName('InternalQuotaRow')
$externalQuotaRowDefinition = $window.FindName('ExternalQuotaRowDefinition')
$internalQuotaRowDefinition = $window.FindName('InternalQuotaRowDefinition')
$updatedText = $window.FindName('UpdatedText')
$pinToggle = $window.FindName('PinToggle')
$refreshButton = $window.FindName('RefreshButton')
$closeButton = $window.FindName('CloseButton')
$dragArea = $window.FindName('DragArea')
$autoRefreshToggle = $window.FindName('AutoRefreshToggle')
$showExternalQuotaToggle = $window.FindName('ShowExternalQuotaToggle')
$showInternalQuotaToggle = $window.FindName('ShowInternalQuotaToggle')
$barChartToggle = $window.FindName('BarChartToggle')
$lineChartToggle = $window.FindName('LineChartToggle')
$settingsButton = $window.FindName('SettingsButton')
$settingsPopup = $window.FindName('SettingsPopup')
$loginButton = $window.FindName('LoginButton')
$autoRefreshToggle.IsChecked = [bool]$script:UiPreferences.AutoRefresh
$showExternalQuotaToggle.IsChecked = [bool]$script:UiPreferences.ShowExternalQuota
$showInternalQuotaToggle.IsChecked = [bool]$script:UiPreferences.ShowInternalQuota
$barChartToggle.IsChecked = $script:UiPreferences.ChartMode -eq 'bar'
$lineChartToggle.IsChecked = $script:UiPreferences.ChartMode -eq 'line'

function Show-LanZLogin {
    param([switch]$ClearExistingSession)

    if ($script:LoginWindowOpen) {
        return
    }

    $script:LoginWindowOpen = $true
    $script:SuppressAutoLogin = $false
    $timer.Stop()

    try {
        $loginNavigationUri = $null
        if (-not [Uri]::TryCreate([string]$script:UsageDashboardUrl, [UriKind]::Absolute, [ref]$loginNavigationUri) -or $loginNavigationUri.Scheme -ne 'https') {
            throw '资源看板地址无效，请重新配置连接信息。'
        }

        $webViewDirectory = Join-Path $script:RuntimeDirectory 'WebView2'
        $runtimeFilesReady = @(
            'Microsoft.Web.WebView2.Core.dll',
            'Microsoft.Web.WebView2.Wpf.dll',
            'WebView2Loader.dll'
        ) | ForEach-Object { Test-Path -LiteralPath (Join-Path $webViewDirectory $_) }
        if ($runtimeFilesReady -contains $false) {
            $webViewDirectory = Join-Path $script:AppDirectory 'lib\WebView2'
        }
        $coreAssembly = Join-Path $webViewDirectory 'Microsoft.Web.WebView2.Core.dll'
        $wpfAssembly = Join-Path $webViewDirectory 'Microsoft.Web.WebView2.Wpf.dll'
        $loaderAssembly = Join-Path $webViewDirectory 'WebView2Loader.dll'
        if (-not (Test-Path -LiteralPath $coreAssembly) -or -not (Test-Path -LiteralPath $wpfAssembly) -or -not (Test-Path -LiteralPath $loaderAssembly)) {
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
        $webViewProfileDirectory = Join-Path $env:LOCALAPPDATA 'LanZMonitor\WebView2'
        [void][IO.Directory]::CreateDirectory($webViewProfileDirectory)
        $creationProperties.UserDataFolder = $webViewProfileDirectory
        $webView.CreationProperties = $creationProperties
        [void]$browserHost.Children.Add($webView)

        $loginState = @{
            Stage = 'ensure'
            EnsureTask = $null
            CookieTask = $null
            NavigationUri = $loginNavigationUri.AbsoluteUri
            LastCandidate = ''
            LastCookiePoll = [DateTime]::MinValue
            Success = $false
        }
        $loginTimer = [Windows.Threading.DispatcherTimer]::new()
        $loginTimer.Interval = [TimeSpan]::FromMilliseconds(250)

        $loginWindow.Add_Loaded(({
            try {
                $loginState.EnsureTask = $webView.EnsureCoreWebView2Async()
                $loginTimer.Start()
            }
            catch {
                $loginStatusText.Text = '验证窗口异常：' + $_.Exception.Message
                $loginState.Stage = 'error'
            }
        }).GetNewClosure())

        $webView.add_NavigationCompleted(({
            param($sender, $eventArgs)
            if (-not $eventArgs.IsSuccess) {
                $loginStatusText.Text = '登录页面加载失败：' + [string]$eventArgs.WebErrorStatus
                $loginState.Stage = 'error'
            }
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
                    $webView.CoreWebView2.Settings.IsPasswordAutosaveEnabled = $true
                    $webView.CoreWebView2.Settings.IsGeneralAutofillEnabled = $true
                    $webView.CoreWebView2.Profile.IsPasswordAutosaveEnabled = $true
                    $webView.CoreWebView2.Profile.IsGeneralAutofillEnabled = $true
                    if ($ClearExistingSession) {
                        $webView.CoreWebView2.CookieManager.DeleteAllCookies()
                    }
                    $webView.CoreWebView2.Navigate($loginState.NavigationUri)
                    $loginStatusText.Text = '请在资源看板完成登录；若页面提供保存密码提示可自行选择，程序只保存会话 Cookie。'
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
                    $loginState.CookieTask = $webView.CoreWebView2.CookieManager.GetCookiesAsync($loginState.NavigationUri)
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
                $autoRefreshToggle.IsChecked = $true
                Update-Widget
                $timer.Start()
            }
            else {
                $script:SuppressAutoLogin = $true
                $autoRefreshToggle.IsChecked = $false
                $updatedText.Text = '登录未完成，可在齿轮菜单中继续'
            }
        }).GetNewClosure())

        [void]$loginWindow.ShowDialog()
    }
    catch {
        $script:LoginWindowOpen = $false
        $loginErrorMessage = '登录窗口启动失败：' + $_.Exception.Message
        $updatedText.Text = $loginErrorMessage
        $updatedText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#F56C6C')
        try {
            [void][Windows.MessageBox]::Show(
                $loginErrorMessage,
                'LanZ 身份验证',
                [Windows.MessageBoxButton]::OK,
                [Windows.MessageBoxImage]::Error
            )
        }
        catch {
            # A message box is best-effort; the red status text remains visible if WPF is unavailable.
        }
    }
}

function Set-LanZRefreshError {
    param([Parameter(Mandatory)][System.Exception]$Exception)

    $updatedText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#F56C6C')
    $updatedText.Text = $Exception.Message
    $isUnauthorized = $Exception -is [System.UnauthorizedAccessException] -or $Exception.Message -match '会话已过期'
    if ($isUnauthorized) {
        $timer.Stop()
        if (-not $script:SuppressAutoLogin) {
            Show-LanZLogin
        }
    }
}

function Start-LanZRefresh {
    if ($script:RefreshInProgress) {
        return
    }

    try {
        $sessionValue = Get-LanZSessionValue
        $functionNames = @(
            'New-LanZRequestToken',
            'Get-LanZModels',
            'Get-LanZUsageOverview',
            'Get-LanZAuthenticatedText',
            'Import-LanZBillingRulesCache',
            'Get-LanZBillingRules'
        )
        $functionDefinitions = foreach ($functionName in $functionNames) {
            $definition = (Get-Command -Name $functionName -CommandType Function -ErrorAction Stop).Definition
            $definition = $definition -replace '\$script:', '$global:'
            "function $functionName {`n$definition`n}`n"
        }
        $workerHeader = @'
param(
    [object]$Configuration,
    [string]$SessionValue,
    [string]$BillingRulesPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[void](Add-Type -AssemblyName System.Net.Http)
$global:Configuration = $Configuration
$global:Endpoint = [string]$Configuration.ApiEndpoint
$global:UsageEndpoint = [string]$Configuration.UsageEndpoint
$global:UsageDashboardUrl = [string]$Configuration.UsageDashboardUrl
$global:SessionCookieName = [string]$Configuration.SessionCookieName
$global:BillingRulesPath = $BillingRulesPath
$global:BillingRules = $null
'@
        $workerTail = @'
$models = @(Get-LanZModels -SessionValue $SessionValue)
$usageOverview = Get-LanZUsageOverview -SessionValue $SessionValue
$billingRules = Get-LanZBillingRules -SessionValue $SessionValue
[pscustomobject]@{
    Models = $models
    UsageOverview = $usageOverview
    BillingRules = $billingRules
}
'@

        $worker = [System.Management.Automation.PowerShell]::Create()
        $workerScript =
            $workerHeader +
            [Environment]::NewLine +
            ($functionDefinitions -join [Environment]::NewLine) +
            [Environment]::NewLine +
            $workerTail
        [void]$worker.AddScript($workerScript)
        [void]$worker.AddArgument($script:Configuration)
        [void]$worker.AddArgument($sessionValue)
        [void]$worker.AddArgument($script:BillingRulesPath)
        $script:RefreshWorker = [pscustomobject]@{
            PowerShell = $worker
            Handle = $worker.BeginInvoke()
        }
        $script:RefreshInProgress = $true
        $updatedText.Text = '正在刷新…'
        $updatedText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#8694A0')
        $refreshPollTimer.Start()
    }
    catch {
        $script:RefreshInProgress = $false
        if ($null -ne $script:RefreshWorker) {
            $script:RefreshWorker.PowerShell.Dispose()
            $script:RefreshWorker = $null
        }
        Set-LanZRefreshError -Exception $_.Exception
    }
    finally {
        $sessionValue = $null
    }
}

function Complete-LanZRefresh {
    if ($null -eq $script:RefreshWorker -or -not $script:RefreshWorker.Handle.IsCompleted) {
        return
    }

    $worker = $script:RefreshWorker
    $script:RefreshWorker = $null
    $script:RefreshInProgress = $false
    $refreshPollTimer.Stop()
    try {
        $result = @($worker.PowerShell.EndInvoke($worker.Handle) | Select-Object -Last 1)[0]
        if ($null -eq $result) {
            throw '刷新没有返回可用数据。'
        }
        $models = @($result.Models)
        $usageOverview = $result.UsageOverview
        $script:BillingRules = $result.BillingRules
        $modelsWithHistory = @(Add-LanZChartHistory -Models $models)
        $script:DisplayedModels = @(Sort-LanZModels -Models $modelsWithHistory)
        $modelsList.ItemsSource = $script:DisplayedModels
        $usageCard.DataContext = New-LanZQuotaViewModel -Overview $usageOverview -BillingRules $script:BillingRules
        try {
            Save-LanZStatusSnapshot -Models $models -Overview $usageOverview
        }
        catch {
            # The live widget remains authoritative if local snapshot persistence fails.
        }
        $updatedText.Text = '已更新 ' + (Get-Date).ToString('HH:mm:ss')
        $updatedText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#8694A0')
    }
    catch {
        Set-LanZRefreshError -Exception $_.Exception
    }
    finally {
        $worker.PowerShell.Dispose()
    }
}

function Update-Widget {
    Start-LanZRefresh
}

function Show-LanZCachedStatus {
    if ($null -eq $script:CachedStatusSnapshot) {
        return
    }
    try {
        $snapshotTime = [DateTime]::Parse(
            [string]$script:CachedStatusSnapshot.Timestamp,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
        $cachedModels = @($script:CachedStatusSnapshot.Models | ForEach-Object {
            [pscustomobject]@{
                Name = [string]$_.Name
                ModelId = [string]$_.ModelId
                Active = [int]$_.Active
                Capacity = [int]$_.Capacity
                Percent = [int]$_.Percent
                Available = [bool]$_.Available
                Summary = [string]$_.Summary
                Color = [string]$_.Color
                CardBackground = [string]$_.CardBackground
                CardBorder = [string]$_.CardBorder
            }
        })
        $modelsWithHistory = @(Add-LanZChartHistory -Models $cachedModels -SampleTimestamp $snapshotTime -SkipPersistence)
        $script:DisplayedModels = @(Sort-LanZModels -Models $modelsWithHistory)
        $modelsList.ItemsSource = $script:DisplayedModels
        $cachedRules = Import-LanZBillingRulesCache
        $usageCard.DataContext = New-LanZQuotaViewModel -Overview $script:CachedStatusSnapshot.Usage -BillingRules $cachedRules
        $localTime = $snapshotTime.ToLocalTime()
        $updatedText.Text = '上次记录 ' + $localTime.ToString('MM-dd HH:mm:ss') + ' · 正在刷新…'
        $updatedText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#8694A0')
    }
    catch {
        $script:CachedStatusSnapshot = $null
    }
}

function Update-LanZQuotaVisibility {
    $externalVisible = [bool]$showExternalQuotaToggle.IsChecked
    $internalVisible = [bool]$showInternalQuotaToggle.IsChecked
    $externalQuotaRow.Visibility = if ($externalVisible) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    $internalQuotaRow.Visibility = if ($internalVisible) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    $externalQuotaRowDefinition.Height = [Windows.GridLength]::new($(if ($externalVisible) { 30 } else { 0 }))
    $internalQuotaRowDefinition.Height = [Windows.GridLength]::new($(if ($internalVisible) { 30 } else { 0 }))
    $visibleCount = [int]$externalVisible + [int]$internalVisible
    $usageRowDefinition.Height = [Windows.GridLength]::new(78 + (30 * $visibleCount))
}

function Update-LanZChartMode {
    if ($barChartToggle.IsChecked) {
        $script:UiPreferences.ChartMode = 'bar'
    }
    else {
        $script:UiPreferences.ChartMode = 'line'
    }

    if ($script:DisplayedModels.Count -gt 0) {
        [void](Add-LanZChartHistory -Models @($script:DisplayedModels) -SkipPersistence -SkipSample)
        $modelsList.ItemsSource = $null
        $modelsList.ItemsSource = $script:DisplayedModels
    }
}

function Save-LanZUiPreferences {
    $preferences = [ordered]@{
        AutoRefresh = [bool]$autoRefreshToggle.IsChecked
        ShowExternalQuota = [bool]$showExternalQuotaToggle.IsChecked
        ShowInternalQuota = [bool]$showInternalQuotaToggle.IsChecked
        ChartMode = [string]$script:UiPreferences.ChartMode
    }
    [System.IO.File]::WriteAllText(
        $script:UiPreferencesPath,
        ($preferences | ConvertTo-Json -Compress),
        [System.Text.UTF8Encoding]::new($false)
    )
}

$timer = [Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromSeconds($RefreshSeconds)
$timer.Add_Tick({ Update-Widget })
$refreshPollTimer = [Windows.Threading.DispatcherTimer]::new()
$refreshPollTimer.Interval = [TimeSpan]::FromMilliseconds(120)
$refreshPollTimer.Add_Tick({ Complete-LanZRefresh })
$startupTimer = [Windows.Threading.DispatcherTimer]::new()
$startupTimer.Interval = [TimeSpan]::FromMilliseconds(80)
$startupTimer.Add_Tick({
    $startupTimer.Stop()
    Update-Widget
    if ($autoRefreshToggle.IsChecked -and -not $script:LoginWindowOpen) {
        $timer.Start()
    }
})
$refreshButton.Add_Click({ Update-Widget })
$autoRefreshToggle.Add_Checked({
    Save-LanZUiPreferences
    $script:SuppressAutoLogin = $false
    Update-Widget
    if ($autoRefreshToggle.IsChecked -and -not $script:LoginWindowOpen) {
        $timer.Start()
    }
})
$autoRefreshToggle.Add_Unchecked({
    Save-LanZUiPreferences
    $timer.Stop()
    if (-not $script:LoginWindowOpen) {
        $updatedText.Text = '自动刷新已暂停'
        $updatedText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#8694A0')
    }
})
$loginButton.Add_Click({
    $settingsPopup.IsOpen = $false
    $script:SuppressAutoLogin = $false
    [void]$window.Dispatcher.BeginInvoke([Action]{ Show-LanZLogin -ClearExistingSession })
})
$settingsButton.Add_Checked({ $settingsPopup.IsOpen = $true })
$settingsButton.Add_Unchecked({ $settingsPopup.IsOpen = $false })
$settingsPopup.Add_Closed({ $settingsButton.IsChecked = $false })
$showExternalQuotaToggle.Add_Checked({ Update-LanZQuotaVisibility; Save-LanZUiPreferences })
$showExternalQuotaToggle.Add_Unchecked({ Update-LanZQuotaVisibility; Save-LanZUiPreferences })
$showInternalQuotaToggle.Add_Checked({ Update-LanZQuotaVisibility; Save-LanZUiPreferences })
$showInternalQuotaToggle.Add_Unchecked({ Update-LanZQuotaVisibility; Save-LanZUiPreferences })
$barChartToggle.Add_Checked({
    $script:UiPreferences.ChartMode = 'bar'
    Save-LanZUiPreferences
    Update-LanZChartMode
})
$lineChartToggle.Add_Checked({
    $script:UiPreferences.ChartMode = 'line'
    Save-LanZUiPreferences
    Update-LanZChartMode
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
    if ($position.Y -gt 70) {
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
    Update-LanZQuotaVisibility
    Show-LanZCachedStatus
    if (-not [string]::IsNullOrWhiteSpace($ScreenshotPath) -or -not [string]::IsNullOrWhiteSpace($SettingsScreenshotPath)) {
        Update-Widget
        if (-not [string]::IsNullOrWhiteSpace($SettingsScreenshotPath)) {
            $settingsButton.IsChecked = $true
        }
        $screenshotDeadline = [DateTime]::UtcNow.AddSeconds(10)
        $screenshotTimer = [Windows.Threading.DispatcherTimer]::new()
        $screenshotTimer.Interval = [TimeSpan]::FromMilliseconds(500)
        $screenshotTimer.Add_Tick({
            if ($script:RefreshInProgress -and [DateTime]::UtcNow -lt $screenshotDeadline) {
                return
            }
            $screenshotTimer.Stop()
            if (-not [string]::IsNullOrWhiteSpace($ScreenshotPath)) {
                Export-LanZWindowScreenshot -TargetWindow $window -Path $ScreenshotPath
            }
            if (-not [string]::IsNullOrWhiteSpace($SettingsScreenshotPath)) {
                Export-LanZWindowScreenshot -TargetWindow $settingsPopup.Child -Path $SettingsScreenshotPath
            }
            $window.Close()
        }.GetNewClosure())
        $screenshotTimer.Start()
        return
    }
    $startupTimer.Start()
})
$window.Add_Closed({
    $startupTimer.Stop()
    $timer.Stop()
    $refreshPollTimer.Stop()
    if ($null -ne $script:RefreshWorker) {
        try {
            $script:RefreshWorker.PowerShell.Stop()
        }
        catch {
            # The process is closing; the background refresh can be abandoned.
        }
        $script:RefreshWorker.PowerShell.Dispose()
        $script:RefreshWorker = $null
        $script:RefreshInProgress = $false
    }
})

[void]$window.ShowDialog()
}
finally {
    $singleInstanceMutex.ReleaseMutex()
    $singleInstanceMutex.Dispose()
}
