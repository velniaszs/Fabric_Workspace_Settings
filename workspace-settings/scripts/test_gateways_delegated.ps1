<#
.SYNOPSIS
    Lists Fabric gateways with a DELEGATED token issued to the FabricSetting connector's app
    registration (SVC_PROD_AT43156_FABRIC_POLICY) - no client secret and no localhost needed when
    using the Microsoft nativeclient redirect (see option A below).
    Prints the encoded access token, its decoded header and claims, the token response (tokens
    redacted) and a summary (delegated vs app-only, app, user, scopes, expiry).

.DESCRIPTION
    Signs the user in with authorization code + PKCE (or device code with -UseDeviceCode), so the
    token carries the user's identity (scp/upn/oid) and the result is exactly what the custom
    connector returns for that user.

    Redirect options (the connector keeps working unchanged in every case):

    A) -RedirectUri https://login.microsoftonline.com/common/oauth2/nativeclient   (recommended, no secret)
       Microsoft's own redirect for desktop apps - no localhost needed. Prerequisite on the app:
         Authentication > Add a platform > "Mobile and desktop applications" > tick the nativeclient URI.
       "Allow public client flows" is NOT needed (it only covers device code / ROPC / IWA).
       Sign-in happens in a window opened by this script (Windows' built-in browser control), which
       picks the code off the redirect before the page loads - nothing to copy or paste. In a normal
       browser this page deliberately hides the code and bounces to /common/wrongplace.

    B) -UseClientSecret -RedirectUri <an existing *Web* redirect URI>   (no app change, but needs the secret)
       e.g. the connector's own https://global.consent.azure-apim.net/redirect/... URI. Same sign-in window.

    C) Default: loopback http://localhost:<Port>, caught automatically. Requires a "Mobile and desktop
       applications" redirect http://localhost. -Port must not match a Web redirect URI on the app.

    D) -UseDeviceCode: no redirect at all, but requires "Allow public client flows" = Yes and is
       often blocked by Conditional Access.

.EXAMPLE
    .\test_gateways_delegated.ps1 -ClientId <app-client-id> -RedirectUri https://login.microsoftonline.com/common/oauth2/nativeclient
.EXAMPLE
    .\test_gateways_delegated.ps1 -ClientId <app-client-id> -UseClientSecret -RedirectUri <existing Web redirect URI>
.EXAMPLE
    .\test_gateways_delegated.ps1 -ClientId <app-client-id>
.EXAMPLE
    .\test_gateways_delegated.ps1 -ClientId <app-client-id> -UseDeviceCode
#>
param(
    [Parameter(Mandatory)] [string] $ClientId,
    [string] $TenantId = '9e929790-272d-4977-a2ab-301443c11ece',
    # Non-localhost URI => sign-in in an embedded window that intercepts it. Must match the app registration exactly.
    [string] $RedirectUri,
    # Loopback only. Must not be a port registered as a *Web* redirect URI on the app (8400 is), or Entra demands a secret
    [int]    $Port = 8401,
    [switch] $UseDeviceCode,
    [switch] $UseClientSecret
)

$ErrorActionPreference = 'Stop'
if ($UseClientSecret -and $UseDeviceCode) { throw 'Device code is public-client only; -UseClientSecret cannot be combined with it.' }
if ($RedirectUri -and $UseDeviceCode)     { throw 'Device code does not use a redirect URI; -RedirectUri cannot be combined with it.' }
if ($UseClientSecret -and -not $PSBoundParameters.ContainsKey('Port')) { $Port = 8400 }
$scope     = 'https://api.fabric.microsoft.com/Gateway.Read.All offline_access'
$authority = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0"

function ConvertTo-Base64Url([byte[]] $bytes) {
    [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertFrom-Base64Url([string] $s) {
    $s = $s.Replace('-', '+').Replace('_', '/')
    $s += '=' * ((4 - $s.Length % 4) % 4)
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s))
}

# Hosts the sign-in in an embedded browser window and returns the redirect URL (with ?code=) as soon as
# Entra navigates to it - before the page loads. This is the intended use of the nativeclient redirect:
# opened in a normal browser that page deliberately hides the code and bounces to /common/wrongplace.
function Invoke-EmbeddedSignIn([string] $AuthorizeUrl, [string] $RedirectUri) {
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        throw 'The sign-in window needs an STA thread. Run: powershell -STA -ExecutionPolicy Bypass -File .\test_gateways_delegated.ps1 ...'
    }
    Add-Type -AssemblyName System.Windows.Forms

    # The WebBrowser control defaults to IE7 rendering, which the Entra sign-in page does not support.
    # Opt this process into IE11 mode (per user, no admin) and restore the previous value afterwards.
    $key  = 'HKCU:\Software\Microsoft\Internet Explorer\Main\FeatureControl\FEATURE_BROWSER_EMULATION'
    $exe  = [IO.Path]::GetFileName([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    if (-not (Test-Path $key)) { New-Item $key -Force | Out-Null }
    $prev = (Get-ItemProperty $key -Name $exe -ErrorAction SilentlyContinue).$exe
    Set-ItemProperty $key -Name $exe -Value 11001 -Type DWord

    $result  = @{ Url = $null }
    $form    = New-Object Windows.Forms.Form -Property @{
        Text = 'Sign in - Fabric gateway test'; Width = 520; Height = 720; StartPosition = 'CenterScreen'; TopMost = $true
    }
    $browser = New-Object Windows.Forms.WebBrowser -Property @{ Dock = 'Fill'; ScriptErrorsSuppressed = $true }
    $form.Controls.Add($browser)

    # Navigating catches client-side navigations; Navigated catches server-side 302s, which do not always raise Navigating
    $check = {
        param($sender, $e)
        if (-not $result.Url -and $e.Url -and $e.Url.AbsoluteUri.StartsWith($RedirectUri, [StringComparison]::OrdinalIgnoreCase)) {
            $result.Url = $e.Url.AbsoluteUri
            if ($e -is [Windows.Forms.WebBrowserNavigatingEventArgs]) { $e.Cancel = $true }
            $browser.Stop()
            $form.Close()
        }
    }
    $browser.add_Navigating($check)
    $browser.add_Navigated($check)
    $browser.add_NewWindow({ param($sender, $e) $e.Cancel = $true })
    $form.add_Shown({ $form.TopMost = $false; $form.Activate(); $browser.Navigate($AuthorizeUrl) })

    try {
        [void]$form.ShowDialog()
    } finally {
        $browser.Dispose()
        $form.Dispose()
        if ($null -eq $prev) { Remove-ItemProperty $key -Name $exe -ErrorAction SilentlyContinue }
        else { Set-ItemProperty $key -Name $exe -Value $prev -Type DWord }
    }
    if (-not $result.Url) { throw 'The sign-in window was closed before sign-in completed.' }
    $result.Url
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

if ($UseDeviceCode) {
    $dc = Invoke-RestMethod -Method Post "$authority/devicecode" -Body @{ client_id = $ClientId; scope = $scope }
    Write-Host $dc.message -ForegroundColor Yellow
    $deadline = (Get-Date).AddSeconds($dc.expires_in)
    $tok = $null
    while (-not $tok -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $dc.interval
        try {
            $tok = Invoke-RestMethod -Method Post "$authority/token" -Body @{
                client_id   = $ClientId
                grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                device_code = $dc.device_code
            }
        } catch {
            $err = $null
            try { $err = ($_.ErrorDetails.Message | ConvertFrom-Json).error } catch { }
            if ($err -ne 'authorization_pending' -and $err -ne 'slow_down') { throw }
        }
    }
    if (-not $tok) { throw 'Device code expired before sign-in completed.' }
}
else {
    $verifierBytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($verifierBytes)
    $verifier  = ConvertTo-Base64Url $verifierBytes
    $challenge = ConvertTo-Base64Url ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier)))
    $state     = [guid]::NewGuid().ToString()
    # Web redirect URIs must match the registration exactly, including the trailing slash
    $redirect  = if ($RedirectUri) { $RedirectUri } elseif ($UseClientSecret) { "http://localhost:$Port/" } else { "http://localhost:$Port" }
    $loopback  = ([uri]$redirect).IsLoopback -and ([uri]$redirect).Scheme -eq 'http'
    if ($UseClientSecret) {
        $secureSecret = Read-Host 'Client secret (paste with right-click if Ctrl+V does nothing)' -AsSecureString
        $secretLength = [Net.NetworkCredential]::new('', $secureSecret).Password.Trim().Length
        if ($secretLength -eq 0) { throw 'Client secret is empty - the paste did not reach the prompt. Try right-click paste, or a standalone PowerShell window.' }
        Write-Host "Client secret received ($secretLength chars)." -ForegroundColor DarkGray
    }

    $authorizeUrl = "$authority/authorize?client_id=$ClientId&response_type=code&response_mode=query" +
        "&redirect_uri=$([uri]::EscapeDataString($redirect))" +
        "&scope=$([uri]::EscapeDataString($scope))" +
        "&state=$state&code_challenge=$challenge&code_challenge_method=S256&prompt=select_account"

    if ($loopback) {
        $listener = New-Object Net.HttpListener
        $listener.Prefixes.Add("http://localhost:$(([uri]$redirect).Port)/")
        $listener.Start()
        try {
            Start-Process $authorizeUrl
            Write-Host "Waiting for sign-in in the browser..." -ForegroundColor Yellow
            $ctx = $listener.GetContext()
            $q = $ctx.Request.QueryString
            $msg = if ($q['error']) { "Sign-in failed: $($q['error']) - $($q['error_description'])" } else { 'Signed in. You can close this tab.' }
            $buf = [Text.Encoding]::UTF8.GetBytes($msg)
            $ctx.Response.OutputStream.Write($buf, 0, $buf.Length)
            $ctx.Response.Close()
        } finally {
            $listener.Stop()
        }
    }
    else {
        Write-Host "Sign in in the window that opened..." -ForegroundColor Yellow
        $returned  = Invoke-EmbeddedSignIn -AuthorizeUrl $authorizeUrl -RedirectUri $redirect
        $queryPart = if ($returned -match '[?#](.*)$') { $Matches[1] } else { '' }
        $q = @{}
        foreach ($pair in $queryPart -split '[&#]') {
            if ($pair -match '^([^=]+)=(.*)$') { $q[$Matches[1]] = [uri]::UnescapeDataString($Matches[2].Replace('+', ' ')) }
        }
        if (-not $q['code'] -and -not $q['error']) { throw 'Sign-in returned neither a code nor an error.' }
        $msg = "Sign-in failed: $($q['error']) - $($q['error_description'])"
    }
    if ($q['error'])             { throw $msg }
    if ($q['state'] -ne $state)  { throw 'State mismatch - the response is not from this sign-in. Aborting.' }

    $tokenBody = @{
        client_id     = $ClientId
        grant_type    = 'authorization_code'
        code          = $q['code']
        redirect_uri  = $redirect
        code_verifier = $verifier
        scope         = $scope
    }
    if ($UseClientSecret) { $tokenBody.client_secret = [Net.NetworkCredential]::new('', $secureSecret).Password.Trim() }
    try {
        $tok = Invoke-RestMethod -Method Post "$authority/token" -Body $tokenBody
    } catch {
        if ($UseClientSecret -and "$($_.ErrorDetails.Message)" -match 'AADSTS7000215') {
            Write-Host 'AADSTS7000215: wrong secret. Use the secret *Value* (shown once at creation), not the Secret ID, and check it has not expired.' -ForegroundColor Red
        }
        if (-not $UseClientSecret -and "$($_.ErrorDetails.Message)" -match 'AADSTS7000218') {
            Write-Host ("AADSTS7000218: Entra treated $redirect as a Web (confidential) redirect. Register it under the " +
                "'Mobile and desktop applications' platform instead (e.g. https://login.microsoftonline.com/common/oauth2/nativeclient), " +
                "or rerun with -UseClientSecret.") -ForegroundColor Red
        }
        throw
    } finally {
        $tokenBody.Remove('client_secret')
    }
}

Show-TokenInfo -AccessToken $tok.access_token -TokenResponse $tok

$headers = @{ Authorization = "Bearer $($tok.access_token)" }
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
