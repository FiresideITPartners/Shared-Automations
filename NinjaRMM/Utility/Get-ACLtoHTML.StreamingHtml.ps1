function New-StreamingAclHtmlState {
    param(
        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [string]$RootPath,

        [Parameter(Mandatory)]
        [string]$DisplayTitle
    )

    $directoryPath = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($directoryPath) -and -not (Test-Path -LiteralPath $directoryPath)) {
        [void](New-Item -Path $directoryPath -ItemType Directory -Force)
    }

    $writer = [System.IO.StreamWriter]::new($OutputPath, $false, [System.Text.UTF8Encoding]::new($false))
    $writer.AutoFlush = $false

    return @{
        Writer          = $writer
        OutputPath      = $OutputPath
        RootPath        = $RootPath
        DisplayTitle    = $DisplayTitle
        GeneratedAt     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        NodeCounter     = 0
        CurrentDepth    = 0
        TotalItems      = 0
        ErrorCount      = 0
        FlushInterval   = 100
    }
}

function Write-StreamingAclHtmlHeader {
    param(
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    $title = ConvertTo-HtmlEncoded $State['DisplayTitle']
    $rootPath = ConvertTo-HtmlEncoded $State['RootPath']
    $generatedAt = ConvertTo-HtmlEncoded $State['GeneratedAt']

    $State['Writer'].WriteLine(@"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ACL Report - $title</title>
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
  <h1>&#128273; ACL Report &mdash; $title</h1>
  <h2 class="meta">Path: $rootPath</h2>
  <span class="meta">Generated: $generatedAt</span>
  <span class="badge" id="itemCountBadge">Scanning...</span>
  <span class="badge err" id="errorCountBadge" style="display:none"></span>
  <div class="controls">
    <input type="search" id="searchBox" placeholder="Filter by name..." oninput="filterTree(this.value)">
    <button onclick="collapseAll()">Collapse All</button>
    <button onclick="collapseLeft()">Collapse Left</button>
    <button onclick="expandRight()">Expand Right</button>
    <button onclick="expandAll()">Expand All</button>
  </div>
</header>
<main>
<ul>
"@)
}

function Write-StreamingAclHtmlNodeStart {
    param(
        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter(Mandatory)]
        [pscustomobject]$Record,

        [AllowNull()]
        [object[]]$ChildPaths = @()
    )

    $State['NodeCounter']++
    $State['TotalItems']++
    $hasError = -not [string]::IsNullOrWhiteSpace([string]$Record.Error) -or -not [string]::IsNullOrWhiteSpace([string]$Record.EnumerationError)

    if ($hasError) {
        $State['ErrorCount']++
    }

    $nodeId = "n$($State['NodeCounter'])"
    $childCount = @($ChildPaths).Count
    $hasChildren = $childCount -gt 0
    $name = Split-Path $Record.Path -Leaf
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = $Record.Path
    }

    $icon = if ($Record.ItemType -eq "Folder") { "&#128193;" } else { "&#128196;" }
    $labelClass = if ($hasError) { "item-name has-error" } else { "item-name" }
    if (-not [string]::IsNullOrWhiteSpace([string]$Record.EnumerationError)) {
        $name = "$name [inaccessible]"
    }
    $ownerRaw = [string]$Record.Owner
    $ownerIsUnknown = [string]::IsNullOrWhiteSpace($ownerRaw)
    $ownerText = if ($ownerIsUnknown) { "Owner: (unknown)" } else { "Owner: $ownerRaw" }
    $ownerBadgeClass = if ($ownerIsUnknown) { "owner-badge unknown-owner" } else { "owner-badge" }

    $State['Writer'].Write("<li>")
    if ($hasChildren) {
        $State['Writer'].Write("<span class='caret' id='c$nodeId' onclick='toggleTree(""$nodeId"",""c$nodeId"")'></span>")
    } else {
        $State['Writer'].Write("<span class='caret-spacer'></span>")
    }

    $State['Writer'].Write("<span class='$labelClass' onclick='toggleDetails(""d$nodeId"")'>$icon $(ConvertTo-HtmlEncoded $name)<span class='$ownerBadgeClass'>$(ConvertTo-HtmlEncoded $ownerText)</span></span>")
    $State['Writer'].Write("<div class='details' id='d$nodeId'>")

    $State['Writer'].Write("<div class='detail-path'>$(ConvertTo-HtmlEncoded $Record.Path)</div>")
    if (-not [string]::IsNullOrWhiteSpace([string]$Record.EnumerationError)) {
        $State['Writer'].Write("<div class='detail-error'><b>&#9888; Inaccessible:</b> Unable to enumerate child items. $(ConvertTo-HtmlEncoded $Record.EnumerationError)</div>")
    }

    if ($Record.Error) {
        $State['Writer'].Write("<div class='detail-error'><b>&#9888; Error:</b> $(ConvertTo-HtmlEncoded $Record.Error)</div>")
    } else {
        $State['Writer'].Write("<div class='detail-owner'><b>Owner:</b> $(ConvertTo-HtmlEncoded $Record.Owner)</div>")
        $State['Writer'].Write("<table class='perm-table'><thead><tr><th>Identity</th><th>Rights</th><th>Type</th><th>Inherited</th></tr></thead><tbody>")
        foreach ($permission in $Record.Permissions) {
            $rowClass = if ($permission.AccessControlType -eq "Deny") { " class='deny'" } else { "" }
            $State['Writer'].Write("<tr$rowClass>")
            $State['Writer'].Write("<td>$(ConvertTo-HtmlEncoded $permission.IdentityReference)</td>")
            $State['Writer'].Write("<td>$(ConvertTo-HtmlEncoded $permission.FileSystemRights)</td>")
            $State['Writer'].Write("<td>$(ConvertTo-HtmlEncoded $permission.AccessControlType)</td>")
            $State['Writer'].Write("<td>$(ConvertTo-HtmlEncoded ([string]$permission.IsInherited))</td>")
            $State['Writer'].Write("</tr>")
        }
        $State['Writer'].Write("</tbody></table>")
    }

    $State['Writer'].Write("</div>")

    if ($hasChildren) {
        $childDepth = [int]$State['CurrentDepth'] + 1
        $State['Writer'].Write("<ul id='$nodeId' class='nested' data-depth='$childDepth'>")
        $State['CurrentDepth'] = $childDepth
    }

    if (($State['TotalItems'] % $State['FlushInterval']) -eq 0) {
        $State['Writer'].Flush()
    }
}

function Write-StreamingAclHtmlNodeEnd {
    param(
        [Parameter(Mandatory)]
        [hashtable]$State,

        [AllowNull()]
        [object[]]$ChildPaths = @()
    )

    if (@($ChildPaths).Count -gt 0) {
        $State['Writer'].Write("</ul>")
        $State['CurrentDepth'] = [Math]::Max(0, [int]$State['CurrentDepth'] - 1)
    }

    $State['Writer'].Write("</li>")
}

function Complete-StreamingAclHtmlReport {
    param(
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    try {
        $State['Writer'].WriteLine(@"
</ul>
</main>
<script>
function forEachNode(nodeList, callback) {
  for (var i = 0; i < nodeList.length; i++) {
    callback(nodeList[i], i);
  }
}
function getDirectItemLabel(li) {
  for (var i = 0; i < li.children.length; i++) {
    var child = li.children[i];
    if (child.classList && child.classList.contains('item-name')) {
      return child;
    }
  }
  return null;
}
function setNestedOpen(ul, isOpen) {
  if (!ul) return;
  ul.classList.toggle('open', isOpen);
  var caret = document.getElementById('c' + ul.id);
  if (caret) caret.classList.toggle('open', isOpen);
}
function getNestedDepth(ul) {
  var value = parseInt(ul.getAttribute('data-depth') || '0', 10);
  return isNaN(value) ? 0 : value;
}
function getDeepestOpenDepth() {
  var deepest = 0;
  forEachNode(document.querySelectorAll('.nested.open'), function(ul) {
    deepest = Math.max(deepest, getNestedDepth(ul));
  });
  return deepest;
}
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
function expandRight() {
  var targetDepth = getDeepestOpenDepth() + 1;
  var foundMatch = false;
  forEachNode(document.querySelectorAll('.nested'), function(ul) {
    if (getNestedDepth(ul) === targetDepth) {
      setNestedOpen(ul, true);
      foundMatch = true;
    }
  });
  if (!foundMatch && targetDepth > 1) {
    expandAll();
  }
}
function collapseLeft() {
  var targetDepth = getDeepestOpenDepth();
  if (targetDepth <= 0) {
    return;
  }
  forEachNode(document.querySelectorAll('.nested.open'), function(ul) {
    if (getNestedDepth(ul) === targetDepth) {
      setNestedOpen(ul, false);
    }
  });
}
function expandAll() {
  forEachNode(document.querySelectorAll('.nested'), function(el){setNestedOpen(el, true)});
}
function collapseAll() {
  forEachNode(document.querySelectorAll('.nested'), function(el){setNestedOpen(el, false)});
  forEachNode(document.querySelectorAll('.details'), function(el){el.classList.remove('open')});
}
function filterTree(q) {
  q = q.trim().toLowerCase();
  var items = document.querySelectorAll('li');
  if (!q) {
    forEachNode(items, function(li){li.classList.remove('hidden')});
    collapseAll();
    return;
  }
  forEachNode(items, function(li) {
    var lbl = getDirectItemLabel(li);
    var txt = lbl ? lbl.textContent.toLowerCase() : '';
    li.classList.toggle('hidden', !txt.includes(q));
  });
  forEachNode(document.querySelectorAll('.nested'), function(el){el.classList.add('open')});
  forEachNode(document.querySelectorAll('.caret'), function(el){el.classList.add('open')});
}
document.getElementById('itemCountBadge').textContent = '$($State['TotalItems']) items';
var errorBadge = document.getElementById('errorCountBadge');
if ($($State['ErrorCount']) > 0) {
  errorBadge.textContent = '$($State['ErrorCount']) errors';
  errorBadge.style.display = 'inline-block';
}
</script>
</body>
</html>
"@)
        $State['Writer'].Flush()
    } finally {
        $State['Writer'].Dispose()
    }
}

function New-StreamingHtmlAclReport {
    param(
        [Parameter(Mandatory)]
        [string]$RootPath,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter()]
        [AllowEmptyString()]
        [string]$ReportTitle,

        [Parameter(Mandatory)]
        [bool]$FoldersOnly
    )

    $displayTitle = Get-DefaultReportTitle -AuditPath $RootPath -ReportTitle $ReportTitle
    $state = New-StreamingAclHtmlState -OutputPath $OutputPath -RootPath (Get-NormalizedPath -Path $RootPath) -DisplayTitle $displayTitle

    Write-StreamingAclHtmlHeader -State $state

    try {
        $summary = Invoke-StreamingAclScan -RootPath $RootPath -FoldersOnly:$FoldersOnly -CallbackContext $state -OnNodeStart {
            param($record, $childPaths, $callbackState)

            Write-StreamingAclHtmlNodeStart -State $callbackState -Record $record -ChildPaths $childPaths
        } -OnNodeEnd {
            param($record, $childPaths, $callbackState)

            Write-StreamingAclHtmlNodeEnd -State $callbackState -ChildPaths $childPaths
        }

        return $summary
    } finally {
        Complete-StreamingAclHtmlReport -State $state
    }
}
