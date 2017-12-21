#Requires -Version 3.0

# Parameters
[CmdletBinding()]
Param(
 [Parameter(Mandatory=$true)]
 [string]$srcFolder,
 [Parameter(Mandatory=$true)]
 [string]$serverUrl,
 [Parameter(Mandatory=$true)]
 [string]$siteUrl,
 [Parameter(Mandatory=$true)]
 [string]$docLibName,
 [Parameter(Mandatory=$false)]
 [string]$filter = "*.*"
)

# Getting csom if not already present
if (-not (Test-Path "_csom\lib\net40-full"))
{
    $nusrc = (Invoke-WebRequest –Uri "https://www.nuget.org/packages/Microsoft.SharePointOnline.CSOM").Links | where { $_.outerText -eq "Manual download" -or $_."data-track" -eq "outbound-manual-download"}
    $nuvrs = $nusrc.href.Substring($nusrc.href.LastIndexOf("/") + 1, $nusrc.href.Length - $nusrc.href.LastIndexOf("/") - 1)
    $fileName = "Microsoft.SharePointOnline.CSOM_" + $nuvrs + ".nupkg"
    (New-Object System.Net.WebClient).DownloadFile($nusrc.href, $fileName)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($fileName, "_csom")
    Remove-Item $fileName
}
Add-Type -Path "_csom\lib\net40-full\Microsoft.SharePoint.Client.dll"
Add-Type -Path "_csom\lib\net40-full\Microsoft.SharePoint.Client.Runtime.dll"

# Members
$dstUrl = "$siteUrl/$docLibName"
$regGuid = [guid]::NewGuid()
$global:lastWrite = Get-Date
[System.Collections.ArrayList]$global:checkedOut = @()

# Login
Write-Output "Login to SharePoint"
$cred = Get-Credential -Message "Enter Sharepoint Online password:"
$creds = New-Object Microsoft.SharePoint.Client.SharePointOnlineCredentials($cred.UserName, $cred.Password)
$ctx = New-Object Microsoft.SharePoint.Client.ClientContext($serverUrl+$siteUrl)
$ctx.credentials = $creds
$ctx.load($ctx.Web)
$docLib = $ctx.Web.Lists.GetByTitle($docLibName)
$ctx.Load($docLib)
$ctx.Load($docLib.RootFolder)
$ctx.executeQuery()

# Functions
function Handle-Upload($eventArgs)
{
    try
    {
        $path = $eventArgs.SourceEventArgs.FullPath
        $lastWriteTime = [IO.File]::GetLastWriteTime($path)
        if ($lastWriteTime -ne $global:lastWrite)
        {
            $global:lastWrite = $lastWriteTime
            $name = $eventArgs.SourceEventArgs.Name
            $changeType = $eventArgs.SourceEventArgs.ChangeType
            $timeStamp = $eventArgs.TimeGenerated
            $relPath = $path.substring($srcFolder.length, $path.length-$srcFolder.length)
            $relUrl = $relPath.replace("\", "/")
            Write-Host "The file '$relPath' was $changeType at $timeStamp" -fore green
            Write-Host "  Checking existing file"
            $scope = new-object Microsoft.SharePoint.Client.ExceptionHandlingScope -ArgumentList @(,$ctx)
            $scopeStart = $scope.StartScope()
            $scopeTry = $scope.StartTry()
            $spUrl = $dstUrl + $relUrl
            if (-not $global:checkedOut.Contains($spUrl)) { $tmp = $global:checkedOut.Add($spUrl) }
            $file = $ctx.Web.GetFileByServerRelativeUrl($spUrl)
            $ctx.Load($file)
            $ctx.Load($file.ListItemAllFields)
            $scopeTry.Dispose()
            $scopeCatch = $scope.StartCatch()
            $scopeCatch.Dispose()
            $scopeStart.Dispose()
            $ctx.ExecuteQuery()
            if ($file.Exists)
            {
                if ($file.CheckOutType -eq "None")
                {
                    Write-Host "  Checkout file"
                    $file.CheckOut()
                    $ctx.ExecuteQuery()
                }
            }
            Write-Host "  Uploading the file"
            $fileStream = New-Object IO.FileStream($path, "Open", "Read", "Read")
            $fileCreationInfo = New-Object Microsoft.SharePoint.Client.FileCreationInformation
            $fileCreationInfo.Overwrite = $true
            $fileCreationInfo.ContentStream = $fileStream
            $fileCreationInfo.URL = $spUrl
            $file = $docLib.RootFolder.Files.Add($fileCreationInfo)
            $ctx.Load($file)
            $ctx.Load($file.ListItemAllFields)
            $ctx.ExecuteQuery()
            $fileStream.Close()
            Write-Host "  Done"
        }
    }
    catch
    {
        if ($fileStream) { $fileStream.Close() }
        Write-Host "Exception:" $_.Exception.Message $_.Exception.StackTrace 
    }
}

function Handle-Delete($eventArgs)
{
    try
    {
        $path = $eventArgs.SourceEventArgs.FullPath
        $changeType = $eventArgs.SourceEventArgs.ChangeType
        $timeStamp = $eventArgs.TimeGenerated
        $relPath = $path.substring($srcFolder.length, $path.length-$srcFolder.length)
        $relUrl = $relPath.replace("\", "/")
        Write-Host "The file '$relPath' was $changeType at $timeStamp" -fore red
        Write-Host "  Deleting file"
        $spUrl = $dstUrl + $relUrl
        $file = $ctx.Web.GetFileByServerRelativeUrl($spUrl)
        $file.DeleteObject()
        $ctx.ExecuteQuery()
        if ($global:checkedOut.Contains($spUrl)) { $tmp = $global:checkedOut.Remove($spUrl) }
        Write-Host "  Done"
    }
    catch
    {
        Write-Host "Exception:" $_.Exception.Message $_.Exception.StackTrace 
    }
}

function Unregister
{
    Write-Host "Unregistering watchers" -fore Cyan
    Unregister-Event "FileCreated-$($regGuid)"
    Unregister-Event "FileDeleted-$($regGuid)"
    Unregister-Event "FileChanged-$($regGuid)"
    Write-Host "  Done"
}

function Checkin
{
    Write-Host "File checkin" -fore Cyan
    foreach($spUrl in $global:checkedOut)
    {
        $file = $ctx.Web.GetFileByServerRelativeUrl($spUrl)
        $file.CheckIn("Checked in by FileSystemWatcher",[Microsoft.SharePoint.Client.CheckinType]::MinorCheckIn)
        $ctx.ExecuteQuery()
    }
    Write-Host "  Done"
}

function CheckinAndPublish
{
    Write-Host "File checkin and publish" -fore Cyan
    foreach($spUrl in $global:checkedOut)
    {
        $file = $ctx.Web.GetFileByServerRelativeUrl($spUrl)
        $file.CheckIn("Checked in by FileSystemWatcher",[Microsoft.SharePoint.Client.CheckinType]::MajorCheckIn)
        $ctx.ExecuteQuery()
    }
    Write-Host "  Done"
}

# Register wacher
Write-Output "Registering FileSystemWatcher with filter $($filter) on:"
Write-Output "  $srcFolder" 
$fsw = New-Object IO.FileSystemWatcher $srcFolder, $filter -Property @{IncludeSubdirectories = $true; NotifyFilter = [IO.NotifyFilters]'FileName, LastWrite'}

Write-Output "Registering FileCreated-$($regGuid)"
$tmp = Register-ObjectEvent $fsw Created -SourceIdentifier "FileCreated-$($regGuid)" -Action {
    Handle-Upload $Event
}

Write-Output "Registering FileDeleted-$($regGuid)"
$tmp = Register-ObjectEvent $fsw Deleted -SourceIdentifier "FileDeleted-$($regGuid)" -Action {
    Handle-Delete $Event
}

Write-Output "Registering FileChanged-$($regGuid)"
$tmp = Register-ObjectEvent $fsw Changed -SourceIdentifier "FileChanged-$($regGuid)" -Action {
    Handle-Upload $Event
}

# Follow up
Write-Host "---------------------------------------------------" -fore Cyan
Write-Host "Type Unregister to stop watching folders" -fore Cyan
Write-Host "Type Checkin to checkin all your changes" -fore Cyan
Write-Host "Type CheckinAndPublish to publish all your changes" -fore Cyan
Write-Host "---------------------------------------------------" -fore Cyan
