param(
    [switch]$Once,
    [string]$ScreenshotPath,
    [string]$SettingsScreenshotPath,
    [ValidateRange(2, 60)]
    [int]$RefreshSeconds = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:AppVersion = '1.4.3'
$script:UpdateRepository = 'HankLiu2020/LanZ-Monitor'
$script:UpdateManifestUrl = "https://github.com/$($script:UpdateRepository)/releases/latest/download/latest.txt"
$script:UpdateReleaseUrl = "https://github.com/$($script:UpdateRepository)/releases/latest"

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
$script:LoginWindowOpen = $false
$script:SuppressAutoLogin = $false
$script:LoadHistory = @{}
$script:HistoryPath = Join-Path $script:DataDirectory 'chart-history.json'
$script:LatestStatusPath = Join-Path $script:DataDirectory 'latest-status.json'
$script:StatusLogPath = Join-Path $script:DataDirectory 'load-history.jsonl'
$script:LoginDiagLog = Join-Path $script:DataDirectory 'login-diag.log'
$script:BrowserDiagLog = Join-Path $script:DataDirectory 'browser-diag.log'
$script:UiPreferencesPath = Join-Path $script:SettingsDirectory 'ui.json'
$script:BillingRulesPath = Join-Path $script:SettingsDirectory 'billing-rules.json'
$script:BillingOverridesPath = Join-Path $script:SettingsDirectory 'billing-overrides.json'
$script:CadencePath = Join-Path $script:SettingsDirectory 'refresh-cadence.json'
$script:BillingRules = $null
# 模型负载与当日用量都来自 WebView2 看板响应；只有计费规则
# 采用四小时一次的低频读取，避免高频直连调用。
$script:BillingRefreshSeconds = 14400
$script:LastUsageFetchUtc = [DateTime]::MinValue
$script:LastBillingFetchUtc = [DateTime]::MinValue
$script:CachedStatusSnapshot = $null
$script:StatusLogWriteCount = 0
$script:LastArchivedStatusTime = [DateTime]::MinValue
$script:LastHistoryPersistUtc = [DateTime]::MinValue
$script:StatusRetentionDays = 30
$script:UiPreferences = [ordered]@{ AutoRefresh = $true; ShowExternalQuota = $false; ShowInternalQuota = $true; ChartMode = 'bar' }
$script:ChartWidth = 330.0
$script:ChartPixelBucketWidth = 4.0
$script:TimelineAges = @(18000.0, 3600.0, 1800.0, 900.0, 600.0, 300.0, 180.0, 120.0, 60.0, 50.0, 40.0, 30.0, 20.0, 10.0, 0.0)
$script:TimelineXs = @(0.0, 24.0, 52.0, 110.0, 130.0, 150.0, 170.0, 190.0, 210.0, 228.0, 250.0, 270.0, 290.0, 310.0, 330.0)
$script:ModelOrderPath = Join-Path $script:SettingsDirectory 'model-order.json'
$script:ModelOrder = [System.Collections.Generic.List[string]]::new()
$script:ModelOrderSchemaVersion = 2
$script:ModelOrderUserDefined = $false
$script:ModelOrderNeedsSave = $false
$script:DefaultModelOrderHints = @(
    'a-lanz-code-auto',
    'a-lanz-code-medium',
    'a-lanz-code-qwen36-27b'
)
$script:DisplayedModels = @()
$script:DragStartPoint = $null
$script:DragModelId = $null
$script:RefreshInProgress = $false
$script:RefreshWorker = $null
$script:ForceBillingRefreshPending = $false
$script:LastSuccessfulModelRefreshUtc = [DateTime]::MinValue
$script:BrowserReloadSeconds = 15
$script:BrowserUiRefreshSeconds = 10
$script:BrowserCaptureWindow = $null
$script:BrowserView = $null
$script:BrowserCaptureState = $null
$script:BrowserCaptureTimer = $null
$script:BrowserResponseQueue = [System.Collections.Generic.List[object]]::new()
$script:BrowserModels = $null
$script:BrowserActualModelMap = @{}
$script:BrowserUsage = $null
$script:BrowserLastModelsUtc = [DateTime]::MinValue
$script:BrowserLastUsageUtc = [DateTime]::MinValue
$script:BrowserLastUiUpdateUtc = [DateTime]::MinValue
$script:BrowserLastDataPersistUtc = [DateTime]::MinValue
$script:BrowserUiRefreshPending = $false
$script:ResumeUiTimer = $null
$script:ExitRequested = $false
$script:TrayIcon = $null
$script:TrayContextMenu = $null
$script:TrayPinMenu = $null
$script:TrayExitMenu = $null
$script:TrayOwnedIcon = $null
$script:TrayPinHandler = $null
$script:TrayExitHandler = $null
$script:TrayDoubleClickHandler = $null
$script:TrayWindowState = @{
    Hidden = $false
    LastDoubleClickUtc = [DateTime]::MinValue
}
$script:SharedHttpHandler = $null
$script:SharedHttpClient = $null
$script:UpdateWorker = $null
$script:UpdateInProgress = $false
$script:PendingUpdate = $null

$legacyStateFiles = [ordered]@{
    '.lanz-session.bin' = $script:SessionPath
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
        $savedModelOrder = Get-Content -LiteralPath $script:ModelOrderPath -Raw -Encoding UTF8 | ConvertFrom-Json
        # v1 used a bare JSON array and could preserve malformed drag payloads. Treat it as
        # a legacy default so this release can establish the requested Auto/Medium/Flash
        # order once. v2 is explicit and remains user-controlled after any drag operation.
        if ($null -ne $savedModelOrder.PSObject.Properties['Version'] -and
            [int]$savedModelOrder.Version -ge $script:ModelOrderSchemaVersion -and
            $null -ne $savedModelOrder.PSObject.Properties['Order']) {
            if ($null -ne $savedModelOrder.PSObject.Properties['UserDefined']) {
                $script:ModelOrderUserDefined = [bool]$savedModelOrder.UserDefined
            }
            else {
                $script:ModelOrderNeedsSave = $true
            }
            $seenModelIds = @{}
            foreach ($modelIdValue in @($savedModelOrder.Order)) {
                $modelId = [string]$modelIdValue
                if ($modelId -match '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$' -and -not $seenModelIds.ContainsKey($modelId)) {
                    $script:ModelOrder.Add($modelId)
                    $seenModelIds[$modelId] = $true
                }
            }
        }
    }
}
catch {
    $script:ModelOrder.Clear()
}

try {
    if (Test-Path -LiteralPath $script:UiPreferencesPath) {
        $savedUiPreferences = Get-Content -LiteralPath $script:UiPreferencesPath -Raw -Encoding UTF8 | ConvertFrom-Json
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
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$script:Configuration = [pscustomobject][ordered]@{
    ApiEndpoint = 'https://lanz.hikvision.com/v1/openai/models'
    UsageEndpoint = 'https://lanz.hikvision.com/v1/ai-resource/dashboard'
    UsageDashboardUrl = 'https://lanz.hikvision.com/resource/dashboard'
    LoginUrl = 'https://lanz.hikvision.com/'
    SessionCookieName = 'nsession_id'
    SuccessCode = 2001
    UnauthorizedCode = 3001
}
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
        throw [System.UnauthorizedAccessException]::new('未找到有效会话，需要在内置登录窗口中完成验证。')
    }

    $protectedBytes = [System.IO.File]::ReadAllBytes($script:SessionPath)
    $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $protectedBytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    $sessionValue = [System.Text.Encoding]::UTF8.GetString($plainBytes).Trim()
    if ([string]::IsNullOrWhiteSpace($sessionValue) -or $sessionValue -eq '0') {
        throw [System.UnauthorizedAccessException]::new('会话已过期，需要重新验证。')
    }
    return $sessionValue
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

function Add-LanZBrowserHeaders {
    param(
        [Parameter(Mandatory)][System.Net.Http.HttpRequestMessage]$Request,
        [switch]$ForScript
    )

    # 仅供计费规则的低频看板读取使用。模型负载和额度只监听页面自身请求。
    # 不手工设置 User-Agent，也不伪造 Sec-Fetch/Client-Hints。
    $accept = if ($ForScript) { '*/*' } else { 'application/json, text/plain, */*' }
    [void]$Request.Headers.TryAddWithoutValidation('Accept', $accept)
    [void]$Request.Headers.TryAddWithoutValidation('Accept-Language', 'zh-CN,zh;q=0.9,en;q=0.8')
}

function ConvertTo-LanZModels {
    param(
        [Parameter(Mandatory)][array]$Data,
        [hashtable]$ActualModelMap
    )

    return @($Data | ForEach-Object {
        $modelName = [string]$_.modelName
        $actualModel = ''
        if ($null -ne $ActualModelMap -and $ActualModelMap.ContainsKey($modelName)) {
            $actualModel = [string]$ActualModelMap[$modelName]
        }
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
            Name      = $modelName
            ModelId   = [string]$_.apiInterface
            ActualModel = $actualModel
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

function Get-LanZAuthenticatedText {
    param(
        [Parameter(Mandatory)][Uri]$Uri,
        [Parameter(Mandatory)][string]$SessionValue,
        [System.Net.Http.HttpClient]$HttpClient
    )

    $ownsClient = $null -eq $HttpClient
    $handler = $null
    if ($ownsClient) {
        $handler = [System.Net.Http.HttpClientHandler]::new()
        # 当前内网 TLS 代理无法可靠查询 CRL；这里只关闭吊销列表查询，
        # 不改写服务器证书回调，主机名、有效期和证书链仍由 .NET 校验。
        $handler.CheckCertificateRevocationList = $false
        $handler.UseCookies = $false
        $HttpClient = [System.Net.Http.HttpClient]::new($handler)
        $HttpClient.Timeout = [TimeSpan]::FromSeconds(8)
    }
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Uri)
    $response = $null
    try {
        [void]$request.Headers.TryAddWithoutValidation('Cookie', "$($script:SessionCookieName)=$SessionValue")
        Add-LanZBrowserHeaders -Request $request -ForScript
        $response = $HttpClient.SendAsync($request).GetAwaiter().GetResult()
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
        if ($null -ne $response) {
            $response.Dispose()
        }
        $request.Dispose()
        if ($ownsClient) {
            $HttpClient.Dispose()
            $handler.Dispose()
        }
    }
}

function Import-LanZRefreshCadence {
    # 读取上次用量/规则刷新时间,用于在 worker 内决定是否低频调用。
    # 文件缺失或损坏时回退到 MinValue,触发首次调用。
    try {
        if (Test-Path -LiteralPath $script:CadencePath) {
            $cached = Get-Content -LiteralPath $script:CadencePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $cached.LastUsageFetch) {
                $script:LastUsageFetchUtc = [DateTime]::Parse(
                    [string]$cached.LastUsageFetch,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind
                ).ToUniversalTime()
            }
            if ($null -ne $cached.LastBillingFetch) {
                $script:LastBillingFetchUtc = [DateTime]::Parse(
                    [string]$cached.LastBillingFetch,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind
                ).ToUniversalTime()
            }
        }
    }
    catch {
        $script:LastUsageFetchUtc = [DateTime]::MinValue
        $script:LastBillingFetchUtc = [DateTime]::MinValue
    }
}

function Save-LanZRefreshCadence {
    param(
        [switch]$UsageUpdated,
        [switch]$BillingUpdated
    )
    try {
        if ($UsageUpdated) {
            $script:LastUsageFetchUtc = [DateTime]::UtcNow
        }
        if ($BillingUpdated) {
            $script:LastBillingFetchUtc = [DateTime]::UtcNow
        }
        $cadence = [ordered]@{
            LastUsageFetch = if ($script:LastUsageFetchUtc -ne [DateTime]::MinValue) { $script:LastUsageFetchUtc.ToString('o') } else { $null }
            LastBillingFetch = if ($script:LastBillingFetchUtc -ne [DateTime]::MinValue) { $script:LastBillingFetchUtc.ToString('o') } else { $null }
        }
        [IO.File]::WriteAllText($script:CadencePath, ($cadence | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    }
    catch {
        # 节奏持久化失败不影响实时刷新,下次按内存时间继续。
    }
}

function Import-LanZBillingRulesCache {
    if ($null -ne $script:BillingRules) {
        return $script:BillingRules
    }
    try {
        if (Test-Path -LiteralPath $script:BillingRulesPath) {
            $cached = Get-Content -LiteralPath $script:BillingRulesPath -Raw -Encoding UTF8 | ConvertFrom-Json
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
    param(
        [Parameter(Mandatory)][string]$SessionValue,
        [System.Net.Http.HttpClient]$HttpClient,
        [switch]$Force
    )

    # 手动覆盖文件优先级最高:用户可手写规则,在前端改版导致自动抓取失效时兜底。
    # 文件格式与 billing-rules.json 相同(FetchedAt/ScheduleText/WeekendFree/Intervals)。
    # 覆盖文件存在且有效时,直接返回,不再抓取网页。
    try {
        if (Test-Path -LiteralPath $script:BillingOverridesPath) {
            $override = Get-Content -LiteralPath $script:BillingOverridesPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (@($override.Intervals).Count -gt 0) {
                $script:BillingRules = $override
                return $override
            }
        }
    }
    catch {
        # 覆盖文件损坏则忽略,回退到自动抓取。
    }

    $cached = Import-LanZBillingRulesCache
    if ($null -ne $cached -and -not $Force) {
        try {
            $fetchedAt = [DateTime]::Parse(
                [string]$cached.FetchedAt,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind
            ).ToUniversalTime()
            $billingWindow = if ($null -ne $script:BillingRefreshSeconds) { [int]$script:BillingRefreshSeconds } else { 14400 }
            if (([DateTime]::UtcNow - $fetchedAt).TotalSeconds -lt $billingWindow) {
                return $cached
            }
        }
        catch {
            # An old cache is still a safe fallback if refreshing the source fails.
        }
    }

    try {
        $dashboardUri = [Uri]$script:UsageDashboardUrl
        $dashboardHtml = Get-LanZAuthenticatedText -Uri $dashboardUri -SessionValue $SessionValue -HttpClient $HttpClient
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

        $runtimeText = Get-LanZAuthenticatedText -Uri $runtimeUri -SessionValue $SessionValue -HttpClient $HttpClient
        $appText = Get-LanZAuthenticatedText -Uri $appUri -SessionValue $SessionValue -HttpClient $HttpClient
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
            $chunkText = Get-LanZAuthenticatedText -Uri $chunkUri -SessionValue $SessionValue -HttpClient $HttpClient
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

function Update-LanZLocalQuotaStatus {
    # 规则同步和时段判断是两件事：规则可以低频抓取，但当前免费/计费
    # 状态必须使用本地时间高频重算。此函数只更新绑定，不产生网络流量。
    $overview = $script:BrowserUsage
    if ($null -eq $overview -and $null -ne $script:CachedStatusSnapshot) {
        $overview = $script:CachedStatusSnapshot.Usage
    }
    if ($null -eq $overview) {
        return
    }
    if ($null -eq $script:BillingRules) {
        $script:BillingRules = Import-LanZBillingRulesCache
    }
    $usageCard.DataContext = New-LanZQuotaViewModel -Overview $overview -BillingRules $script:BillingRules
}

if ($Once) {
    if (-not (Test-Path -LiteralPath $script:LatestStatusPath)) {
        throw '尚无本地状态快照，请先正常启动一次应用并完成登录。'
    }
    Get-Content -LiteralPath $script:LatestStatusPath -Raw -Encoding UTF8
    exit 0
}

# HttpClient 仅用于计费规则的低频看板读取，模型负载和额度不使用它。
# 复用连接池和 TLS 会话，避免每次低频同步都新建 handler/连接。
$script:SharedHttpHandler = [System.Net.Http.HttpClientHandler]::new()
$script:SharedHttpHandler.CheckCertificateRevocationList = $false
$script:SharedHttpHandler.UseCookies = $false
$script:SharedHttpClient = [System.Net.Http.HttpClient]::new($script:SharedHttpHandler)
$script:SharedHttpClient.Timeout = [TimeSpan]::FromSeconds(8)

$createdNew = $false
$singleInstanceMutex = [System.Threading.Mutex]::new(
    $true,
    'Local\LanZLoadMonitorWidget',
    [ref]$createdNew
)
if (-not $createdNew) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][Windows.Forms.MessageBox]::Show(
            'LanZ Monitor 已在系统托盘运行，请勿重复启动。可双击托盘图标显示窗口。',
            'LanZ Monitor',
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Information
        )
    }
    catch {
        # 即使提示框不可用，第二个实例也必须安静退出。
    }
    $singleInstanceMutex.Dispose()
    $script:SharedHttpClient.Dispose()
    $script:SharedHttpHandler.Dispose()
    exit 0
}

try {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

function Initialize-LanZHistory {
    if (-not (Test-Path -LiteralPath $script:HistoryPath)) {
        return
    }

    try {
        $payload = Get-Content -LiteralPath $script:HistoryPath -Raw -Encoding UTF8 | ConvertFrom-Json
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
            $script:CachedStatusSnapshot = Get-Content -LiteralPath $script:LatestStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
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
                ActualModel = if ($null -ne $_.PSObject.Properties['ActualModel']) { [string]$_.ActualModel } else { '' }
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
        $compactedHistory = [System.Collections.Generic.List[object]]::new()
        $serializedSamples = [System.Collections.Generic.List[object]]::new()
        foreach ($sample in $storedSamples) {
            $sampleTimestamp = $sample.Timestamp.ToUniversalTime()
            $sampleEndTimestamp = if ($null -ne $sample.PSObject.Properties['EndTimestamp'] -and $sample.EndTimestamp -is [DateTime]) {
                $sample.EndTimestamp.ToUniversalTime()
            }
            else {
                $sampleTimestamp
            }
            # 文件中保存的是降采样结果，内存也必须同步替换为同一份有界
            # 数据；否则长时间运行会继续积累每 3 秒一个的原始点，导致
            # 每次绘图遍历越来越慢，而重启后又因读取压缩文件暂时恢复。
            $compactedHistory.Add([pscustomobject]@{
                Timestamp = $sampleTimestamp
                EndTimestamp = $sampleEndTimestamp
                Percent = [int]$sample.Percent
            })
            $serializedSamples.Add([ordered]@{
                Timestamp = $sampleTimestamp.ToString('o')
                EndTimestamp = $sampleEndTimestamp.ToString('o')
                Percent = [int]$sample.Percent
            })
        }
        $script:LoadHistory[$key] = $compactedHistory
        $payload[$key] = @($serializedSamples)
    }
    [System.IO.File]::WriteAllText(
        $script:HistoryPath,
        ($payload | ConvertTo-Json -Depth 5 -Compress),
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Add-LanZHistorySamples {
    param(
        [Parameter(Mandatory)][array]$Models,
        [DateTime]$SampleTimestamp = [DateTime]::UtcNow,
        [DateTime]$Now = [DateTime]::UtcNow,
        [switch]$SkipSample
    )

    $sampleTime = $SampleTimestamp.ToUniversalTime()
    $cutoff = $Now.ToUniversalTime().AddHours(-5)
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
    }
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
    Add-LanZHistorySamples -Models $Models -SampleTimestamp $sampleTime -Now $now -SkipSample:$SkipSample
    foreach ($model in $Models) {
        $key = [string]$model.ModelId
        $history = $script:LoadHistory[$key]

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

    if (-not $SkipPersistence -and
        ([DateTime]::UtcNow - $script:LastHistoryPersistUtc).TotalSeconds -ge 10) {
        try {
            Save-LanZHistory
            $script:LastHistoryPersistUtc = [DateTime]::UtcNow
        }
        catch {
            # History persistence is optional; a write failure must not stop live monitoring.
        }
    }
    return $Models
}

Initialize-LanZHistory
if ($script:LoadHistory.Count -gt 0) {
    try {
        # 启动时立即迁移旧版本遗留的密集采样，而不是等待下一次状态包。
        Save-LanZHistory
        $script:LastHistoryPersistUtc = [DateTime]::UtcNow
    }
    catch {
        # 历史迁移失败不阻断主程序；后续正常采样仍会再次尝试压缩。
    }
}
Initialize-LanZStatusSnapshot
Import-LanZRefreshCadence
[void](Import-LanZBillingRulesCache)

function Save-LanZModelOrder {
    $payload = [ordered]@{
        Version = $script:ModelOrderSchemaVersion
        UserDefined = [bool]$script:ModelOrderUserDefined
        Order = @($script:ModelOrder)
    }
    $json = ConvertTo-Json -InputObject $payload -Depth 3 -Compress
    [System.IO.File]::WriteAllText($script:ModelOrderPath, $json, [System.Text.UTF8Encoding]::new($false))
    $script:ModelOrderNeedsSave = $false
}

function Sort-LanZModels {
    param([Parameter(Mandatory)][array]$Models)

    $orderChanged = $false
    # A saved v2 order is authoritative. On first run/migration, seed it with the
    # current preferred IDs and then append every unknown model in server order.
    # Missing preferred IDs are simply ignored; future models never need code changes.
    if (-not $script:ModelOrderUserDefined) {
        $availableIds = @{}
        foreach ($model in $Models) {
            $modelId = [string]$model.ModelId
            if (-not [string]::IsNullOrWhiteSpace($modelId)) {
                $availableIds[$modelId] = $true
            }
        }
        $defaultOrder = [System.Collections.Generic.List[string]]::new()
        $defaultSeen = @{}
        foreach ($hint in $script:DefaultModelOrderHints) {
            if ($availableIds.ContainsKey($hint)) {
                $defaultOrder.Add($hint)
                $defaultSeen[$hint] = $true
            }
        }
        foreach ($model in $Models) {
            $modelId = [string]$model.ModelId
            if (-not [string]::IsNullOrWhiteSpace($modelId) -and -not $defaultSeen.ContainsKey($modelId)) {
                $defaultOrder.Add($modelId)
                $defaultSeen[$modelId] = $true
            }
        }
        if (($script:ModelOrder -join "`n") -ne ($defaultOrder -join "`n")) {
            $script:ModelOrder.Clear()
            foreach ($modelId in $defaultOrder) {
                $script:ModelOrder.Add($modelId)
            }
            $orderChanged = $true
        }
    }

    $orderIndex = @{}
    for ($index = 0; $index -lt $script:ModelOrder.Count; $index++) {
        $modelId = [string]$script:ModelOrder[$index]
        if (-not [string]::IsNullOrWhiteSpace($modelId) -and -not $orderIndex.ContainsKey($modelId)) {
            $orderIndex[$modelId] = $index
        }
    }

    foreach ($model in $Models) {
        $modelId = [string]$model.ModelId
        if (-not [string]::IsNullOrWhiteSpace($modelId) -and -not $orderIndex.ContainsKey($modelId)) {
            $orderIndex[$modelId] = $script:ModelOrder.Count
            $script:ModelOrder.Add($modelId)
            $orderChanged = $true
        }
    }
    if ($orderChanged -or $script:ModelOrderNeedsSave -or -not (Test-Path -LiteralPath $script:ModelOrderPath)) {
        Save-LanZModelOrder
    }

    return @($Models | Sort-Object @{ Expression = {
        $modelId = [string]$_.ModelId
        if ($orderIndex.ContainsKey($modelId)) { $orderIndex[$modelId] } else { [int]::MaxValue }
    } })
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
        Topmost="True" ShowInTaskbar="False"
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
                <ToggleButton x:Name="SettingsButton" Grid.Column="3" Content="&#xE713;" FontFamily="Segoe Fluent Icons" Width="30" Height="25" FontSize="15" Style="{StaticResource AutoToggleStyle}" ToolTip="设置"/>
                <Button x:Name="CloseButton" Grid.Column="4" Content="×" FontSize="20" Foreground="#536675" Background="Transparent" BorderThickness="0" Cursor="Hand" ToolTip="隐藏到托盘"/>
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
                                <TextBlock Grid.Row="1" Grid.ColumnSpan="2" Text="{Binding ActualModel}" FontSize="11" FontWeight="Normal" Foreground="#87949E" TextTrimming="CharacterEllipsis" ToolTip="{Binding ActualModel}"/>
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
                        <CheckBox x:Name="AutoRefreshToggle" Content="自动刷新（跟随网页，约 3 秒）" IsChecked="True" FontSize="11" Foreground="#536675" Margin="2,4" Cursor="Hand"/>
                        <CheckBox x:Name="ShowExternalQuotaToggle" Content="显示外网模型额度" IsChecked="False" FontSize="11" Foreground="#536675" Margin="2,4" Cursor="Hand"/>
                        <CheckBox x:Name="ShowInternalQuotaToggle" Content="显示内网模型额度" IsChecked="True" FontSize="11" Foreground="#536675" Margin="2,4" Cursor="Hand"/>
                        <StackPanel Orientation="Horizontal" Margin="2,5,0,0">
                            <TextBlock Text="图表模式" FontSize="11" Foreground="#536675" VerticalAlignment="Center" Margin="0,0,8,0"/>
                            <RadioButton x:Name="BarChartToggle" Content="柱状图" GroupName="ChartMode" IsChecked="True" FontSize="11" Foreground="#536675" Margin="0,0,9,0" Cursor="Hand"/>
                            <RadioButton x:Name="LineChartToggle" Content="折线图" GroupName="ChartMode" IsChecked="False" FontSize="11" Foreground="#536675" Cursor="Hand"/>
                        </StackPanel>
                        <Separator Margin="0,7,0,7" Background="#E7ECEF"/>
                        <Button x:Name="LoginButton" Content="重新登录 / 切换凭据" Height="29" FontSize="11" Foreground="#5A47E5" Background="#F0EEFF" BorderBrush="#D9D3FF" Cursor="Hand"/>
                        <Button x:Name="UpdateButton" Content="检查更新" Height="29" Margin="0,7,0,0" FontSize="11" Foreground="#356A5A" Background="#EAF7F2" BorderBrush="#BCE4D4" Cursor="Hand"/>
                        <TextBlock x:Name="UpdateStatusText" Text="当前版本 v1.4.3" Margin="2,6,2,0" FontSize="9" Foreground="#87949E" TextWrapping="Wrap"/>
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
$updateButton = $window.FindName('UpdateButton')
$updateStatusText = $window.FindName('UpdateStatusText')
$autoRefreshToggle.IsChecked = [bool]$script:UiPreferences.AutoRefresh
$showExternalQuotaToggle.IsChecked = [bool]$script:UiPreferences.ShowExternalQuota
$showInternalQuotaToggle.IsChecked = [bool]$script:UiPreferences.ShowInternalQuota
$barChartToggle.IsChecked = $script:UiPreferences.ChartMode -eq 'bar'
$lineChartToggle.IsChecked = $script:UiPreferences.ChartMode -eq 'line'

function Import-LanZWebView2Runtime {
    $requiredFiles = @(
        'Microsoft.Web.WebView2.Core.dll',
        'Microsoft.Web.WebView2.Wpf.dll',
        'WebView2Loader.dll'
    )

    # 源码运行时直接使用仓库依赖。单文件 EXE 则把 ps2exe 的固定释放目录
    # 仅当作未加载的 payload，再复制到按内容哈希区分的实际加载目录。
    # 因此重复双击时，第二个进程可以安全覆盖 payload，并在互斥锁检查后
    # 退出，不会尝试覆盖第一个实例已经加载并锁定的 WebView2Loader.dll。
    $sourceDirectory = Join-Path $script:AppDirectory 'lib\WebView2'
    $sourceReady = @($requiredFiles | ForEach-Object { Test-Path -LiteralPath (Join-Path $sourceDirectory $_) }) -notcontains $false
    if ($sourceReady) {
        $webViewDirectory = $sourceDirectory
    }
    else {
        $payloadDirectory = Join-Path $script:RuntimeDirectory 'WebView2Payload'
        $payloadReady = @($requiredFiles | ForEach-Object { Test-Path -LiteralPath (Join-Path $payloadDirectory $_) }) -notcontains $false
        if (-not $payloadReady) {
            throw '缺少 WebView2 组件，请重新获取完整程序。'
        }

        $componentHashes = foreach ($fileName in $requiredFiles) {
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                $bytes = [IO.File]::ReadAllBytes((Join-Path $payloadDirectory $fileName))
                ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
            }
            finally {
                $sha.Dispose()
            }
        }
        $manifestSha = [Security.Cryptography.SHA256]::Create()
        try {
            $manifestBytes = [Text.Encoding]::UTF8.GetBytes(($componentHashes -join ':'))
            $fingerprint = ([BitConverter]::ToString($manifestSha.ComputeHash($manifestBytes))).Replace('-', '').Substring(0, 16)
        }
        finally {
            $manifestSha.Dispose()
        }

        $webViewDirectory = Join-Path (Join-Path $script:RuntimeDirectory 'WebView2') $fingerprint
        [void][IO.Directory]::CreateDirectory($webViewDirectory)
        foreach ($fileName in $requiredFiles) {
            $payloadPath = Join-Path $payloadDirectory $fileName
            $runtimePath = Join-Path $webViewDirectory $fileName
            $copyRequired = -not (Test-Path -LiteralPath $runtimePath)
            if (-not $copyRequired) {
                $copyRequired = (Get-Item -LiteralPath $payloadPath).Length -ne (Get-Item -LiteralPath $runtimePath).Length
            }
            if ($copyRequired) {
                Copy-Item -LiteralPath $payloadPath -Destination $runtimePath -Force
            }
        }
    }

    $coreAssembly = Join-Path $webViewDirectory 'Microsoft.Web.WebView2.Core.dll'
    $wpfAssembly = Join-Path $webViewDirectory 'Microsoft.Web.WebView2.Wpf.dll'
    $loaderAssembly = Join-Path $webViewDirectory 'WebView2Loader.dll'
    if (-not (Test-Path -LiteralPath $coreAssembly) -or -not (Test-Path -LiteralPath $wpfAssembly) -or -not (Test-Path -LiteralPath $loaderAssembly)) {
        throw 'WebView2 组件准备失败，请重新获取完整程序。'
    }

    $env:PATH = "$webViewDirectory;$env:PATH"
    if ($null -eq ('Microsoft.Web.WebView2.Core.CoreWebView2Environment' -as [type])) {
        Add-Type -Path $coreAssembly
    }
    if ($null -eq ('Microsoft.Web.WebView2.Wpf.WebView2' -as [type])) {
        Add-Type -Path $wpfAssembly
    }
    return $webViewDirectory
}

function Update-LanZFromBrowserCapture {
    param([switch]$DataOnly)

    if ($null -eq $script:BrowserModels) {
        return
    }

    $overview = $script:BrowserUsage
    if ($null -eq $overview -and $null -ne $script:CachedStatusSnapshot) {
        $overview = $script:CachedStatusSnapshot.Usage
    }
    if ($null -eq $overview) {
        return
    }

    $models = @($script:BrowserModels)
    if ($DataOnly) {
        Add-LanZHistorySamples -Models $models
        if (([DateTime]::UtcNow - $script:LastHistoryPersistUtc).TotalSeconds -ge 10) {
            try {
                Save-LanZHistory
                $script:LastHistoryPersistUtc = [DateTime]::UtcNow
            }
            catch { }
        }
        try {
            Save-LanZStatusSnapshot -Models $models -Overview $overview
        }
        catch { }
        $script:BrowserLastDataPersistUtc = [DateTime]::UtcNow
        return
    }

    $modelsWithHistory = @(Add-LanZChartHistory -Models $models)
    $script:DisplayedModels = @(Sort-LanZModels -Models $modelsWithHistory)
    $modelsList.ItemsSource = $script:DisplayedModels
    Update-LanZLocalQuotaStatus
    try {
        Save-LanZStatusSnapshot -Models $models -Overview $overview
    }
    catch {
        # 浏览器数据仍可实时显示；本地快照失败不阻断同步。
    }
    $script:LastSuccessfulModelRefreshUtc = [DateTime]::UtcNow
    $script:BrowserLastUiUpdateUtc = [DateTime]::UtcNow
    $script:BrowserLastDataPersistUtc = [DateTime]::UtcNow
    $updatedText.Text = '浏览器同步 ' + (Get-Date).ToString('HH:mm:ss')
    $updatedText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#8694A0')
}

function Set-LanZActualModelMappings {
    param([Parameter(Mandatory)][array]$Mappings)

    $validRows = @($Mappings | Where-Object {
        $null -ne $_ -and
        $null -ne $_.PSObject.Properties['ProductName'] -and
        -not [string]::IsNullOrWhiteSpace([string]$_.ProductName)
    })
    if ($validRows.Count -eq 0) {
        return $false
    }

    $newMap = @{}
    foreach ($mapping in $validRows) {
        $productName = ([string]$mapping.ProductName).Trim()
        $actualModel = if ($null -ne $mapping.PSObject.Properties['ActualModel']) {
            ([string]$mapping.ActualModel).Trim()
        }
        else {
            ''
        }
        # UI text only: discard unexpectedly large/multiline values instead of allowing
        # a page change to disturb the card layout. An empty value is intentionally valid.
        if ($productName.Length -le 128 -and $actualModel.Length -le 160 -and $actualModel -notmatch '[\r\n]') {
            $newMap[$productName] = $actualModel
        }
    }
    if ($newMap.Count -eq 0) {
        return $false
    }

    $script:BrowserActualModelMap = $newMap
    foreach ($model in @($script:BrowserModels) + @($script:DisplayedModels)) {
        if ($null -eq $model -or $null -eq $model.PSObject.Properties['Name']) {
            continue
        }
        $actualModel = ''
        $productName = [string]$model.Name
        if ($newMap.ContainsKey($productName)) {
            $actualModel = [string]$newMap[$productName]
        }
        $model | Add-Member -NotePropertyName ActualModel -NotePropertyValue $actualModel -Force
    }
    if ($null -ne $modelsList -and $script:DisplayedModels.Count -gt 0) {
        $modelsList.Items.Refresh()
    }
    return $true
}

function Complete-LanZBrowserResponses {
    for ($index = $script:BrowserResponseQueue.Count - 1; $index -ge 0; $index--) {
        $entry = $script:BrowserResponseQueue[$index]
        if (-not $entry.Task.IsCompleted) {
            continue
        }
        $script:BrowserResponseQueue.RemoveAt($index)
        if ($entry.Task.IsFaulted -or $entry.Task.IsCanceled) {
            Write-LanZBrowserDiag ('response task failed kind={0}' -f $entry.Kind)
            continue
        }

        $stream = $null
        $reader = $null
        try {
            $stream = $entry.Task.GetAwaiter().GetResult()
            if ($null -eq $stream) {
                continue
            }
            $reader = [IO.StreamReader]::new($stream)
            $content = $reader.ReadToEnd()
            $trimmed = $content.TrimStart()
            if ($trimmed.Length -eq 0 -or $trimmed[0] -ne '{') {
                continue
            }
            $payload = $content | ConvertFrom-Json
            if ([int]$payload.code -ne [int]$script:Configuration.SuccessCode) {
                continue
            }

            if ($entry.Kind -eq 'models') {
                $script:BrowserModels = @(ConvertTo-LanZModels -Data @($payload.data) -ActualModelMap $script:BrowserActualModelMap)
                $script:BrowserLastModelsUtc = [DateTime]::UtcNow
                if ($null -ne $script:BrowserCaptureState -and $script:BrowserCaptureState.AtMonitorPage) {
                    $script:BrowserCaptureState.MonitorPanelReady = $true
                }
                # 页面约每 3 秒返回一次状态包，但图表设计粒度是 10 秒。
                # 每个响应都更新内存中的最新模型，UI/历史最多每 10 秒重绘
                # 一次；手动刷新和首次捕获仍立即呈现。
                $manualRefreshActive = $null -ne $script:BrowserCaptureState -and [bool]$script:BrowserCaptureState.ManualRefreshActive
                $uiRefreshDue = $script:BrowserLastUiUpdateUtc -eq [DateTime]::MinValue -or
                    ([DateTime]::UtcNow - $script:BrowserLastUiUpdateUtc).TotalSeconds -ge $script:BrowserUiRefreshSeconds
                $windowHidden = [bool]$script:TrayWindowState.Hidden -or -not $window.IsVisible
                if ($windowHidden) {
                    $script:BrowserUiRefreshPending = $true
                    $dataPersistDue = $script:BrowserLastDataPersistUtc -eq [DateTime]::MinValue -or
                        ([DateTime]::UtcNow - $script:BrowserLastDataPersistUtc).TotalSeconds -ge $script:BrowserUiRefreshSeconds
                    if ($dataPersistDue) {
                        Update-LanZFromBrowserCapture -DataOnly
                    }
                }
                elseif ($manualRefreshActive -or $uiRefreshDue) {
                    Update-LanZFromBrowserCapture
                }
                if ($null -ne $script:BrowserCaptureState -and -not $script:BrowserCaptureState.FirstCaptureLogged) {
                    $script:BrowserCaptureState.FirstCaptureLogged = $true
                    Write-LanZBrowserDiag ('initial capture ready models={0}' -f @($script:BrowserModels).Count)
                }
            }
            elseif ($entry.Kind -eq 'usage' -and $null -ne $payload.data.overview) {
                $script:BrowserUsage = $payload.data.overview
                $script:BrowserLastUsageUtc = [DateTime]::UtcNow
                Save-LanZRefreshCadence -UsageUpdated
                if ([bool]$script:TrayWindowState.Hidden -or -not $window.IsVisible) {
                    $script:BrowserUiRefreshPending = $true
                    Update-LanZFromBrowserCapture -DataOnly
                }
                else {
                    Update-LanZFromBrowserCapture
                }
            }
        }
        catch {
            # 某个响应读取失败时保留缓存，等待页面下一次正常响应或低频回退。
            Write-LanZBrowserDiag ('response parse failed kind={0} error={1}' -f $entry.Kind, $_.Exception.GetBaseException().Message)
        }
        finally {
            if ($null -ne $reader) {
                $reader.Dispose()
            }
            elseif ($null -ne $stream) {
                $stream.Dispose()
            }
        }
    }
}

function Step-LanZBrowserCapture {
    $state = $script:BrowserCaptureState
    if ($null -eq $state -or $null -eq $script:BrowserView) {
        return
    }

    try {
        if ($state.Stage -eq 'ensure') {
            if (-not $state.EnsureTask.IsCompleted) {
                return
            }
            if ($state.EnsureTask.IsFaulted) {
                throw $state.EnsureTask.Exception.GetBaseException()
            }

            $core = $script:BrowserView.CoreWebView2
            Write-LanZBrowserDiag 'webview ensure completed'
            $core.Settings.AreDevToolsEnabled = $false
            $core.Settings.AreDefaultContextMenusEnabled = $false
            $core.Settings.IsPasswordAutosaveEnabled = $false
            $core.Settings.IsGeneralAutofillEnabled = $false

            # GetNewClosure() 会创建动态模块，其中的 $script: 不再指向主脚本。
            # 显式捕获队列引用，避免响应任务在事件闭包中静默丢失。
            $browserResponseQueue = $script:BrowserResponseQueue
            $responseHandler = ({
                param($sender, $eventArgs)
                try {
                    $requestUri = [Uri][string]$eventArgs.Request.Uri
                    $kind = $null
                    if ($requestUri.Host -eq $state.EndpointHost -and $requestUri.AbsolutePath -eq $state.ModelPath) {
                        $kind = 'models'
                    }
                    elseif ($requestUri.Host -eq $state.EndpointHost -and $requestUri.AbsolutePath -eq $state.UsagePath) {
                        $kind = 'usage'
                    }
                    if ($null -ne $kind -and [int]$eventArgs.Response.StatusCode -in @(401, 403)) {
                        # 交给 UI 计时器统一弹出登录窗，避免在 WebView2 网络事件
                        # 回调中关闭当前监听窗口造成重入。
                        $state.SignedOut = $true
                        if ($state.SignedOutSinceUtc -eq [DateTime]::MinValue) {
                            $state.SignedOutSinceUtc = [DateTime]::UtcNow
                        }
                        return
                    }
                    if ($null -ne $kind -and [int]$eventArgs.Response.StatusCode -eq 200) {
                        $contentTask = $eventArgs.Response.GetContentAsync()
                        $browserResponseQueue.Add([pscustomobject]@{
                            Kind = $kind
                            Task = $contentTask
                        })
                    }
                }
                catch {
                    # 仅监听目标 JSON 响应，其他页面资源一律忽略。
                }
            }).GetNewClosure()
            $state.ResponseHandler = $responseHandler
            $core.add_WebResourceResponseReceived($responseHandler)
            $core.AddWebResourceRequestedFilter('*', [Microsoft.Web.WebView2.Core.CoreWebView2WebResourceContext]::All)

            $navigationHandler = ({
                param($sender, $eventArgs)
                try {
                    if ($eventArgs.IsSuccess) {
                        $sourceUri = [Uri][string]$sender.CoreWebView2.Source
                        if ($sourceUri.Scheme -in @('http', 'https')) {
                            # 过期会话既可能跳转到独立 SSO 域，也可能停在服务域
                            # 自身的 /login 页面；两种情况都应进入重新验证流程。
                            $isLoginPath = $sourceUri.AbsolutePath -match '^/(login|auth)(/|$)'
                            $state.SignedOut = $sourceUri.Host -ne $state.EndpointHost -or $isLoginPath
                            if ($state.SignedOut) {
                                if ($state.SignedOutSinceUtc -eq [DateTime]::MinValue) {
                                    $state.SignedOutSinceUtc = [DateTime]::UtcNow
                                }
                                Write-LanZBrowserDiag ('navigation left service path={0}' -f $sourceUri.AbsolutePath)
                            }
                            else {
                                $state.SignedOutSinceUtc = [DateTime]::MinValue
                                $state.AtMonitorPage = $sourceUri.AbsolutePath -eq ([Uri]$state.MonitorUri).AbsolutePath
                                if ($state.AtMonitorPage) {
                                    $state.MonitorPanelReady = $false
                                    $state.PanelScriptTask = $null
                                    $state.PanelNextAttemptUtc = [DateTime]::UtcNow
                                    $state.ModelMetadataTask = $null
                                    $state.ModelMetadataNextAttemptUtc = [DateTime]::UtcNow
                                }
                            }
                        }
                    }
                }
                catch { }
            }).GetNewClosure()
            $state.NavigationHandler = $navigationHandler
            $script:BrowserView.add_NavigationCompleted($navigationHandler)

            $sessionValue = Get-LanZSessionValue
            try {
                $cookie = $core.CookieManager.CreateCookie($state.CookieName, $sessionValue, $state.EndpointHost, '/')
                $cookie.IsHttpOnly = $true
                $cookie.IsSecure = $true
                $core.CookieManager.AddOrUpdateCookie($cookie)
            }
            finally {
                $sessionValue = $null
            }

            $core.Navigate($state.NavigationUri)
            Write-LanZBrowserDiag ('navigate dashboard path={0}' -f ([Uri]$state.NavigationUri).AbsolutePath)
            $state.Stage = 'bootstrap'
            return
        }

        if ($state.SignedOut -and
            $state.SignedOutSinceUtc -ne [DateTime]::MinValue -and
            ([DateTime]::UtcNow - $state.SignedOutSinceUtc).TotalMilliseconds -ge 750) {
            if (-not $script:LoginWindowOpen -and
                -not $script:SuppressAutoLogin -and
                -not [bool]$state.LoginPromptQueued) {
                $state.LoginPromptQueued = $true
                $updatedText.Text = '会话已过期，正在打开登录窗口…'
                $updatedText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#E6A23C')
                Write-LanZBrowserDiag 'session expired; login prompt queued'
                # 延迟到当前捕获 Tick 结束后再关闭隐藏 WebView2 并打开登录窗，
                # 防止 NavigationCompleted/响应事件回调与 Dispose 相互重入。
                [void]$window.Dispatcher.BeginInvoke([Action]{
                    if (-not $script:LoginWindowOpen -and -not $script:SuppressAutoLogin) {
                        Show-LanZLogin
                    }
                })
            }
            return
        }

        if ($state.Stage -eq 'bootstrap') {
            Complete-LanZBrowserResponses
            $bootstrapReady = if ($state.ManualRefreshActive) {
                # 手动刷新必须等到资源看板返回一个比点击前更新的用量包，
                # 不能因为内存里已有旧请求数就立刻跳回模型页面。
                $script:BrowserLastUsageUtc -gt $state.UsageRefreshBaselineUtc
            }
            else {
                $null -ne $script:BrowserModels -and $null -ne $script:BrowserUsage
            }
            if ($bootstrapReady -or [DateTime]::UtcNow -ge $state.BootstrapDeadlineUtc) {
                $script:BrowserView.CoreWebView2.Navigate($state.MonitorUri)
                $state.LastNavigationUtc = [DateTime]::UtcNow
                $state.Stage = 'monitor'
                Write-LanZBrowserDiag ('navigate model monitor path={0}' -f ([Uri]$state.MonitorUri).AbsolutePath)
            }
            return
        }

        if ($state.Stage -eq 'monitor') {
            Complete-LanZBrowserResponses
            if ($state.ManualRefreshActive) {
                $usageRefreshed = $script:BrowserLastUsageUtc -gt $state.UsageRefreshBaselineUtc
                $modelsRefreshed = $script:BrowserLastModelsUtc -gt $state.ModelRefreshBaselineUtc
                if ($usageRefreshed -and $modelsRefreshed) {
                    $state.ManualRefreshActive = $false
                    $updatedText.Text = '已完整刷新 ' + (Get-Date).ToString('HH:mm:ss')
                    $updatedText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#8694A0')
                    Write-LanZBrowserDiag 'manual full refresh completed'
                    if ($state.ManualOnly -and -not $autoRefreshToggle.IsChecked) {
                        Stop-LanZBrowserCapture
                        return
                    }
                }
                elseif ([DateTime]::UtcNow -ge $state.ManualRefreshDeadlineUtc) {
                    $state.ManualRefreshActive = $false
                    $updatedText.Text = '完整刷新超时，已保留上次数据'
                    $updatedText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#E6A23C')
                    Write-LanZBrowserDiag ('manual full refresh timeout usage={0} models={1}' -f $usageRefreshed, $modelsRefreshed)
                    if ($state.ManualOnly -and -not $autoRefreshToggle.IsChecked) {
                        Stop-LanZBrowserCapture
                        return
                    }
                }
            }
            if (-not $state.AtMonitorPage) {
                return
            }

            if ($null -ne $state.PanelScriptTask -and $state.PanelScriptTask.IsCompleted) {
                $state.PanelScriptTask = $null
            }
            if ($null -ne $state.ModelMetadataTask -and $state.ModelMetadataTask.IsCompleted) {
                $metadataReadSucceeded = $false
                try {
                    if (-not $state.ModelMetadataTask.IsFaulted -and -not $state.ModelMetadataTask.IsCanceled) {
                        $metadataJson = [string]$state.ModelMetadataTask.GetAwaiter().GetResult()
                        if (-not [string]::IsNullOrWhiteSpace($metadataJson) -and $metadataJson -ne 'null') {
                            $metadataValue = $metadataJson | ConvertFrom-Json
                            # Some WebView2 runtime builds return an already-serialized JSON
                            # string. Accept either representation without assuming a version.
                            if ($metadataValue -is [string] -and $metadataValue.TrimStart() -match '^[\[{]') {
                                $metadataValue = $metadataValue | ConvertFrom-Json
                            }
                            $metadataRows = @($metadataValue)
                            if (Set-LanZActualModelMappings -Mappings $metadataRows) {
                                $metadataReadSucceeded = $true
                                Write-LanZBrowserDiag ('model metadata parsed rows={0}' -f $metadataRows.Count)
                            }
                            else {
                                Write-LanZBrowserDiag ('model metadata waiting rows={0}' -f $metadataRows.Count)
                            }
                        }
                    }
                }
                catch {
                    # Model metadata is optional. A page redesign may hide it while load
                    # monitoring continues from the normal model response stream.
                    Write-LanZBrowserDiag ('model metadata unavailable: {0}' -f $_.Exception.GetBaseException().Message)
                }
                finally {
                    $state.ModelMetadataTask = $null
                    $state.ModelMetadataNextAttemptUtc = if ($metadataReadSucceeded) {
                        [DateTime]::UtcNow.AddMinutes(1)
                    }
                    else {
                        [DateTime]::UtcNow.AddSeconds(2)
                    }
                }
            }
            if (-not $state.MonitorPanelReady -and $null -eq $state.PanelScriptTask -and [DateTime]::UtcNow -ge $state.PanelNextAttemptUtc) {
                # 复现真实用户的一次性操作：打开右上角账户菜单，再进入
                # “模型 API Key 申请”弹窗。弹窗自身每约 3 秒请求模型状态，
                # 程序只监听这些页面响应，不自行构造模型请求。
                $openPanelScript = @'
(() => {
  const account = document.querySelector('.agentHeader__right');
  if (!account) return 'waiting-account';
  account.click();
  setTimeout(() => {
    const item = Array.from(document.querySelectorAll('.agentHeader__operate'))
      .find(el => (el.textContent || '').trim() === '模型 API Key 申请');
    if (item) item.click();
  }, 250);
  return 'requested';
})()
'@
                $state.PanelScriptTask = $script:BrowserView.CoreWebView2.ExecuteScriptAsync($openPanelScript)
                $state.PanelNextAttemptUtc = [DateTime]::UtcNow.AddSeconds(2)
            }

            if ($state.MonitorPanelReady -and $null -eq $state.ModelMetadataTask -and [DateTime]::UtcNow -ge $state.ModelMetadataNextAttemptUtc) {
                # Read the optional upstream-model label from the model-name cell's
                # secondary block. No provider/model name is matched here: future labels
                # are accepted as data, and an absent block simply produces an empty value.
                $modelMetadataScript = @'
(() => {
  const clean = value => (value || '').replace(/\s+/g, ' ').trim();
  return Array.from(document.querySelectorAll('table tbody tr')).map(row => {
    const cells = row.querySelectorAll('td');
    if (cells.length < 2) return null;
    const box = cells[1].querySelector('.api__dialog__box');
    if (!box || !box.firstElementChild) return null;

    const primary = box.firstElementChild.cloneNode(true);
    primary.querySelectorAll('.el-tag, [class*="tag"], [class*="children"]').forEach(node => node.remove());
    const productName = clean(primary.textContent);
    const detail = box.querySelector('.api__dialog__children') ||
      Array.from(box.children).slice(1).find(node => clean(node.textContent));
    return productName ? {
      ProductName: productName,
      ActualModel: detail ? clean(detail.textContent) : ''
    } : null;
  }).filter(Boolean);
})()
'@
                $state.ModelMetadataTask = $script:BrowserView.CoreWebView2.ExecuteScriptAsync($modelMetadataScript)
                Write-LanZBrowserDiag 'model metadata read scheduled'
            }

            # 正常弹窗约每 3 秒产生一个模型响应。连续 15 秒没有数据时只
            # 重载真实主页面并重新打开弹窗，不再使用 HttpClient 模型兜底。
            $lastBrowserDataUtc = $script:BrowserLastModelsUtc
            $browserDataStale = $lastBrowserDataUtc -eq [DateTime]::MinValue -or ([DateTime]::UtcNow - $lastBrowserDataUtc).TotalSeconds -ge $script:BrowserReloadSeconds
            $reloadDue = ([DateTime]::UtcNow - $state.LastNavigationUtc).TotalSeconds -ge $script:BrowserReloadSeconds
            if ($browserDataStale -and $reloadDue) {
                $state.MonitorPanelReady = $false
                $state.ModelMetadataTask = $null
                $script:BrowserView.CoreWebView2.Reload()
                $state.LastNavigationUtc = [DateTime]::UtcNow
            }
        }
    }
    catch {
        $state.Stage = 'error'
        Write-LanZBrowserDiag ('capture step failed: {0}' -f $_.Exception.GetBaseException().Message)
        $updatedText.Text = '浏览器同步等待重新验证'
        $updatedText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#E6A23C')
    }
}

function Stop-LanZBrowserCapture {
    if ($null -ne $script:BrowserCaptureTimer) {
        $script:BrowserCaptureTimer.Stop()
    }
    $script:BrowserResponseQueue.Clear()
    if ($null -ne $script:BrowserView) {
        try { $script:BrowserView.Dispose() } catch { }
        $script:BrowserView = $null
    }
    if ($null -ne $script:BrowserCaptureWindow) {
        try { $script:BrowserCaptureWindow.Close() } catch { }
        $script:BrowserCaptureWindow = $null
    }
    $script:BrowserCaptureState = $null
}

function Start-LanZBrowserCapture {
    param(
        [switch]$Restart,
        [switch]$Manual
    )

    if ($Restart) {
        Stop-LanZBrowserCapture
    }
    if ($null -ne $script:BrowserCaptureState -or (-not $autoRefreshToggle.IsChecked -and -not $Manual)) {
        return
    }

    try {
        [void](Import-LanZWebView2Runtime)
        $dashboardUri = [Uri][string]$script:UsageDashboardUrl
        $monitorUri = [Uri]::new($dashboardUri.GetLeftPart([UriPartial]::Authority) + '/')
        $modelUri = [Uri][string]$script:Endpoint
        $usageUri = [Uri][string]$script:UsageEndpoint
        if ($dashboardUri.Host -ne $modelUri.Host -or $dashboardUri.Host -ne $usageUri.Host) {
            throw '资源看板与数据接口必须位于同一服务域。'
        }

        $captureWindow = [Windows.Window]::new()
        $captureWindow.Title = 'LanZ Browser Sync'
        $captureWindow.Width = 2
        $captureWindow.Height = 2
        $captureWindow.Left = -32000
        $captureWindow.Top = -32000
        $captureWindow.ShowInTaskbar = $false
        $captureWindow.ShowActivated = $false
        $captureWindow.WindowStyle = [Windows.WindowStyle]::ToolWindow
        $captureWindow.ResizeMode = [Windows.ResizeMode]::NoResize
        $captureWindow.Opacity = 0

        $captureView = [Microsoft.Web.WebView2.Wpf.WebView2]::new()
        $creationProperties = [Microsoft.Web.WebView2.Wpf.CoreWebView2CreationProperties]::new()
        $creationProperties.UserDataFolder = Join-Path $env:LOCALAPPDATA 'LanZMonitor\WebView2'
        $captureView.CreationProperties = $creationProperties
        $captureWindow.Content = $captureView
        $script:BrowserCaptureWindow = $captureWindow
        $script:BrowserView = $captureView
        $script:BrowserCaptureState = @{
            Stage = 'ensure'
            EnsureTask = $null
            NavigationUri = $dashboardUri.AbsoluteUri
            MonitorUri = $monitorUri.AbsoluteUri
            EndpointHost = $dashboardUri.Host
            ModelPath = $modelUri.AbsolutePath
            UsagePath = $usageUri.AbsolutePath
            CookieName = [string]$script:SessionCookieName
            ResponseHandler = $null
            NavigationHandler = $null
            SignedOut = $false
            SignedOutSinceUtc = [DateTime]::MinValue
            LoginPromptQueued = $false
            AtMonitorPage = $false
            MonitorPanelReady = $false
            PanelScriptTask = $null
            PanelNextAttemptUtc = [DateTime]::MinValue
            ModelMetadataTask = $null
            ModelMetadataNextAttemptUtc = [DateTime]::MinValue
            BootstrapDeadlineUtc = [DateTime]::UtcNow.AddSeconds(10)
            LastNavigationUtc = [DateTime]::UtcNow
            FirstCaptureLogged = $false
            ManualRefreshActive = [bool]$Manual
            ManualOnly = [bool]$Manual -and -not [bool]$autoRefreshToggle.IsChecked
            UsageRefreshBaselineUtc = [DateTime]::MinValue
            ModelRefreshBaselineUtc = [DateTime]::MinValue
            ManualRefreshDeadlineUtc = if ($Manual) { [DateTime]::UtcNow.AddSeconds(25) } else { [DateTime]::MinValue }
        }
        $script:BrowserLastModelsUtc = [DateTime]::MinValue
        $script:BrowserLastUsageUtc = [DateTime]::MinValue
        $script:BrowserLastUiUpdateUtc = [DateTime]::MinValue
        $script:BrowserLastDataPersistUtc = [DateTime]::MinValue
        $script:BrowserUiRefreshPending = $false
        $captureWindow.Show()
        $script:BrowserCaptureState.EnsureTask = $captureView.EnsureCoreWebView2Async()
        $script:BrowserCaptureTimer.Start()
        Write-LanZBrowserDiag 'capture window started'
    }
    catch {
        Write-LanZBrowserDiag ('capture start failed: {0}' -f $_.Exception.GetBaseException().Message)
        Stop-LanZBrowserCapture
        $updatedText.Text = '浏览器同步不可用，请重新验证'
        $updatedText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#E6A23C')
    }
}

function Request-LanZBrowserFullRefresh {
    # 手动刷新先回到资源看板，等待一次新的用量响应，再回主页面
    # 打开模型监控弹窗。这样一次点击同时更新请求数、额度和模型负载。
    if ($null -eq $script:BrowserCaptureState -or $null -eq $script:BrowserView -or $null -eq $script:BrowserView.CoreWebView2) {
        Write-LanZBrowserDiag 'manual full refresh requested with new capture'
        Start-LanZBrowserCapture -Restart -Manual
        return
    }

    $state = $script:BrowserCaptureState
    $state.ManualRefreshActive = $true
    $state.ManualOnly = $false
    $state.UsageRefreshBaselineUtc = $script:BrowserLastUsageUtc
    $state.ModelRefreshBaselineUtc = $script:BrowserLastModelsUtc
    $state.ManualRefreshDeadlineUtc = [DateTime]::UtcNow.AddSeconds(25)
    $state.Stage = 'bootstrap'
    $state.SignedOut = $false
    $state.SignedOutSinceUtc = [DateTime]::MinValue
    $state.LoginPromptQueued = $false
    $state.AtMonitorPage = $false
    $state.MonitorPanelReady = $false
    $state.PanelScriptTask = $null
    $state.ModelMetadataTask = $null
    $state.BootstrapDeadlineUtc = [DateTime]::UtcNow.AddSeconds(10)
    $state.LastNavigationUtc = [DateTime]::UtcNow
    $script:BrowserView.CoreWebView2.Navigate($state.NavigationUri)
    $updatedText.Text = '正在完整刷新…'
    $updatedText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#8694A0')
    Write-LanZBrowserDiag 'manual full refresh requested'
}

function Write-LanZBrowserDiag {
    param([Parameter(Mandatory)][string]$Message)

    try {
        # 仅写阶段、路径和状态；不记录 URL 查询、Cookie、Token 或响应正文。
        if ((Test-Path -LiteralPath $script:BrowserDiagLog) -and (Get-Item -LiteralPath $script:BrowserDiagLog).Length -gt 1MB) {
            $oldPath = $script:BrowserDiagLog + '.old'
            if (Test-Path -LiteralPath $oldPath) { Remove-Item -LiteralPath $oldPath -Force }
            Move-Item -LiteralPath $script:BrowserDiagLog -Destination $oldPath -Force
        }
        $line = '[{0}] {1}{2}' -f [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss.fff'), $Message, [Environment]::NewLine
        [IO.File]::AppendAllText($script:BrowserDiagLog, $line, [Text.UTF8Encoding]::new($false))
    }
    catch {
        # 诊断失败不影响主功能。
    }
}

function Show-LanZMainWindow {
    param([switch]$Pin)

    $script:TrayWindowState.Hidden = $false
    if ($Pin) {
        $pinToggle.IsChecked = $true
    }
    if ($window.WindowState -eq [Windows.WindowState]::Minimized) {
        $window.WindowState = [Windows.WindowState]::Normal
    }
    $window.Show()
    [void]$window.Activate()
    [void]$window.Focus()
    $window.Topmost = [bool]$pinToggle.IsChecked
    if ($script:BrowserUiRefreshPending -and $null -ne $script:ResumeUiTimer) {
        # 先让窗口真正显示，再在下一次 UI 调度中重建一次最新图表，
        # 避免恢复动作本身被隐藏期间积压的布局工作阻塞。
        $script:ResumeUiTimer.Stop()
        $script:ResumeUiTimer.Start()
    }
    Write-LanZBrowserDiag 'main window shown from tray'
}

function Hide-LanZMainWindow {
    # IsVisible 在 Hide/Closing 与 WinForms 托盘回调交错时可能短暂保留旧值。
    # 先记录明确状态，让下一次托盘双击永远以用户最后一次操作为准。
    $script:TrayWindowState.Hidden = $true
    if ($null -ne $script:ResumeUiTimer) {
        $script:ResumeUiTimer.Stop()
    }
    $settingsPopup.IsOpen = $false
    $window.Hide()
    Write-LanZBrowserDiag 'main window hidden to tray'
}

function Request-LanZExit {
    if ($script:ExitRequested) {
        return
    }

    $script:ExitRequested = $true
    Write-LanZBrowserDiag 'tray exit requested'
    try { $settingsPopup.IsOpen = $false } catch { }
    $currentApplication = [Windows.Application]::Current
    if ($null -ne $currentApplication) {
        # Shutdown 会同时结束可能仍打开的登录窗口和隐藏的主窗口，
        # 不依赖 Close/Closing 的“隐藏到托盘”分支。
        $currentApplication.Shutdown()
        return
    }
    $window.Close()
}

function Initialize-LanZTrayIcon {
    if ($null -ne $script:TrayIcon) {
        return
    }

    $notifyIcon = [Windows.Forms.NotifyIcon]::new()
    $notifyIcon.Text = 'LanZ 负载监控'
    try {
        $processPath = [Environment]::GetCommandLineArgs()[0]
        $script:TrayOwnedIcon = [Drawing.Icon]::ExtractAssociatedIcon($processPath)
        if ($null -ne $script:TrayOwnedIcon) {
            $notifyIcon.Icon = $script:TrayOwnedIcon
        }
        else {
            $notifyIcon.Icon = [Drawing.SystemIcons]::Application
        }
    }
    catch {
        $notifyIcon.Icon = [Drawing.SystemIcons]::Application
    }

    $contextMenu = [Windows.Forms.ContextMenuStrip]::new()
    $pinMenu = [Windows.Forms.ToolStripMenuItem]::new('窗口置顶')
    $pinMenu.CheckOnClick = $true
    $pinMenu.Checked = [bool]$pinToggle.IsChecked
    $exitMenu = [Windows.Forms.ToolStripMenuItem]::new('退出')

    $pinHandlerBlock = {
        param($sender, $eventArgs)
        $requested = [bool]$pinMenu.Checked
        [void]$window.Dispatcher.BeginInvoke([Action]{
            $pinToggle.IsChecked = $requested
            if ($requested) {
                Show-LanZMainWindow -Pin
            }
        }.GetNewClosure())
    }.GetNewClosure()
    $script:TrayPinHandler = [EventHandler]$pinHandlerBlock
    $pinMenu.Add_Click($script:TrayPinHandler)

    $exitHandlerBlock = {
        param($sender, $eventArgs)
        Write-LanZBrowserDiag 'tray exit click callback entered'
        if ($window.Dispatcher.CheckAccess()) {
            Request-LanZExit
            return
        }
        [void]$window.Dispatcher.BeginInvoke([Action]{ Request-LanZExit }.GetNewClosure())
    }.GetNewClosure()
    $script:TrayExitHandler = [EventHandler]$exitHandlerBlock
    $exitMenu.Add_Click($script:TrayExitHandler)

    $trayWindowState = $script:TrayWindowState
    $doubleClickHandlerBlock = {
        param($sender, $eventArgs)
        $clickUtc = [DateTime]::UtcNow
        if (($clickUtc - $trayWindowState.LastDoubleClickUtc).TotalMilliseconds -lt 350) {
            return
        }
        $trayWindowState.LastDoubleClickUtc = $clickUtc
        [void]$window.Dispatcher.BeginInvoke([Action]{
            if (-not $trayWindowState.Hidden -and $window.IsVisible) {
                Hide-LanZMainWindow
            }
            else {
                Show-LanZMainWindow
            }
        }.GetNewClosure())
    }.GetNewClosure()
    $script:TrayDoubleClickHandler = [EventHandler]$doubleClickHandlerBlock
    $notifyIcon.Add_DoubleClick($script:TrayDoubleClickHandler)

    [void]$contextMenu.Items.Add($pinMenu)
    [void]$contextMenu.Items.Add([Windows.Forms.ToolStripSeparator]::new())
    [void]$contextMenu.Items.Add($exitMenu)
    $notifyIcon.ContextMenuStrip = $contextMenu
    $script:TrayIcon = $notifyIcon
    $script:TrayContextMenu = $contextMenu
    $script:TrayPinMenu = $pinMenu
    $script:TrayExitMenu = $exitMenu
    # Icon 和菜单都就绪后再显示，避免 NotifyIcon 在初始化中途
    # 进入 shell，从而使 WPF Loaded 事件中断。
    $notifyIcon.Visible = $true
}

function Dispose-LanZTrayIcon {
    if ($null -ne $script:TrayPinMenu -and $null -ne $script:TrayPinHandler) {
        $script:TrayPinMenu.Remove_Click($script:TrayPinHandler)
    }
    if ($null -ne $script:TrayExitMenu -and $null -ne $script:TrayExitHandler) {
        $script:TrayExitMenu.Remove_Click($script:TrayExitHandler)
    }
    if ($null -ne $script:TrayIcon -and $null -ne $script:TrayDoubleClickHandler) {
        $script:TrayIcon.Remove_DoubleClick($script:TrayDoubleClickHandler)
    }
    if ($null -ne $script:TrayIcon) {
        $script:TrayIcon.Visible = $false
        $script:TrayIcon.Dispose()
        $script:TrayIcon = $null
    }
    if ($null -ne $script:TrayContextMenu) {
        $script:TrayContextMenu.Dispose()
        $script:TrayContextMenu = $null
    }
    if ($null -ne $script:TrayOwnedIcon) {
        $script:TrayOwnedIcon.Dispose()
        $script:TrayOwnedIcon = $null
    }
    $script:TrayPinMenu = $null
    $script:TrayExitMenu = $null
    $script:TrayPinHandler = $null
    $script:TrayExitHandler = $null
    $script:TrayDoubleClickHandler = $null
}

function Show-LanZLogin {
    param([switch]$ClearExistingSession)

    if ($script:LoginWindowOpen) {
        return
    }

    $script:LoginWindowOpen = $true
    $script:SuppressAutoLogin = $false
    $timer.Stop()
    Stop-LanZBrowserCapture

    try {
        $loginNavigationUri = $null
        if (-not [Uri]::TryCreate([string]$script:UsageDashboardUrl, [UriKind]::Absolute, [ref]$loginNavigationUri) -or $loginNavigationUri.Scheme -ne 'https') {
            throw '资源看板地址无效，请重新配置连接信息。'
        }
        # 延迟事件回调使用闭包局部变量，避免在 ps2exe/WPF 闭包中读取
        # $script: 变量时出现路径不可见，导致诊断日志静默失败。
        $loginDiagPath = [IO.Path]::GetFullPath([string]$script:LoginDiagLog)
        $loginDiagEncoding = [Text.UTF8Encoding]::new($false)
        $loginSessionCookieName = [string]$script:SessionCookieName
        $loginHost = $loginNavigationUri.Host
        $loginHostParts = @($loginHost.Split('.') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $loginDomainSuffix = if ($loginHostParts.Count -ge 2) {
            '.' + ($loginHostParts[($loginHostParts.Count - 2)..($loginHostParts.Count - 1)] -join '.')
        }

        if ((Test-Path -LiteralPath $loginDiagPath) -and (Get-Item -LiteralPath $loginDiagPath).Length -gt 2MB) {
            $oldLoginDiagPath = $loginDiagPath + '.old'
            if (Test-Path -LiteralPath $oldLoginDiagPath) { Remove-Item -LiteralPath $oldLoginDiagPath -Force }
            Move-Item -LiteralPath $loginDiagPath -Destination $oldLoginDiagPath -Force
        }
        else {
            '.' + $loginHost
        }

        [void](Import-LanZWebView2Runtime)

        [xml]$loginXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="LanZ 登录" Width="980" Height="720"
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
                <TextBlock Text="登录 LanZ" FontSize="15" FontWeight="SemiBold" Foreground="#293B49"/>
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
        if ($window.IsVisible) {
            $loginWindow.Owner = $window
        }
        else {
            $loginWindow.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterScreen
        }
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
            LastCandidateAttemptAt = [DateTime]::MinValue
            LastCookiePoll = [DateTime]::MinValue
            NavCompletedAt = $null
            NoSessionPrompted = $false
            NavigationRetryCount = 0
            NetworkDiagCount = 0
            LastCookieSummary = ''
            LastCookieDiagAt = [DateTime]::MinValue
            LastDiagAt = [DateTime]::MinValue
            Success = $false
        }
        try {
            [IO.File]::AppendAllText($loginDiagPath, ("[{0}] === login window open === navUri='{1}' clearExisting={2}`n" -f [DateTime]::Now.ToString('HH:mm:ss.fff'), $loginState.NavigationUri, [bool]$ClearExistingSession), $loginDiagEncoding)
        } catch { }
        $loginTimer = [Windows.Threading.DispatcherTimer]::new()
        $loginTimer.Interval = [TimeSpan]::FromMilliseconds(250)

        $loginWindow.Add_Loaded(({
            try {
                $loginState.EnsureTask = $webView.EnsureCoreWebView2Async()
                $loginTimer.Start()
                try { [IO.File]::AppendAllText($loginDiagPath, ('[{0}] window loaded, EnsureCoreWebView2Async started' -f [DateTime]::Now.ToString('HH:mm:ss.fff')) + "`n", $loginDiagEncoding) } catch { }
            }
            catch {
                $loginStatusText.Text = '验证窗口异常：' + $_.Exception.Message
                $loginState.Stage = 'error'
            }
        }).GetNewClosure())

        $webView.add_NavigationCompleted(({
            param($sender, $eventArgs)
            $safeSource = ''
            try {
                $source = [string]$webView.CoreWebView2.Source
                if (-not [string]::IsNullOrWhiteSpace($source)) {
                    $safeSource = ($source -replace '[?#].*$', '')
                }
            }
            catch { }
            try {
                [IO.File]::AppendAllText(
                    $loginDiagPath,
                    ('[{0}] navigation completed success={1} error={2} source={3}' -f [DateTime]::Now.ToString('HH:mm:ss.fff'), [bool]$eventArgs.IsSuccess, [string]$eventArgs.WebErrorStatus, $safeSource) + "`n",
                    $loginDiagEncoding
                )
            }
            catch { }
            if (-not $eventArgs.IsSuccess) {
                $loginStatusText.Text = '登录页面加载失败：' + [string]$eventArgs.WebErrorStatus
                $loginState.Stage = 'error'
            }
            elseif ($null -eq $loginState.NavCompletedAt) {
                # 只记录首次导航完成时间,避免 SSO 重定向多次刷新导致 15 秒计时重置。
                $loginState.NavCompletedAt = [DateTime]::UtcNow
            }
        }).GetNewClosure())

        $loginTimer.Add_Tick(({
            try {
                if (([DateTime]::UtcNow - $loginState.LastDiagAt).TotalSeconds -ge 10) {
                    $loginState.LastDiagAt = [DateTime]::UtcNow
                    try { [IO.File]::AppendAllText($loginDiagPath, ('[{0}] tick stage={1} ensure={2} cookieTask={3}' -f [DateTime]::Now.ToString('HH:mm:ss.fff'), $loginState.Stage, ($null -ne $loginState.EnsureTask), ($null -ne $loginState.CookieTask)) + "`n", $loginDiagEncoding) } catch { }
                }
                if ($loginState.Stage -eq 'ensure') {
                    if (-not $loginState.EnsureTask.IsCompleted) {
                        return
                    }
                    if ($loginState.EnsureTask.IsFaulted) {
                        try { [IO.File]::AppendAllText($loginDiagPath, ('[{0}] EnsureTask FAULTED: {1}' -f [DateTime]::Now.ToString('HH:mm:ss.fff'), $loginState.EnsureTask.Exception.GetBaseException().Message) + "`n", $loginDiagEncoding) } catch { }
                        throw $loginState.EnsureTask.Exception.GetBaseException()
                    }
                    $webView.CoreWebView2.Settings.AreDevToolsEnabled = $false
                    $webView.CoreWebView2.Settings.AreDefaultContextMenusEnabled = $false
                    $webView.CoreWebView2.Settings.IsPasswordAutosaveEnabled = $true
                    $webView.CoreWebView2.Settings.IsGeneralAutofillEnabled = $true
                    $webView.CoreWebView2.Profile.IsPasswordAutosaveEnabled = $true
                    $webView.CoreWebView2.Profile.IsGeneralAutofillEnabled = $true
                    # 只记录登录跳转的脱敏网络摘要,用于确认 SSO 回跳是否真正给资源域
                    # 设置了会话 Cookie。绝不记录 Cookie 值、请求头或查询参数值。
                    $webView.CoreWebView2.add_WebResourceResponseReceived(({
                        param($sender, $eventArgs)
                        try {
                            if ($loginState.NetworkDiagCount -ge 160) {
                                return
                            }
                            $response = $eventArgs.Response
                            $uri = [Uri][string]$eventArgs.Request.Uri
                            $isRelatedHost = $uri.Host -eq $loginHost -or $uri.Host.EndsWith($loginDomainSuffix, [StringComparison]::OrdinalIgnoreCase)
                            if (-not $isRelatedHost) {
                                return
                            }
                            $statusCode = [int]$response.StatusCode
                            $setCookieCount = 0
                            $hasConfiguredSessionCookie = $false
                            try {
                                $iterator = $response.Headers.GetHeaders('Set-Cookie')
                                while ($iterator.MoveNext()) {
                                    $line = [string]$iterator.Current.Value
                                    if ($line -match '^\s*([^=;\s]+)\s*=') {
                                        $setCookieCount++
                                        if ([string]$matches[1] -eq $loginSessionCookieName) {
                                            $hasConfiguredSessionCookie = $true
                                        }
                                    }
                                }
                            }
                            catch { }
                            $path = $uri.GetLeftPart([UriPartial]::Path)
                            $locationPath = ''
                            try {
                                $location = [string]$response.Headers.GetHeader('Location')
                                if (-not [string]::IsNullOrWhiteSpace($location)) {
                                    $locationUri = $null
                                    if ([Uri]::TryCreate($location, [UriKind]::Absolute, [ref]$locationUri)) {
                                        $locationPath = $locationUri.GetLeftPart([UriPartial]::Path)
                                    }
                                }
                            }
                            catch { }
                            $interesting = $statusCode -in @(301, 302, 303, 307, 308, 401, 403) -or $setCookieCount -gt 0 -or $uri.AbsolutePath -match '/(login|resource/dashboard|v1/(openai/models|ai-resource/dashboard))'
                            if ($interesting) {
                                $loginState.NetworkDiagCount++
                                [IO.File]::AppendAllText(
                                    $loginDiagPath,
                                    ('[{0}] response status={1} path={2} location={3} setCookieCount={4} hasSessionCookie={5}' -f [DateTime]::Now.ToString('HH:mm:ss.fff'), $statusCode, $path, $locationPath, $setCookieCount, $hasConfiguredSessionCookie) + "`n",
                                    $loginDiagEncoding
                                )
                            }
                        }
                        catch { }
                    }).GetNewClosure())
                    $webView.CoreWebView2.AddWebResourceRequestedFilter('*', [Microsoft.Web.WebView2.Core.CoreWebView2WebResourceContext]::All)
                    if ($ClearExistingSession) {
                        $webView.CoreWebView2.CookieManager.DeleteAllCookies()
                    }
                    else {
                        # 自动重新验证时保留 SSO Cookie,但删除上次未授权时留下的
                        # 无效会话 Cookie。否则资源域可能继续把它当作现有会话，
                        # 不在 SSO 回跳时重新签发有效会话。
                        $webView.CoreWebView2.CookieManager.DeleteCookies($loginSessionCookieName, $loginState.NavigationUri)
                        $webView.CoreWebView2.CookieManager.DeleteCookiesWithDomainAndPath($loginSessionCookieName, $loginNavigationUri.Host, '/')
                        try { [IO.File]::AppendAllText($loginDiagPath, ('[{0}] cleared session cookie only; kept SSO cookies' -f [DateTime]::Now.ToString('HH:mm:ss.fff')) + "`n", $loginDiagEncoding) } catch { }
                    }
                    $webView.CoreWebView2.Navigate($loginState.NavigationUri)
                    $loginStatusText.Text = '请在资源看板完成登录；若页面提供保存密码提示可自行选择，程序只保存会话 Cookie。'
                    $loginState.Stage = 'cookies'
                    try { [IO.File]::AppendAllText($loginDiagPath, ('[{0}] stage ensure->cookies, navigated' -f [DateTime]::Now.ToString('HH:mm:ss.fff')) + "`n", $loginDiagEncoding) } catch { }
                    return
                }

                if ($loginState.Stage -ne 'cookies') {
                    return
                }

                if ($null -ne $loginState.CookieTask -and $loginState.CookieTask.IsCompleted) {
                    if ($loginState.CookieTask.IsFaulted) {
                        try { [IO.File]::AppendAllText($loginDiagPath, ('[{0}] CookieTask FAULTED: {1}' -f [DateTime]::Now.ToString('HH:mm:ss.fff'), $loginState.CookieTask.Exception.GetBaseException().Message) + "`n", $loginDiagEncoding) } catch { }
                        throw $loginState.CookieTask.Exception.GetBaseException()
                    }
                    $cookies = $loginState.CookieTask.GetAwaiter().GetResult()
                    $loginState.CookieTask = $null
                    # 诊断日志只记录 cookie 状态变化，或每 10 秒写一次心跳。
                    # 不写完整 value，避免泄露凭据或因每秒轮询导致日志膨胀。
                    try {
                        $cookieSummaryParts = @()
                        foreach ($c in @($cookies | Where-Object { $_.Name -eq $loginSessionCookieName })) {
                            $cookieValue = [string]$c.Value
                            $isZero = ($cookieValue -eq '0')
                            $isDashboardHost = ([string]$c.Domain).TrimStart('.') -eq $loginNavigationUri.Host
                            $cookieSummaryParts += ('sessionCookie valLen={0} isZero={1} dashboardHost={2}' -f $cookieValue.Length, $isZero, $isDashboardHost)
                        }
                        $summaryKey = [string]::Join('|', [string[]]$cookieSummaryParts)
                        $diagDue = $summaryKey -ne [string]$loginState.LastCookieSummary -or ([DateTime]::UtcNow - $loginState.LastCookieDiagAt).TotalSeconds -ge 10
                        if ($diagDue) {
                            $loginState.LastCookieSummary = $summaryKey
                            $loginState.LastCookieDiagAt = [DateTime]::UtcNow
                            $diagText = @('[{0}] poll count={1} uri={2}' -f [DateTime]::Now.ToString('HH:mm:ss.fff'), @($cookies).Count, $loginState.NavigationUri)
                            $diagText += $cookieSummaryParts | ForEach-Object { '  ' + $_ }
                            [IO.File]::AppendAllText($loginDiagPath, ([string]::Join([Environment]::NewLine, [string[]]$diagText) + [Environment]::NewLine), $loginDiagEncoding)
                        }
                    }
                    catch {
                        try { [IO.File]::AppendAllText($loginDiagPath, ('[{0}] COOKIE DIAG ERROR: {1}' -f [DateTime]::Now.ToString('HH:mm:ss.fff'), $_.Exception.Message) + [Environment]::NewLine, $loginDiagEncoding) } catch { }
                    }
                    $validCandidates = @($cookies | Where-Object { $_.Name -eq $loginSessionCookieName -and -not [string]::IsNullOrWhiteSpace([string]$_.Value) -and $_.Value -ne '0' })
                    $candidate = $validCandidates | Where-Object { ([string]$_.Domain).TrimStart('.') -eq $loginNavigationUri.Host } | Select-Object -First 1
                    if ($null -eq $candidate) {
                        $candidate = $validCandidates | Select-Object -First 1
                    }
                    $candidateChanged = $null -ne $candidate -and [string]$candidate.Value -ne [string]$loginState.LastCandidate
                    $candidateRetryDue = $null -ne $candidate -and -not $candidateChanged -and ([DateTime]::UtcNow - $loginState.LastCandidateAttemptAt).TotalSeconds -ge 10
                    if ($null -ne $candidate -and ($candidateChanged -or $candidateRetryDue)) {
                        # 登录会话由资源看板自身签发。只有 WebView2 已经回到固定的
                        # dashboard 页面时才接收非零 Cookie，避免在 SSO 中间跳转阶段
                        # 误存临时值；不再为了“验证”额外调用签名模型接口。
                        $dashboardReady = $false
                        try {
                            $currentSourceUri = [Uri][string]$webView.CoreWebView2.Source
                            $dashboardReady = $currentSourceUri.Host -eq $loginNavigationUri.Host -and
                                $currentSourceUri.AbsolutePath.TrimEnd('/') -eq $loginNavigationUri.AbsolutePath.TrimEnd('/')
                        }
                        catch { }
                        if (-not $dashboardReady) {
                            $loginStatusText.Text = '已检测到会话，正在等待资源看板完成跳转…'
                            return
                        }

                        $loginState.LastCandidate = $candidate.Value
                        $loginState.LastCandidateAttemptAt = [DateTime]::UtcNow
                        $loginStatusText.Text = '检测到有效会话，正在保存…'
                        try {
                            Save-LanZSessionValue -SessionValue $candidate.Value
                            $loginState.Success = $true
                            $loginStatusText.Text = '验证成功。'
                            try { [IO.File]::AppendAllText($loginDiagPath, ('[{0}] SESSION SAVED dashboardReady=true valLen={1}' -f [DateTime]::Now.ToString('HH:mm:ss.fff'), ([string]$candidate.Value).Length) + "`n", $loginDiagEncoding) } catch { }
                            $loginWindow.Close()
                            return
                        }
                        catch {
                            try { [IO.File]::AppendAllText($loginDiagPath, ('[{0}] SESSION SAVE FAIL: {1}' -f [DateTime]::Now.ToString('HH:mm:ss.fff'), $_.Exception.Message) + "`n", $loginDiagEncoding) } catch { }
                            $loginStatusText.Text = '会话保存失败，请关闭窗口后重试。'
                        }
                    }
                    elseif ($null -eq $candidate -and -not $loginState.NoSessionPrompted -and $null -ne $loginState.NavCompletedAt) {
                        # 配置的会话 Cookie 一直是 '0' 或不存在。看板页可能靠 Windows 集成认证
                        # 加载(显示欢迎回来),但 API 需要的有效会话需要用户主动登录
                        # 才会生成。导航完成 15 秒后仍无有效会话,提示用户主动登录。
                        if (([DateTime]::UtcNow - $loginState.NavCompletedAt).TotalSeconds -ge 15) {
                            $canRetryDashboardNavigation = $false
                            try {
                                $currentSourceUri = [Uri][string]$webView.CoreWebView2.Source
                                $canRetryDashboardNavigation = $currentSourceUri.Host -eq $loginNavigationUri.Host -and $currentSourceUri.AbsolutePath -eq ([Uri][string]$loginState.NavigationUri).AbsolutePath
                            }
                            catch { }
                            if ($canRetryDashboardNavigation -and $loginState.NavigationRetryCount -lt 2) {
                                # SSO 页面显示欢迎信息后,资源域有时仍保留初始的
                                # 无效会话值。仅在当前确实已经回到看板时重载,
                                # 避免用户正在 SSO 输入密码时丢失表单内容。
                                $loginState.NavigationRetryCount++
                                $loginState.NavCompletedAt = $null
                                $loginState.NoSessionPrompted = $false
                                $loginState.LastCookiePoll = [DateTime]::MinValue
                                $loginStatusText.Text = '已完成登录，正在重新同步资源看板会话…'
                                try { [IO.File]::AppendAllText($loginDiagPath, ('[{0}] dashboard reload retry={1}' -f [DateTime]::Now.ToString('HH:mm:ss.fff'), $loginState.NavigationRetryCount) + "`n", $loginDiagEncoding) } catch { }
                                $webView.CoreWebView2.Navigate($loginState.NavigationUri)
                            }
                            else {
                                $loginState.NoSessionPrompted = $true
                                $loginStatusText.Text = '未检测到有效会话，请在页面中完成登录（输入账号密码）后等待自动验证。'
                            }
                        }
                    }
                }

                if ($null -eq $loginState.CookieTask -and ([DateTime]::UtcNow - $loginState.LastCookiePoll).TotalSeconds -ge 1) {
                    $loginState.LastCookiePoll = [DateTime]::UtcNow
                    # 传入 null 表示读取当前 WebView2 profile 的全部 Cookie,
                    # 避免按 dashboard 的 URI 过滤掉 SSO 域名或不同 path 下的会话 Cookie。
                    $loginState.CookieTask = $webView.CoreWebView2.CookieManager.GetCookiesAsync([string]$null)
                }
            }
            catch {
                try { [IO.File]::AppendAllText($loginDiagPath, ('[{0}] TICK EXCEPTION: {1}' -f [DateTime]::Now.ToString('HH:mm:ss.fff'), $_.Exception.Message) + "`n", $loginDiagEncoding) } catch { }
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
                $autoWasChecked = [bool]$autoRefreshToggle.IsChecked
                $autoRefreshToggle.IsChecked = $true
                # 登录窗与后台监听共用同一 WebView2 profile。登录成功后重新
                # 建立监听页面，让后续负载来自资源看板自身的网络响应。
                Start-LanZBrowserCapture -Restart
                if ($autoWasChecked) {
                    Update-Widget
                }
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
            # 保留 WebView2 的 SSO 登录态(不清 cookie),让用户在登录窗里
            # 重新触发登录流程以生成新的会话 Cookie。清 cookie 会丢失
            # SSO 登录态,导致看板页虽能加载但会话值一直是 '0'。
            Show-LanZLogin
        }
    }
}

function Start-LanZRefresh {
    param([switch]$ForceBilling)

    if ($script:RefreshInProgress) {
        if ($ForceBilling) {
            $script:ForceBillingRefreshPending = $true
        }
        return
    }

    if ($ForceBilling) {
        $script:ForceBillingRefreshPending = $false
    }

    try {
        $sessionValue = Get-LanZSessionValue
        Import-LanZRefreshCadence
        $functionNames = @(
            'Add-LanZBrowserHeaders',
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
    [object]$HttpClient,
    [string]$BillingRulesPath,
    [string]$BillingOverridesPath,
    [string]$LastBillingFetchUtc,
    [int]$BillingRefreshSeconds,
    [bool]$ForceBilling
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
$global:BillingOverridesPath = $BillingOverridesPath
$global:BillingRules = $null
$global:BillingRefreshSeconds = $BillingRefreshSeconds
# 计费规则首次无缓存时同步一次，之后最多四小时读取一次看板规则。
$global:ShouldFetchBilling = $true
if (-not $ForceBilling -and -not [string]::IsNullOrWhiteSpace($LastBillingFetchUtc)) {
    try {
        $lastBilling = [DateTime]::Parse($LastBillingFetchUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        if (([DateTime]::UtcNow - $lastBilling).TotalSeconds -lt $BillingRefreshSeconds) {
            $global:ShouldFetchBilling = $false
        }
    } catch { }
}
'@
        $workerTail = @'
$billingRules = $null
$billingRefreshed = $false
if ($global:ShouldFetchBilling) {
    $billingRules = Get-LanZBillingRules -SessionValue $SessionValue -HttpClient $HttpClient -Force:$ForceBilling
    $billingRefreshed = $true
}
[pscustomobject]@{
    Models = @()
    UsageOverview = $null
    BillingRules = $billingRules
    UsageRefreshed = $false
    BillingRefreshed = $billingRefreshed
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
        [void]$worker.AddArgument($script:SharedHttpClient)
        [void]$worker.AddArgument($script:BillingRulesPath)
        [void]$worker.AddArgument($script:BillingOverridesPath)
        $lastBillingArg = if ($script:LastBillingFetchUtc -ne [DateTime]::MinValue) { $script:LastBillingFetchUtc.ToString('o') } else { '' }
        [void]$worker.AddArgument($lastBillingArg)
        [void]$worker.AddArgument([int]$script:BillingRefreshSeconds)
        [void]$worker.AddArgument([bool]$ForceBilling)
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
        $hasModelData = $models.Count -gt 0
        # 用量按低频节奏刷新;未刷新时沿用上次快照,避免用量卡片空白。
        $usageOverview = $result.UsageOverview
        if ($null -eq $usageOverview -and $null -ne $script:BrowserUsage) {
            $usageOverview = $script:BrowserUsage
        }
        if ($null -eq $usageOverview -and $null -ne $script:CachedStatusSnapshot) {
            $usageOverview = $script:CachedStatusSnapshot.Usage
        }
        # 规则同理:未刷新时保留内存中已同步的规则。
        if ($null -ne $result.BillingRules) {
            $script:BillingRules = $result.BillingRules
        }
        if ($hasModelData) {
            $script:BrowserModels = $models
            $modelsWithHistory = @(Add-LanZChartHistory -Models $models)
            $script:DisplayedModels = @(Sort-LanZModels -Models $modelsWithHistory)
            $modelsList.ItemsSource = $script:DisplayedModels
        }
        if ($null -ne $usageOverview) {
            $script:BrowserUsage = $usageOverview
        }
        Update-LanZLocalQuotaStatus
        $snapshotModels = @()
        if ($hasModelData) {
            $snapshotModels = @($models)
        }
        elseif ($null -ne $script:BrowserModels) {
            $snapshotModels = @($script:BrowserModels)
        }
        if ($snapshotModels.Count -gt 0 -and $null -ne $usageOverview) {
            try {
                Save-LanZStatusSnapshot -Models $snapshotModels -Overview $usageOverview
            }
            catch {
                # The live widget remains authoritative if local snapshot persistence fails.
            }
        }
        # 记录低频调用节奏:只有真正发起了请求才更新对应时间戳。
        Save-LanZRefreshCadence -UsageUpdated:([bool]$result.UsageRefreshed) -BillingUpdated:([bool]$result.BillingRefreshed)
        if ([bool]$result.BillingRefreshed) {
            Write-LanZBrowserDiag 'billing rules refresh completed'
        }
        if ($hasModelData) {
            $script:LastSuccessfulModelRefreshUtc = [DateTime]::UtcNow
            $updatedText.Text = '已更新 ' + (Get-Date).ToString('HH:mm:ss')
            $updatedText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#8694A0')
        }
    }
    catch {
        $refreshFailure = $_.Exception.GetBaseException().Message
        if (-not [string]::IsNullOrWhiteSpace([string]$_.ScriptStackTrace)) {
            $refreshFailure += ' stack=' + ([string]$_.ScriptStackTrace -replace '[\r\n]+', ' ')
        }
        Write-LanZBrowserDiag ('billing rules refresh failed: {0}' -f $refreshFailure)
        Set-LanZRefreshError -Exception $_.Exception
    }
    finally {
        $worker.PowerShell.Dispose()
    }

    if ($script:ForceBillingRefreshPending) {
        $script:ForceBillingRefreshPending = $false
        Start-LanZRefresh -ForceBilling
    }
}

function Update-Widget {
    param([switch]$Force)

    # 每个 3 秒节拍都用已缓存规则和当前本地时间重算显示；不访问网络。
    Update-LanZLocalQuotaStatus

    if ($Force) {
        # 手动刷新是完整刷新：先让真实资源看板产生新的当日用量包，
        # 再回模型页面取得新负载，并强制同步一次计费规则。
        Request-LanZBrowserFullRefresh
        Start-LanZRefresh -ForceBilling
        return
    }

    # 当日额度只来自真实 WebView2 页面响应。计费规则按 4 小时低频读取
    # 已登录看板脚本；不调用模型或用量 API，也不需要 AES 请求令牌。
    $billingDue = $script:LastBillingFetchUtc -eq [DateTime]::MinValue -or ([DateTime]::UtcNow - $script:LastBillingFetchUtc).TotalSeconds -ge $script:BillingRefreshSeconds
    if ($billingDue) {
        Start-LanZRefresh
    }
}

function Set-LanZJitteredInterval {
    # 跟随模型申请弹窗实测的约 3 秒页面轮询节奏。
    $timer.Interval = [TimeSpan]::FromSeconds([int]$RefreshSeconds)
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
                ActualModel = if ($null -ne $_.PSObject.Properties['ActualModel']) { [string]$_.ActualModel } else { '' }
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

function Open-LanZReleasePage {
    param([Parameter(Mandatory)][string]$Url)

    $releaseUri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$releaseUri) -or
        $releaseUri.Scheme -ne 'https' -or
        $releaseUri.Host -ne 'github.com' -or
        -not $releaseUri.AbsolutePath.StartsWith('/HankLiu2020/LanZ-Monitor/releases/', [StringComparison]::OrdinalIgnoreCase)) {
        throw '更新页面地址未通过安全校验。'
    }
    Start-Process -FilePath $releaseUri.AbsoluteUri
}

function Start-LanZUpdateOperation {
    param(
        [Parameter(Mandatory)][ValidateSet('Check', 'Download')][string]$Operation,
        [object]$Release
    )

    if ($script:UpdateInProgress) {
        return
    }

    $worker = [PowerShell]::Create()
    try {
        if ($Operation -eq 'Check') {
            $checkScript = @'
param($ManifestUrl, $Repository, $CurrentVersion)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

$manifestUri = [Uri]$ManifestUrl
if ($manifestUri.Scheme -ne 'https' -or $manifestUri.Host -ne 'github.com' -or
    $manifestUri.AbsolutePath -ne ('/' + $Repository + '/releases/latest/download/latest.txt')) {
    throw 'GitHub 更新清单地址未通过安全校验。'
}

$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.UseCookies = $false
$handler.AllowAutoRedirect = $true
$handler.CheckCertificateRevocationList = $true
$client = [System.Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromSeconds(15)
$request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $manifestUri)
$response = $null
try {
    [void]$request.Headers.UserAgent.ParseAdd('LanZ-Monitor/' + $CurrentVersion)
    [void]$request.Headers.TryAddWithoutValidation('Accept', 'text/plain')
    $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    if (-not $response.IsSuccessStatusCode) {
        throw ('GitHub latest.txt 返回 HTTP ' + [int]$response.StatusCode)
    }
    $contentLength = $response.Content.Headers.ContentLength
    if ($null -ne $contentLength -and $contentLength -gt 4KB) {
        throw 'GitHub 更新清单异常过大。'
    }
    $manifestText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if ($manifestText.Length -gt 4KB -or $manifestText.IndexOf([char]0) -ge 0) {
        throw 'GitHub 更新清单内容无效。'
    }

    $manifest = @{}
    $allowedKeys = @('version', 'file', 'size', 'sha256')
    foreach ($line in @($manifestText -split '\r?\n')) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ($trimmed -notmatch '^([a-z0-9]+)=([^\r\n]+)$') {
            throw 'GitHub 更新清单格式无效。'
        }
        $key = [string]$matches[1]
        $value = [string]$matches[2]
        if ($key -notin $allowedKeys -or $manifest.ContainsKey($key)) {
            throw 'GitHub 更新清单包含未知或重复字段。'
        }
        $manifest[$key] = $value
    }
    if ($manifest.Count -ne $allowedKeys.Count) {
        throw 'GitHub 更新清单缺少必要字段。'
    }

    $versionText = [string]$manifest.version
    if ($versionText -notmatch '^\d+\.\d+\.\d+$') { throw '更新版本号格式无效。' }
    $latestVersion = [Version]$versionText
    $installedVersion = [Version]$CurrentVersion
    $expectedAssetName = 'LanZ-Monitor-v' + $latestVersion.ToString(3) + '.exe'
    if ([string]$manifest.file -cne $expectedAssetName) { throw '更新文件名与版本号不一致。' }
    $assetSize = [long]0
    if (-not [long]::TryParse([string]$manifest.size, [ref]$assetSize) -or $assetSize -lt 100KB -or $assetSize -gt 64MB) {
        throw '更新文件大小无效。'
    }
    $hash = [string]$manifest.sha256
    if ($hash -notmatch '^[0-9a-fA-F]{64}$') { throw '更新清单中的 SHA-256 无效。' }

    $tag = 'v' + $latestVersion.ToString(3)
    $htmlUri = [Uri]('https://github.com/' + $Repository + '/releases/tag/' + $tag)
    $assetUri = [Uri]('https://github.com/' + $Repository + '/releases/download/' + $tag + '/' + $expectedAssetName)

    [pscustomobject]@{
        Operation = 'Check'
        CurrentVersion = $installedVersion.ToString()
        LatestVersion = $latestVersion.ToString()
        UpdateAvailable = $latestVersion -gt $installedVersion
        HtmlUrl = $htmlUri.AbsoluteUri
        AssetUrl = $assetUri.AbsoluteUri
        AssetName = $expectedAssetName
        AssetSize = $assetSize
        Digest = 'sha256:' + $hash.ToUpperInvariant()
    }
}
finally {
    if ($null -ne $response) { $response.Dispose() }
    $request.Dispose()
    $client.Dispose()
    $handler.Dispose()
}
'@
            [void]$worker.AddScript($checkScript)
            [void]$worker.AddArgument([string]$script:UpdateManifestUrl)
            [void]$worker.AddArgument([string]$script:UpdateRepository)
            [void]$worker.AddArgument([string]$script:AppVersion)
            $updateStatusText.Text = '正在安全检查 GitHub Release…'
        }
        else {
            if ($null -eq $Release) {
                throw '缺少待下载的 Release 信息。'
            }
            $updateDirectory = Join-Path $script:StateRoot ('updates\v' + [string]$Release.LatestVersion)
            [void][IO.Directory]::CreateDirectory($updateDirectory)
            $downloadScript = @'
param($DownloadUrl, $AssetName, $ExpectedSize, $ExpectedDigest, $OutputDirectory, $CurrentVersion)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

$downloadUri = [Uri]$DownloadUrl
if ($downloadUri.Scheme -ne 'https' -or $downloadUri.Host -ne 'github.com' -or
    -not $downloadUri.AbsolutePath.StartsWith('/HankLiu2020/LanZ-Monitor/releases/download/', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Release 下载地址未通过安全校验。'
}
if ($ExpectedDigest -notmatch '^sha256:([0-9a-fA-F]{64})$') {
    throw 'Release 没有可用的 SHA-256 摘要，已拒绝自动下载。'
}
if ($AssetName -notmatch '^LanZ-Monitor-v\d+\.\d+\.\d+\.exe$') {
    throw 'Release 附件名称未通过安全校验。'
}
$assetVersion = [Version]($AssetName -replace '^LanZ-Monitor-v(\d+\.\d+\.\d+)\.exe$', '$1')
$downloadFileName = [Uri]::UnescapeDataString([IO.Path]::GetFileName($downloadUri.AbsolutePath))
if ($downloadFileName -cne $AssetName) {
    throw 'Release 下载地址与附件名称不一致。'
}
$expectedHash = $matches[1].ToUpperInvariant()
$expectedLength = [long]$ExpectedSize
if ($expectedLength -lt 100KB -or $expectedLength -gt 64MB) {
    throw 'Release 文件大小超出允许范围。'
}

$temporaryPath = Join-Path $OutputDirectory ($AssetName + '.download')
$readyPath = Join-Path $OutputDirectory ($AssetName + '.ready')
if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
if (Test-Path -LiteralPath $readyPath) { Remove-Item -LiteralPath $readyPath -Force }

$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.UseCookies = $false
$handler.AllowAutoRedirect = $true
$handler.CheckCertificateRevocationList = $true
$client = [System.Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromMinutes(2)
$request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $downloadUri)
$response = $null
$inputStream = $null
$outputStream = $null
try {
    [void]$request.Headers.UserAgent.ParseAdd('LanZ-Monitor/' + $CurrentVersion)
    [void]$request.Headers.TryAddWithoutValidation('Accept', 'application/octet-stream')
    $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    if (-not $response.IsSuccessStatusCode) {
        throw ('GitHub 下载返回 HTTP ' + [int]$response.StatusCode)
    }
    $declaredLength = $response.Content.Headers.ContentLength
    if ($null -ne $declaredLength -and [long]$declaredLength -ne $expectedLength) {
        throw 'Release 下载大小与元数据不一致。'
    }
    $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $outputStream = [IO.File]::Create($temporaryPath)
    $buffer = New-Object byte[] 81920
    $total = [long]0
    while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $total += $read
        if ($total -gt $expectedLength -or $total -gt 64MB) {
            throw 'Release 下载内容超出声明大小。'
        }
        $outputStream.Write($buffer, 0, $read)
    }
    $outputStream.Dispose()
    $outputStream = $null
    if ($total -ne $expectedLength) {
        throw 'Release 下载不完整。'
    }

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $fileStream = [IO.File]::OpenRead($temporaryPath)
        try { $actualHash = ([BitConverter]::ToString($sha.ComputeHash($fileStream))).Replace('-', '') }
        finally { $fileStream.Dispose() }
    }
    finally { $sha.Dispose() }
    if ($actualHash -cne $expectedHash) {
        throw 'Release SHA-256 校验失败，已拒绝安装。'
    }
    $downloadedVersion = [Version][Diagnostics.FileVersionInfo]::GetVersionInfo($temporaryPath).FileVersion
    if ($downloadedVersion.Major -ne $assetVersion.Major -or
        $downloadedVersion.Minor -ne $assetVersion.Minor -or
        $downloadedVersion.Build -ne $assetVersion.Build) {
        throw 'Release 文件版本与附件名称不一致。'
    }
    [IO.File]::Move($temporaryPath, $readyPath)
    [pscustomobject]@{ Operation = 'Download'; ReadyPath = $readyPath; AssetName = $AssetName; Sha256 = $actualHash }
}
finally {
    if ($null -ne $outputStream) { $outputStream.Dispose() }
    if ($null -ne $inputStream) { $inputStream.Dispose() }
    if ($null -ne $response) { $response.Dispose() }
    $request.Dispose()
    $client.Dispose()
    $handler.Dispose()
    if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
}
'@
            [void]$worker.AddScript($downloadScript)
            [void]$worker.AddArgument([string]$Release.AssetUrl)
            [void]$worker.AddArgument([string]$Release.AssetName)
            [void]$worker.AddArgument([long]$Release.AssetSize)
            [void]$worker.AddArgument([string]$Release.Digest)
            [void]$worker.AddArgument([string]$updateDirectory)
            [void]$worker.AddArgument([string]$script:AppVersion)
            $updateStatusText.Text = '正在下载并校验更新…'
        }

        $script:UpdateWorker = [pscustomobject]@{
            Operation = $Operation
            PowerShell = $worker
            Handle = $worker.BeginInvoke()
        }
        $script:UpdateInProgress = $true
        $updateButton.IsEnabled = $false
        $updatePollTimer.Start()
    }
    catch {
        $worker.Dispose()
        $script:UpdateInProgress = $false
        $updateButton.IsEnabled = $true
        throw
    }
}

function Start-LanZVerifiedUpdateInstall {
    param(
        [Parameter(Mandatory)][string]$ReadyPath,
        [Parameter(Mandatory)][ValidatePattern('^LanZ-Monitor-v\d+\.\d+\.\d+\.exe$')][string]$TargetFileName,
        [Parameter(Mandatory)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ExpectedSha256,
        [Parameter(Mandatory)][string]$ReleaseUrl
    )

    $currentExecutable = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ([IO.Path]::GetFileName($currentExecutable) -notmatch '^(?:LanZ-Monitor(?:-v\d+\.\d+\.\d+)?|v\d+\.\d+\.\d+-LanZ-Monitor)\.exe$') {
        $updateStatusText.Text = '源码运行模式不能自替换，请从 Release 页面更新。'
        Open-LanZReleasePage -Url $ReleaseUrl
        return
    }
    if (-not (Test-Path -LiteralPath $ReadyPath)) {
        throw '已校验的更新文件不存在。'
    }

    $targetDirectory = Split-Path -Parent $currentExecutable
    $targetExecutable = Join-Path $targetDirectory $TargetFileName
    $writeTestPath = Join-Path $targetDirectory ('.lanz-update-write-test-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($writeTestPath, '')
    }
    catch {
        $updateStatusText.Text = '程序目录不可写，请从 Release 页面手动更新。'
        Open-LanZReleasePage -Url $ReleaseUrl
        return
    }
    finally {
        if (Test-Path -LiteralPath $writeTestPath) { Remove-Item -LiteralPath $writeTestPath -Force -ErrorAction SilentlyContinue }
    }

    $quoteLiteral = {
        param([string]$Value)
        "'" + $Value.Replace("'", "''") + "'"
    }
    $currentLiteral = & $quoteLiteral $currentExecutable
    $targetLiteral = & $quoteLiteral $targetExecutable
    $readyLiteral = & $quoteLiteral ([IO.Path]::GetFullPath($ReadyPath))
    $logLiteral = & $quoteLiteral (Join-Path $script:DataDirectory 'update.log')
    $hashLiteral = & $quoteLiteral $ExpectedSha256.ToUpperInvariant()
    $updaterCode = @"
`$ErrorActionPreference = 'Stop'
`$waitProcessId = $PID
`$currentPath = $currentLiteral
`$targetPath = $targetLiteral
`$readyPath = $readyLiteral
`$logPath = $logLiteral
`$expectedHash = $hashLiteral
`$replacementPath = `$targetPath + '.update'
`$backupPath = `$targetPath + '.previous'
`$targetExisted = Test-Path -LiteralPath `$targetPath
`$oldRestarted = `$false
function Write-UpdateLog([string]`$message) {
    try {
        if ((Test-Path -LiteralPath `$logPath) -and (Get-Item -LiteralPath `$logPath).Length -gt 256KB) {
            Remove-Item -LiteralPath (`$logPath + '.old') -Force -ErrorAction SilentlyContinue
            Move-Item -LiteralPath `$logPath -Destination (`$logPath + '.old') -Force
        }
        Add-Content -LiteralPath `$logPath -Value ('[{0}] {1}' -f [DateTime]::Now.ToString('s'), `$message) -Encoding UTF8
    } catch { }
}
try {
    for (`$i = 0; `$i -lt 120; `$i++) {
        if (`$null -eq (Get-Process -Id `$waitProcessId -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 250
    }
    if (`$null -ne (Get-Process -Id `$waitProcessId -ErrorAction SilentlyContinue)) { throw '旧版本未能及时退出。' }
    `$sha = [Security.Cryptography.SHA256]::Create()
    try {
        `$readyStream = [IO.File]::OpenRead(`$readyPath)
        try { `$readyHash = ([BitConverter]::ToString(`$sha.ComputeHash(`$readyStream))).Replace('-', '') }
        finally { `$readyStream.Dispose() }
    }
    finally { `$sha.Dispose() }
    if (`$readyHash -cne `$expectedHash) { throw '安装前 SHA-256 复核失败。' }
    Remove-Item -LiteralPath `$replacementPath -Force -ErrorAction SilentlyContinue
    [IO.File]::Copy(`$readyPath, `$replacementPath, `$true)
    Remove-Item -LiteralPath `$backupPath -Force -ErrorAction SilentlyContinue
    if (`$targetExisted) {
        try {
            [IO.File]::Replace(`$replacementPath, `$targetPath, `$backupPath, `$true)
        }
        catch {
            Move-Item -LiteralPath `$targetPath -Destination `$backupPath -Force
            Move-Item -LiteralPath `$replacementPath -Destination `$targetPath -Force
        }
    }
    else {
        Move-Item -LiteralPath `$replacementPath -Destination `$targetPath -Force
    }
    try {
        `$newProcess = Start-Process -FilePath `$targetPath -PassThru
        Start-Sleep -Seconds 3
        if (`$newProcess.HasExited) {
            throw ('新版本启动后意外退出，exitCode=' + `$newProcess.ExitCode)
        }
        `$newProcess.Dispose()
        Write-UpdateLog 'update installed and restarted'
        Remove-Item -LiteralPath `$readyPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath `$backupPath -Force -ErrorAction SilentlyContinue
        if (`$currentPath -ne `$targetPath) {
            Remove-Item -LiteralPath `$currentPath -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        if (Test-Path -LiteralPath `$backupPath) {
            [IO.File]::Copy(`$backupPath, `$targetPath, `$true)
        }
        elseif (-not `$targetExisted) {
            Remove-Item -LiteralPath `$targetPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath `$currentPath) {
            Start-Process -FilePath `$currentPath
            `$oldRestarted = `$true
        }
        throw
    }
}
catch {
    Write-UpdateLog ('update failed: ' + `$_.Exception.Message)
    Remove-Item -LiteralPath `$replacementPath -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath `$targetPath) -and (Test-Path -LiteralPath `$backupPath)) {
        Move-Item -LiteralPath `$backupPath -Destination `$targetPath -Force -ErrorAction SilentlyContinue
    }
    if (-not `$oldRestarted -and (Test-Path -LiteralPath `$currentPath)) {
        Start-Process -FilePath `$currentPath -ErrorAction SilentlyContinue
    }
}
"@
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($updaterCode))
    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $powerShellPath
    $startInfo.Arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand ' + $encodedCommand
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) {
        throw '无法启动本地更新替换程序。'
    }
    $process.Dispose()
    $script:ExitRequested = $true
    $window.Close()
}

function Complete-LanZUpdateOperation {
    if ($null -eq $script:UpdateWorker -or -not $script:UpdateWorker.Handle.IsCompleted) {
        return
    }

    $updatePollTimer.Stop()
    $worker = $script:UpdateWorker
    $script:UpdateWorker = $null
    $script:UpdateInProgress = $false
    $updateButton.IsEnabled = $true
    try {
        $result = @($worker.PowerShell.EndInvoke($worker.Handle) | Select-Object -Last 1)[0]
        if ($null -eq $result) { throw '更新操作没有返回结果。' }
        if ([string]$result.Operation -eq 'Check') {
            $script:PendingUpdate = $result
            if (-not [bool]$result.UpdateAvailable) {
                $updateStatusText.Text = '已是最新版本 v' + [string]$script:AppVersion
                return
            }
            if ([string]::IsNullOrWhiteSpace([string]$result.AssetUrl)) {
                $updateStatusText.Text = '新版本未附带正确命名的 EXE。'
                [void][Windows.MessageBox]::Show('发现新版本，但没有可用的 EXE 附件。请查看官方 Release 页面。', 'LanZ Monitor 更新', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Warning)
                Open-LanZReleasePage -Url ([string]$result.HtmlUrl)
                return
            }
            if ([string]$result.Digest -notmatch '^sha256:[0-9a-fA-F]{64}$') {
                $updateStatusText.Text = '新版本缺少 SHA-256，已禁止自动安装。'
                $choice = [Windows.MessageBox]::Show('发现新版本 v' + [string]$result.LatestVersion + '，但 GitHub 没有提供可校验的 SHA-256。为安全起见不会自动下载。是否打开官方 Release 页面？', 'LanZ Monitor 更新', [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Warning)
                if ($choice -eq [Windows.MessageBoxResult]::Yes) { Open-LanZReleasePage -Url ([string]$result.HtmlUrl) }
                return
            }
            $updateStatusText.Text = '发现新版本 v' + [string]$result.LatestVersion
            Start-LanZUpdateOperation -Operation Download -Release $result
        }
        elseif ([string]$result.Operation -eq 'Download') {
            $updateStatusText.Text = '更新已下载并通过 SHA-256 校验。'
            $choice = [Windows.MessageBox]::Show('更新已下载并通过 SHA-256 校验。是否现在退出程序、完成替换并重新启动？', 'LanZ Monitor 更新', [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Information)
            if ($choice -eq [Windows.MessageBoxResult]::Yes) {
                Start-LanZVerifiedUpdateInstall -ReadyPath ([string]$result.ReadyPath) -TargetFileName ([string]$result.AssetName) -ExpectedSha256 ([string]$result.Sha256) -ReleaseUrl ([string]$script:PendingUpdate.HtmlUrl)
            }
        }
    }
    catch {
        $errorMessage = $_.Exception.GetBaseException().Message
        $updateStatusText.Text = '更新失败：' + $errorMessage
        [void][Windows.MessageBox]::Show($updateStatusText.Text, 'LanZ Monitor 更新', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Warning)
    }
    finally {
        $worker.PowerShell.Dispose()
    }
}

$timer = [Windows.Threading.DispatcherTimer]::new()
Set-LanZJitteredInterval
$timer.Add_Tick({
    Update-Widget
    Set-LanZJitteredInterval
})
$refreshPollTimer = [Windows.Threading.DispatcherTimer]::new()
$refreshPollTimer.Interval = [TimeSpan]::FromMilliseconds(120)
$refreshPollTimer.Add_Tick({ Complete-LanZRefresh })
$updatePollTimer = [Windows.Threading.DispatcherTimer]::new()
$updatePollTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$updatePollTimer.Add_Tick({ Complete-LanZUpdateOperation })
$script:BrowserCaptureTimer = [Windows.Threading.DispatcherTimer]::new()
$script:BrowserCaptureTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:BrowserCaptureTimer.Add_Tick({ Step-LanZBrowserCapture })
$script:ResumeUiTimer = [Windows.Threading.DispatcherTimer]::new()
$script:ResumeUiTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:ResumeUiTimer.Add_Tick({
    $script:ResumeUiTimer.Stop()
    if ($window.IsVisible -and $script:BrowserUiRefreshPending) {
        $script:BrowserUiRefreshPending = $false
        Update-LanZFromBrowserCapture
    }
})
$startupTimer = [Windows.Threading.DispatcherTimer]::new()
$startupTimer.Interval = [TimeSpan]::FromSeconds(5)
$startupTimer.Add_Tick({
    $startupTimer.Stop()
    Update-Widget
    if ($autoRefreshToggle.IsChecked -and -not $script:LoginWindowOpen) {
        $timer.Start()
    }
})
$refreshButton.Add_Click({ Update-Widget -Force })
$autoRefreshToggle.Add_Checked({
    Save-LanZUiPreferences
    $script:SuppressAutoLogin = $false
    Start-LanZBrowserCapture
    Update-Widget
    if ($autoRefreshToggle.IsChecked -and -not $script:LoginWindowOpen) {
        $timer.Start()
    }
})
$autoRefreshToggle.Add_Unchecked({
    Save-LanZUiPreferences
    $timer.Stop()
    Stop-LanZBrowserCapture
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
$updateButton.Add_Click({
    try {
        Start-LanZUpdateOperation -Operation Check
    }
    catch {
        $updateStatusText.Text = '更新失败：' + $_.Exception.GetBaseException().Message
    }
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
    if ($null -ne $script:TrayPinMenu) {
        $script:TrayPinMenu.Checked = $true
    }
})
$pinToggle.Add_Unchecked({
    $window.Topmost = $false
    $pinToggle.ToolTip = '未置顶，点击置顶'
    if ($null -ne $script:TrayPinMenu) {
        $script:TrayPinMenu.Checked = $false
    }
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
    $script:ModelOrderUserDefined = $true
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
$closeButton.Add_Click({ Hide-LanZMainWindow })
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
$window.Add_Closing({
    if (-not $script:ExitRequested -and [string]::IsNullOrWhiteSpace($ScreenshotPath) -and [string]::IsNullOrWhiteSpace($SettingsScreenshotPath)) {
        $_.Cancel = $true
        Hide-LanZMainWindow
    }
})
$window.Add_Loaded({
    Update-LanZQuotaVisibility
    Show-LanZCachedStatus
    if (-not [string]::IsNullOrWhiteSpace($ScreenshotPath) -or -not [string]::IsNullOrWhiteSpace($SettingsScreenshotPath)) {
        Update-Widget -Force
        if (-not [string]::IsNullOrWhiteSpace($SettingsScreenshotPath)) {
            $settingsButton.IsChecked = $true
        }
        $screenshotNotBefore = [DateTime]::UtcNow.AddSeconds(25)
        $screenshotDeadline = [DateTime]::UtcNow.AddSeconds(40)
        $screenshotTimer = [Windows.Threading.DispatcherTimer]::new()
        $screenshotTimer.Interval = [TimeSpan]::FromMilliseconds(500)
        $screenshotTimer.Add_Tick({
            if ([DateTime]::UtcNow -lt $screenshotNotBefore) {
                return
            }
            $browserManualRefreshActive = $null -ne $script:BrowserCaptureState -and [bool]$script:BrowserCaptureState.ManualRefreshActive
            if (($script:RefreshInProgress -or $browserManualRefreshActive) -and [DateTime]::UtcNow -lt $screenshotDeadline) {
                return
            }
            $screenshotTimer.Stop()
            if (-not [string]::IsNullOrWhiteSpace($ScreenshotPath)) {
                Export-LanZWindowScreenshot -TargetWindow $window -Path $ScreenshotPath
            }
            if (-not [string]::IsNullOrWhiteSpace($SettingsScreenshotPath)) {
                Export-LanZWindowScreenshot -TargetWindow $settingsPopup.Child -Path $SettingsScreenshotPath
            }
            $script:ExitRequested = $true
            $window.Close()
        }.GetNewClosure())
        $screenshotTimer.Start()
        return
    }
    try {
        Initialize-LanZTrayIcon
        $needsInitialLogin = -not (Test-Path -LiteralPath $script:SessionPath)
        if ($needsInitialLogin) {
            [void]$window.Dispatcher.BeginInvoke([Action]{ Show-LanZLogin -ClearExistingSession })
            return
        }
        Start-LanZBrowserCapture
    }
    catch {
        $updatedText.Text = '托盘初始化失败，主窗口仍可使用'
        $updatedText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#E6A23C')
    }
    $startupTimer.Start()
})
$window.Add_Closed({
    $startupTimer.Stop()
    $timer.Stop()
    $refreshPollTimer.Stop()
    $updatePollTimer.Stop()
    $script:ResumeUiTimer.Stop()
    Stop-LanZBrowserCapture
    Dispose-LanZTrayIcon
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
    if ($null -ne $script:UpdateWorker) {
        try { $script:UpdateWorker.PowerShell.Stop() } catch { }
        $script:UpdateWorker.PowerShell.Dispose()
        $script:UpdateWorker = $null
        $script:UpdateInProgress = $false
    }
})

$application = [Windows.Application]::new()
$application.ShutdownMode = [Windows.ShutdownMode]::OnMainWindowClose
[void]$application.Run($window)
}
finally {
    if ($null -ne $script:SharedHttpClient) {
        $script:SharedHttpClient.Dispose()
        $script:SharedHttpClient = $null
    }
    if ($null -ne $script:SharedHttpHandler) {
        $script:SharedHttpHandler.Dispose()
        $script:SharedHttpHandler = $null
    }
    $singleInstanceMutex.ReleaseMutex()
    $singleInstanceMutex.Dispose()
}
