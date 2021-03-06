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
 [Parameter(Mandatory=$true, ParameterSetName="doclib")]
 [string]$docLibName,
 [Parameter(Mandatory=$true, ParameterSetName="catalog")]
 [ValidateSet('masterpage')]
 [string]$catalogName,
 [Parameter(Mandatory=$false)]
 [string]$fileFilter = "*",
 [Parameter(Mandatory=$false)]
 [string]$dirFilter = "*"
)

# Validate input
if ($serverUrl.StartsWith("http://")) { $serverUrl = $serverUrl.Replace("http://", "https://") }
if (-not $serverUrl.StartsWith("https://")) { $serverUrl = "https://" + $serverUrl }
$serverUrl = $serverUrl.TrimEnd("/")
if (-not ($serverUrl -match "https://[^.]*\.sharepoint\.com"))
{
	Write-Error "This script only works together with SharePoint Online"
	break
}
if (-not $siteUrl.StartsWith("/sites/"))
{
	Write-Error "The parameter siteUrl has to start with /sites/"
	break
}
$docLibName = $docLibName.TrimStart("/").TrimEnd("/")

# Getting csom if not already present
function DownloadAndInstallCSOM()
{
	$fileName = "$PSScriptRoot\Microsoft.SharePointOnline.CSOM_" + $nuvrs + ".nupkg"
	Invoke-WebRequest -Uri $nusrc.href -OutFile $fileName
	if (-not (Test-Path $fileName))
	{
		Write-Error "Was not able to download Microsoft.SharePointOnline.CSOM which is a prerequisite for this script"
		break
	}
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($fileName, "$PSScriptRoot\_csom")
    Remove-Item $fileName
}
$resp = Invoke-WebRequest –Uri "https://www.nuget.org/packages/Microsoft.SharePointOnline.CSOM"
$nusrc = ($resp).Links | where { $_.outerText -eq "Manual download" -or $_."data-track" -eq "outbound-manual-download"}
$nuvrs = $nusrc.href.Substring($nusrc.href.LastIndexOf("/") + 1, $nusrc.href.Length - $nusrc.href.LastIndexOf("/") - 1)
if (-not (Test-Path "$PSScriptRoot\_csom\lib\net40-full"))
{
    DownloadAndInstallCSOM
}
else
{
    # Checking CSOM version, updating if required
    $nuspec = [xml](Get-Content "$PSScriptRoot\_csom\Microsoft.SharePointOnline.CSOM.nuspec")
    if ($nuspec.package.metadata.version -ne $nuvrs)
    {
        Write-Output "There is a newer CSOM package available. Downloading and installing it."
        Remove-Item -Recurse -Force "$PSScriptRoot\_csom"
        DownloadAndInstallCSOM
    }
}
Add-Type -Path "$PSScriptRoot\_csom\lib\net40-full\Microsoft.SharePoint.Client.dll"
Add-Type -Path "$PSScriptRoot\_csom\lib\net40-full\Microsoft.SharePoint.Client.Runtime.dll"

# Members
if ($PSCmdlet.ParameterSetName -eq "doclib")
{
    $dstUrl = "$siteUrl/$docLibName"
}
else
{
    $dstUrl = "$siteUrl/_catalogs/$catalogName"
    if ($catalogName.ToLower() -eq "masterpage")
    {
        $docLibName = "Master Page Gallery"
    }
}
$global:regGuid = [guid]::NewGuid()
[System.Collections.ArrayList]$global:checkedOut = @()

# Prepare local dir
if (-not (Test-Path $srcFolder))
{
    New-Item $srcFolder -ItemType Directory
}

# Login
Write-Output "Login to SharePoint site: $($serverUrl+$siteUrl)"
if (-not $global:credLS4D) { $global:credLS4D = Get-Credential -Message "Enter Sharepoint Online password:" }
$creds = New-Object Microsoft.SharePoint.Client.SharePointOnlineCredentials($global:credLS4D.UserName, $global:credLS4D.Password)
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
		if (Test-Path $path -pathType container) { break }
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
		else
		{
            Write-Host "  Checking folders"
			$fileDir = Split-Path -parent $path
            if ($fileDir.length -gt $srcFolder.length)
            {
				$relDir = $fileDir.substring($srcFolder.length+1, $fileDir.length-$srcFolder.length-1)
				$dirs = $relDir.Split("\")
				$relDir = $dstUrl
				foreach($dir in $dirs)
				{
					#TODO how to cleanup created folders?
					$parentFolder = $ctx.Web.GetFolderByServerRelativeUrl($relDir)
					$ctx.Load($parentFolder)
					$ctx.Load($parentFolder.Folders)
					$ctx.ExecuteQuery()
                    $folderNames = $parentFolder.Folders | Select -ExpandProperty Name
                    if($folderNames -notcontains $folderNames)
                    {
					    $folder = $parentFolder.Folders.Add($dir)
					    $ctx.ExecuteQuery()
                    }
					$relDir = $relDir + "/" + $dir
				}
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
    finally
    {
        if ($fileStream) { $fileStream.Close() }
    }
}

function Handle-FileRename($eventArgs)
{
    $path = $eventArgs.SourceEventArgs.FullPath
    $oldpath = $eventArgs.SourceEventArgs.OldFullPath
    $name = $eventArgs.SourceEventArgs.Name
    $oldname = $eventArgs.SourceEventArgs.OldName
    $changeType = $eventArgs.SourceEventArgs.ChangeType
    $timeStamp = $eventArgs.TimeGenerated
    Write-Host "The file '$oldname' was $changeType to '$name' at $timeStamp" -fore green
    Write-Host "  Moving file"
    $relPath = $oldpath.substring($srcFolder.length, $oldpath.length-$srcFolder.length)
    $relUrlOld = $relPath.replace("\", "/")
    $relPath = $path.substring($srcFolder.length, $path.length-$srcFolder.length)
    $relUrlNew = $relPath.replace("\", "/")
    $scope = new-object Microsoft.SharePoint.Client.ExceptionHandlingScope -ArgumentList @(,$ctx)
    $scopeStart = $scope.StartScope()
    $scopeTry = $scope.StartTry()
    $spUrl = $dstUrl + $relUrlOld
    if ($global:checkedOut.Contains($spUrl)) { $tmp = $global:checkedOut.Remove($spUrl) }
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
		$spUrl = $dstUrl + $relUrlNew
        if (-not $global:checkedOut.Contains($spUrl)) { $tmp = $global:checkedOut.Add($spUrl) }
		$file.MoveTo($spUrl, [Microsoft.SharePoint.Client.MoveOperations]::Overwrite)
		$ctx.ExecuteQuery()
		Write-Host "  Moved"
	}
}

function Handle-FileDelete($eventArgs)
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

function Handle-CreateDirectory($eventArgs)
{
    $path = $eventArgs.SourceEventArgs.FullPath
    $name = $eventArgs.SourceEventArgs.Name
    $changeType = $eventArgs.SourceEventArgs.ChangeType
    $timeStamp = $eventArgs.TimeGenerated
    $relPath = $path.substring($srcFolder.length, $path.length-$srcFolder.length)
    Write-Host "The directory '$relPath' was $changeType at $timeStamp" -fore green
    Write-Host "  Creating directory"
	$fileDir = $path
    if ($fileDir.length -gt $srcFolder.length)
    {
		$relDir = $fileDir.substring($srcFolder.length+1, $fileDir.length-$srcFolder.length-1)
		$dirs = $relDir.Split("\")
		$relDir = $dstUrl
		foreach($dir in $dirs)
		{
			#TODO how to cleanup created folders?
			$parentFolder = $ctx.Web.GetFolderByServerRelativeUrl($relDir)
			$ctx.Load($parentFolder)
			$ctx.Load($parentFolder.Folders)
			$ctx.ExecuteQuery()
            $folderNames = $parentFolder.Folders | Select -ExpandProperty Name
            if($folderNames -notcontains $folderNames)
            {
				$folder = $parentFolder.Folders.Add($dir)
				$ctx.ExecuteQuery()
            }
			$relDir = $relDir + "/" + $dir
		}
    }
    Write-Host "  Done"
}

function Handle-DirectoryDelete($eventArgs)
{
    $path = $eventArgs.SourceEventArgs.FullPath
    $changeType = $eventArgs.SourceEventArgs.ChangeType
    $timeStamp = $eventArgs.TimeGenerated
    $relPath = $path.substring($srcFolder.length, $path.length-$srcFolder.length)
    $relUrl = $relPath.replace("\", "/")
    Write-Host "The directory '$relPath' was $changeType at $timeStamp" -fore red
    Write-Host "  Deleting directory"
    $spUrl = $dstUrl + $relUrl
    $folder = $ctx.Web.GetFolderByServerRelativeUrl($spUrl)
    $folder.DeleteObject()
    $ctx.ExecuteQuery()
    Write-Host "  Done"
}

function Handle-DirectoryRename($eventArgs)
{
    $path = $eventArgs.SourceEventArgs.FullPath
    $oldpath = $eventArgs.SourceEventArgs.OldFullPath
    $name = $eventArgs.SourceEventArgs.Name
    $oldname = $eventArgs.SourceEventArgs.OldName
    $changeType = $eventArgs.SourceEventArgs.ChangeType
    $timeStamp = $eventArgs.TimeGenerated
    Write-Host "The folder '$oldname' was $changeType to '$name' at $timeStamp" -fore green
    Write-Host "  Renaming folder"
    $relPath = $oldpath.substring($srcFolder.length, $oldpath.length-$srcFolder.length)
    $relUrlOld = $relPath.replace("\", "/")
    $scope = new-object Microsoft.SharePoint.Client.ExceptionHandlingScope -ArgumentList @(,$ctx)
    $scopeStart = $scope.StartScope()
    $scopeTry = $scope.StartTry()
    $spUrl = $dstUrl + $relUrlOld
    $folder = $ctx.Web.GetFolderByServerRelativeUrl($spUrl)
    $ctx.Load($folder)
    $ctx.Load($folder.ListItemAllFields)
    $scopeTry.Dispose()
    $scopeCatch = $scope.StartCatch()
    $scopeCatch.Dispose()
    $scopeStart.Dispose()
    $ctx.ExecuteQuery()
    if ($folder.Exists)
	{
		$folderItem = $folder.ListItemAllFields
		$name = Split-Path -Path $path -Leaf
		$folderItem["Title"] = $name
		$folderItem["FileLeafRef"] = $name
		$folderItem.Update()
		$ctx.ExecuteQuery()
	}
}

function Reset-Watcher()
{
    Write-Host "Reset"
    $global:fsw.EnableRaisingEvents = $false
    for( $attempt = 1; $attempt -le 120; $attempt++ )
    {
        try
        {
            $global:fsw.EnableRaisingEvents = $true
            Write-Error "FileSystemWatcher reactivated"
            break
        }
        catch
        {
            sleep 1
        }
    }
    if ($attempt -ge 120)
    {
        throw "Was not able to reactivate FileSystemWatcher, giving up"
    }
}

function Handle-Error($eventArgs)
{
    Write-Error "FileSystemWatcher Error"
    #TODO error message
    Reset-Watcher
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
	[System.Collections.ArrayList]$global:checkedOut = @()
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
	[System.Collections.ArrayList]$global:checkedOut = @()
    Write-Host "  Done"
}

function Unregister
{
    Write-Host "Unregistering watchers" -fore Cyan
    Unregister-Event "FileCreated-$($global:regGuid)" -ErrorAction SilentlyContinue
    Unregister-Event "FileDeleted-$($global:regGuid)" -ErrorAction SilentlyContinue
    Unregister-Event "FileChanged-$($global:regGuid)" -ErrorAction SilentlyContinue
    Unregister-Event "FileRenamed-$($global:regGuid)" -ErrorAction SilentlyContinue
    Unregister-Event "FileError-$($global:regGuid)" -ErrorAction SilentlyContinue
    Unregister-Event "DirectoryDeleted-$($global:regGuid)" -ErrorAction SilentlyContinue
    Unregister-Event "DirectoryCreated-$($global:regGuid)" -ErrorAction SilentlyContinue
    Unregister-Event "DirectoryRenamed-$($global:regGuid)" -ErrorAction SilentlyContinue
    Write-Host "  Done"
}

function Reregister
{
    Unregister
    Register
}

function Register
{
	Write-Output "Registering on '$($srcFolder)' a FileSystemWatcher for"
	Write-Output "  - file changes with filter '$($fileFilter)'" 
	Write-Output "  - directory changes with filter '$($dirFilter)'" 
    try
    {
	    $global:fsw = New-Object IO.FileSystemWatcher $srcFolder, $fileFilter -Property @{IncludeSubdirectories = $true; NotifyFilter = [IO.NotifyFilters]'FileName, LastWrite'}
	    $global:dsw = New-Object IO.FileSystemWatcher $srcFolder, $dirFilter -Property @{IncludeSubdirectories = $true; NotifyFilter = [IO.NotifyFilters]'DirectoryName'}

	    Write-Output "Registering FileCreated-$($global:regGuid)"
	    $tmp = Register-ObjectEvent $global:fsw Created -SourceIdentifier "FileCreated-$($global:regGuid)" -Action {
            try
            {
                Handle-Upload $Event
            }
            catch
            {
                Write-Error "Exception in FileSystemWatcher event: FileCreated"
                Write-Host "ItemName: $($_.Exception.ItemName), Message: $($_.Exception.Message), InnerException: $($_.Exception.InnerException), ErrorRecord: $($_.Exception.ErrorRecord), StackTrace: $($_.Exception.StackTrace)"
            }
	    }

	    Write-Output "Registering DirectoryCreated-$($global:regGuid)"
	    $tmp = Register-ObjectEvent $global:dsw Created -SourceIdentifier "DirectoryCreated-$($global:regGuid)" -Action {
            try
            {
                Handle-CreateDirectory $Event
            }
            catch
            {
                Write-Error "Exception in FileSystemWatcher event: DirectoryCreated"
                Write-Host "ItemName: $($_.Exception.ItemName), Message: $($_.Exception.Message), InnerException: $($_.Exception.InnerException), ErrorRecord: $($_.Exception.ErrorRecord), StackTrace: $($_.Exception.StackTrace)"
            }
	    }

	    Write-Output "Registering FileDeleted-$($global:regGuid)"
	    $tmp = Register-ObjectEvent $global:fsw Deleted -SourceIdentifier "FileDeleted-$($global:regGuid)" -Action {
            try
            {
		        Handle-FileDelete $Event
            }
            catch
            {
                Write-Error "Exception in FileSystemWatcher event: FileDeleted"
                Write-Host "ItemName: $($_.Exception.ItemName), Message: $($_.Exception.Message), InnerException: $($_.Exception.InnerException), ErrorRecord: $($_.Exception.ErrorRecord), StackTrace: $($_.Exception.StackTrace)"
            }
	    }

	    Write-Output "Registering DirectoryDeleted-$($global:regGuid)"
	    $tmp = Register-ObjectEvent $global:dsw Deleted -SourceIdentifier "DirectoryDeleted-$($global:regGuid)" -Action {
            try
            {
		        Handle-DirectoryDelete $Event
            }
            catch
            {
                Write-Error "Exception in FileSystemWatcher event: DirectoryDelete"
                Write-Host "ItemName: $($_.Exception.ItemName), Message: $($_.Exception.Message), InnerException: $($_.Exception.InnerException), ErrorRecord: $($_.Exception.ErrorRecord), StackTrace: $($_.Exception.StackTrace)"
            }
	    }

	    Write-Output "Registering FileRenamed-$($global:regGuid)"
	    $tmp = Register-ObjectEvent $global:fsw Renamed -SourceIdentifier "FileRenamed-$($global:regGuid)" -Action {
            try
            {
		        Handle-FileRename $Event
            }
            catch
            {
                Write-Error "Exception in FileSystemWatcher event: FileRenamed"
                Write-Host "ItemName: $($_.Exception.ItemName), Message: $($_.Exception.Message), InnerException: $($_.Exception.InnerException), ErrorRecord: $($_.Exception.ErrorRecord), StackTrace: $($_.Exception.StackTrace)"
            }
	    }

	    Write-Output "Registering DirectoryRenamed-$($global:regGuid)"
	    $tmp = Register-ObjectEvent $global:dsw Renamed -SourceIdentifier "DirectoryRenamed-$($global:regGuid)" -Action {
            try
            {
		        Handle-DirectoryRename $Event
            }
            catch
            {
                Write-Error "Exception in FileSystemWatcher event: DirectoryRenamed"
                Write-Host "ItemName: $($_.Exception.ItemName), Message: $($_.Exception.Message), InnerException: $($_.Exception.InnerException), ErrorRecord: $($_.Exception.ErrorRecord), StackTrace: $($_.Exception.StackTrace)"
            }
	    }

	    Write-Output "Registering FileChanged-$($global:regGuid)"
	    $tmp = Register-ObjectEvent $global:fsw Changed -SourceIdentifier "FileChanged-$($global:regGuid)" -Action {
            try
            {
		        Handle-Upload $Event
            }
            catch
            {
                Write-Error "Exception in FileSystemWatcher event: FileChanged"
                Write-Host "ItemName: $($_.Exception.ItemName), Message: $($_.Exception.Message), InnerException: $($_.Exception.InnerException), ErrorRecord: $($_.Exception.ErrorRecord), StackTrace: $($_.Exception.StackTrace)"
            }
	    }

	    Write-Output "Registering FileError-$($global:regGuid)"
	    $tmp = Register-ObjectEvent $global:fsw Error -SourceIdentifier "FileError-$($global:regGuid)" -Action {
            try
            {
		        Handle-Error $Event
            }
            catch
            {
                Write-Error "Exception in FileSystemWatcher event: FileError"
                Write-Host "ItemName: $($_.Exception.ItemName), Message: $($_.Exception.Message), InnerException: $($_.Exception.InnerException), ErrorRecord: $($_.Exception.ErrorRecord), StackTrace: $($_.Exception.StackTrace)"
            }
	    }
    }
    catch
    {
        Write-Error "Exception in registering FileSystemWatcher"
        Write-Host "ItemName: $($_.Exception.ItemName), Message: $($_.Exception.Message), InnerException: $($_.Exception.InnerException), ErrorRecord: $($_.Exception.ErrorRecord), StackTrace: $($_.Exception.StackTrace)"
    }
}

# Register watcher
Register

# Show commands
Write-Host "---------------------------------------------------" -fore Cyan
Write-Host "Type Unregister to stop watching folders" -fore Cyan
Write-Host "Type Register to start watching folders again" -fore Cyan
Write-Host "Type Reregister to stop and start watcher at once" -fore Cyan
Write-Host "Type Checkin to checkin all your changes" -fore Cyan
Write-Host "Type CheckinAndPublish to publish all your changes" -fore Cyan
Write-Host "---------------------------------------------------" -fore Cyan
