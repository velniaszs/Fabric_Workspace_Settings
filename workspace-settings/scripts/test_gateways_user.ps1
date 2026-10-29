<#
.SYNOPSIS
    Lists Fabric gateways as the signed-in user, without any app registration, client ID or secret.

.DESCRIPTION
    The user signs in with Azure CLI (az login), so the token is delegated and issued to Microsoft's
    Azure CLI client - not to SVC_PROD_AT43156_FABRIC_POLICY. The gateway list reflects the user's own
    Fabric roles, so it should match what the FabricSetting connector returns for the same user; any
    difference points at the connector's app (consent, scopes), not at the user's permissions.

    Requires Azure CLI: https://aka.ms/installazurecliwindows

.EXAMPLE
    .\test_gateways_user.ps1
.EXAMPLE
    .\test_gateways_user.ps1 -UseDeviceCode
.EXAMPLE
    .\test_gateways_user.ps1 -UseExistingLogin
#>
param(
    [string] $TenantId = '9e929790-272d-4977-a2ab-301443c11ece',
    [switch] $UseDeviceCode,
    # Reuse the current az session instead of signing in again
    [switch] $UseExistingLogin
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) not found. Install it from https://aka.ms/installazurecliwindows' }

function ConvertFrom-Base64Url([string] $s) {
    $s = $s.Replace('-', '+').Replace('_', '/')
    $s += '=' * ((4 - $s.Length % 4) % 4)
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s))
}

function Show-TokenInfo([string] $AccessToken, $TokenResponse) {
    $parts  = $AccessToken.Split('.')
    $header = ConvertFrom-Base64Url $parts[0] | ConvertFrom-Json
    $c      = ConvertFrom-Base64Url $parts[1] | ConvertFrom-Json

    Write-Host "`n===== Access token (encoded) - a live bearer credential: do not share it or paste it into online decoders" -ForegroundColor Cyan
    Write-Host $AccessToken
    Write-Host "`n===== Token header (decoded)" -ForegroundColor Cyan
    Write-Host ($header | ConvertTo-Json -Depth 10)
    Write-Host "`n===== Token claims (decoded)" -ForegroundColor Cyan
    Write-Host ($c | ConvertTo-Json -Depth 10)

    if ($TokenResponse) {
        $r = [ordered]@{}
        foreach ($prop in $TokenResponse.PSObject.Properties) {
            $r[$prop.Name] = if ($prop.Name -match 'token$' -and $prop.Name -notmatch 'type') { "<present, $("$($prop.Value)".Length) chars>" } else { $prop.Value }
        }
        Write-Host "`n===== Token response (tokens redacted)" -ForegroundColor Cyan
        Write-Host (([pscustomobject]$r | Format-List | Out-String).Trim())
    }

    $toLocal  = { param($t) if ($t) { [DateTimeOffset]::FromUnixTimeSeconds([long]$t).LocalDateTime } }
    $callType = if ($c.idtyp -eq 'app' -or ($c.roles -and -not $c.scp)) { 'App-only (service principal)' }
                elseif ($c.scp) { 'Delegated (signed-in user)' } else { 'Unknown' }
    $user     = if ($c.upn) { $c.upn } else { $c.unique_name }
    $appId    = if ($c.appid) { $c.appid } else { $c.azp }
    Write-Host "`n===== Token summary" -ForegroundColor Cyan
    Write-Host (([pscustomobject][ordered]@{
        CallType    = $callType
        App         = if ($c.app_displayname) { "$($c.app_displayname) ($appId)" } else { $appId }
        User        = "$($c.name) <$user>"
        ObjectId    = $c.oid
        Tenant      = $c.tid
        Audience    = $c.aud
        Scopes      = $c.scp
        Roles       = ($c.roles -join ' ')
        AuthMethods = ($c.amr -join ', ')
        IssuedAt    = & $toLocal $c.iat
        ExpiresAt   = & $toLocal $c.exp
    } | Format-List | Out-String).Trim())
}

if (-not $UseExistingLogin) {
    $loginArgs = @('login', '--tenant', $TenantId, '--allow-no-subscriptions', '--only-show-errors', '--output', 'none')
    if ($UseDeviceCode) { $loginArgs += '--use-device-code' }
    Write-Host "Signing in to tenant $TenantId ..." -ForegroundColor Yellow
    & az @loginArgs
    if ($LASTEXITCODE -ne 0) { throw 'az login failed.' }
}

$tokJson = az account get-access-token --tenant $TenantId --resource https://api.fabric.microsoft.com --output json --only-show-errors
if ($LASTEXITCODE -ne 0 -or -not $tokJson) { throw 'Could not get a Fabric token. Run without -UseExistingLogin to sign in.' }
$tok = ($tokJson -join "`n") | ConvertFrom-Json

Show-TokenInfo -AccessToken $tok.accessToken -TokenResponse $tok

$headers = @{ Authorization = "Bearer $($tok.accessToken)" }
$uri  = 'https://api.fabric.microsoft.com/v1/gateways'
$page = 0
$all  = @()

do {
    $page++
    Write-Host "`n===== Page $page : GET $uri" -ForegroundColor Cyan
    try {
        $resp = Invoke-WebRequest -Uri $uri -Headers $headers -Method Get -UseBasicParsing
    } catch {
        $err = $_.Exception.Response
        if ($err) {
            Write-Host "HTTP $([int]$err.StatusCode) $($err.StatusDescription)" -ForegroundColor Red
            Write-Host "RequestId: $($err.Headers['RequestId'])"
            (New-Object IO.StreamReader($err.GetResponseStream())).ReadToEnd()
        } else {
            Write-Host $_.Exception.Message -ForegroundColor Red
        }
        break
    }

    Write-Host "HTTP $($resp.StatusCode) $($resp.StatusDescription)" -ForegroundColor Green
    Write-Host "RequestId: $($resp.Headers['RequestId'])"

    $body = $resp.Content | ConvertFrom-Json
    $all += $body.value
    $uri = if ($body.continuationToken) { "https://api.fabric.microsoft.com/v1/gateways?continuationToken=$([uri]::EscapeDataString($body.continuationToken))" }
} while ($uri)

Write-Host "`n===== Summary: $($all.Count) gateway(s) across $page page(s)" -ForegroundColor Cyan
$all | Format-Table displayName, type, id -AutoSize
