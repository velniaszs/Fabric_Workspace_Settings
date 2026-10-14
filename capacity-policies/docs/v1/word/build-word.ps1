<#
.SYNOPSIS
  Builds the Word versions of the documents in docs\v1, without opening Word.

.DESCRIPTION
  1. Creates reference.docx - the house style - by editing the XML of a pandoc-generated
     document: fonts, colours, headings, notes, code, the table style, A4 page and a footer
     with page numbers.
  2. Converts each Markdown document with pandoc, using word.lua for the title, the table of
     contents and diagram sizing.

  Word is never automated: in a tenant with mandatory sensitivity labels a hidden Word cannot
  answer the label prompt on save and hangs.

  When a document is first opened, Word asks whether to update its fields. Answer Yes - that
  fills in the table of contents and its page numbers.

.EXAMPLE
  .\build-word.ps1
  .\build-word.ps1 -Documents ARCHITECTURE-v2.md -RebuildReference
#>
param(
    [string[]]$Documents = @('ARCHITECTURE-v2.md', 'DEPLOYMENT-GUIDE.md', 'MIGRATION-GUIDE.md', 'ERROR-HANDLING-AND-MONITORING.md'),
    [string]$Version = '1.0',
    [switch]$RebuildReference
)

$ErrorActionPreference = 'Stop'
$clock = [System.Diagnostics.Stopwatch]::StartNew()
function Log([string]$message) { Write-Host ('{0,6:N1}s  {1}' -f $clock.Elapsed.TotalSeconds, $message) }

$here = $PSScriptRoot
$source = Split-Path $here -Parent
$reference = Join-Path $here 'reference.docx'
$filter = Join-Path $here 'word.lua'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
$R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'

# --- House style ------------------------------------------------------------------------------
$body = 'Segoe UI'
$head = 'Segoe UI Semibold'
$mono = 'Consolas'
$navy = '0B2A5B'; $blue = '1F6FEB'; $purple = '7A3EC8'; $ink = '1B1F2A'; $muted = '5B6475'
$line = 'D5DBE6'; $headFill = 'EEF2F9'; $noteFill = 'F3F8FF'; $codeFill = 'F5F7FB'

function Fonts([string]$name) { "<w:rFonts w:ascii=`"$name`" w:hAnsi=`"$name`" w:cs=`"$name`" w:eastAsia=`"$name`"/>" }
function Run([string]$font, [string]$colour, [int]$halfPoints, [switch]$Bold) {
    $b = if ($Bold) { '<w:b/><w:bCs/>' } else { '' }
    "<w:rPr>$(Fonts $font)$b<w:color w:val=`"$colour`"/><w:sz w:val=`"$halfPoints`"/><w:szCs w:val=`"$halfPoints`"/></w:rPr>"
}
function Heading([int]$level, [int]$before, [int]$after, [string]$colour, [int]$halfPoints, [switch]$NewPage) {
    $pb = if ($NewPage) { '<w:pageBreakBefore/>' } else { '' }
    $p = "<w:pPr><w:keepNext/><w:keepLines/>$pb<w:spacing w:before=`"$before`" w:after=`"$after`"/><w:outlineLvl w:val=`"$($level - 1)`"/></w:pPr>"
    $p + (Run $head $colour $halfPoints -Bold)
}

$styleXml = @{
    'BodyText'       = '<w:pPr><w:spacing w:before="0" w:after="120"/></w:pPr>'
    'FirstParagraph' = '<w:pPr><w:spacing w:before="0" w:after="120"/></w:pPr>'
    'Compact'        = '<w:pPr><w:spacing w:before="0" w:after="40"/></w:pPr>'
    'Title'          = '<w:pPr><w:keepNext/><w:spacing w:before="4200" w:after="200"/></w:pPr>' + (Run $head $navy 56 -Bold)
    'Subtitle'       = '<w:pPr><w:spacing w:before="0" w:after="160"/></w:pPr>' + (Run $body $blue 34)
    'Date'           = '<w:pPr><w:spacing w:before="0" w:after="120"/></w:pPr>' + (Run $body $muted 22)
    'Heading1'       = Heading 1 0 240 $navy 36 -NewPage
    'Heading2'       = Heading 2 320 120 $blue 28
    'Heading3'       = Heading 3 240 80 $purple 23
    'Heading4'       = Heading 4 200 60 $ink 21
    'TOCHeading'     = "<w:pPr><w:keepNext/><w:pageBreakBefore/><w:spacing w:before=`"0`" w:after=`"240`"/><w:outlineLvl w:val=`"9`"/></w:pPr>" + (Run $head $navy 36 -Bold)
    'BlockText'      = "<w:pPr><w:pBdr><w:left w:val=`"single`" w:sz=`"18`" w:space=`"8`" w:color=`"$blue`"/></w:pBdr><w:shd w:val=`"clear`" w:color=`"auto`" w:fill=`"$noteFill`"/><w:spacing w:before=`"120`" w:after=`"120`"/><w:ind w:left=`"227`" w:right=`"0`"/></w:pPr>" + (Run $body $ink 19)
    'SourceCode'     = "<w:pPr><w:shd w:val=`"clear`" w:color=`"auto`" w:fill=`"$codeFill`"/><w:spacing w:before=`"60`" w:after=`"60`"/></w:pPr>" + (Run $mono $ink 17)
    'VerbatimChar'   = Run $mono '3B4356' 18
    'Hyperlink'      = "<w:rPr><w:color w:val=`"$blue`"/><w:u w:val=`"single`"/></w:rPr>"
    'Figure'         = '<w:pPr><w:keepNext/><w:spacing w:before="120" w:after="200"/><w:jc w:val="center"/></w:pPr>'
    'ImageCaption'   = '<w:pPr><w:spacing w:before="0" w:after="200"/><w:jc w:val="center"/></w:pPr>' + (Run $body $muted 18)
    'Table'          = '<w:rPr><w:sz w:val="18"/><w:szCs w:val="18"/></w:rPr>' +
                       "<w:tblPr><w:tblBorders><w:top w:val=`"single`" w:sz=`"4`" w:space=`"0`" w:color=`"$line`"/><w:left w:val=`"single`" w:sz=`"4`" w:space=`"0`" w:color=`"$line`"/><w:bottom w:val=`"single`" w:sz=`"4`" w:space=`"0`" w:color=`"$line`"/><w:right w:val=`"single`" w:sz=`"4`" w:space=`"0`" w:color=`"$line`"/><w:insideH w:val=`"single`" w:sz=`"4`" w:space=`"0`" w:color=`"$line`"/><w:insideV w:val=`"single`" w:sz=`"4`" w:space=`"0`" w:color=`"$line`"/></w:tblBorders>" +
                       '<w:tblCellMar><w:top w:w="45" w:type="dxa"/><w:left w:w="100" w:type="dxa"/><w:bottom w:w="45" w:type="dxa"/><w:right w:w="100" w:type="dxa"/></w:tblCellMar></w:tblPr>' +
                       "<w:tblStylePr w:type=`"firstRow`"><w:rPr><w:b/><w:bCs/><w:color w:val=`"$navy`"/></w:rPr><w:tcPr><w:shd w:val=`"clear`" w:color=`"auto`" w:fill=`"$headFill`"/></w:tcPr></w:tblStylePr>"
}

$footerXml = @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:ftr xmlns:w="$W" xmlns:r="$R"><w:p><w:pPr><w:pBdr><w:top w:val="single" w:sz="4" w:space="6" w:color="$line"/></w:pBdr><w:tabs><w:tab w:val="right" w:pos="9412"/></w:tabs><w:spacing w:before="0" w:after="0"/></w:pPr>
<w:r>$(Run $body $muted 16)<w:t xml:space="preserve">Fabric Capacity Policies</w:t></w:r>
<w:r>$(Run $body $muted 16)<w:tab/><w:t xml:space="preserve">Page </w:t></w:r>
<w:fldSimple w:instr=" PAGE "><w:r>$(Run $body $muted 16)<w:t>1</w:t></w:r></w:fldSimple>
<w:r>$(Run $body $muted 16)<w:t xml:space="preserve"> of </w:t></w:r>
<w:fldSimple w:instr=" NUMPAGES "><w:r>$(Run $body $muted 16)<w:t>1</w:t></w:r></w:fldSimple>
</w:p></w:ftr>
"@

$sectPr = "<w:sectPr xmlns:w=`"$W`" xmlns:r=`"$R`"><w:footerReference w:type=`"default`" r:id=`"rIdHouseFooter`"/><w:pgSz w:w=`"11906`" w:h=`"16838`"/><w:pgMar w:top=`"1247`" w:right=`"1247`" w:bottom=`"1247`" w:left=`"1247`" w:header=`"567`" w:footer=`"567`" w:gutter=`"0`"/><w:titlePg/></w:sectPr>"

# --- Zip helpers ------------------------------------------------------------------------------
function Read-Entry($zip, [string]$name) {
    $reader = New-Object System.IO.StreamReader($zip.GetEntry($name).Open())
    try { $reader.ReadToEnd() } finally { $reader.Close() }
}
function Write-Entry($zip, [string]$name, [string]$text) {
    $existing = $zip.GetEntry($name)
    if ($existing) { $existing.Delete() }
    $writer = New-Object System.IO.StreamWriter($zip.CreateEntry($name).Open(), (New-Object System.Text.UTF8Encoding($false)))
    try { $writer.Write($text) } finally { $writer.Close() }
}

function Set-Style([xml]$styles, $ns, [string]$id, [string]$inner) {
    $style = $styles.SelectSingleNode("//w:style[@w:styleId='$id']", $ns)
    if (-not $style) { return }
    foreach ($tag in 'pPr', 'rPr', 'tblPr', 'trPr', 'tcPr', 'tblStylePr') {
        foreach ($n in @($style.SelectNodes("w:$tag", $ns))) { [void]$style.RemoveChild($n) }
    }
    $fragment = $styles.CreateDocumentFragment()
    $fragment.InnerXml = "<root xmlns:w=`"$W`">$inner</root>"
    foreach ($child in @($fragment.FirstChild.ChildNodes)) { [void]$style.AppendChild($child) }
}

function New-Reference {
    Log 'template: generating base document with pandoc'
    $tmp = Join-Path $env:TEMP ('word-ref-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $sample = @('# Title', '', '## Heading', '', 'First paragraph.', '', 'Body with `code` and a [link](https://example.com).', '',
            '### Heading 3', '', '#### Heading 4', '', '- one', '- two', '', '> A note.', '', '```text', 'code', '```', '',
            '| A | B |', '|---|---|', '| 1 | 2 |', '', '::: {custom-style="Figure"}', 'Figure', ':::') -join "`n"
        [System.IO.File]::WriteAllText("$tmp\sample.md", $sample)
        & pandoc "$tmp\sample.md" -f markdown -o "$tmp\base.docx" --toc -M title=T -M subtitle=S -M date=D
        if ($LASTEXITCODE -ne 0) { throw 'pandoc could not create the base document' }
        Copy-Item "$tmp\base.docx" $reference -Force
    }
    finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

    Log 'template: applying house style'
    $zip = [System.IO.Compression.ZipFile]::Open($reference, 'Update')
    try {
        [xml]$styles = Read-Entry $zip 'word/styles.xml'
        $ns = New-Object System.Xml.XmlNamespaceManager($styles.NameTable)
        $ns.AddNamespace('w', $W)

        $rDefault = $styles.SelectSingleNode('//w:docDefaults/w:rPrDefault', $ns)
        $rDefault.InnerXml = "<w:rPr xmlns:w=`"$W`">$(Fonts $body)<w:color w:val=`"$ink`"/><w:sz w:val=`"20`"/><w:szCs w:val=`"20`"/><w:lang w:val=`"en-GB`"/></w:rPr>"
        foreach ($id in $styleXml.Keys) { Set-Style $styles $ns $id $styleXml[$id] }
        Write-Entry $zip 'word/styles.xml' $styles.OuterXml

        Log 'template: page size, margins and footer'
        Write-Entry $zip 'word/footer1.xml' $footerXml

        [xml]$rels = Read-Entry $zip 'word/_rels/document.xml.rels'
        $rel = $rels.CreateElement('Relationship', $rels.DocumentElement.NamespaceURI)
        $rel.SetAttribute('Id', 'rIdHouseFooter')
        $rel.SetAttribute('Type', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer')
        $rel.SetAttribute('Target', 'footer1.xml')
        [void]$rels.DocumentElement.AppendChild($rel)
        Write-Entry $zip 'word/_rels/document.xml.rels' $rels.OuterXml

        [xml]$types = Read-Entry $zip '[Content_Types].xml'
        $ov = $types.CreateElement('Override', $types.DocumentElement.NamespaceURI)
        $ov.SetAttribute('PartName', '/word/footer1.xml')
        $ov.SetAttribute('ContentType', 'application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml')
        [void]$types.DocumentElement.AppendChild($ov)
        Write-Entry $zip '[Content_Types].xml' $types.OuterXml

        [xml]$document = Read-Entry $zip 'word/document.xml'
        $dns = New-Object System.Xml.XmlNamespaceManager($document.NameTable)
        $dns.AddNamespace('w', $W)
        $bodyNode = $document.SelectSingleNode('//w:body', $dns)
        foreach ($old in @($bodyNode.SelectNodes('w:sectPr', $dns))) { [void]$bodyNode.RemoveChild($old) }
        [xml]$sect = $sectPr
        [void]$bodyNode.AppendChild($document.ImportNode($sect.DocumentElement, $true))
        Write-Entry $zip 'word/document.xml' $document.OuterXml
    }
    finally { $zip.Dispose() }
    Log 'template: reference.docx ready'
}

# --- Build ------------------------------------------------------------------------------------
if ($RebuildReference -or -not (Test-Path $reference)) { New-Reference }

Push-Location $source
try {
    foreach ($name in $Documents) {
        $md = Join-Path $source $name
        $heading = (Get-Content $md -Encoding UTF8 | Where-Object { $_ -match '^# ' } | Select-Object -First 1) -replace '^#\s+', ''
        $title = ($heading -replace '^Fabric Capacity Policies - ', '').Trim()
        $out = Join-Path $here "Fabric Capacity Policies - $title.docx"

        Log "pandoc: $name"
        & pandoc $md -f gfm -t docx -o $out `
            --reference-doc=$reference `
            --lua-filter=$filter `
            --resource-path=$source `
            --columns=100000 `
            --toc --toc-depth=2 `
            --syntax-highlighting=none `
            -M "title=Fabric Capacity Policies" `
            -M "subtitle=$title" `
            -M "date=Version $Version - $(Get-Date -Format 'd MMMM yyyy')" `
            -M "toc-title=Contents"
        if ($LASTEXITCODE -ne 0) { throw "pandoc failed for $name" }
        Log "built  $([System.IO.Path]::GetFileName($out))"
    }
}
finally { Pop-Location }
Log 'done'
