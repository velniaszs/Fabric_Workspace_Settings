<#
.SYNOPSIS
    Lists Outbound Access Protection (OAP) data connection rules for a Fabric workspace.

.DESCRIPTION
    Calls GET /v1/workspaces/{id}/networking/communicationPolicy/outbound/connections
    and returns one object per connection-type rule.

    By default only ACTIVE rules are returned - those whose defaultAction is 'Allow'.
    Use -IncludeAll to see denied rules as well.

    Also reports whether OAP itself is enabled on the workspace. When OAP is off these
    rules are inert configuration and enforce nothing.

.PARAMETER WorkspaceId
    The Fabric workspace GUID.

.PARAMETER TenantId
    Entra tenant ID. Falls back to $env:FABRIC_TENANT_ID.
    Supply tenant, client and secret together to authenticate as a service principal.
    Supply none of them to use the current Az PowerShell sign-in.

.PARAMETER ClientId
    Application (client) ID of the service principal. Falls back to $env:FABRIC_CLIENT_ID.

.PARAMETER ClientSecret
    Client secret, as a SecureString. Falls back to $env:FABRIC_CLIENT_SECRET.

.PARAMETER IncludeAll
    Return denied rules too, not just active ones.

.PARAMETER CsvPath
    Also write the results to this path as CSV. Lists are flattened to semicolon-separated
    text so the file opens cleanly in Excel.

.EXAMPLE
    Connect-AzAccount
    .\Get-FabricOutboundRules.ps1 -WorkspaceId '00000000-0000-0000-0000-000000000000'

.EXAMPLE
    $secret = Read-Host 'Client secret' -AsSecureString
    .\Get-FabricOutboundRules.ps1 -WorkspaceId $ws -TenantId $tid -ClientId $cid -ClientSecret $secret

.EXAMPLE
    $env:FABRIC_TENANT_ID     = '<tenant>'
    $env:FABRIC_CLIENT_ID     = '<client>'
    $env:FABRIC_CLIENT_SECRET = '<secret>'
    .\Get-FabricOutboundRules.ps1 -WorkspaceId $ws

.EXAMPLE
    # Export to CSV. -CsvPath goes on the same call, after -WorkspaceId.
    .\Get-FabricOutboundRules.ps1 -WorkspaceId '00000000-0000-0000-0000-000000000000' -CsvPath '.\outbound-rules.csv'

.EXAMPLE
    # Everything together: service principal, denied rules included, exported.
    .\Get-FabricOutboundRules.ps1 -WorkspaceId $ws -TenantId $tid -ClientId $cid -ClientSecret $secret -IncludeAll -CsvPath 'C:\temp\rules.csv'

.NOTES
    Requires Contributor (or higher) on the workspace.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$WorkspaceId,

    [string]$TenantId,

    [string]$ClientId,

    [securestring]$ClientSecret,

    [string]$CsvPath,

    [switch]$IncludeAll
)

$ErrorActionPreference = 'Stop'
$resource = 'https://api.fabric.microsoft.com'

if (-not $TenantId) { $TenantId = $env:FABRIC_TENANT_ID }
if (-not $ClientId) { $ClientId = $env:FABRIC_CLIENT_ID }
if (-not $ClientSecret -and -not [string]::IsNullOrWhiteSpace($env:FABRIC_CLIENT_SECRET)) {
    $ClientSecret = ConvertTo-SecureString $env:FABRIC_CLIENT_SECRET -AsPlainText -Force
}

# Any one of the three means service-principal auth was intended; all three are then required.
if ($TenantId -or $ClientId -or $ClientSecret) {
    $missing = @()
    if (-not $TenantId)     { $missing += 'TenantId (or $env:FABRIC_TENANT_ID)' }
    if (-not $ClientId)     { $missing += 'ClientId (or $env:FABRIC_CLIENT_ID)' }
    if (-not $ClientSecret) { $missing += 'ClientSecret (or $env:FABRIC_CLIENT_SECRET)' }
    if ($missing) {
        throw "Incomplete service principal credentials. Missing: $($missing -join ', ')."
    }
}

function Get-FabricToken {
    param($TenantId, $ClientId, [securestring]$ClientSecret, $Resource)

    if ($ClientId) {
        $body = @{
            client_id     = $ClientId
            scope         = "$Resource/.default"
            client_secret = [System.Net.NetworkCredential]::new('', $ClientSecret).Password
            grant_type    = 'client_credentials'
        }
        $uri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
        return (Invoke-RestMethod -Method Post -Uri $uri -Body $body -ContentType 'application/x-www-form-urlencoded').access_token
    }

    if (-not (Get-Command Get-AzAccessToken -ErrorAction SilentlyContinue)) {
        throw "Az.Accounts is not available. Install-Module Az.Accounts, run Connect-AzAccount, or pass -TenantId/-ClientId/-ClientSecret."
    }
    $t = Get-AzAccessToken -ResourceUrl $Resource
    # Newer Az versions return the token as a SecureString.
    if ($t.Token -is [securestring]) { return [System.Net.NetworkCredential]::new('', $t.Token).Password }
    return $t.Token
}

$token = Get-FabricToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret -Resource $resource
$headers = @{ Authorization = "Bearer $token"; Accept = 'application/json' }
$base = "$resource/v1/workspaces/$WorkspaceId/networking/communicationPolicy"

try {
    $policy = Invoke-RestMethod -Method Get -Uri $base -Headers $headers
    $oapEnabled = ($policy.outbound.publicAccessRules.defaultAction -eq 'Deny')

    $response = Invoke-RestMethod -Method Get -Uri "$base/outbound/connections" -Headers $headers
}
catch {
    $status = $_.Exception.Response.StatusCode.value__
    switch ($status) {
        401 { throw "401 Unauthorized - the token is missing, expired, or for the wrong resource." }
        403 { throw "403 Forbidden - the identity lacks permission on workspace $WorkspaceId." }
        404 { throw "404 Not Found - workspace $WorkspaceId does not exist, or OAP is not available on it." }
        default { throw }
    }
}

if (-not $oapEnabled) {
    Write-Warning "Outbound Access Protection is OFF for this workspace. The rules below are stored but enforce nothing."
}

$rules = @($response.rules)
if (-not $IncludeAll) { $rules = $rules | Where-Object { $_.defaultAction -eq 'Allow' } }

if (-not $rules) {
    Write-Host "No $(if ($IncludeAll) { '' } else { 'active ' })outbound connection rules found." -ForegroundColor Yellow
    return
}

# Flattens anything the API returns - string, array or nested object - into one CSV-safe cell.
function ConvertTo-FlatString {
    param($Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [System.Collections.IEnumerable]) {
        return (($Value | ForEach-Object { ConvertTo-FlatString $_ }) -join '; ')
    }
    if ($Value -is [psobject] -and $Value.PSObject.Properties.Count -gt 0) {
        # An object where a plain value was expected - keep every field rather than lose data.
        return (ConvertTo-Json $Value -Compress -Depth 5)
    }
    return [string]$Value
}

$results = $rules | ForEach-Object {
    [pscustomobject]@{
        WorkspaceId       = $WorkspaceId
        OapEnabled        = $oapEnabled
        ConnectionType    = ConvertTo-FlatString $_.connectionType
        DefaultAction     = ConvertTo-FlatString $_.defaultAction
        EndpointCount     = @($_.allowedEndpoints).Count
        WorkspaceCount    = @($_.allowedWorkspaces).Count
        AllowedEndpoints  = ConvertTo-FlatString @($_.allowedEndpoints  | ForEach-Object { $_.hostnamePattern })
        AllowedWorkspaces = ConvertTo-FlatString @($_.allowedWorkspaces | ForEach-Object { $_.workspaceId })
    }
}

if ($CsvPath) {
    $dir = Split-Path -Parent $CsvPath
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $results | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "Wrote $($results.Count) row(s) to $CsvPath" -ForegroundColor Green
}

$results
