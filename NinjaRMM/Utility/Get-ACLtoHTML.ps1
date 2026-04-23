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

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$AuditPath = $env:pathToAudit,

    [Parameter()]
    [string]$OnlyAuditFolders = [string]$env:onlyAuditFolders,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$HTMLOutputPath = $env:htmlOutputPath,

    [Parameter()]
    [AllowEmptyString()]
    [string]$ReportTitle = $env:reportName,

    [Parameter()]
    [ValidateSet("Html", "UI")]
    [string]$OutputMode = "Html"
)
$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $PSCommandPath

. (Join-Path -Path $scriptRoot -ChildPath "Get-ACLtoHTML.StreamingScan.ps1")
. (Join-Path -Path $scriptRoot -ChildPath "Get-ACLtoHTML.StreamingHtml.ps1")

$allNinjaInputsBlank = `
    [string]::IsNullOrWhiteSpace([string]$env:pathToAudit) -and `
    [string]::IsNullOrWhiteSpace([string]$env:htmlOutputPath) -and `
    [string]::IsNullOrWhiteSpace([string]$env:reportName) -and `
    [string]::IsNullOrWhiteSpace([string]$env:onlyAuditFolders)

if ([string]::IsNullOrWhiteSpace($AuditPath) -and $allNinjaInputsBlank) {
    $AuditPath = (Get-Location).Path
}

if ([string]::IsNullOrWhiteSpace($AuditPath)) {
    throw "AuditPath is required. Provide -AuditPath, set env:pathToAudit, or run the script from the folder you want to audit."
}

if ($OutputMode -eq "Html" -and [string]::IsNullOrWhiteSpace($HTMLOutputPath)) {
    if ($allNinjaInputsBlank) {
        $HTMLOutputPath = (Get-Location).Path
    } else {
        throw "HTMLOutputPath is required in Html mode. Provide -HTMLOutputPath or set env:htmlOutputPath."
    }
}

# Default: audit both folders and files. Accept Ninja-style env values or direct parameter input.
$AuditFoldersOnly = $false
if (-not [string]::IsNullOrWhiteSpace($OnlyAuditFolders)) {
    switch ($OnlyAuditFolders.Trim().ToLowerInvariant()) {
        "1" { $AuditFoldersOnly = $true; break }
        "0" { $AuditFoldersOnly = $false; break }
        "true" { $AuditFoldersOnly = $true; break }
        "false" { $AuditFoldersOnly = $false; break }
        default { throw "Invalid value for OnlyAuditFolders. Expected '0', '1', 'true', or 'false', got '$OnlyAuditFolders'." }
    }
}

# Dynamically generate HTML file name
$parentFolder = Split-Path $AuditPath -Leaf
$dateString = Get-Date -Format "yyyyMMdd"
if ([string]::IsNullOrWhiteSpace($ReportTitle)) {
    $fileName = "ACL_${parentFolder}_${dateString}.html"
} else {
    $safeReportTitle = $ReportTitle -replace '[\\/:*?"<>|]', '_'
    $fileName = "ACL_${safeReportTitle}_${dateString}.html"
}
$HtmlPath = $null
if (-not [string]::IsNullOrWhiteSpace($HTMLOutputPath)) {
    $HtmlPath = Join-Path -Path $HTMLOutputPath -ChildPath $fileName
}

# ===============================
# HTML Encode Helper
# ===============================
function ConvertTo-HtmlEncoded {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    $Text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace('"', "&quot;")
}

function Get-NormalizedPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    $resolvedPath = $Path
    try {
        $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    } catch {
        # Fall back to the original value when the path cannot be resolved yet.
    }

    $root = [System.IO.Path]::GetPathRoot($resolvedPath)
    if ($resolvedPath -ne $root) {
        return $resolvedPath.TrimEnd('\')
    }

    return $resolvedPath
}

function Get-DefaultReportTitle {
    param(
        [string]$AuditPath,
        [string]$ReportTitle
    )

    if (-not [string]::IsNullOrWhiteSpace($ReportTitle)) {
        return $ReportTitle
    }

    $rootName = Split-Path (Get-NormalizedPath -Path $AuditPath) -Leaf
    if ([string]::IsNullOrWhiteSpace($rootName)) {
        return $AuditPath
    }

    return $rootName
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

    $normalizedRootPath = Get-NormalizedPath -Path $RootPath

    # Build lookup maps
    $nodeDataMap = @{}
    $childrenMap = @{}
    foreach ($item in $Data) {
        $normalizedItemPath = Get-NormalizedPath -Path $item.Path
        $nodeDataMap[$normalizedItemPath] = $item
        if ($normalizedItemPath -ne $normalizedRootPath) {
            $parent = Get-NormalizedPath -Path (Split-Path $item.Path -Parent)
            if (-not $childrenMap.ContainsKey($parent)) {
                $childrenMap[$parent] = [System.Collections.Generic.List[string]]::new()
            }
            [void]$childrenMap[$parent].Add($normalizedItemPath)
        }
    }

    $script:nodeCounter = 0
    $rootName      = Split-Path $normalizedRootPath -Leaf
    if ([string]::IsNullOrEmpty($rootName)) { $rootName = $normalizedRootPath }
    $displayTitle  = if ([string]::IsNullOrWhiteSpace($ReportTitle)) { $rootName } else { $ReportTitle }
    $generatedAt   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $totalItems    = $Data.Count
    $errorCount    = ($Data | Where-Object { $_.Error }).Count
    $errorBadge    = if ($errorCount -gt 0) { "<span class='badge err'>$errorCount errors</span>" } else { "" }

    $treeHtml = Build-HtmlTreeNode -NodePath $normalizedRootPath -NodeDataMap $nodeDataMap -ChildrenMap $childrenMap

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

function New-AclTreeMaps {
    param(
        [System.Collections.Generic.List[PSCustomObject]]$Data,
        [string]$RootPath
    )

    $normalizedRootPath = Get-NormalizedPath -Path $RootPath
    $nodeDataMap = @{}
    $childrenMap = @{}
    foreach ($item in $Data) {
        $normalizedItemPath = Get-NormalizedPath -Path $item.Path
        $nodeDataMap[$normalizedItemPath] = $item
        if ($normalizedItemPath -ne $normalizedRootPath) {
            $parent = Get-NormalizedPath -Path (Split-Path $item.Path -Parent)
            if (-not $childrenMap.ContainsKey($parent)) {
                $childrenMap[$parent] = [System.Collections.Generic.List[string]]::new()
            }
            [void]$childrenMap[$parent].Add($normalizedItemPath)
        }
    }

    [PSCustomObject]@{
        RootPath    = $normalizedRootPath
        NodeDataMap = $nodeDataMap
        ChildrenMap = $childrenMap
    }
}

function Test-TreeNodeMatch {
    param(
        [string]$NodePath,
        [hashtable]$NodeDataMap,
        [hashtable]$ChildrenMap,
        [string]$Query
    )

    if ([string]::IsNullOrWhiteSpace($Query)) {
        return $true
    }

    $data = $NodeDataMap[$NodePath]
    $name = Split-Path $NodePath -Leaf
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = $NodePath
    }

    $searchTexts = [System.Collections.Generic.List[string]]::new()
    [void]$searchTexts.Add($name)
    [void]$searchTexts.Add($NodePath)
    if ($null -ne $data) {
        [void]$searchTexts.Add([string]$data.Owner)
        [void]$searchTexts.Add([string]$data.Error)
        foreach ($permission in $data.Permissions) {
            [void]$searchTexts.Add([string]$permission.IdentityReference)
            [void]$searchTexts.Add([string]$permission.FileSystemRights)
            [void]$searchTexts.Add([string]$permission.AccessControlType)
        }
    }

    foreach ($text in $searchTexts) {
        if (-not [string]::IsNullOrWhiteSpace($text) -and $text.IndexOf($Query, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }

    foreach ($child in @($ChildrenMap[$NodePath] | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
        if (Test-TreeNodeMatch -NodePath $child -NodeDataMap $NodeDataMap -ChildrenMap $ChildrenMap -Query $Query) {
            return $true
        }
    }

    return $false
}

function Add-AclTreeNode {
    param(
        [System.Windows.Forms.TreeNodeCollection]$Nodes,
        [string]$NodePath,
        [hashtable]$NodeDataMap,
        [hashtable]$ChildrenMap,
        [string]$Query
    )

    if (-not (Test-TreeNodeMatch -NodePath $NodePath -NodeDataMap $NodeDataMap -ChildrenMap $ChildrenMap -Query $Query)) {
        return $null
    }

    $data = $NodeDataMap[$NodePath]
    $name = Split-Path $NodePath -Leaf
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = $NodePath
    }

    $typePrefix = if ($null -ne $data -and $data.ItemType -eq "File") { "[F]" } else { "[D]" }
    $treeNode = New-Object System.Windows.Forms.TreeNode("$typePrefix $name")
    $treeNode.Name = $NodePath
    $treeNode.Tag = $data
    [void]$Nodes.Add($treeNode)

    foreach ($child in (@($ChildrenMap[$NodePath] | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) | Sort-Object)) {
        [void](Add-AclTreeNode -Nodes $treeNode.Nodes -NodePath $child -NodeDataMap $NodeDataMap -ChildrenMap $ChildrenMap -Query $Query)
    }

    $treeNode
}

function Set-AclViewerDetails {
    param(
        [System.Windows.Forms.TreeNode]$SelectedNode,
        [System.Windows.Forms.Label]$PathValueLabel,
        [System.Windows.Forms.Label]$OwnerValueLabel,
        [System.Windows.Forms.Label]$TypeValueLabel,
        [System.Windows.Forms.Label]$ErrorValueLabel,
        [System.Windows.Forms.DataGridView]$PermissionsGrid
    )

    $PermissionsGrid.Rows.Clear()

    if ($null -eq $SelectedNode -or $null -eq $SelectedNode.Tag) {
        $PathValueLabel.Text = ""
        $OwnerValueLabel.Text = ""
        $TypeValueLabel.Text = ""
        $ErrorValueLabel.Text = ""
        return
    }

    $data = $SelectedNode.Tag
    $PathValueLabel.Text = [string]$data.Path
    $OwnerValueLabel.Text = if ([string]::IsNullOrWhiteSpace([string]$data.Owner)) { "(unknown)" } else { [string]$data.Owner }
    $TypeValueLabel.Text = [string]$data.ItemType
    $ErrorValueLabel.Text = [string]$data.Error

    foreach ($permission in $data.Permissions) {
        [void]$PermissionsGrid.Rows.Add(
            [string]$permission.IdentityReference,
            [string]$permission.FileSystemRights,
            [string]$permission.AccessControlType,
            [string]$permission.IsInherited
        )
    }
}

function Show-AclReportViewer {
    param(
        [System.Collections.Generic.List[PSCustomObject]]$Data,
        [string]$RootPath,
        [string]$ReportTitle
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $viewerState = [hashtable]::Synchronized(@{
        AuditPath     = (Get-NormalizedPath -Path $RootPath)
        Data          = $Data
        Maps          = (New-AclTreeMaps -Data $Data -RootPath $RootPath)
        DisplayTitle  = (Get-DefaultReportTitle -AuditPath $RootPath -ReportTitle $ReportTitle)
        TotalItems    = $Data.Count
        ErrorCount    = @($Data | Where-Object { $_.Error }).Count
    })

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "ACL Viewer - $($viewerState.DisplayTitle)"
    $form.StartPosition = "CenterScreen"
    $form.Width = 1450
    $form.Height = 900
    $form.MinimumSize = New-Object System.Drawing.Size(900, 620)

    $rootLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $rootLayout.Dock = "Fill"
    $rootLayout.ColumnCount = 1
    $rootLayout.RowCount = 2
    $rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 128)))
    $rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $form.Controls.Add($rootLayout)

    $headerLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $headerLayout.Dock = "Fill"
    $headerLayout.ColumnCount = 1
    $headerLayout.RowCount = 3
    $headerLayout.Padding = New-Object System.Windows.Forms.Padding(12, 8, 12, 8)
    $headerLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 34)))
    $headerLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 34)))
    $headerLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 34)))
    $rootLayout.Controls.Add($headerLayout, 0, 0)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Dock = "Fill"
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $titleLabel.Text = "ACL Viewer - $($viewerState.DisplayTitle)"
    $titleLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $headerLayout.Controls.Add($titleLabel, 0, 0)

    $pathRowLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $pathRowLayout.Dock = "Fill"
    $pathRowLayout.ColumnCount = 4
    $pathRowLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 70)))
    $pathRowLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $pathRowLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 90)))
    $pathRowLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 90)))
    $headerLayout.Controls.Add($pathRowLayout, 0, 1)

    $auditPathLabel = New-Object System.Windows.Forms.Label
    $auditPathLabel.Text = "Audit Path"
    $auditPathLabel.Dock = "Fill"
    $auditPathLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $pathRowLayout.Controls.Add($auditPathLabel, 0, 1)

    $auditPathTextBox = New-Object System.Windows.Forms.TextBox
    $auditPathTextBox.Dock = "Fill"
    $auditPathTextBox.Text = [string]$viewerState.AuditPath
    $pathRowLayout.Controls.Add($auditPathTextBox, 1, 1)

    $browseButton = New-Object System.Windows.Forms.Button
    $browseButton.Text = "Browse..."
    $browseButton.Dock = "Fill"
    $pathRowLayout.Controls.Add($browseButton, 2, 1)

    $reloadButton = New-Object System.Windows.Forms.Button
    $reloadButton.Text = "Reload"
    $reloadButton.Dock = "Fill"
    $pathRowLayout.Controls.Add($reloadButton, 3, 1)

    $bottomRowLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $bottomRowLayout.Dock = "Fill"
    $bottomRowLayout.ColumnCount = 2
    $bottomRowLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $bottomRowLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $headerLayout.Controls.Add($bottomRowLayout, 0, 2)

    $metaLabel = New-Object System.Windows.Forms.Label
    $metaLabel.Dock = "Fill"
    $metaLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $metaLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $bottomRowLayout.Controls.Add($metaLabel, 0, 0)

    $searchControls = New-Object System.Windows.Forms.FlowLayoutPanel
    $searchControls.Dock = "Fill"
    $searchControls.AutoSize = $true
    $searchControls.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $searchControls.WrapContents = $false
    $searchControls.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $searchControls.Margin = New-Object System.Windows.Forms.Padding(0)
    $bottomRowLayout.Controls.Add($searchControls, 1, 0)

    $searchLabel = New-Object System.Windows.Forms.Label
    $searchLabel.AutoSize = $true
    $searchLabel.Text = "Search"
    $searchLabel.Margin = New-Object System.Windows.Forms.Padding(0, 8, 8, 0)
    $searchControls.Controls.Add($searchLabel)

    $searchBox = New-Object System.Windows.Forms.TextBox
    $searchBox.Width = 280
    $searchBox.Margin = New-Object System.Windows.Forms.Padding(0, 4, 12, 0)
    $searchControls.Controls.Add($searchBox)

    $expandButton = New-Object System.Windows.Forms.Button
    $expandButton.Text = "Expand All"
    $expandButton.Width = 95
    $expandButton.Margin = New-Object System.Windows.Forms.Padding(0, 2, 8, 0)
    $searchControls.Controls.Add($expandButton)

    $collapseButton = New-Object System.Windows.Forms.Button
    $collapseButton.Text = "Collapse All"
    $collapseButton.Width = 95
    $collapseButton.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)
    $searchControls.Controls.Add($collapseButton)

    $folderBrowserDialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderBrowserDialog.Description = "Select a folder to audit"
    $folderBrowserDialog.UseDescriptionForTitle = $true

    $splitContainer = New-Object System.Windows.Forms.SplitContainer
    $splitContainer.Dock = "Fill"
    $splitContainer.SplitterWidth = 8
    $rootLayout.Controls.Add($splitContainer, 0, 1)

    $treeView = New-Object System.Windows.Forms.TreeView
    $treeView.Dock = "Fill"
    $treeView.HideSelection = $false
    $treeView.FullRowSelect = $true
    $treeView.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $splitContainer.Panel1.Controls.Add($treeView)

    $detailPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $detailPanel.Dock = "Fill"
    $detailPanel.ColumnCount = 2
    $detailPanel.RowCount = 5
    $detailPanel.Padding = New-Object System.Windows.Forms.Padding(12)
    $detailPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 90)))
    $detailPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $detailPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 36)))
    $detailPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 36)))
    $detailPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 36)))
    $detailPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 56)))
    $detailPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $splitContainer.Panel2.Controls.Add($detailPanel)

    $pathLabel = New-Object System.Windows.Forms.Label
    $pathLabel.Text = "Path"
    $pathLabel.AutoSize = $true
    $pathLabel.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
    $detailPanel.Controls.Add($pathLabel, 0, 0)

    $pathValueLabel = New-Object System.Windows.Forms.Label
    $pathValueLabel.AutoSize = $true
    $pathValueLabel.MaximumSize = New-Object System.Drawing.Size(760, 0)
    $pathValueLabel.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
    $detailPanel.Controls.Add($pathValueLabel, 1, 0)

    $ownerLabel = New-Object System.Windows.Forms.Label
    $ownerLabel.Text = "Owner"
    $ownerLabel.AutoSize = $true
    $ownerLabel.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
    $detailPanel.Controls.Add($ownerLabel, 0, 1)

    $ownerValueLabel = New-Object System.Windows.Forms.Label
    $ownerValueLabel.AutoSize = $true
    $ownerValueLabel.MaximumSize = New-Object System.Drawing.Size(760, 0)
    $ownerValueLabel.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
    $detailPanel.Controls.Add($ownerValueLabel, 1, 1)

    $typeLabel = New-Object System.Windows.Forms.Label
    $typeLabel.Text = "Type"
    $typeLabel.AutoSize = $true
    $typeLabel.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
    $detailPanel.Controls.Add($typeLabel, 0, 2)

    $typeValueLabel = New-Object System.Windows.Forms.Label
    $typeValueLabel.AutoSize = $true
    $typeValueLabel.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
    $detailPanel.Controls.Add($typeValueLabel, 1, 2)

    $errorLabel = New-Object System.Windows.Forms.Label
    $errorLabel.Text = "Error"
    $errorLabel.AutoSize = $true
    $errorLabel.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
    $detailPanel.Controls.Add($errorLabel, 0, 3)

    $errorValueLabel = New-Object System.Windows.Forms.Label
    $errorValueLabel.AutoSize = $true
    $errorValueLabel.ForeColor = [System.Drawing.Color]::Firebrick
    $errorValueLabel.MaximumSize = New-Object System.Drawing.Size(760, 0)
    $errorValueLabel.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
    $detailPanel.Controls.Add($errorValueLabel, 1, 3)

    $permissionsGrid = New-Object System.Windows.Forms.DataGridView
    $permissionsGrid.Dock = "Fill"
    $permissionsGrid.ReadOnly = $true
    $permissionsGrid.AllowUserToAddRows = $false
    $permissionsGrid.AllowUserToDeleteRows = $false
    $permissionsGrid.AllowUserToResizeRows = $false
    $permissionsGrid.AutoSizeColumnsMode = "Fill"
    $permissionsGrid.SelectionMode = "FullRowSelect"
    $permissionsGrid.MultiSelect = $false
    $permissionsGrid.RowHeadersVisible = $false
    [void]$permissionsGrid.Columns.Add("IdentityReference", "Identity")
    [void]$permissionsGrid.Columns.Add("FileSystemRights", "Rights")
    [void]$permissionsGrid.Columns.Add("AccessControlType", "Type")
    [void]$permissionsGrid.Columns.Add("IsInherited", "Inherited")
    $detailPanel.Controls.Add($permissionsGrid, 0, 4)
    $detailPanel.SetColumnSpan($permissionsGrid, 2)

    $updateViewerMetadata = {
        $metaLabel.Text = "Path: $($viewerState.AuditPath)   Items: $($viewerState.TotalItems)   Errors: $($viewerState.ErrorCount)"
        $titleLabel.Text = "ACL Viewer - $($viewerState.DisplayTitle)"
        $form.Text = "ACL Viewer - $($viewerState.DisplayTitle)"
        $auditPathTextBox.Text = [string]$viewerState.AuditPath
    }

    $populateTree = {
        param([string]$Query)

        $treeView.BeginUpdate()
        $treeView.Nodes.Clear()
        [void](Add-AclTreeNode -Nodes $treeView.Nodes -NodePath $viewerState.Maps.RootPath -NodeDataMap $viewerState.Maps.NodeDataMap -ChildrenMap $viewerState.Maps.ChildrenMap -Query $Query)
        $treeView.EndUpdate()

        if ($treeView.Nodes.Count -gt 0) {
            if (-not [string]::IsNullOrWhiteSpace($Query)) {
                $treeView.ExpandAll()
            }
            $treeView.SelectedNode = $treeView.Nodes[0]
            $treeView.Nodes[0].EnsureVisible()
        } else {
            Set-AclViewerDetails -SelectedNode $null -PathValueLabel $pathValueLabel -OwnerValueLabel $ownerValueLabel -TypeValueLabel $typeValueLabel -ErrorValueLabel $errorValueLabel -PermissionsGrid $permissionsGrid
        }
    }

    $reloadAuditPath = {
        param([string]$RequestedPath)

        $candidatePath = [string]$RequestedPath
        if ([string]::IsNullOrWhiteSpace($candidatePath)) {
            [void][System.Windows.Forms.MessageBox]::Show(
                "Enter or select a folder path to audit.",
                "ACL Viewer",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            return
        }

        if (-not (Test-Path -LiteralPath $candidatePath -PathType Container)) {
            [void][System.Windows.Forms.MessageBox]::Show(
                "The selected audit path does not exist or is not a folder.`r`n`r`n$candidatePath",
                "ACL Viewer",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            return
        }

        $resolvedPath = (Resolve-Path -LiteralPath $candidatePath).Path

        $form.UseWaitCursor = $true
        $treeView.Enabled = $false
        $reloadButton.Enabled = $false
        $browseButton.Enabled = $false

        try {
            $loadedData = Get-RecursiveACLReport -Path $resolvedPath -FoldersOnly:$AuditFoldersOnly
            if ($null -eq $loadedData -or $loadedData.Count -eq 0) {
                throw "No audit data was collected for '$resolvedPath'."
            }

            $viewerState.AuditPath = (Get-NormalizedPath -Path $resolvedPath)
            $viewerState.Data = $loadedData
            $viewerState.Maps = New-AclTreeMaps -Data $loadedData -RootPath $resolvedPath
            $viewerState.DisplayTitle = Get-DefaultReportTitle -AuditPath $resolvedPath -ReportTitle $ReportTitle
            $viewerState.TotalItems = $loadedData.Count
            $viewerState.ErrorCount = @($loadedData | Where-Object { $_.Error }).Count

            & $updateViewerMetadata
            & $populateTree $searchBox.Text
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show(
                "Failed to load ACL data.`r`n`r`n$($_.Exception.Message)",
                "ACL Viewer",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        } finally {
            $form.UseWaitCursor = $false
            $treeView.Enabled = $true
            $reloadButton.Enabled = $true
            $browseButton.Enabled = $true
        }
    }

    $treeView.add_AfterSelect({
        Set-AclViewerDetails -SelectedNode $_.Node -PathValueLabel $pathValueLabel -OwnerValueLabel $ownerValueLabel -TypeValueLabel $typeValueLabel -ErrorValueLabel $errorValueLabel -PermissionsGrid $permissionsGrid
    })

    $searchBox.add_TextChanged({
        & $populateTree $searchBox.Text
    })

    $expandButton.add_Click({
        $treeView.ExpandAll()
    })

    $collapseButton.add_Click({
        $treeView.CollapseAll()
    })

    $browseButton.add_Click({
        $folderBrowserDialog.SelectedPath = [string]$viewerState.AuditPath
        if ($folderBrowserDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            & $reloadAuditPath $folderBrowserDialog.SelectedPath
        }
    })

    $reloadButton.add_Click({
        & $reloadAuditPath $auditPathTextBox.Text
    })

    $auditPathTextBox.add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $_.SuppressKeyPress = $true
            & $reloadAuditPath $auditPathTextBox.Text
        }
    })

    $form.add_Shown({
        $splitContainer.Panel1MinSize = 320
        $splitContainer.Panel2MinSize = 360

        $availableWidth = [Math]::Max($splitContainer.ClientSize.Width, 760)
        $preferredLeftWidth = [Math]::Max([int]($availableWidth * 0.58), 420)
        $maxLeftWidth = [Math]::Max($availableWidth - $splitContainer.Panel2MinSize - $splitContainer.SplitterWidth, $splitContainer.Panel1MinSize)
        $splitContainer.SplitterDistance = [Math]::Min($preferredLeftWidth, $maxLeftWidth)
    })

    & $updateViewerMetadata
    & $populateTree ""

    [void]$form.ShowDialog()
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

    if ($OutputMode -eq "Html") {
        if ([string]::IsNullOrWhiteSpace($HTMLOutputPath)) {
            throw "HTMLOutputPath is not set."
        }

        if (-not (Test-Path -LiteralPath $HTMLOutputPath)) {
            [void](New-Item -Path $HTMLOutputPath -ItemType Directory -Force)
        }

        [void](New-StreamingHtmlAclReport -RootPath $AuditPath -OutputPath $HtmlPath -ReportTitle $ReportTitle -FoldersOnly:$AuditFoldersOnly)

        if (-not (Test-Path -LiteralPath $HtmlPath)) {
            throw "HTML report file was not created: $HtmlPath"
        }

        Write-Host "ACL audit complete. HTML report exported to $HtmlPath"
    } else {
        $report = Get-RecursiveACLReport -Path $AuditPath -FoldersOnly:$AuditFoldersOnly
        if ($null -eq $report -or $report.Count -eq 0) {
            throw "No audit data was collected."
        }

        Show-AclReportViewer -Data $report -RootPath $AuditPath -ReportTitle $ReportTitle
        Write-Host "ACL audit complete. Viewer closed."
    }
    exit 0
}
catch {
    Write-Error "ACL audit failed: $($_.Exception.Message)"
    exit 1
}
