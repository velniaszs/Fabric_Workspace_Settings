<#
.SYNOPSIS
  Renders a diagram HTML file in this folder to a PNG of the same name, cropped to its content.

.EXAMPLE
  .\render-diagram.ps1 flow-initialize-capacity-policy-set
#>
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [int]$Scale = 2,
    [int]$Width = 1400,
    [int]$Height = 2600
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$html = Join-Path $here "$Name.html"
$png = Join-Path $here "$Name.png"
if (-not (Test-Path $html)) { throw "Not found: $html" }

$edge = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw 'Microsoft Edge not found.' }

$profileDir = Join-Path $env:TEMP ('edge-render-' + [guid]::NewGuid().ToString('N'))
$url = 'file:///' + ($html -replace '\\', '/')
$errLog = Join-Path $env:TEMP ('edge-render-stderr-' + [guid]::NewGuid().ToString('N') + '.txt')
$edgeArgs = @(
    '--headless=new', '--disable-gpu', '--hide-scrollbars',
    "--force-device-scale-factor=$Scale", "--user-data-dir=$profileDir",
    "--window-size=$Width,$Height", '--virtual-time-budget=3000',
    "--screenshot=$png", $url
)
if (Test-Path $png) { Remove-Item $png }
Start-Process -FilePath $edge -ArgumentList $edgeArgs -NoNewWindow -Wait -RedirectStandardError $errLog | Out-Null
Remove-Item $errLog, $profileDir -Recurse -Force -ErrorAction SilentlyContinue
if (-not (Test-Path $png)) { throw 'Edge did not write the screenshot.' }

# Crop to the diagram. The bottom edge is the end of the first content block followed by a
# long blank gap: headless Edge occasionally paints a stray copy of the page further down,
# and stopping at the gap keeps that copy out of the image.
Add-Type -AssemblyName System.Drawing
if (-not ('DiagramCrop' -as [type])) {
    Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class DiagramCrop {
    static bool Ink(byte[] px, int i) { return px[i] < 250 || px[i + 1] < 250 || px[i + 2] < 250; }
    public static int[] Bounds(Bitmap bmp, int gap) {
        var rect = new Rectangle(0, 0, bmp.Width, bmp.Height);
        var data = bmp.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        var px = new byte[data.Stride * bmp.Height];
        Marshal.Copy(data.Scan0, px, 0, px.Length);
        bmp.UnlockBits(data);
        int maxY = 0, maxX = 0, blank = 0; bool started = false;
        for (int y = 0; y < bmp.Height; y++) {
            bool ink = false;
            for (int x = 0; x < bmp.Width; x++) {
                if (Ink(px, y * data.Stride + x * 4)) { ink = true; if (x > maxX) maxX = x; }
            }
            if (ink) { started = true; maxY = y; blank = 0; }
            else if (started && ++blank >= gap) break;
        }
        return new[] { maxX, maxY };
    }
}
'@
}
$bmp = [System.Drawing.Bitmap]::FromFile($png)
$bounds = [DiagramCrop]::Bounds($bmp, 60 * $Scale)
$w = [Math]::Min($bmp.Width, $bounds[0] + 4)
$h = [Math]::Min($bmp.Height, $bounds[1] + 4)
$crop = $bmp.Clone((New-Object System.Drawing.Rectangle 0, 0, $w, $h), $bmp.PixelFormat)
$bmp.Dispose()
$tmp = "$png.tmp"
$crop.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
$crop.Dispose()
Move-Item $tmp $png -Force

$ratio = [Math]::Round($w / $h, 2)
$fit = if ($ratio -ge 0.6) { 'fits an A4 portrait page' } else { 'taller than an A4 portrait page - consider collapsing actions' }
"{0}.png  {1} x {2} px  width/height {3}  ({4})" -f $Name, $w, $h, $ratio, $fit
