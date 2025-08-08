# .SYNOPSIS
#   Retrieves attached monitor information using NirSoft MonitorInfoView and outputs results for NinjaRMM custom fields.
#
# .DESCRIPTION
#   This script downloads and runs NirSoft MonitorInfoView to collect detailed information about monitors attached to the system.
#   It parses the output, formats it as an HTML table, and sends it to NinjaRMM using a custom property set command.
#   Temporary files are cleaned up after execution.
#
# 
#
# .NOTES
#   Author: Fireside IT Partners
#   Requirements: 
#       - PowerShell 5.0+
#       - Internet access
#       - NinjaRMM WYSIWYG custom field (change variable below)
#   External Tool: https://www.nirsoft.net/utils/monitorinfoview.html
#
# .EXAMPLE
#   .\Get-AttachedMonitors.ps1
#   Runs the script and updates the NinjaRMM custom field with attached monitor information.
#
# .EXAMPLE
#   .\Get-AttachedMonitors.ps1
#   (Can be scheduled or run remotely via NinjaRMM scripting module.)
#
# .OUTPUTS
#   HTML table of monitor information sent to NinjaRMM custom field 'attachedMonitors'.
#
# .COMPONENT
#   NinjaRMM Integration, MonitorInfoView
#
# .LICENSE
#   This script is open to be copied, modified, and reused as necessary, with or without attribution.
#   The included MonitorInfoView utility is subject to NirSoft licensing terms:
#   https://www.nirsoft.net/utils/monitorinfoview.html

#Variables:
$ninjacustomfield = "attachedMonitors" #NinjaRMM custom field to set

$tempFolder = Join-Path $env:TEMP "MonitorProcessing"
New-Item -Path $tempFolder -ItemType Directory -Force | Out-Null
$monitorinfoviewURL = "https://www.nirsoft.net/utils/monitorinfoview.zip"
$monitorinfoviewDLPath = Join-Path $tempFolder "monitorinfoview.zip"
$monitorinfoviewPath = Join-Path $tempFolder "MonitorInfoView.exe"
function ConvertTo-ObjectToHtmlTable {
    <#
    .SYNOPSIS
        Function for converting Object into HTML for Ninja's consumption. (https://discord.com/channels/676451788395642880/676453812428341261/1238233730850623521)
    #>
    param (
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[Object]]$Objects
    )

    $sb = New-Object System.Text.StringBuilder

    # Start the HTML table
    [void]$sb.Append('<table><thead><tr>')

    # Add column headers based on the properties of the first object, excluding "RowColour"
    $Objects[0].PSObject.Properties.Name |
    Where-Object { $_ -ne 'RowColour' } |
    ForEach-Object { [void]$sb.Append("<th>$_</th>") }

    [void]$sb.Append('</tr></thead><tbody>')

    foreach ($obj in $Objects) {
        # Use the RowColour property from the object to set the class for the row
        $rowClass = if ($obj.RowColour) { $obj.RowColour } else { "" }

        [void]$sb.Append("<tr class=`"$rowClass`">")
        # Generate table cells, excluding "RowColour"
        foreach ($propName in $obj.PSObject.Properties.Name | Where-Object { $_ -ne 'RowColour' }) {
            [void]$sb.Append("<td>$($obj.$propName)</td>")
        }
        [void]$sb.Append('</tr>')
    }

    [void]$sb.Append('</tbody></table>')

    return $sb.ToString()
}


# Download MonitorInfoView.exe if it doesn't exist
if (Test-Path $monitorinfoviewPath) {
    Write-Host "File already exists: $monitorinfoviewPath"
} else {
    try {
        Write-Host "Downloading MonitorInfoView from $monitorinfoviewURL ..."
        Invoke-WebRequest -Uri $monitorinfoviewURL -OutFile $monitorinfoviewDLPath -ErrorAction Stop
        Write-Host "Extracting MonitorInfoView..."
        Expand-Archive -Path $monitorinfoviewDLPath -DestinationPath $tempfolder -Force
        Write-Host "Download and extraction successful: $monitorinfoviewPath"
    } catch {
        Write-Host "ERROR: Failed to download or extract MonitorInfoView from $monitorinfoviewURL to $monitorinfoviewPath. Error: $_" -ForegroundColor Red
        Remove-Item -Path $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
        exit 1
    }
}


$outXML = Join-Path $tempFolder "monitorinfo.xml"
try {
    Write-Host "Running MonitorInfoView to collect monitor information..."
    Start-Process -FilePath $monitorinfoviewPath -ArgumentList "/sxml $outXML" -Wait
} catch {
    Write-Host "ERROR: Failed to run MonitorInfoView.exe. Error: $_" -ForegroundColor Red
    Remove-Item -Path $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

if (!(Test-Path $outXML)) {
    Write-Host "ERROR: MonitorInfoView.exe did not create the expected XML file: $outXML" -ForegroundColor Red
    Remove-Item -Path $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

try {
    [xml]$monitorsxml = Get-Content $outXML
    $monitors = $monitorsxml.monitors_list.item
} catch {
    Write-Host "ERROR: Failed to parse XML output: $outXML. Error: $_" -ForegroundColor Red
    Remove-Item -Path $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

if (-not $monitors) {
    Write-Host "ERROR: No monitor information found in XML output." -ForegroundColor Yellow
    Remove-Item -Path $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

$customMonitors = @()
foreach ($monitor in $monitors) {
    $customMonitors += [PSCustomObject]@{
        Name        = $monitor.'monitor_name'
        Serial      = $monitor.'serial_number'
        Resolution  = $monitor.'maximum_resolution'
        Size        = if (![string]::IsNullOrWhiteSpace($monitor.'image_size')) { $monitor.'image_size' } else { $monitor.'maximum_image_size' }
        Active     = $monitor.'active'
        LastUpdated = $monitor.'last_update_time'
    }
}

if ($customMonitors.Count -eq 0) {
    Write-Host "WARNING: No monitor data was collected." -ForegroundColor Yellow
    Remove-Item -Path $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
}

Write-Host "Monitor information collected successfully."
#create HTML table for custom fields
try {
    $htmlTable = ConvertTo-ObjectToHtmlTable -Objects $customMonitors
    $htmlTable | Ninja-Property-Set-Piped $ninjacustomfield
    Write-Host "Monitor information sent to NinjaRMM custom field '$ninjacustomfield'."
} catch {
    Write-Host "ERROR: Failed to convert monitor data to HTML or send to NinjaRMM. Error: $_" -ForegroundColor Red
    Remove-Item -Path $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

#cleanup temp folder
Remove-Item -Path $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Temporary files cleaned up."
exit 0