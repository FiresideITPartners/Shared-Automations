<#
.SYNOPSIS
Checks if a mapped drive is connected.

.DESCRIPTION
This script checks if a mapped drive is connected by testing the path of the drive letter provided. If no drive letter is provided, it checks all mapped drives.
In NinjaRMM create a Policy condition "Script Result" and choose this script.  Any exit code other than 0 should trigger the condition.

.PARAMETER Drives
Specifies the drive letter(s) to check, with the colon "X:".  Multiple Drives can be checked by separating them with commas. If not provided, all mapped drives will be checked.

.EXAMPLE
.\Monitor Mapped Drive.ps1 -Drives "Z"
Checks if the mapped drive with the letter "Z" is connected.

.EXAMPLE
.\Monitor Mapped Drive.ps1 -Drives "X,Y"
Checks if the mapped drives with the letters "X:" and "Y:" are connected.

.EXAMPLE
.\Monitor Mapped Drive.ps1
Checks if all mapped drives are connected.

.OUTPUTS
None. The script writes the result to the console.  Exit Code 0 if all checks are successful, Exit Code 1 if any check fails.

.NOTES
Author: Timothy McBride
#>

param (
    [string[]]$Drives 
)

if($Drives) {
    if ($Drives -contains ',') {
        $Driveletters = $Drives.Split(',')
    } else {
        $Driveletters = $Drives
    }
    ForEach ($driveletter in $Driveletters) {
        Write-Host "Checking drive $driveletter"
        $Test = Test-Path $driveletter
        if ($Test -eq $true) {
            Write-Host "Drive $driveletter is connected"
            $success = $true
        } else {
            Write-Host "Drive $driveletter is not connected"
            $success = $false
        }
    }
} else {
    $MappedDrives = Get-WmiObject -Class Win32_MappedLogicalDisk | Select-Object -ExpandProperty DeviceID
    If ($MappedDrives) { 
        ForEach ($DriveLetter in $MappedDrives) {
        Write-Host "Checking drive $DriveLetter"
        $Test = Test-Path $DriveLetter
        if ($Test -eq $true) {
            Write-Host "Drive $DriveLetter is connected"
            $success = $true
        } else {
            Write-Host "Drive $DriveLetter is not connected"
            $success = $false
        }
    }
} Else {
    Write-Host "No mapped drives found"
    $success = $false
}

}
if ($success -eq $true) {
    exit 0
} else {
    exit 1
}