# .SYNOPSIS
#   Retrieves attached monitor information using NirSoft MonitorInfoView and outputs results for NinjaRMM custom fields.
#
# .DESCRIPTION
#   This script downloads and runs NirSoft MonitorInfoView to collect detailed information about monitors attached to the system.
#   It parses the output, formats it as an HTML table, and sends it to NinjaRMM using a custom property set command.
#   Temporary files are cleaned up after execution.
#
# .NOTES
#   Author: Fireside IT Partners
#   Requirements: PowerShell 5.0+, Internet access, permission to download and run external utilities
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
    Write-Output "File already exists: $monitorinfoviewPath"
    return
}
try {
    Invoke-WebRequest -Uri $monitorinfoviewURL -OutFile $monitorinfoviewDLPath -ErrorAction Stop
    Expand-Archive -Path $monitorinfoviewDLPath -DestinationPath $tempfolder -Force
    Write-Output "Download successful: $monitorinfoviewPath"
}
catch {
    Write-Error "Failed to download file from $monitorinfoviewURL to $monitorinfoviewPath. Error: $_"
    exit 1
}

#Run MonitorInfoView.exe
$outCSV = Join-Path $tempfolder "monitorinfo.csv"
Try {
    Start-Process -FilePath $monitorinfoviewPath -ArgumentList "/scomma $outCSV" -Wait
}
Catch {
    Write-Error "Failed to run MonitorInfoView.exe. Error: $_"
    exit 1
}
#verify CSV created
if (!(Test-Path $outCSV)) {
    Write-Error "MonitorInfoView.exe did not create the expected XML file: $outCSV"
    exit 1
}

# Import the CSV
$monitors = Import-CSV $outCSV
# Create custom objects with selected and renamed fields
$customMonitors = $monitors | ForEach-Object {
    [PSCustomObject]@{
        Name        = $_.'Monitor Name'
        Serial      = $_.'Serial Number'
        Resolution  = $_.'Maximum Resolution'
        Size        = if (![string]::IsNullOrWhiteSpace($_.'Image Size')) { $_.'Image Size' } else { $_.'Maximum Image Size' }
        LastChecked = $_.'Last Update Time'
    }
}

#create HTML table for custom fields
$htmlTable = ConvertTo-ObjectToHtmlTable -Objects $customMonitors
$htmlTable | Ninja-Property-Set-Piped $ninjacustomfield

#cleanup temp folder
Remove-Item -Path $tempFolder -Recurse -Force