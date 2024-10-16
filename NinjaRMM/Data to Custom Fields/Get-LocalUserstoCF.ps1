<#
.SYNOPSIS
    Lists Local Computer's Users and formats into HTML output for Ninja
.DESCRIPTION
    Lists Local Computer's Users and formats into HTML output for Ninja.  Output is passed to a Ninja WYSIWYG custom field.
.NOTES
    Build to be run via NinjaRMM as SYSTEM.
    Requires a Custom Field of WYSIWYG type.  Custom Field is named localusers by default, but the variable can be changed in the script.
#>
param (
    # Parameter help description
    [Parameter()]
    [string]$ParameterName = "localusers",
    [Parameter()]
    [Switch]$AllUsers = [System.Convert]::ToBoolean($env:includeDisabledUsers)
)
#Function for converting Object into HTML for Ninja's consumption. (https://discord.com/channels/676451788395642880/676453812428341261/1238233730850623521)
function ConvertTo-ObjectToHtmlTable {
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

# Initialize an empty array to hold the custom objects
$userObjects = @()
$userDetails = Get-LocalUser | Select-Object -Property Name,FullName,LastLogon,PasswordExpires,PasswordLastSet,Enabled
$skipusers = "Guest","DefaultAccount","WDAGUtilityAccount"
foreach ($user in $userDetails) {
if ($user.Name -in $skipusers) {
    #do nothing
} else {    
        $userObject = New-Object PSObject -Property @{
            Username = $user.Name
            FullName = $user.FullName
            Enabled = if ($user.Enabled) { "Yes" } else { "No" }
            LastLogon = $user.LastLogon
            PasswordLastSet = $user.PasswordLastSet
            PasswordExpires = if (!$user.PasswordExpires) {"Never Expire"} else { $user.PasswordExpires}
            RowColour = if ($user.Enabled) {"success"} else { "unknown"}
        }
        # Add the custom object to the array
        $userObjects += $userObject
}
}
$output = $userObjects | Select-Object -Property Username,FullName,Enabled,LastLogon,PasswordExpires,PasswordLastSet,RowColour
$html = ConvertTo-ObjectToHtmlTable $output
$html | Ninja-Property-Set-Piped localusers