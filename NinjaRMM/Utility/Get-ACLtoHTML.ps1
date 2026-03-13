<#
.SYNOPSIS
Generates a recursive NTFS ACL audit report and exports results to an HTML file.

.DESCRIPTION
This script audits a target path, collects ACL ownership and permission entries for folders
and optionally files, and builds a date-stamped HTML report in the specified output folder.

When adding this script to the Ninja script library, you must create Script Variables
that map to the environment variables used by this script:

Required Ninja Script Variables
- pathToAudit: (String) Full path to the folder to audit.
- htmlOutputPath: (String) Full path where the HTML report should be written.

Optional Ninja Script Variables
- reportName: (String) Custom report title/file name prefix.
- onlyAuditFolders: (Checkbox) Folder-only mode. Checked = $true (default: $false). When enabled, only folders will be audited, skipping all files.

If required variables are not configured in Ninja, the script may fail or produce no output.
#>

# ===============================
# Recursive ACL Audit to HTML Report Script
# ===============================
# Configuration Variables

$ErrorActionPreference = "Stop"

# Path to audit
$AuditPath = $env:pathToAudit 
# Audit mode default: $true = Folders only, $false = Folders and Files
# Can be overridden by Ninja env var onlyAuditFolders where "1" = $true, "0" = $false.
$AuditFoldersOnly = $false
$onlyAuditFoldersRaw = [string]$env:onlyAuditFolders 
if (-not [string]::IsNullOrWhiteSpace($onlyAuditFoldersRaw)) {
    switch ($onlyAuditFoldersRaw.Trim().ToLowerInvariant()) {
        "1" { $AuditFoldersOnly = $true; break }
        "0" { $AuditFoldersOnly = $false; break }
        "true" { $AuditFoldersOnly = $true; break }
        "false" { $AuditFoldersOnly = $false; break }
        default { throw "Invalid value for env:onlyAuditFolders. Expected '0', '1', 'true', or 'false', got '$onlyAuditFoldersRaw'." }
    }
}
# Output folder for HTML report
$HTMLOutputPath = $env:htmlOutputPath  # Example output path
# Optional custom report title. Leave blank to default to audit path leaf.
$ReportTitle = $env:reportName

# Dynamically generate HTML file name
$parentFolder = Split-Path $AuditPath -Leaf
$dateString = Get-Date -Format "yyyyMMdd"
if ([string]::IsNullOrWhiteSpace($ReportTitle)) {
    $fileName = "ACL_${parentFolder}_${dateString}.html"
} else {
    $safeReportTitle = $ReportTitle -replace '[\\/:*?"<>|]', '_'
    $fileName = "ACL_${safeReportTitle}_${dateString}.html"
}
$HtmlPath = Join-Path -Path $HTMLOutputPath -ChildPath $fileName

# ===============================
# HTML Encode Helper
# ===============================
function ConvertTo-HtmlEncoded {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    $Text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace('"', "&quot;")
}

# ===============================
# ACL Collection Function
# ===============================
function Get-RecursiveACLReport {
    param(
        [string]$Path,
        [bool]$FoldersOnly = $false
    )
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    $rootItem = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $rootItem) {
        Write-Warning "Root path not found: $Path"
        return $results
    }

    $allItems = [System.Collections.Generic.List[object]]::new()
    $allItems.Add($rootItem)

    $childItems = Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    if ($FoldersOnly) {
        if (-not $rootItem.PSIsContainer) {
            Write-Warning "Root path is not a folder."
            return $results
        }
        $childItems = $childItems | Where-Object { $_.PSIsContainer }
    }
    foreach ($c in $childItems) { $allItems.Add($c) }

    $total = $allItems.Count
    $i = 0
    foreach ($item in $allItems) {
        $i++
        Write-Progress -Activity "Collecting ACLs" -Status $item.FullName -PercentComplete (($i / $total) * 100)
        $itemType = if ($item.PSIsContainer) { "Folder" } else { "File" }
        try {
            $acl = Get-Acl -LiteralPath $item.FullName -ErrorAction Stop
            $permissions = $acl.Access | ForEach-Object {
                [PSCustomObject]@{
                    IdentityReference = $_.IdentityReference.Value
                    FileSystemRights  = $_.FileSystemRights.ToString()
                    AccessControlType = $_.AccessControlType.ToString()
                    IsInherited       = $_.IsInherited
                }
            }
            $results.Add([PSCustomObject]@{
                Path        = $item.FullName
                ItemType    = $itemType
                Owner       = $acl.Owner
                Permissions = $permissions
                Error       = $null
            })
        } catch {
            $results.Add([PSCustomObject]@{
                Path        = $item.FullName
                ItemType    = $itemType
                Owner       = $null
                Permissions = @()
                Error       = $_.Exception.Message
            })
        }
    }
    Write-Progress -Activity "Collecting ACLs" -Completed
    return $results
}

# ===============================
# Build HTML Tree Node (recursive)
# ===============================
$script:nodeCounter = 0

function Build-HtmlTreeNode {
    param(
        [string]$NodePath,
        [hashtable]$NodeDataMap,
        [hashtable]$ChildrenMap
    )
    $script:nodeCounter++
    $nodeId = "n$($script:nodeCounter)"

    $data     = $NodeDataMap[$NodePath]
    $children = $ChildrenMap[$NodePath]
    $hasChildren = ($null -ne $children) -and ($children.Count -gt 0)

    $name     = Split-Path $NodePath -Leaf
    if ([string]::IsNullOrEmpty($name)) { $name = $NodePath }

    $itemType = if ($data) { $data.ItemType } else { "Folder" }
    $icon     = if ($itemType -eq "Folder") { "&#128193;" } else { "&#128196;" }
    $hasError = $data -and $data.Error

    $sb = [System.Text.StringBuilder]::new()

    [void]$sb.Append("<li>")

    # Caret / spacer
    if ($hasChildren) {
        [void]$sb.Append("<span class='caret' id='c$nodeId' onclick='toggleTree(""$nodeId"",""c$nodeId"")'></span>")
    } else {
        [void]$sb.Append("<span class='caret-spacer'></span>")
    }

    # Item label
    $labelClass = if ($hasError) { "item-name has-error" } else { "item-name" }
    $ownerRaw = $null
    if ($null -ne $data -and $null -ne $data.PSObject.Properties["Owner"]) {
        $ownerRaw = [string]$data.Owner
    }
    $ownerIsUnknown = [string]::IsNullOrWhiteSpace($ownerRaw)
    $ownerText = if ($ownerIsUnknown) { "Owner: (unknown)" } else { "Owner: $ownerRaw" }
    $ownerBadgeClass = if ($ownerIsUnknown) { "owner-badge unknown-owner" } else { "owner-badge" }
    [void]$sb.Append("<span class='$labelClass' onclick='toggleDetails(""d$nodeId"")'>$icon $(ConvertTo-HtmlEncoded $name)<span class='$ownerBadgeClass'>$(ConvertTo-HtmlEncoded $ownerText)</span></span>")

    # Detail panel
    [void]$sb.Append("<div class='details' id='d$nodeId'>")
    if ($null -ne $data) {
        if ($data.Error) {
            [void]$sb.Append("<div class='detail-path'>$(ConvertTo-HtmlEncoded $data.Path)</div>")
            [void]$sb.Append("<div class='detail-error'><b>&#9888; Error:</b> $(ConvertTo-HtmlEncoded $data.Error)</div>")
        } else {
            [void]$sb.Append("<div class='detail-path'>$(ConvertTo-HtmlEncoded $data.Path)</div>")
            [void]$sb.Append("<div class='detail-owner'><b>Owner:</b> $(ConvertTo-HtmlEncoded $data.Owner)</div>")
            [void]$sb.Append("<table class='perm-table'><thead><tr><th>Identity</th><th>Rights</th><th>Type</th><th>Inherited</th></tr></thead><tbody>")
            foreach ($p in $data.Permissions) {
                $rowClass = if ($p.AccessControlType -eq "Deny") { " class='deny'" } else { "" }
                [void]$sb.Append("<tr$rowClass>")
                [void]$sb.Append("<td>$(ConvertTo-HtmlEncoded $p.IdentityReference)</td>")
                [void]$sb.Append("<td>$(ConvertTo-HtmlEncoded $p.FileSystemRights)</td>")
                [void]$sb.Append("<td>$($p.AccessControlType)</td>")
                [void]$sb.Append("<td>$($p.IsInherited)</td>")
                [void]$sb.Append("</tr>")
            }
            [void]$sb.Append("</tbody></table>")
        }
    }
    [void]$sb.Append("</div>")

    # Children
    if ($hasChildren) {
        [void]$sb.Append("<ul id='$nodeId' class='nested'>")
        foreach ($child in ($children | Sort-Object)) {
            [void]$sb.Append((Build-HtmlTreeNode -NodePath $child -NodeDataMap $NodeDataMap -ChildrenMap $ChildrenMap))
        }
        [void]$sb.Append("</ul>")
    }

    [void]$sb.Append("</li>")
    return $sb.ToString()
}

# ===============================
# Generate Full HTML Report
# ===============================
function New-HtmlACLReport {
    param(
        [System.Collections.Generic.List[PSCustomObject]]$Data,
        [string]$RootPath,
        [string]$OutputPath,
        [string]$ReportTitle
    )

    # Build lookup maps
    $nodeDataMap = @{}
    $childrenMap = @{}
    foreach ($item in $Data) {
        $nodeDataMap[$item.Path] = $item
        if ($item.Path -ne $RootPath) {
            $parent = Split-Path $item.Path -Parent
            if (-not $childrenMap.ContainsKey($parent)) {
                $childrenMap[$parent] = [System.Collections.Generic.List[string]]::new()
            }
            [void]$childrenMap[$parent].Add($item.Path)
        }
    }

    $script:nodeCounter = 0
    $rootName      = Split-Path $RootPath -Leaf
    if ([string]::IsNullOrEmpty($rootName)) { $rootName = $RootPath }
    $displayTitle  = if ([string]::IsNullOrWhiteSpace($ReportTitle)) { $rootName } else { $ReportTitle }
    $generatedAt   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $totalItems    = $Data.Count
    $errorCount    = ($Data | Where-Object { $_.Error }).Count
    $errorBadge    = if ($errorCount -gt 0) { "<span class='badge err'>$errorCount errors</span>" } else { "" }

    $treeHtml = Build-HtmlTreeNode -NodePath $RootPath -NodeDataMap $nodeDataMap -ChildrenMap $childrenMap

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ACL Report - $(ConvertTo-HtmlEncoded $displayTitle)</title>
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:'Segoe UI',Arial,sans-serif;background:#1e1e2e;color:#cdd6f4;font-size:14px}
  header{background:#181825;padding:14px 22px;border-bottom:1px solid #313244;position:sticky;top:0;z-index:100;display:flex;align-items:center;gap:12px;flex-wrap:wrap}
  header h1{font-size:17px;color:#cba6f7;flex:1;white-space:nowrap}
  header h2{font-size:14px;color:#cba6f7;flex:1;white-space:nowrap}
  .meta{font-size:12px;color:#6c7086}
  .badge{background:#313244;border-radius:4px;padding:3px 9px;font-size:12px;white-space:nowrap}
  .badge.err{background:#f3817425;color:#f38174}
  .controls{display:flex;gap:8px;flex-wrap:wrap;margin-left:auto}
  button{background:#313244;color:#cdd6f4;border:1px solid #45475a;border-radius:6px;padding:5px 12px;cursor:pointer;font-size:13px;transition:background .15s}
  button:hover{background:#45475a}
  input[type=search]{background:#313244;color:#cdd6f4;border:1px solid #45475a;border-radius:6px;padding:5px 12px;font-size:13px;width:220px;outline:none}
  input[type=search]:focus{border-color:#cba6f7}
  main{padding:16px 22px}
  ul{list-style:none;padding-left:0}
  ul.nested{padding-left:22px;border-left:1px dashed #383850;margin-left:8px;display:none}
  ul.nested.open{display:block}
  li{margin:2px 0}
  .caret{display:inline-flex;align-items:center;justify-content:center;width:18px;height:18px;cursor:pointer;user-select:none;color:#89b4fa;font-size:10px;border-radius:3px;transition:background .1s}
  .caret::before{content:'▶';transition:transform .15s}
  .caret:hover{background:#313244}
  .caret.open::before{transform:rotate(90deg)}
  .caret-spacer{display:inline-block;width:18px;height:18px}
    .item-name{cursor:pointer;padding:2px 6px;border-radius:4px;display:inline-flex;align-items:center;gap:8px}
  .item-name:hover{background:#313244}
  .item-name.has-error{color:#f38174}
    .owner-badge{display:inline-block;padding:1px 7px;border-radius:999px;font-size:11px;line-height:1.4;background:#313244;color:#a6adc8;border:1px solid #45475a;white-space:nowrap}
    .owner-badge.unknown-owner{background:#3b2f20;color:#f9c97a;border-color:#6a5433}
  .details{display:none;margin:6px 0 6px 38px;background:#181825;border:1px solid #313244;border-radius:7px;padding:10px 14px;font-size:13px}
  .details.open{display:block}
  .detail-path{color:#a6adc8;word-break:break-all;margin-bottom:6px;font-size:12px}
  .detail-owner{margin-bottom:8px}
  .detail-error{color:#f38174}
  .perm-table{width:100%;border-collapse:collapse;margin-top:6px}
  .perm-table th{background:#252535;color:#a6adc8;font-weight:600;padding:5px 10px;text-align:left;border-bottom:1px solid #45475a;font-size:12px}
  .perm-table td{padding:4px 10px;border-bottom:1px solid #25253590}
  .perm-table tr:last-child td{border-bottom:none}
  .perm-table tr.deny td{color:#f38174}
  li.hidden{display:none}
  ::-webkit-scrollbar{width:7px;height:7px}
  ::-webkit-scrollbar-track{background:#181825}
  ::-webkit-scrollbar-thumb{background:#45475a;border-radius:4px}
</style>
</head>
<body>
<header>
    <h1>&#128273; ACL Report &mdash; $(ConvertTo-HtmlEncoded $displayTitle)</h1>
    <h2 class="meta">Path: $(ConvertTo-HtmlEncoded $RootPath)</h2>
  <span class="meta">Generated: $generatedAt</span>
  <span class="badge">$totalItems items</span>
  $errorBadge
  <div class="controls">
    <input type="search" id="searchBox" placeholder="Filter by name..." oninput="filterTree(this.value)">
    <button onclick="expandAll()">Expand All</button>
    <button onclick="collapseAll()">Collapse All</button>
  </div>
</header>
<main>
<ul>
$treeHtml
</ul>
</main>
<script>
function toggleTree(id, caretId) {
  var ul = document.getElementById(id);
  var ca = document.getElementById(caretId);
  if (ul) ul.classList.toggle('open');
  if (ca) ca.classList.toggle('open');
}
function toggleDetails(id) {
  var el = document.getElementById(id);
  if (el) el.classList.toggle('open');
}
function expandAll() {
  document.querySelectorAll('.nested').forEach(function(el){el.classList.add('open')});
  document.querySelectorAll('.caret').forEach(function(el){el.classList.add('open')});
}
function collapseAll() {
  document.querySelectorAll('.nested').forEach(function(el){el.classList.remove('open')});
  document.querySelectorAll('.caret').forEach(function(el){el.classList.remove('open')});
  document.querySelectorAll('.details').forEach(function(el){el.classList.remove('open')});
}
function filterTree(q) {
  q = q.trim().toLowerCase();
  var items = document.querySelectorAll('li');
  if (!q) {
    items.forEach(function(li){li.classList.remove('hidden')});
    collapseAll();
    return;
  }
  items.forEach(function(li) {
    var lbl = li.querySelector(':scope > .item-name');
    var txt = lbl ? lbl.textContent.toLowerCase() : '';
    li.classList.toggle('hidden', !txt.includes(q));
  });
  document.querySelectorAll('.nested').forEach(function(el){el.classList.add('open')});
  document.querySelectorAll('.caret').forEach(function(el){el.classList.add('open')});
}
</script>
</body>
</html>
"@

    $html | Out-File -FilePath $OutputPath -Encoding UTF8
}

# ===============================
# Main Execution
# ===============================
try {
    if ([string]::IsNullOrWhiteSpace($AuditPath)) {
        throw "AuditPath is not set."
    }

    if (-not (Test-Path -LiteralPath $AuditPath)) {
        throw "Audit path does not exist: $AuditPath"
    }

    if ([string]::IsNullOrWhiteSpace($HTMLOutputPath)) {
        throw "HTMLOutputPath is not set."
    }

    if (-not (Test-Path -LiteralPath $HTMLOutputPath)) {
        [void](New-Item -Path $HTMLOutputPath -ItemType Directory -Force)
    }

    $report = Get-RecursiveACLReport -Path $AuditPath -FoldersOnly:$AuditFoldersOnly
    if ($null -eq $report -or $report.Count -eq 0) {
        throw "No audit data was collected."
    }

    $aclFailures = @($report | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Error) })
    if ($aclFailures.Count -gt 0) {
        $failurePreview = ($aclFailures | Select-Object -First 3 | ForEach-Object { "$($_.Path) => $($_.Error)" }) -join "; "
        throw "ACL collection completed with $($aclFailures.Count) item error(s). Sample: $failurePreview"
    }

    New-HtmlACLReport -Data $report -RootPath $AuditPath -OutputPath $HtmlPath -ReportTitle $ReportTitle

    if (-not (Test-Path -LiteralPath $HtmlPath)) {
        throw "HTML report file was not created: $HtmlPath"
    }

    Write-Host "ACL audit complete. HTML report exported to $HtmlPath"
    exit 0
}
catch {
    Write-Error "ACL HTML audit failed: $($_.Exception.Message)"
    exit 1
}