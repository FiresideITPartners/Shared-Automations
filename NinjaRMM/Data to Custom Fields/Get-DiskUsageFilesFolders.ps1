<#
.SYNOPSIS
    Uses WizTree (https://www.diskanalyzer.com/) to scan a drive and output the largest folders and files to searate Ninja WYSIWYG custom fields.
.DESCRIPTION
    Uses WizTree to scan a drive and output the largest folders and files to separate Ninja WYSIWYG custom fields.  Output is passed to Ninja WYSIWYG custom fields.  
    Some customization is required to build this script into your Ninja environment.
.NOTES
    Build to be run via NinjaRMM as SYSTEM.
    Requires 2 Custom Fields of WYSIWYG type assigned to the role of the target devices. 
    Modify the $NinjaFoldersCustomField and $NinjaFilesCustomField variables to match the names of the custom fields in your Ninja environment.
    The script will download WizTree from the specified URL if it is not found in the specified folder.  
    You will need to host the WizTree executable on your own server and update the $WizTreeURL variable.
#>

#region Script Variables
$scriptGUID = New-GUID # This is a unique identifier for the script run to prevent conflicts with other scripts
$scanpath = "C:\" # The path to scan for disk usage. Replace with a Ninja Variable if needed.
$folder = $ENV:TEMP # The folder to store the CSV and WizTree executable. Replace with a Ninja Variable or ENV:TEMP if needed.
$csvname = "$scriptGUID.csv" # The name of the CSV file to store the WizTree output. Set to use the scriptGUID for uniqueness.
$maxFolderDepth = 5 # The maximum depth of folders to scan. Default is 5. Replace with a Ninja Variable if needed.
$folderdispcount = 25 # The number of folders to display in the Ninja Custom Field. Replace with a Ninja Variable if needed.
$filesdispcount = 50 # The number of files to display in the Ninja Custom Field. Replace with a Ninja Variable if needed.
$NinjaFoldersCustomField = "DiskUsageFolders" # The name of the Ninja Custom Field to store the folder data.
$NinjaFilesCustomField = "DiskUsageFiles" # The name of the Ninja Custom Field to store the file data.
$WizTreeURL = "" # The URL to download WizTree from. Suggest hosting the file on your own server.
#Do not modify below this line
$WizTreePath = Join-Path -Path $folder -ChildPath "Wiztree64.exe"
$csvpath = Join-Path -Path $folder -ChildPath $csvname
$licenseString = "Generated by WizTree" # The string to check for in the first line of the CSV to verify it is the header.
#endregion
function DownloadWizTree {
    $url = $WizTreeURL
    $output = $WizTreePath
    Invoke-WebRequest -Uri $url -OutFile $output 
}

Function Export-FilesizeCSV {
    param (
        [Parameter()]
        [string]$Path = $scanpath,
        [Parameter()]
        [string]$OutputPath = $csvpath,
        [Parameter()]
        [int]$maxDepth = $maxFolderDepth
    )
    $csvtemp = $OutputPath + ".temp"
    $WiztreeArgs = @(
        "`"$Path`"" 
        "/export=`"$OutputPath`"" 
        "/admin=1" 
        "/exportfolders=1"
        "/sortby=1" 
        "/exportmftrecno=1" 
        "/exportalldates=1" 
        "/exportsplitfilename=1" 
        "/exportmaxdepth=$maxDepth"
        "/filterExclude=`"*.sys`""
    )
    write-host $WiztreeArgs
    Start-Process -FilePath $WizTreePath -ArgumentList $WiztreeArgs -Wait
    #Remove the Licensing Disclaimer from the CSV
    $licenseString = "Generated by WizTree"
    $firstline = Get-Content -Path $OutputPath -TotalCount 1
    if ($firstline -like "$licenseString*") {
        Write-Host "First line is not header, removing first line."
        $skip = 1
        $ins = New-Object System.IO.StreamReader ($OutputPath)
        $outs = New-Object System.IO.StreamWriter ($csvtemp)
        try {
            # Skip the first N lines, but allow for fewer than N, as well
            for( $s = 1; $s -le $skip -and !$ins.EndOfStream; $s++ ) {
                $ins.ReadLine()
            }
            while( !$ins.EndOfStream ) {
                $outs.WriteLine( $ins.ReadLine() )
            }
        }
        finally {
            $outs.Close()
            $ins.Close()
        }
        Move-Item -Path $csvtemp -Destination $OutputPath -Force
    }
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

function cleanup {
    if (Test-Path $csvpath) {
        Remove-Item $csvpath
    }
    if (Test-Path $WizTreePath) {
        Remove-Item $WizTreePath
    }
    if (Test-Path "$csvfolder\WizTree3.ini") {
        Remove-Item "$csvfolder\WizTree3.ini"
    }
}
#region Check for Wiztree and download if missing
Write-Host "Checking for WizTree"
if (-Not (Test-Path "$WizTreePath")) {
    Write-Host "WizTree not found, downloading to $WizTreePath"
    DownloadWizTree
    try {
        $checkDownload = Test-Path $WizTreePath
    }
    catch {
        Write-Host "Failed to download WizTree"
        exit 1
    }
}
#endregion 

#region Run WizTree and export CSV
Export-FilesizeCSV -Path $scanpath -OutputPath $csvpath -maxDepth $maxFolderDepth
#Verify first row is header
    $firstLine = Get-Content -Path $csvpath -TotalCount 1
if ($firstline -like "*$licenseString*") {
    Write-Host "First line is not header after removal, exiting."
    exit 1
} else {
    Write-Host "License string not found in the first line of the CSV."
}
#endregion

#region Convert CSV to Object
$initscan = Import-CSV $csvpath
$initscan | ForEach-Object { 
    $_.Allocated = [int64]::Parse($_.Allocated)
    $_.Size = [int64]::Parse($_.Size)
    $_.CREATEDDATE = [datetime]::Parse($_.CREATEDDATE)
    $_.MODIFIED = [datetime]::Parse($_.MODIFIED)
    $_.LASTACCESSDATE = [datetime]::Parse($_.LASTACCESSDATE)
    $_.Folders = [int]::Parse($_.Folders)
    $_.MFTPARENTRECNO = [int]::Parse($_.MFTPARENTRECNO)
    $_.MFTRECNO = [int]::Parse($_.MFTRECNO)
    # Adding Size in MB and GB
    $_ | Add-Member -MemberType NoteProperty -Name SizeMB -Value ($_.Size / 1MB)
    $_ | Add-Member -MemberType NoteProperty -Name SizeGB -Value ($_.Size / 1GB)
    #$_
}
#endregion

#region Filter objects to Folders and Files
$foldersizes = $initscan | Where-Object { $_.FILEEXT -eq "" -and $_.Allocated -gt 10000000}
$filesizes = $initscan | Where-Object { $_.FILEEXT -ne "" -and $_.Allocated -gt 10000000}
Remove-Variable -Name initscan
#endregion

#region Create Folders object for HTML Table and output to STDOUT and Ninja CF
#region Filter out parent folders to only show the deepest level
# Create a hash table to store MFTPARENTRECNO values
$parentHash = @{}
$foldersizes | ForEach-Object { $parentHash[$_.MFTPARENTRECNO] = $true }
# Filter to only show folders that are not parents
$deepestChildFolders = $foldersizes | Where-Object {
    -not $parentHash.ContainsKey($_.MFTRECNO)
}
Remove-Variable -Name parentHash
Remove-Variable -Name foldersizes
#endregion
#Create object to store folder data for HTML Table
$folderObjects = @()
$largestfolders = $deepestChildFolders | Sort-Object -Property Allocated -Descending | Select-Object -First $folderdispcount -Property "File Name","SizeMB"
$largestfolders | ForEach-Object {
    $folderObject = New-Object PSObject -Property @{
        Folder = $_."File Name"
        SizeMB = [math]::Round($_.SizeMB, 2)
    }
    $folderObjects += $folderObject
}
$folderObjectsOutput = $folderObjects | Sort-Object -Property SizeMB -Descending
$folderObjectsOutput | Format-Table -AutoSize
$folderObjectsHTML = ConvertTo-ObjectToHtmlTable -Objects $folderObjectsOutput
$folderObjectsHTML | Ninja-Property-Set-Piped $NinjaFoldersCustomField
Remove-Variable -Name folderObjects
Remove-Variable -Name largestfolders
Remove-Variable -Name folderObjectsOutput
Remove-Variable -Name folderObjectsHTML
#endregion

#region Create File object for HTML Table and output to STDOUT and Ninja CF
#Create object to store folder data for HTML Table
$fileObjects = @()
$largestfiles = $filesizes | Sort-Object -Property Allocated -Descending | Select-Object -First $filesdispcount -Property "File Name","SizeMB"
$largestfiles | ForEach-Object {
    $fileObject = New-Object PSObject -Property @{
        File = $_."File Name"
        SizeMB = [math]::Round($_.SizeMB, 2)
    }
    $fileObjects += $fileObject
}
$fileObjectsOutput = $fileObjects | Sort-Object -Property SizeMB -Descending
$fileObjectsOutput | Format-Table -AutoSize
$fileObjectsHTML = ConvertTo-ObjectToHtmlTable -Objects $fileObjectsOutput
$fileObjectsHTML | Ninja-Property-Set-Piped $NinjaFilesCustomField
Remove-Variable -Name fileObjects
Remove-Variable -Name largestfiles
Remove-Variable -Name fileObjectsOutput
Remove-Variable -Name fileObjectsHTML
#endregion
cleanup