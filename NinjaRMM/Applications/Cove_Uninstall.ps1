<#
.SYNOPSIS
    Uninstalls Cove with the option to keep configuration for re-install or wipe out config for a clean start.

.DESCRIPTION
    This script uninstalls Cove Backup Manager. It provides an option to keep the configuration file for re-installation, which will maintain the backup chain on reinstall. If the -KeepConfig switch is used, the configuration file will be backed up before uninstallation.

.PARAMETER keepconfig
    A switch parameter. If specified, the configuration file will be backed up before uninstallation.

.EXAMPLE
    .\Cove_Uninstall.ps1
    This command will uninstall Cove without keeping the configuration file.

.EXAMPLE
    .\Cove_Uninstall.ps1 -KeepConfig
    This command will uninstall Cove and keep the configuration file for re-installation.

.NOTES
    For more information, visit:
    https://documentation.n-able.com/covedataprotection/USERGUIDE/documentation/Content/backup-manager/backup-manager-installation/uninstall-win-silent.htm

#>
param (
    [switch]$keepconfig,
    [string]$backupname = "coveconfigbackup.ini",
    [string]$backupfolder = "c:\"
)

#Variables
$regpath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Backup Manager'
$reguninstvalue = 'QuietUninstallString'
$installpath = Get-ItemPropertyValue -Path $regpath -Name InstallLocation
$backuppath = Join-Path $backupfolder $backupname

Function Test-RegistryValue ($regkey, $name) {
    if (Get-ItemProperty -Path $regkey -Name $name -ErrorAction Ignore) {
        Write-Host "Cove is installed.  Continuing."
        $true
    } else {
        Write-Host "Cove is not installed. Exiting"
        $false
    }
}

Function Copy-CoveConfig ($installpath,$backuppath) {
    $configfile = Join-Path $installpath 'config.ini'
    Stop-Service -Name "Backup Service Controller"
    Copy-Item -Path $configfile -Destination $backuppath
    if (Test-Path $backuppath) {
        $true
    }
    else {
        $false
        Write-Host "Backup Failed"
    }
}

Function Uninstall-Cove ($uninstallcommand,$uninstallArguments) {
    #Write-Host "-FilePath $uninstallcommand -ArgumentList $uninstallArguments -Wait    "
    Start-Process -FilePath $uninstallcommand -ArgumentList $uninstallArguments -Wait    
    if (!(Test-Path -Path $installpath) -and !(Get-Service -Name "Backup Service Controller" -ErrorAction SilentlyContinue) ){
        Write-Host "Uninstall completed and Install Folder and Service have been deleted."
        $true
    }
    else {
        Write-Host "Install Artifacts still found. Manually verify uninstallation"
        $false
    }
}


if (!(Test-RegistryValue $regpath))
    {
        Write-Host "Cove not installed on this computer or Registry is broken"
        Write-Host "Exiting Script"
        Exit 1
    }
Else {
    #Get Silent uninstall path
    $uninpath = Get-ItemPropertyValue -Path $regpath -Name $reguninstvalue
    # Get the index of the first quote
    $firstQuoteIndex = $uninpath.IndexOf('"')
    # Get the index of the second quote
    $secondQuoteIndex = $uninpath.IndexOf('"', $firstQuoteIndex + 1)
    # Extract the command and arguments
    $uninstallCommand = $uninpath.Substring($firstQuoteIndex, $secondQuoteIndex - $firstQuoteIndex + 1)
    $uninstallArguments = $uninpath.Substring($secondQuoteIndex + 1).Trim()
}

if ($keepconfig) {
    $isbackedup = Copy-CoveConfig -installpath $installpath -backuppath $backuppath
    if ($isbackedup) {
        Write-Host "Config File backed up to $backuppath."
        Write-Host "On Re-Install copy backed up config to install folder and rename config.ini."
    }
    Else {
        Write-Host "Config file backup failed.  Manually backup config and try re-run without KeepBackup parameter. Exiting"
        Exit 1
    }
}
Write-Host "Running Cove Uninstall"

if (Uninstall-Cove -uninstallcommand $uninstallCommand -uninstallArguments $uninstallArguments) {
    exit 0
}
else {
     exit 2
}

