#This Script Requires Ninja Script Variables:
$captureTime =  #int variable
$HostIP = #string variable
$path = #string variable
<#
Adapted from:
QuickPcap.ps1
https://github.com/dwmetz
Author: @dwmetz
Function: This script will use the native functions on a Windows host to collect a packet capture as an .etl file.
Note the secondary phase where etl2pcapng is required to convert to pcap.
#>

$etl2pcapng = Join-Path $path "etl2pcapng.exe"
$etl = Join-Path $path "capture.etl"
$pcap = Join-Path $path "capture.pcap"
$cabfile = Join-Path $path "capture.cab"
#Check for the presence of the etl2pcapng tool. If not present, download it.
if (-not (Test-Path $etl2pcapng)) {
    Write-Host "Downloading etl2pcapng to $etl2pcapng"
    Invoke-WebRequest -Uri "https://github.com/microsoft/etl2pcapng/releases/download/v1.11.0/etl2pcapng.exe" -OutFile $etl2pcapng
}
#Check for previous captures and remove them
if (Test-Path $etl) {
    Remove-Item $etl
}
Write-Host "Starting packet capture. Will run for $env:captureTime seconds. Writing ETL file to $etl"
#Run the capture until the specified Sleep duration. Adjust as needed (in seconds.)
netsh trace start capture=yes IPv4.Address=$HostIP tracefile=$etl
Start-Sleep $captureTime
netsh trace stop

try {
    & $etl2pcapng $etl $pcap
    Write-Host "PCAP file created at $pcap"
}
catch {
    Write-Host "Failed to convert ETL to PCAP. Error: $_"
    exit 1
}

#Cleanup
Remove-Item $etl
Remove-Item $cabfile
Remove-Item $etl2pcapng
exit 0
