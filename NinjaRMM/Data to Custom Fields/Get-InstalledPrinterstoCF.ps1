<#
.SYNOPSIS
Sets a custom property in NinjaRMM with the list of installed printers on a machine.

.PREREQUISITES
- NinjaRMM API Key
- RunAsUser module (Script will install if not found)
- NinjaRMM WYSIG CustomField named installedPrinters that can be written to by Automations

.DESCRIPTION
This script retrieves the list of installed printers on a machine and sets this list as a custom property in NinjaRMM using the 'Ninja-Property-Set-Piped' cmdlet. The custom property is named 'installedPrinters'.
This script uses the RunAsUser module developed by Kelvin Tegelaar https://github.com/KelvinTegelaar/RunAsUser
Must be run in SYSTEM context.
A temp file is created in c:\temp\printerinfo.xml to store the printer information. This file is deleted at the end of the script.  The folder c:\temp will remain.

.NOTES
Author: Timothy McBride
Date: July 10,2024
Version: 1.0
#>


Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope Process
import-module NJCliPSh -DisableNameChecking

#Check for and/or Install RunAsUser dependency
if (!(Get-InstalledModule | Where-Object { $_.Name -eq "RunAsUser" })) {
    Write-Host "Not Installed. Installing"
    If ((Get-PackageProvider).Name -notcontains "NuGet") {
        Write-Host "Installing required Nuget package first..."
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
    }
    Install-Module RunAsUser -Force
}

#User Context Script
$ScriptBlock = {
    $Printers = Get-Printer | Select-Object Name, @{Name='Type'; Expression={$_.Type.ToString()}}, Portname, DriverName, @{Name='PrinterStatus'; Expression={$_.PrinterStatus.ToString()}} | Where-Object { $_.Name -notmatch "Microsoft|Fax|OneNote|Adobe|Agency|PDF|Dentrix|WebEx|Evernote" }
    $AllPrinters = [System.Collections.Generic.List[Object]]::New()
    foreach ($Printer in $Printers) {
        if ($Printer.Portname -match 'WSD' ) {
            $LocInfo = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Enum\SWD\DAFWSDProvider\*" -ErrorAction SilentlyContinue |
            Where-Object {$_.FriendlyName.replace('(', '').replace(')', '') -match $Printer.Name}).LocationInformation | Select-Object -First 1
            $IP = ($LocInfo | Select-String -Pattern "\d{1,3}(\.\d{1,3}){3}" -AllMatches).Matches.Value
            $Printer | Add-Member -Name "IP" -Type NoteProperty -Value "$IP"
        }
        $AllPrinters.Add($Printer)
    }
    $path = "C:\temp"
    if (!(Test-Path -PathType Container $path)) {
        New-Item -ItemType Directory -Path $path
    } 
    $outfile = Join-Path $path "printerinfo.xml"
    $AllPrinters | Export-Clixml -Path $outfile
}
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
########
#System context actions
########
$ScriptBlockOutputFile = "C:\temp\printerinfo.xml"
#Run script in User context
Invoke-ASCurrentUser -ScriptBlock $ScriptBlock
$ScriptBlockOutput = Import-Clixml -Path $ScriptBlockOutputFile

$SystemPrinters = Get-Printer | Select-Object Name, @{Name='Type'; Expression={$_.Type.ToString()}}, Portname, DriverName, @{Name='PrinterStatus'; Expression={$_.PrinterStatus.ToString()}} | Where-Object { $_.Name -notmatch "Microsoft|Fax|OneNote|Adobe|Agency|PDF|Dentrix|WebEx|Evernote" }
# Get current logged on user
$currentUser = Get-WmiObject -Class Win32_ComputerSystem | Select-Object -ExpandProperty UserName
# Merge objects from $ScriptBlockOutput and $SystemPrinters
$MergedPrinters = $ScriptBlockOutput | ForEach-Object {
    $printer = $_
    $systemPrinter = $SystemPrinters | Where-Object { $_.Name -eq $printer.Name }
    if ($systemPrinter) {
        $printer | Add-Member -Name "Source" -Type NoteProperty -Value "System"
    } else {
        $printer | Add-Member -Name "Source" -Type NoteProperty -Value "$currentUser"
    }
    $printer
}

# Add remaining System printers
$RemainingSystemPrinters = $SystemPrinters | Where-Object { $MergedPrinters.Name -notcontains $_.Name }
$RemainingSystemPrinters | ForEach-Object {
    $_ | Add-Member -Name "Source" -Type NoteProperty -Value "System"
    $MergedPrinters += $_
}

$MergedPrinters

#Get Info saved in file and update custom field
$PrinterCF = ConvertTo-ObjectToHtmlTable -Objects $MergedPrinters
$PrinterCF | Ninja-Property-Set-Piped installedPrinters
Write-Host $MergedPrinters
Write-Host $PrinterCF
#Cleanup Temp File
$fileToDelete = $ScriptBlockOutputFile

# Check if the file exists
if (Test-Path $fileToDelete) {
    # Delete the file
    Remove-Item -Path $fileToDelete -Force
    Write-Host "File '$fileToDelete' deleted successfully."
} else {
    Write-Host "File '$fileToDelete' does not exist."
}
