# SharePoint FileSync 4 Developers
With this PowerShell script you are able to sync every change on a local file to a document library in SharePoint Online.

## Installation
Installation is not more than downloading the PowerShell script [SharePointLiveSync.ps1](https://raw.githubusercontent.com/TVDKoni/SharePointFileSync4Developers/master/SharePointLiveSync.ps1)

## Prerequisites
* A SharePoint Online site where you have write access to a document library
* At least PowerShell version 3 is required
* Microsoft.SharePointOnline.CSOM which is downloaded automatically from the script

## Usage
Start a PowerShell session and change to the directory where you downloaded the script SharePointLiveSync.ps1. Enter the following command:

```PowerShell
. .\SharePointLiveSync.ps1 -srcFolder "C:\Data\Example" -serverUrl "https://yourtenant.sharepoint.com" -siteUrl "/sites/yoursite" -docLibName "Style Library"
```

It is very important that you source the script with a leading point and a space to get defined functions into the actual session!
By hitting return, the script is registering FileSystemWatchers onto the directory specified by the parameter srcFolder. Every change within that folder or any subfolder will be immediatly reflected into the SharePoint Online document library specified by the parameter docLibName.


