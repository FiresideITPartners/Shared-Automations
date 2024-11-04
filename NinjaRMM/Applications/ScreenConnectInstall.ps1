<#
.SYNOPSIS
This script installs ScreenConnect on a Windows device, and uses the NinjaRMM environment variables to pass in the organization and location names.

.DESCRIPTION
This script downloads the ScreenConnect installer from the specified URL, and installs it on the device. The organization and location names are passed in as parameters to the installer.
You can run this manually per device or create a condition to deploy automatically from a policy.

.NOTES 
Ninja Script Configurations:
- Language: PowerShell
- Operating System: Windows
- Architecture: All
- Run As: System

.NOTES
Ninja Policy Configuration:
- Choose Policy and "Add a Condition"
- Click "Select a Condition"
    - Condition: Software
    - Presence: Doesn't Exist
    - Names: "ScreenConnect Client (instanceid)" GRAB THE NAME FROM THE SOFTWARE INVENTORY OF AN EXISTING DEVICE
    - Click "Apply"
- Name: Install ScreenConnect
- Severity: None
- Priority: None
- Auto-Reset: After 3 Mins
- Automations: 
    - Click Add
    - Choose this script
- Click "Apply"
#>

$ScreenConnectURL = "BASEURL" # Replace with your ScreenConnect URL ex. https://yourcompany.screenconnect.com
$url = [uri]::EscapeUriString("$($ScreenConnectURL)/Bin/ConnectWiseControl.ClientSetup.exe?e=Access&y=Guest&c=$env:NINJA_ORGANIZATION_NAME&c=$env:NINJA_LOCATION_NAME&c=&c=&c=&c=&c=&c=")
$output = "$env:TEMP\ConnectWiseControl.ClientSetup.exe"
Add-Type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
#[Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

Invoke-WebRequest -Uri $url -OutFile $output
Start-Process -FilePath $output -ArgumentList "/silent"