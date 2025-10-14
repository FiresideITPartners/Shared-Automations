<#
.SYNOPSIS
Script to monitor and log time drift between local system time and NTP server time.  Saves the details to Ninja RMM Custom Fields.

.DESCRIPTION
This script queries an NTP server to get the current time, compares it with the local system time, and logs the drift in seconds. 
If the drift exceeds a defined threshold, it triggers a warning. The script also stores the local time, NTP time, and drift in Ninja RMM custom fields.

Confifgure monitoring in Ninja RMM with a script monitor using this script.  Exit code 0 = OK, 1 = Error, 2 = Warning (drift exceeds threshold).

.NOTES
Uses custom fields.  Create Custom Fields in Ninja RMM for "timeOnDevice", "ntpServerTime", and "timeDrift".
Author: Fireside IT Partners
Requires PowerShell 5.0+
External NTP server: pool.ntp.org (can be changed in the script)
#>

# Define NTP server and drift threshold (in seconds)
$ntpServer = "pool.ntp.org"
$maxDrift = 5

# Define Custom Fields in Ninja RMM:
$deviceTimeField = "timeOnDevice"
$ntpTimeField = "ntpServerTime"
$driftField = "timeDrift"

# Function to get NTP time
function Get-NtpTime {
    try {
        $ntpData = New-Object byte[] 48
        $ntpData[0] = 0x1B

        $address = [System.Net.Dns]::GetHostAddresses($ntpServer)[0]
        $endpoint = New-Object System.Net.IPEndPoint $address, 123
        $socket = New-Object System.Net.Sockets.UdpClient
        $socket.Connect($endpoint)
        $null = $socket.Send($ntpData, $ntpData.Length)
        $receivedData = $socket.Receive([ref]$endpoint)
        $socket.Close()

        # NTP timestamp is big-endian; reverse the bytes before converting
        $intPart = [BitConverter]::ToUInt32($receivedData[43..40], 0)
        $fracPart = [BitConverter]::ToUInt32($receivedData[47..44], 0)
        $baseTime = [datetime]::SpecifyKind((Get-Date "1900-01-01T00:00:00"), [System.DateTimeKind]::Utc)
        $ntpTime = $baseTime.AddSeconds($intPart + ($fracPart / [Math]::Pow(2, 32)))
        return $ntpTime.ToLocalTime()
    } catch {
        Write-Error "Error retrieving NTP time: $_"
        exit 1
    }
}

# Get local and NTP time
try {
    $localTime = Get-Date
    $ntpTime = Get-NtpTime
} catch {
    Write-Error "Error getting local or NTP time: $_"
    exit 1
}

if (-not ($ntpTime -is [datetime])) {
    Write-Error "Failed to retrieve NTP time."
    exit 1
}

# Calculate drift and log results. Check if drift exceeds threshold.
try {
    $drift = ($localTime - $ntpTime).TotalSeconds
    $driftExceeded = $false
    Write-Output "Local Time: $localTime"
    Write-Output "NTP Time:   $ntpTime"
    Write-Output "Time Drift: $drift seconds"
    if ($drift -gt $maxDrift) {
        Write-Warning "Time drift is ahead of NTP time by more than $maxDrift seconds!"
        $driftExceeded = $true
    } elseif ($drift -lt -$maxDrift) {
        Write-Warning "Time drift is behind NTP time by more than $maxDrift seconds!"
        $driftExceeded = $true
    }
} catch {
    Write-Error "Error calculating drift: $_"
    exit 1
}

# Store Local Time and NTP Time in ISO 8601 format (no milliseconds, no timezone)
try {
    $localTimeIso = $localTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss")
} catch {
    Write-Error "Error converting local time to ISO format: $_"
    exit 1
}

try {
    $ntpTimeIso = $ntpTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss")
} catch {
    Write-Error "Error converting NTP time to ISO format: $_"
    exit 1
}

try {
    # Limit drift to 6 decimal places
    $driftFormatted = [math]::Round($drift, 6)
} catch {
    Write-Error "Error formatting drift value: $_"
    exit 1
}

try {
    Ninja-Property-Set $deviceTimeField $localTimeIso
} catch {
    Write-Error "Error setting Ninja property for device time: $_"
    exit 1
}

try {
    Ninja-Property-Set $ntpTimeField $ntpTimeIso
} catch {
    Write-Error "Error setting Ninja property for NTP time: $_"
    exit 1
}

try {
    Ninja-Property-Set $driftField $driftFormatted
} catch {
    Write-Error "Error setting Ninja property for drift: $_"
    exit 1
}

# Exit 2 if drift exceeds threshold, else 0
if ($driftExceeded -eq $true) {
    exit 2
} else {
    exit 0
}