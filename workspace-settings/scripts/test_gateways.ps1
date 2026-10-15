$t = az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv
if (-not $t) { throw 'No access token. Run az login first.' }

$headers = @{ Authorization = "Bearer $t" }
$uri = 'https://api.fabric.microsoft.com/v1/gateways'
$page = 0
$all = @()

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
            $reader = New-Object System.IO.StreamReader($err.GetResponseStream())
            $reader.ReadToEnd()
        } else {
            Write-Host $_.Exception.Message -ForegroundColor Red
        }
        break
    }

    Write-Host "HTTP $($resp.StatusCode) $($resp.StatusDescription)" -ForegroundColor Green
    Write-Host "RequestId: $($resp.Headers['RequestId'])"
    
    $body = $resp.Content | ConvertFrom-Json
    $body | ConvertTo-Json -Depth 20

    $all += $body.value
    $uri = if ($body.continuationToken) { "https://api.fabric.microsoft.com/v1/gateways?continuationToken=$([uri]::EscapeDataString($body.continuationToken))" }
} while ($uri)

Write-Host "`n===== Summary: $($all.Count) gateway(s) across $page page(s)" -ForegroundColor Cyan
$all | Format-Table displayName, type, id -AutoSize
