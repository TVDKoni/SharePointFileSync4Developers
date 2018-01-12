# SharePoint FileSync 4 Developers
With this PowerShell script you are able to sync every change on a local file to a document library in SharePoint Online.

## Installation
Installation is not more than downloading the PowerShell script [SharePointLiveSync.ps1](https://raw.githubusercontent.com/TVDKoni/SharePointFileSync4Developers/master/SharePointLiveSync.ps1)

## Prerequisites
* A SharePoint Online site where you have write access to a document library
* At least PowerShell version 3 is required
* Microsoft.SharePointOnline.CSOM which is downloaded automatically from the script
* A reference to System.IO.Compression.FileSystem to unpack the NuGet package

## Usage
Start a PowerShell session and change to the directory where you downloaded the script SharePointLiveSync.ps1.

To sync to a document library, enter the following command:
```PowerShell
. .\SharePointLiveSync.ps1 -srcFolder "C:\Data\Example" -serverUrl "https://yourtenant.sharepoint.com" -siteUrl "/sites/yoursite" -docLibName "Style Library"
```

To sync to the masterpage library, enter the following command:
```PowerShell
. .\SharePointLiveSync.ps1 -srcFolder "C:\Data\Example" -serverUrl "https://yourtenant.sharepoint.com" -siteUrl "/sites/yoursite" -catalogName "masterpage"
```

It is very important that you source the script with a leading point and a space to get defined functions into the actual session!
By hitting return, the script is registering FileSystemWatchers onto the directory specified by the parameter srcFolder. Every change within that folder or any subfolder will be immediately reflected into the SharePoint Online document library specified by the parameter docLibName.

## Known issues
* There are not yet all file system operations supported like renaming folders. We are working on it
* Some file system operations initiate multiple file uploads. We don't have yet a solution. If you have an idea how to solve, please inform us
* After creating a new file, the watcher stopps working. You have to unregister and register new in such situation

