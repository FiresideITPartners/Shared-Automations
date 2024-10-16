<#
.SYNOPSIS
Creates or updates local admin user on Windows machines. 

.DESCRIPTION
Creates or updates local admin user on Windows machines. 
Script initially taken from https://github.com/rehatiel/powershell/blob/main/ninja-scripts/rotate-local-admin.ps1 and modified for our use.

.NOTES
NinjaRMM needs to be configured with two custom fields for this script to work.  It is suggested to create these as "Role Custom Fields".
localAdminPassword: Fieldname = localAdminPassword, Label = Local Admin Password, Type = Secure, Technician = Read Only, Automations = Write Only, API = None
localAdminUsername: Fieldname = localAdminUsername, Label = Local Admin Username, Type = Text, Technician = Read Only, Automations = Write Only, API = None
Add these custom fields to the desired role(s).

.PARAMETER NewAdminUsername
Specifies the username to be used for the new admin user.  String

.PARAMETER ChangeAdminUsername
Boolean to specify if we are using built in Administrator account or disabling Administrator and using a new user. 
Set to 0 or false to use built in Administrator and set a new password.
Set to 1 or true to create or update admin user named in NewAdminUsername.
#>
param(
    [Parameter()]
    [string]$NewAdminUsername = 'locadmin',
    [Parameter()]
    [bool]$ChangeAdminUsername = $true
)
#Import needed libraries
add-type -AssemblyName System.Web
#This is the process we'll be perfoming to set the admin account.
$LocalAdminPassword = [System.Web.Security.Membership]::GeneratePassword(24,5)
If($ChangeAdminUsername -eq $false) {
Set-LocalUser -name "Administrator" -Password ($LocalAdminPassword | ConvertTo-SecureString -AsPlainText -Force) -PasswordNeverExpires:$true
} else {
$ExistingNewAdmin = get-localuser | Where-Object {$_.Name -eq $NewAdminUsername}
if(!$ExistingNewAdmin){
write-host "Creating new user" -ForegroundColor Yellow
New-LocalUser -Name $NewAdminUsername -Password ($LocalAdminPassword | ConvertTo-SecureString -AsPlainText -Force) -PasswordNeverExpires:$true
Add-LocalGroupMember -Group Administrators -Member $NewAdminUsername
#Disable-LocalUser -Name "Administrator"
}
else{
    write-host "Updating admin password" -ForegroundColor Yellow
   set-localuser -name $NewAdminUsername -Password ($LocalAdminPassword | ConvertTo-SecureString -AsPlainText -Force)
}
}
if($ChangeAdminUsername -eq $false ) { $username = "Administrator" } else { $Username = $NewAdminUsername }
 
#Now to update the custom data field in NinjaRMM
Ninja-Property-Set localAdminPassword $LocalAdminPassword
Ninja-Property-Set localAdminUsername $username