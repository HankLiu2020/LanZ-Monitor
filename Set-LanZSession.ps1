param(
    [switch]$Reconfigure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Security

$scriptRootValue = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $PSScriptRoot
}
else {
    Get-Variable -Name ScriptRoot -ValueOnly -ErrorAction SilentlyContinue
}
$appDirectory = if (-not [string]::IsNullOrWhiteSpace([string]$scriptRootValue)) {
    [string]$scriptRootValue
}
else {
    Split-Path -Parent ([Environment]::GetCommandLineArgs()[0])
}
$stateRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'LanZ-Monitor'
$secretsDirectory = Join-Path $stateRoot 'secrets'
[void][IO.Directory]::CreateDirectory($secretsDirectory)
$configPath = Join-Path $secretsDirectory 'connection.bin'
$sessionPath = Join-Path $secretsDirectory 'session.bin'
foreach ($legacyPair in @(
    @{ Old = (Join-Path $appDirectory '.lanz-config.bin'); New = $configPath },
    @{ Old = (Join-Path $appDirectory '.lanz-session.bin'); New = $sessionPath }
)) {
    if ((Test-Path -LiteralPath $legacyPair.Old) -and -not (Test-Path -LiteralPath $legacyPair.New)) {
        try {
            [IO.File]::Move($legacyPair.Old, $legacyPair.New)
        }
        catch {
            [IO.File]::Copy($legacyPair.Old, $legacyPair.New, $false)
        }
    }
}
$requestTokenKey = $null
$requestTokenIV = $null

function Read-SecretValue {
    param([Parameter(Mandatory)][string]$Prompt)

    $secureValue = Read-Host $Prompt -AsSecureString
    $pointer = [IntPtr]::Zero
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureValue)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        if ($pointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        }
    }
}

function Protect-AndSave {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Path
    )

    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    try {
        $protectedBytes = [System.Security.Cryptography.ProtectedData]::Protect(
            $plainBytes,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        [System.IO.File]::WriteAllBytes($Path, $protectedBytes)
    }
    finally {
        [Array]::Clear($plainBytes, 0, $plainBytes.Length)
    }
}

if ($Reconfigure -or -not (Test-Path -LiteralPath $configPath)) {
    Write-Host '首次配置：以下连接信息只会以 Windows DPAPI 加密形式保存在本机。' -ForegroundColor Cyan
    $apiEndpoint = (Read-Host '模型状态 API 的 HTTPS 地址').Trim()
    $usageEndpoint = (Read-Host '当日请求用量 API 的 HTTPS 地址').Trim()
    $usageDashboardUrl = (Read-Host '资源看板页面的 HTTPS 地址').Trim()
    $loginUrl = (Read-Host '网页登录入口的 HTTPS 地址').Trim()
    $sessionCookieName = (Read-Host '会话 Cookie 名称').Trim()
    $requestTokenHeader = (Read-Host '请求令牌 Header 名称').Trim()
    $requestTokenPrefix = Read-Host '请求令牌明文前缀（可为空）'
    $requestTokenKey = Read-SecretValue 'AES 密钥（输入不会显示）'
    $requestTokenIV = Read-SecretValue 'AES IV（输入不会显示）'
    $successCodeText = Read-Host '接口成功代码'
    $unauthorizedCodeText = Read-Host '会话失效代码'

    $apiUri = $null
    $usageUri = $null
    $usageDashboardUri = $null
    $loginUri = $null
    if (-not [Uri]::TryCreate($apiEndpoint, [UriKind]::Absolute, [ref]$apiUri) -or $apiUri.Scheme -ne 'https') {
        throw 'API 地址必须是有效的 HTTPS URL。'
    }
    if (-not [Uri]::TryCreate($usageEndpoint, [UriKind]::Absolute, [ref]$usageUri) -or $usageUri.Scheme -ne 'https') {
        throw '用量 API 地址必须是有效的 HTTPS URL。'
    }
    if (-not [Uri]::TryCreate($usageDashboardUrl, [UriKind]::Absolute, [ref]$usageDashboardUri) -or $usageDashboardUri.Scheme -ne 'https') {
        throw '资源看板地址必须是有效的 HTTPS URL。'
    }
    if (-not [Uri]::TryCreate($loginUrl, [UriKind]::Absolute, [ref]$loginUri) -or $loginUri.Scheme -ne 'https') {
        throw '登录地址必须是有效的 HTTPS URL。'
    }
    if ([string]::IsNullOrWhiteSpace($sessionCookieName) -or [string]::IsNullOrWhiteSpace($requestTokenHeader)) {
        throw 'Cookie 名称和请求令牌 Header 名称不能为空。'
    }

    $keyLength = [System.Text.Encoding]::UTF8.GetByteCount($requestTokenKey)
    $ivLength = [System.Text.Encoding]::UTF8.GetByteCount($requestTokenIV)
    if ($keyLength -notin @(16, 24, 32)) {
        throw 'AES 密钥必须是 16、24 或 32 字节。'
    }
    if ($ivLength -ne 16) {
        throw 'AES IV 必须是 16 字节。'
    }

    $successCode = 0
    $unauthorizedCode = 0
    if (-not [int]::TryParse($successCodeText, [ref]$successCode) -or -not [int]::TryParse($unauthorizedCodeText, [ref]$unauthorizedCode)) {
        throw '接口代码必须是整数。'
    }

    $configuration = [ordered]@{
        ApiEndpoint        = $apiEndpoint
        UsageEndpoint      = $usageEndpoint
        UsageDashboardUrl  = $usageDashboardUrl
        LoginUrl           = $loginUrl
        SessionCookieName  = $sessionCookieName
        RequestTokenHeader = $requestTokenHeader
        RequestTokenPrefix = $requestTokenPrefix
        RequestTokenKey    = $requestTokenKey
        RequestTokenIV     = $requestTokenIV
        SuccessCode        = $successCode
        UnauthorizedCode   = $unauthorizedCode
    }
    Protect-AndSave -Value ($configuration | ConvertTo-Json -Compress) -Path $configPath
    Write-Host '连接配置已加密保存。' -ForegroundColor Green
}

$sessionValue = Read-SecretValue '请输入当前会话值（输入不会显示）'
try {
    if ([string]::IsNullOrWhiteSpace($sessionValue) -or $sessionValue -eq '0') {
        throw '会话值不能为空。'
    }
    Protect-AndSave -Value $sessionValue.Trim() -Path $sessionPath
    Write-Host '会话值已使用 Windows DPAPI 加密保存。' -ForegroundColor Green
}
finally {
    $sessionValue = $null
    $requestTokenKey = $null
    $requestTokenIV = $null
}
