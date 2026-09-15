<#
.SYNOPSIS
  Merges locally-added "Mine" entries (exported from the app's Mine tab, or
  imported via its Import JSON button) into the master catalogue.

.DESCRIPTION
  The XR Resource Finder app is a static HTML file with no backend, so anything
  a contributor adds via the "New Entry" form only ever lives in their own
  browser's localStorage. The app's Export as JSON button lets them hand that
  off as a file, but nothing in the browser can write back into
  xr-catalogue-data.json or the HTML's embedded copy of it - that step has to
  happen outside the browser. This script is that step.

  It accepts the same file shape the app's own Import JSON button accepts:
  either {"entries": [...], "runSheet": [...]} (the Export as JSON format) or
  a bare array of entry objects. It applies the same rules the in-app importer
  uses (skip anything without a name, keep an existing id if present, rename
  on collision) so a maintainer running this script gets identical behaviour
  to what a user saw when testing the import in-app.

  It updates BOTH xr-catalogue-data.json and the `const DATA = {...}` block
  embedded in xr-resource-finder.html, and validates both as JSON afterward
  before declaring success.

.PARAMETER InputFile
  Path to the exported/imported JSON file (required).

.PARAMETER DataFile
  Path to xr-catalogue-data.json. Defaults to the file of that name next to
  this script.

.PARAMETER HtmlFile
  Path to xr-resource-finder.html. Defaults to the file of that name next to
  this script.

.PARAMETER DryRun
  Show what would be merged without writing anything.

.EXAMPLE
  .\merge-mine-entries.ps1 -InputFile "C:\Users\someone\Downloads\xr-catalogue-additions.json"

.EXAMPLE
  .\merge-mine-entries.ps1 -InputFile additions.json -DryRun
#>
param(
  [Parameter(Mandatory = $true)]
  [string]$InputFile,

  [string]$DataFile = (Join-Path $PSScriptRoot "xr-catalogue-data.json"),
  [string]$HtmlFile = (Join-Path $PSScriptRoot "xr-resource-finder.html"),

  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Write-Section($title) {
  Write-Output ""
  Write-Output "=== $title ==="
}

if (-not (Test-Path $InputFile)) { throw "Input file not found: $InputFile" }
if (-not (Test-Path $DataFile))  { throw "Catalogue data file not found: $DataFile" }
if (-not (Test-Path $HtmlFile))  { throw "HTML file not found: $HtmlFile" }

# ---------- load input ----------
$payload = Get-Content $InputFile -Raw -Encoding UTF8 | ConvertFrom-Json
$incoming = if ($payload -is [System.Array]) { $payload } else { $payload.entries }
if (-not $incoming -or $incoming.Count -eq 0) {
  Write-Output "No entries found in $InputFile - nothing to do."
  exit 0
}

# ---------- load catalogue ----------
$data = Get-Content $DataFile -Raw -Encoding UTF8 | ConvertFrom-Json
$knownIds = [System.Collections.Generic.HashSet[string]]::new()
foreach ($it in $data.items) { [void]$knownIds.Add($it.id) }

# ---------- merge, mirroring the app's own import handler exactly ----------
$added = @()
$skipped = @()
$i = 0
foreach ($entry in $incoming) {
  $i++
  if (-not $entry -or -not $entry.name) { $skipped += "entry #$i (no name)"; continue }

  $id = if ($entry.id) { $entry.id } else { "mine-$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())-$i" }
  while ($knownIds.Contains($id)) { $id = "$id-imported" }
  [void]$knownIds.Add($id)

  # Build array-valued fields via plain assignment inside each branch, NOT as
  # the "return value" of an if/else expression - PowerShell enumerates a
  # script block's output onto the pipeline, which silently collapses a
  # 1-element array to a bare scalar and a 0-element array to {} once it
  # reaches ConvertTo-Json. Assigning inside the branch avoids that entirely.
  $tagsVal = @(); if ($entry.tags) { $tagsVal = @($entry.tags) }
  $objVal = @(); if ($entry.obj) { $objVal = @($entry.obj) }
  $topicsVal = @('Other'); if ($entry.topics -and $entry.topics.Count) { $topicsVal = @($entry.topics) }
  $notesVal = @(); if ($entry.facilitatorNotes) { $notesVal = @($entry.facilitatorNotes) }
  $descVal = ''; if ($entry.desc) { $descVal = $entry.desc } elseif ($entry.quick) { $descVal = $entry.quick }

  # normalize to the full schema so this entry looks like every other catalogue item
  $normalized = [ordered]@{
    id               = $id
    name             = $entry.name
    kind             = if ($entry.kind) { $entry.kind } else { 'cave' }
    quick            = if ($entry.quick) { $entry.quick } else { '' }
    desc             = $descVal
    tags             = $tagsVal
    system           = if ($entry.system) { $entry.system } else { '' }
    by               = if ($entry.by) { $entry.by } else { '' }
    time             = if ($entry.time) { $entry.time } else { '' }
    active           = if ($entry.active) { $entry.active } else { '' }
    path             = if ($entry.path) { $entry.path } else { '' }
    obj              = $objVal
    page             = if ($null -ne $entry.page) { $entry.page } else { 0 }
    img              = if ($entry.img) { $entry.img } else { '' }
    topics           = $topicsVal
    facilitatorNotes = $notesVal
  }
  if ($entry.imgData) { $normalized['imgData'] = $entry.imgData }

  $added += [PSCustomObject]$normalized
}

Write-Section "Merge summary"
Write-Output "Read: $($incoming.Count) entr$(if ($incoming.Count -eq 1) {'y'} else {'ies'}) from $InputFile"
Write-Output "Adding: $($added.Count)"
if ($skipped.Count) { Write-Output "Skipped: $($skipped -join ', ')" }
$added | ForEach-Object { Write-Output "  + [$($_.id)] $($_.name) ($($_.kind))" }

if ($added.Count -eq 0) {
  Write-Output "Nothing valid to merge - stopping."
  exit 0
}

if ($DryRun) {
  Write-Output ""
  Write-Output "Dry run - no files were changed. Re-run without -DryRun to apply."
  exit 0
}

# ---------- write catalogue data ----------
$data.items = @($data.items) + $added
$json = $data | ConvertTo-Json -Depth 10 -Compress
[System.IO.File]::WriteAllText($DataFile, $json, (New-Object System.Text.UTF8Encoding($false)))

# ---------- sync the embedded DATA blob in the HTML ----------
$html = [System.IO.File]::ReadAllText($HtmlFile)
$pattern = '(?s)(const DATA = )\{.*?\}(;\r?\nconst IMG)'
if ($html -notmatch $pattern) {
  throw "Could not find the embedded 'const DATA = {...};' block in $HtmlFile - HTML was NOT updated. $DataFile was updated; fix the HTML sync manually or re-run once the pattern is restored."
}
$newHtml = [regex]::Replace($html, $pattern, { param($m) $m.Groups[1].Value + $json + $m.Groups[2].Value }, 1)
[System.IO.File]::WriteAllText($HtmlFile, $newHtml, (New-Object System.Text.UTF8Encoding($false)))

# ---------- validate both files ----------
Write-Section "Validation"
$dataCheck = Get-Content $DataFile -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Output "$DataFile : valid JSON, $($dataCheck.items.Count) items"

$htmlText = [System.IO.File]::ReadAllText($HtmlFile)
$m = [regex]::Match($htmlText, $pattern)
$htmlDataCheck = $m.Value.Substring('const DATA = '.Length)
$htmlDataCheck = $htmlDataCheck.Substring(0, $htmlDataCheck.Length - ';'.Length - "`nconst IMG".Length)
$htmlCheck = $htmlDataCheck | ConvertFrom-Json
Write-Output "$HtmlFile : embedded DATA valid JSON, $($htmlCheck.items.Count) items"

Write-Output ""
Write-Output "Done. $($added.Count) new entr$(if ($added.Count -eq 1) {'y'} else {'ies'}) merged."
Write-Output "Open the app and check the new item(s) render correctly before committing."
