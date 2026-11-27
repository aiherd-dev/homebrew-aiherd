#Requires -Version 5.1
<#
.SYNOPSIS
Install AIHerd for this Windows account or as a system service.
.PARAMETER UserMode
Install without elevation under LocalAppData/Programs/AIHerd, using only a user
Start-menu shortcut and user PATH. Opening AIHerd starts or reuses the
signed-in account's gateway.
.EXAMPLE
.\install-windows.ps1 -UserMode
.EXAMPLE
.\install-windows.ps1 -UserMode -ArchivePath C:\Downloads\aiherd.zip -ChecksumPath C:\Downloads\aiherd.zip.sha256
.NOTES
An offline AIHerd archive requires the Evergreen WebView2 Runtime to be installed
already, or internet access to download its verified Microsoft bootstrapper.
Run without UserMode from an elevated shell for the existing system-service install.
#>
[CmdletBinding(DefaultParameterSetName='Download')]
param(
    [string]$Version,
    # Install for the current Windows account without creating a system service.
    [switch]$UserMode,
    [string]$InstallDir = "$env:ProgramFiles\AIHerd",
    [string]$Root = "$env:ProgramData\AIHerd",
    [ValidatePattern('^[A-Za-z0-9-]+$')][string]$ServiceName = 'AIHerd',
    [string]$Relay = 'wss://oci01.aiherd.dev',
    # Defaults to the installing account, or preserves an existing desktop owner.
    [string]$DesktopUserSid,
    # Authorize this account's ordinary desktop terminals for the Windows herd.
    [ValidateSet('','View','Control','Off')][string]$DesktopCapture,
    # An offline archive still needs an installed WebView2 Runtime, or internet access to install it.
    [Parameter(Mandatory=$true,ParameterSetName='Offline')][string]$ArchivePath,
    [Parameter(Mandatory=$true,ParameterSetName='Offline')][string]$ChecksumPath,
    # For isolated acceptance rigs only; persisted in the service command line.
    [switch]$Scratch
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# These helpers are inline because the website distributes only install.ps1.
function Save-AIHDownload {
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [Parameter(Mandatory=$true)][string]$OutFile
    )
    # Windows PowerShell 5.1 progress rendering can dominate large downloads.
    # Keep this preference local to the request, including when it throws.
    $ProgressPreference='SilentlyContinue'
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $OutFile -TimeoutSec 900
}
function Get-AIHDesktopHostManifest {
    param([Parameter(Mandatory=$true)][string]$UiDirectory)
    $manifest=Join-Path $UiDirectory 'desktop-host.json'
    if(-not (Test-Path -LiteralPath $manifest)){return $null} # Legacy native UI.
    try {
        if((Get-Item -LiteralPath $manifest).Length -gt 4096){throw 'Manifest exceeds 4096 bytes'}
        $document=Get-Content -Raw -LiteralPath $manifest | ConvertFrom-Json
        if($null -eq $document -or $document -is [Array] -or $document -is [string]){throw 'Expected an object'}
        $keys=@($document.PSObject.Properties.Name)
        if($keys.Count -lt 2 -or $keys.Count -gt 3 -or $keys -notcontains 'schema_version' -or $keys -notcontains 'webview2' -or @($keys|Where-Object {$_ -notin @('schema_version','webview2','user_gateway')}).Count){throw 'Unexpected manifest properties'}
        if(($document.schema_version -isnot [int] -and $document.schema_version -isnot [long]) -or $document.schema_version -ne 1){throw 'Unsupported schema_version'}
        if($document.webview2 -isnot [bool]){throw 'webview2 must be boolean'}
        $userGateway=$false
        if($keys -contains 'user_gateway'){
            if($document.user_gateway -isnot [bool]){throw 'user_gateway must be boolean'}
            $userGateway=$document.user_gateway
        }
        return [pscustomobject]@{schema_version=1;webview2=$document.webview2;user_gateway=$userGateway}
    } catch {throw "Invalid desktop-host.json. Installed gateways were left untouched. $($_.Exception.Message)"}
}
function Get-AIHDesktopWebView2Requirement {
    param([Parameter(Mandatory=$true)][string]$UiDirectory)
    $manifest=Get-AIHDesktopHostManifest -UiDirectory $UiDirectory
    return ($null -ne $manifest -and $manifest.webview2)
}
function Test-AIHWebView2Runtime {
    # Microsoft's documented Evergreen detection; a browser/preview channel is
    # not a substitute. Explicit registry views also work in 32-bit PowerShell.
    $subkey='Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    foreach($location in @(@('LocalMachine','Registry32'),@('CurrentUser','Registry64'),@('CurrentUser','Registry32'))){
        $base=$null;$key=$null
        try {
            $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey($location[0],$location[1])
            $key=$base.OpenSubKey($subkey)
            if($key){
                $text=$key.GetValue('pv',$null)
                $parsed=$null
                if($text -is [string] -and [Version]::TryParse($text,[ref]$parsed) -and $parsed -gt [Version]'0.0.0.0'){return $true}
            }
        } finally {if($key){$key.Dispose()};if($base){$base.Dispose()}}
    }
    return $false
}
function Install-AIHWebView2Runtime {
    param([Parameter(Mandatory=$true)][string]$WorkDirectory)
    if(Test-AIHWebView2Runtime){return}
    $download='https://go.microsoft.com/fwlink/p/?LinkId=2124703'
    $manual='https://developer.microsoft.com/microsoft-edge/webview2/#download-section'
    $bootstrapper=Join-Path $WorkDirectory 'MicrosoftEdgeWebview2Setup.exe'
    $lock=$null
    try {
        Write-Host 'Installing the Microsoft Edge WebView2 Evergreen Runtime required by the Windows dashboard...'
        Save-AIHDownload -Uri $download -OutFile $bootstrapper
        # Keep the verified executable non-writable until execution completes.
        $lock=[IO.File]::Open($bootstrapper,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $signature=Get-AuthenticodeSignature -LiteralPath $bootstrapper
        if($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or $null -eq $signature.SignerCertificate){throw 'The bootstrapper has no valid trusted Authenticode signature'}
        $certificate=$signature.SignerCertificate
        if($certificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false) -cne 'Microsoft Corporation' -or $certificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)'){throw 'The bootstrapper is not signed by Microsoft Corporation'}
        # SignatureStatus.Valid requires the Windows Authenticode trust policy,
        # including its certificate chain; an unsigned/custom signer is refused.
        $process=Start-Process -FilePath $bootstrapper -ArgumentList @('/silent','/install') -Wait -PassThru
        if($process.ExitCode -notin @(0,3010)){throw "Microsoft's runtime installer returned exit code $($process.ExitCode)"}
        if(-not (Test-AIHWebView2Runtime)){throw 'The runtime registry probe still reports no Evergreen Runtime after installation'}
        if($process.ExitCode -eq 3010){Write-Warning 'Microsoft WebView2 requested a Windows restart.'}
    } catch {
        throw "WebView2 Runtime installation failed before any service upgrade. Install the Microsoft Evergreen Runtime from $manual and retry. An offline AIHerd archive still requires a preinstalled runtime or internet access for this dependency. $($_.Exception.Message)"
    } finally {if($lock){$lock.Dispose()};Remove-Item -LiteralPath $bootstrapper -Force -ErrorAction SilentlyContinue}
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if(-not $UserMode -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this installer in PowerShell as Administrator.'
}
$arch = $env:PROCESSOR_ARCHITECTURE
if($env:PROCESSOR_ARCHITEW6432){$arch=$env:PROCESSOR_ARCHITEW6432}
if($arch -ne 'AMD64'){throw 'This package requires x64 Windows.'}
if([Environment]::OSVersion.Version.Build -lt 17763){throw 'Windows 10 1809 / Server 2019 or newer is required.'}
if($UserMode){
    if($identity.User.Value -notmatch '^S-1-(?:5-21|12-1)-'){throw '-UserMode requires a signed-in Windows user account.'}
    foreach($argument in @('Root','ServiceName','Relay','DesktopUserSid','DesktopCapture')){
        if($PSBoundParameters.ContainsKey($argument)){throw "-$argument belongs to the system-service installer. Omit it with -UserMode."}
    }
    if(-not $PSBoundParameters.ContainsKey('InstallDir')){$InstallDir=Join-Path $env:LOCALAPPDATA 'Programs\AIHerd'}
    $userBase=[IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\')+'\'
    if(-not [IO.Path]::GetFullPath($InstallDir).StartsWith($userBase,[StringComparison]::OrdinalIgnoreCase)){throw '-UserMode InstallDir must be inside the current account LocalAppData directory.'}
}
$checkedPaths=if($UserMode){@($InstallDir)}else{@($InstallDir,$Root)}
foreach($path in $checkedPaths) {
    if($path -notmatch '^[A-Za-z]:[\\/].+'){throw 'InstallDir and Root must be absolute local paths.'}
    $at=[IO.Path]::GetFullPath($path)
    if($at.TrimEnd('\') -eq [IO.Path]::GetPathRoot($at).TrimEnd('\')){throw 'Use a dedicated subdirectory, not a drive root.'}
    while($at){
        if((Test-Path -LiteralPath $at) -and ((Get-Item -Force -LiteralPath $at).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw "Refusing reparse point: $at"}
        $at=Split-Path -Parent $at
    }
}
$InstallDir=[IO.Path]::GetFullPath($InstallDir).TrimEnd([char[]]@('\','/'))
$Root=if($UserMode){$null}else{[IO.Path]::GetFullPath($Root)}
if(-not $UserMode -and $InstallDir -eq $Root){throw 'The program directory and service data root must differ.'}
function Add-InstallDirToPath {
    param([switch]$PerUser,[string]$Directory=$InstallDir,[string]$PreviousDirectory)
    $key=if($PerUser){[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')}else{[Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine','Registry64').OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment',$true)}
    if(-not $key){throw 'Could not open the selected environment registry key.'}
    try {
        $current=[string]$key.GetValue('Path','',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $original=$current
        $target=$Directory.TrimEnd([char[]]@('\','/'))
        if($PerUser -and $PreviousDirectory -and $PreviousDirectory -ine $Directory){
            $current=(@($current -split ';' | Where-Object { [Environment]::ExpandEnvironmentVariables($_.Trim().Trim('"')).TrimEnd([char[]]@('\','/')) -ine $PreviousDirectory.TrimEnd([char[]]@('\','/')) }) -join ';')
        }
        $present=$false
        foreach($entry in ($current -split ';')) {
            $expanded=[Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"')).TrimEnd([char[]]@('\','/'))
            if($expanded -ieq $target){$present=$true;break}
        }
        $updated=$current
        if(-not $present){
            $updated=$current.TrimEnd(';')+';'+$Directory
            if(-not $current){$updated=$Directory}
        }
        if($updated -ceq $original){return}
        $kind=if($key.GetValueNames() -contains 'Path'){$key.GetValueKind('Path')}else{[Microsoft.Win32.RegistryValueKind]::ExpandString}
        $key.SetValue('Path',$updated,$kind)
    } finally {$key.Dispose()}
    $env:Path += ';'+$Directory
    # Explorer and other long-lived processes refresh their environment after this message.
    # Registry persistence is sufficient for new sessions if this notification is unavailable.
    try {
        if(-not ('AIHerd.PathNotification' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace AIHerd {
    public static class PathNotification {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr wParam,
            string lParam, uint flags, uint timeout, out IntPtr result);
    }
}
'@
        }
        $result=[IntPtr]::Zero
        [void][AIHerd.PathNotification]::SendMessageTimeout([IntPtr]0xffff,0x1a,[IntPtr]::Zero,'Environment',2,5000,[ref]$result)
    } catch {
        Write-Warning "PATH was saved, but Windows did not receive its change notification: $($_.Exception.Message)"
    }
}
function Install-AIHCurrentUserPayload {
    param([Parameter(Mandatory=$true)][string]$Stage,[Parameter(Mandatory=$true)][string]$UiStage,[Parameter(Mandatory=$true)][string]$ArchiveHash)
    $owner=$identity.User.Value
    $statePath=Join-Path $InstallDir 'user-install.json'
    $previousDirectory=$null
    if(Test-Path -LiteralPath $InstallDir){
        $existingOwner=(Get-Acl -LiteralPath $InstallDir).GetOwner([Security.Principal.SecurityIdentifier]).Value
        if($existingOwner -ne $owner){throw 'The per-user installation directory belongs to another Windows account.'}
    }
    if(Test-Path -LiteralPath $statePath){
        if((Get-Item -LiteralPath $statePath).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Refusing per-user installation metadata reparse point'}
        $previous=Get-Content -Raw -LiteralPath $statePath|ConvertFrom-Json
        if($previous.schema_version -ne 1 -or $previous.owner_sid -ne $owner){throw 'Invalid per-user installation metadata'}
        $candidate=[IO.Path]::GetFullPath([string]$previous.directory)
        if((Split-Path -Parent $candidate) -ine $InstallDir -or (Split-Path -Leaf $candidate) -notmatch '^user-version-[0-9a-f]{64}$'){throw 'Invalid prior user-version directory'}
        $previousDirectory=$candidate
    }
    # This directory is writable only by this user, SYSTEM and Administrators.
    New-Item -ItemType Directory -Force $InstallDir|Out-Null
    $acl=[Security.AccessControl.DirectorySecurity]::new()
    $acl.SetOwner($identity.User);$acl.SetAccessRuleProtection($true,$false)
    foreach($sid in @($owner,'S-1-5-18','S-1-5-32-544')){
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
    }
    # Persist only the owner/DACL sections changed above. PowerShell Set-Acl
    # can request SACL privileges on an existing directory during reinstall.
    ([IO.DirectoryInfo]::new($InstallDir)).SetAccessControl($acl)
    $destination=Join-Path $InstallDir ('user-version-'+$ArchiveHash)
    if((Test-Path -LiteralPath $destination) -and ((Get-Item -LiteralPath $destination).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Refusing user-version reparse point'}
    $hash=[Security.Cryptography.SHA256]::Create()
    try {$userHash=([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($owner)))).Replace('-','').ToLowerInvariant().Substring(0,20)}finally{$hash.Dispose()}
    $pipe='\\.\pipe\aiherd-user-'+$userHash
    if(-not (Test-Path -LiteralPath $destination)){
        $pending=Join-Path $InstallDir ('.stage-'+[Guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Directory $pending|Out-Null
            foreach($program in @('aih.exe','aih-tty.exe','aih-rdpauth.exe')){Copy-Item -LiteralPath (Join-Path $Stage $program) -Destination (Join-Path $pending $program)}
            Copy-Item -LiteralPath $UiStage -Destination (Join-Path $pending 'ui') -Recurse
            @{user_gateway=$true;pipe=$pipe}|ConvertTo-Json|Set-Content -Encoding UTF8 (Join-Path $pending 'ui\service.json')
            Move-Item -LiteralPath $pending -Destination $destination
        } finally {if(Test-Path -LiteralPath $pending){Remove-Item -LiteralPath $pending -Recurse -Force}}
    }
    # A same-hash reinstall never overwrites files mapped by a running process.
    foreach($program in @('aih.exe','aih-tty.exe','aih-rdpauth.exe')){
        $installed=Join-Path $destination $program
        if(-not (Test-Path -LiteralPath $installed) -or (Get-FileHash -LiteralPath $installed).Hash -ne (Get-FileHash -LiteralPath (Join-Path $Stage $program)).Hash){throw 'An existing user-version payload is incomplete or changed. Close apps using that version and remove only that version directory before retrying.'}
    }
    foreach($file in Get-ChildItem -LiteralPath $UiStage -File -Recurse -Force){
        $relative=$file.FullName.Substring($UiStage.Length).TrimStart('\')
        if($relative -ieq 'service.json'){continue}
        $installed=Join-Path (Join-Path $destination 'ui') $relative
        if(-not (Test-Path -LiteralPath $installed) -or (Get-FileHash -LiteralPath $installed).Hash -ne (Get-FileHash -LiteralPath $file.FullName).Hash){throw 'An existing user-version UI payload is incomplete or changed; it was not overwritten.'}
    }
    $installedHost=Get-Content -Raw -LiteralPath (Join-Path $destination 'ui\service.json')|ConvertFrom-Json
    if(-not $installedHost.user_gateway -or $installedHost.pipe -ne $pipe){throw 'The existing user-version connection metadata is invalid'}
    Add-InstallDirToPath -PerUser -Directory $destination -PreviousDirectory $previousDirectory
    $temporary=$statePath+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try {
        @{schema_version=1;owner_sid=$owner;archive_sha256=$ArchiveHash;directory=$destination;user_gateway=$true}|ConvertTo-Json|Set-Content -Encoding UTF8 $temporary
        if(Test-Path -LiteralPath $statePath){[IO.File]::Replace($temporary,$statePath,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temporary,$statePath)}
    } finally {if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
    $defaultInstall=Join-Path $env:LOCALAPPDATA 'Programs\AIHerd'
    $shortcutName='AIHerd'
    if($InstallDir -ine $defaultInstall){
        $hash=[Security.Cryptography.SHA256]::Create()
        try {$label=([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($InstallDir.ToLowerInvariant())))).Replace('-','').Substring(0,8)}finally{$hash.Dispose()}
        $shortcutName='AIHerd User '+$label
    }
    $shortcutPath=Join-Path ([Environment]::GetFolderPath('Programs')) ($shortcutName+'.lnk')
    New-Item -ItemType Directory -Force (Split-Path -Parent $shortcutPath)|Out-Null
    $shell=New-Object -ComObject WScript.Shell
    $shortcut=$shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath=Join-Path $destination 'ui\AIHerd.Windows.exe'
    $shortcut.WorkingDirectory=Join-Path $destination 'ui'
    $shortcut.Description='AIHerd for this Windows account'
    $shortcut.Save()
    Write-Host "Open $shortcutName from your Start menu to see terminals in this Windows session."
    Write-Host 'The UI is updated. Any running user gateway continues until you explicitly restart it.'
    Write-Host ('Gateway executable: '+(Join-Path $destination 'aih.exe'))
    Write-Host 'The selected version is on your user PATH for new terminals. Existing package versions are retained while apps may still use them.'
}

function Get-AIHInteractiveAccounts {
    if(-not ('AIHerd.InstallSessions' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Security.Principal;
namespace AIHerd {
    public static class InstallSessions {
        [StructLayout(LayoutKind.Sequential)] struct Entry { public int Id; public IntPtr Station; public int State; }
        [DllImport("wtsapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool WTSEnumerateSessionsW(IntPtr server,int reserved,int version,out IntPtr entries,out int count);
        [DllImport("wtsapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool WTSQuerySessionInformationW(IntPtr server,int session,int kind,out IntPtr value,out int bytes);
        [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr value);
        static string Read(int session,int kind){
            IntPtr value;int bytes;
            if(!WTSQuerySessionInformationW(IntPtr.Zero,session,kind,out value,out bytes))return "";
            try{return Marshal.PtrToStringUni(value)??"";}finally{WTSFreeMemory(value);}
        }
        public static Dictionary<int,string> Accounts(){
            IntPtr entries;int count;
            var result=new Dictionary<int,string>();
            if(!WTSEnumerateSessionsW(IntPtr.Zero,0,1,out entries,out count))throw new System.ComponentModel.Win32Exception();
            try{
                for(int i=0;i<count;i++){
                    var entry=(Entry)Marshal.PtrToStructure(IntPtr.Add(entries,i*Marshal.SizeOf(typeof(Entry))),typeof(Entry));
                    if(entry.Id==0)continue;
                    var name=Read(entry.Id,5);var domain=Read(entry.Id,7);
                    if(name.Length==0)continue;
                    try{result[entry.Id]=new NTAccount(domain,name).Translate(typeof(SecurityIdentifier)).Value;}
                    catch(IdentityNotMappedException){}
                }
            }finally{WTSFreeMemory(entries);}
            return result;
        }
    }
}
'@
    }
    return [AIHerd.InstallSessions]::Accounts()
}

function Start-AIHDesktopTask {
    param([string]$TaskName,[string]$Sid)
    $scheduler=New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    $task=$scheduler.GetFolder('\').GetTask($TaskName)
    foreach($pair in (Get-AIHInteractiveAccounts).GetEnumerator()){
        if($pair.Value -eq $Sid){$null=$task.RunEx($null,4,[int]$pair.Key,$null)}
    }
}

function Set-AIHDesktopTask {
    param([string]$Mode,[string]$Sid,[string]$Helper,[string]$TaskName,[string]$Account)
    $existing=Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
    $previous=$null
    if($existing){
        $actions=@($existing.Actions)
        $expectedRoot=(Join-Path $InstallDir 'ui')+'\'
        if($actions.Count -ne 1 -or -not ([IO.Path]::GetFullPath($actions[0].Execute)).StartsWith($expectedRoot,[StringComparison]::OrdinalIgnoreCase) -or
            (Split-Path -Leaf $actions[0].Execute) -ine 'aih-tty.exe' -or $actions[0].Arguments -notmatch ('^desktop-capture --service '+[regex]::Escape($ServiceName)+' --user-sid (S-[0-9-]+)(?: --control)?$')){
            throw 'The desktop task name belongs to another application.'
        }
        $previousSid=$Matches[1]
        $previous=Export-ScheduledTask -TaskPath '\' -TaskName $TaskName
    }
    try {
        if($existing){Stop-ScheduledTask -InputObject $existing}
        if($Mode -eq 'Off'){
            if($existing){Unregister-ScheduledTask -InputObject $existing -Confirm:$false}
        } else {
            $argsText="desktop-capture --service $ServiceName --user-sid $Sid"
            if($Mode -eq 'Control'){$argsText+=' --control'}
            $action=New-ScheduledTaskAction -Execute $Helper -Argument $argsText
            $principal=New-ScheduledTaskPrincipal -UserId $Sid -LogonType Interactive -RunLevel Limited
            $trigger=New-ScheduledTaskTrigger -AtLogOn -User $Account
            $settings=New-ScheduledTaskSettingsSet -MultipleInstances Parallel -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
            Register-ScheduledTask -TaskName $TaskName -TaskPath '\' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "AIHerd desktop terminal access for $Account" -Force|Out-Null
            Start-AIHDesktopTask -TaskName $TaskName -Sid $Sid
        }
        # The helper verifies its peer and waits for this grant. A task failure
        # cannot expand an earlier grant to another user or to terminal control.
        & $binary service desktop-capture --name $ServiceName --user-sid $Sid --access $Mode.ToLowerInvariant()
        if($LASTEXITCODE -ne 0){throw 'Desktop authorization failed.'}
    } catch {
        $candidate=Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
        if($candidate){Stop-ScheduledTask -InputObject $candidate}
        if($previous){
            Register-ScheduledTask -TaskName $TaskName -TaskPath '\' -Xml $previous -Force|Out-Null
            Start-AIHDesktopTask -TaskName $TaskName -Sid $previousSid
        } elseif($candidate){
            Unregister-ScheduledTask -InputObject $candidate -Confirm:$false
        }
        throw
    }
}

$binary=Join-Path $InstallDir 'aih.exe'
$service=$null
if(-not $UserMode){
$service=Get-CimInstance Win32_Service | Where-Object Name -eq $ServiceName
if(-not $DesktopUserSid){
    if($service -and $service.PathName -match '--desktop-user-sid\s+"?(S-[0-9-]+)'){$DesktopUserSid=$Matches[1]}
    else {
        $desktopAccounts=Get-AIHInteractiveAccounts
        $session=[Diagnostics.Process]::GetCurrentProcess().SessionId
        $DesktopUserSid=if($desktopAccounts.ContainsKey($session)){$desktopAccounts[$session]}elseif($identity.User.Value -match '^S-1-(?:5-21|12-1)-'){$identity.User.Value}
    }
}
if($DesktopUserSid){
    $DesktopUserSid=([Security.Principal.SecurityIdentifier]::new($DesktopUserSid)).Value
} elseif($DesktopCapture -in @('View','Control')){
    throw 'Choose the Windows account with -DesktopUserSid when installing outside a user session.'
}
if($service){
    # Do not take over a same-named service belonging to another installation.
    $command=$service.PathName
    if(-not ($command.StartsWith('"'+$binary+'" ',[StringComparison]::OrdinalIgnoreCase) -or $command.StartsWith($binary+' ',[StringComparison]::OrdinalIgnoreCase))){throw 'Service points to another installation; use its existing InstallDir.'}
    if(-not (Test-Path -LiteralPath $binary)){throw 'Installed service binary is missing.'}
    if($Scratch -and $command -notmatch '(?:^|\s)--scratch(?:\s|$)'){throw 'Refusing to run a scratch upgrade against a real service.'}
} elseif(Test-Path -LiteralPath $Root) {
    throw 'A new service requires a new data root. Existing data was left untouched.'
}
}
$work=Join-Path ([IO.Path]::GetTempPath()) ('aih-install-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $work | Out-Null
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    # Invoke-Expression does not create $PSCmdlet, even with CmdletBinding.
    # Parameter binding requires both offline paths when ArchivePath is supplied.
    if(-not $ArchivePath){
        if(-not $Version){
            $page=1
            do {
                $releases=Invoke-RestMethod -Uri ("https://api.github.com/repos/aiherd-dev/homebrew-aiherd/releases?per_page=30&page="+$page) -Headers @{'User-Agent'='AIHerd-Windows-Installer'} -TimeoutSec 60
                foreach($release in $releases){
                    if($release.draft -or $release.prerelease -or $release.tag_name -notmatch '^v(\d+\.\d+\.\d+)$'){continue}
                    $candidate=$Matches[1]
                    $asset="aiherd-$candidate-x86_64-windows-remote.zip"
                    $names=@($release.assets|ForEach-Object {$_.name})
                    if($names -contains $asset -and $names -contains ($asset+'.sha256')){$Version=$candidate;break}
                }
                $page++
            } while(-not $Version -and @($releases).Count -eq 30)
            if(-not $Version){throw 'No stable Windows release with a ZIP and SHA-256 checksum was found.'}
        }
        $Version=$Version -replace '^v',''
        if($Version -notmatch '^\d+\.\d+\.\d+$'){throw 'Version must be a stable version such as 0.5.21.'}
        $name="aiherd-$Version-x86_64-windows-remote.zip"
        $base="https://github.com/aiherd-dev/homebrew-aiherd/releases/download/v$Version"
        $ArchivePath=Join-Path $work $name
        $ChecksumPath="$ArchivePath.sha256"
        try {
            Save-AIHDownload -Uri "$base/$name" -OutFile $ArchivePath
            Save-AIHDownload -Uri "$base/$name.sha256" -OutFile $ChecksumPath
        } catch { throw "Could not download Windows assets for v$Version. Check https://github.com/aiherd-dev/homebrew-aiherd/releases; older releases have no Windows package. $($_.Exception.Message)" }
    }
    $expected=((Get-Content -Raw -LiteralPath $ChecksumPath).Trim() -split '\s+')[0]
    if($expected -notmatch '^[0-9a-fA-F]{64}$'){throw 'Invalid release checksum.'}
    if((Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash -ne $expected){throw 'Release checksum mismatch. Nothing was installed.'}
    # Extract known programs and the complete UI tree. Validate every UI entry
    # before writing anything, including duplicate/case-colliding Windows paths.
    $programs=@('aih.exe','aih-rdpauth.exe','aih-tty.exe')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $ArchivePath).Path)
    try {
        foreach($program in $programs){
            $entries=@($zip.Entries | Where-Object FullName -eq $program)
            if($entries.Count -ne 1){throw "Release must contain exactly one $program at its root."}
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0],(Join-Path $work $program))
        }
        $uiEntries=@($zip.Entries | Where-Object { $_.FullName.StartsWith('ui/',[StringComparison]::OrdinalIgnoreCase) -and -not $_.FullName.EndsWith('/') })
        $hasUi=$uiEntries.Count -gt 0
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($entry in $uiEntries){
            $relative=$entry.FullName.Substring(3)
            if($relative -match '[\\:<>"|?*\x00-\x1f]' -or @($relative -split '/' | Where-Object { -not $_ -or $_ -in @('.','..') -or $_ -match '[. ]$' -or $_ -match '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)' }).Count -gt 0){throw 'Unsafe UI archive path'}
            if(-not $seen.Add($relative)){throw 'Duplicate UI archive path'}
            if((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000){throw 'UI archive links are not allowed'}
        }
        if($hasUi){
            foreach($required in @('AIHerd.Windows.exe','AIHerd.Windows.dll','AIHerd.Windows.pri','AIHerd.Windows.deps.json','AIHerd.Windows.runtimeconfig.json')){
                if(-not $seen.Contains($required)){throw "UI package is missing $required"}
            }
            $uiStage=Join-Path $work 'ui'
            New-Item -ItemType Directory $uiStage | Out-Null
            foreach($entry in $uiEntries){
                $destination=Join-Path $uiStage $entry.FullName.Substring(3)
                New-Item -ItemType Directory -Force (Split-Path $destination) | Out-Null
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$destination)
            }
        }
    } finally { $zip.Dispose() }
    if($DesktopCapture -in @('View','Control') -and -not $hasUi){
        throw 'Desktop terminal authorization requires a Windows release with the desktop UI.'
    }
    # A per-user install requires the bundled user-session gateway.
    $desktopHost=if($hasUi){Get-AIHDesktopHostManifest -UiDirectory $uiStage}else{$null}
    if($UserMode -and ($null -eq $desktopHost -or -not $desktopHost.user_gateway)){
        throw 'This package does not support per-user installation. Download a current AIHerd Windows package with the user-session gateway feature; version 0.5.24 and older native UI packages require the system installer.'
    }
    # Resolve UI dependencies before installed files, ACLs or services change.
    if($hasUi -and (Get-AIHDesktopWebView2Requirement -UiDirectory $uiStage)){
        Install-AIHWebView2Runtime -WorkDirectory $work
    }
    foreach($program in $programs){
        & (Join-Path $work $program) --version
        if($LASTEXITCODE -ne 0){throw "$program failed its version check."}
    }

    $captureMode=$null
    if(-not $UserMode -and $hasUi){
        $captureReady=Test-Path -LiteralPath (Join-Path $uiStage 'desktop-capture-v1.json') -PathType Leaf
        if($DesktopCapture -and -not $captureReady -and $DesktopCapture -ne 'Off'){throw 'This Windows release does not support installer-authorized desktop capture.'}
        if($captureReady -and $DesktopUserSid){
            $captureMode=$DesktopCapture
            $accountName=try {([Security.Principal.SecurityIdentifier]::new($DesktopUserSid)).Translate([Security.Principal.NTAccount]).Value}catch{$DesktopUserSid}
            if(-not $captureMode -and $service -and $service.PathName -match ('--desktop-user-sid\s+"?'+[regex]::Escape($DesktopUserSid)+'"?(?:\s|$)') -and
                $service.PathName -match '--desktop-capture\s+(view|control|off)(?:\s|$)'){
                $captureMode=$Matches[1]
            }
            $currentSession=[Diagnostics.Process]::GetCurrentProcess().SessionId
            if(-not $captureMode -and -not $Scratch -and $currentSession -gt 0 -and -not [Console]::IsInputRedirected){
                Write-Host "AIHerd can show ordinary terminals belonging to $accountName on this PC and on devices paired with this herd. Control also permits sending commands. Open dashboard listeners will require pairing."
                $choice=Read-Host 'Choose V to allow viewing, C to allow viewing and control, or Enter for service only'
                $captureMode=switch($choice.Trim().ToUpperInvariant()){'V'{'View'} 'C'{'Control'} ''{'Off'} default{throw 'Unknown desktop authorization choice.'}}
            }
            if($captureMode -and $captureMode -ne 'Off'){
                Write-Host "Desktop grant for $accountName on $ServiceName and its full-access paired devices: $captureMode. Open dashboard listeners require pairing."
            }
        }
    }

    if($UserMode){
        Install-AIHCurrentUserPayload -Stage $work -UiStage $uiStage -ArchiveHash $expected.ToLowerInvariant()
        return
    }

    # Program files must not be replaceable by unprivileged users. LocalService
    # and desktop users get read/execute here. Credentials remain in separate
    # private data roots; Users must never get write access to service executables.
    New-Item -ItemType Directory -Force $InstallDir | Out-Null
    $acl=[Security.AccessControl.DirectorySecurity]::new()
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    $acl.SetAccessRuleProtection($true,$false)
    foreach($sid in @('S-1-5-18','S-1-5-32-544','S-1-5-19','S-1-5-32-545')){
        $rights=if($sid -in @('S-1-5-19','S-1-5-32-545')){'ReadAndExecute'}else{'FullControl'}
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),$rights,'ContainerInherit,ObjectInherit','None','Allow'))
    }
    Set-Acl -LiteralPath $InstallDir -AclObject $acl
    $uiDestination=$null
    if($hasUi){
        # Versioned folders let running UI instances finish while an upgrade is
        # staged. Publish the shortcut only after service upgrade/access succeeds.
        $uiDestination=Join-Path $InstallDir ('ui\'+$expected.ToLowerInvariant())
        foreach($path in @((Join-Path $InstallDir 'ui'),$uiDestination,(Join-Path $uiDestination 'service.json'))){
            if((Test-Path -LiteralPath $path) -and ((Get-Item -Force -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Refusing a UI installation reparse point'}
        }
        if(-not (Test-Path $uiDestination)){
            New-Item -ItemType Directory -Force $uiDestination | Out-Null
            Copy-Item (Join-Path $uiStage '*') $uiDestination -Recurse -Force
        }
        @{pipe=('\\.\pipe\aiherd-service-'+$ServiceName)} | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $uiDestination 'service.json')
    }
    $helper=''
    $taskName="AIHerd Desktop $ServiceName"
    if($captureMode -in @('View','Control')){
        $captureDirectory=Join-Path $uiDestination 'capture'
        if((Test-Path -LiteralPath $captureDirectory) -and ((Get-Item -Force -LiteralPath $captureDirectory).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unexpected capture reparse point'}
        New-Item -ItemType Directory -Force $captureDirectory|Out-Null
        $helper=Join-Path $captureDirectory 'aih-tty.exe'
        $source=Join-Path $work 'aih-tty.exe'
        if(-not(Test-Path -LiteralPath $helper)){Copy-Item -LiteralPath $source -Destination $helper}
        if((Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $helper).Hash){throw 'Versioned desktop helper failed verification'}
    }
    & icacls.exe $InstallDir /setowner '*S-1-5-32-544' /T /C | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Could not protect ownership of installed program files'}
    if($service){
        # The installed CLI owns preflight, graceful stop, mapped-image
        # replacement, readiness verification and rollback as one transaction.
        $upgradeArgs=@('service','upgrade','--name',$ServiceName,'--from',$work)
        if($Scratch){$upgradeArgs+='--scratch'}
        & $binary @upgradeArgs
        if($LASTEXITCODE -ne 0){throw 'Service upgrade failed; see aih diagnostics above.'}
    } else {
        foreach($program in $programs){
            Copy-Item -LiteralPath (Join-Path $work $program) -Destination (Join-Path $InstallDir $program)
        }
        $created=$false
        try {
            $installArgs=@('service','install','--name',$ServiceName,'--root',$Root,'--proxy',$Relay)
            if($hasUi -and $DesktopUserSid){$installArgs+=@('--desktop-user-sid',$DesktopUserSid)}
            if($Scratch){$installArgs+='--scratch'}
            & $binary @installArgs
            if($LASTEXITCODE -ne 0){throw 'Service installation failed.'}
            $created=$true
            if($captureMode){Set-AIHDesktopTask -Mode $captureMode -Sid $DesktopUserSid -Helper $helper -TaskName $taskName -Account $accountName}
            & $binary service start --name $ServiceName
            if($LASTEXITCODE -ne 0){throw 'Service start failed.'}
            $running=$false
            for($i=0;$i -lt 30;$i++){
                Start-Sleep -Milliseconds 500
                if((Get-Service $ServiceName).Status -eq 'Running'){$running=$true;break}
            }
            if(-not $running){throw 'Service failed to reach Running.'}
        } catch {
            if($created){
                Stop-Service $ServiceName -ErrorAction SilentlyContinue
                & $binary service uninstall --name $ServiceName | Out-Null
            }
            throw
        }
    }
    if($hasUi){
        if($service -and $captureMode){
            Set-AIHDesktopTask -Mode $captureMode -Sid $DesktopUserSid -Helper $helper -TaskName $taskName -Account $accountName
        } elseif($service -and $DesktopUserSid){
            & $binary service desktop-access --name $ServiceName --user-sid $DesktopUserSid
            if($LASTEXITCODE -ne 0){throw 'Desktop service access configuration failed.'}
        }
        $shortcutName=if($ServiceName -eq 'AIHerd'){'AIHerd'}else{'AIHerd-'+$ServiceName}
        $shortcutPath=Join-Path ([Environment]::GetFolderPath('CommonPrograms')) ($shortcutName+'.lnk')
        $shell=New-Object -ComObject WScript.Shell
        $shortcut=$shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath=Join-Path $uiDestination 'AIHerd.Windows.exe'
        $shortcut.WorkingDirectory=$uiDestination
        $shortcut.Description='AIHerd Windows dashboard'
        $shortcut.Save()
        Write-Host "Open $shortcutName from the Start menu. The UI connects to the service without elevation."
    }
    Add-InstallDirToPath
    $suffix=if($ServiceName -eq 'AIHerd'){''}else{' --socket \\.\pipe\aiherd-service-'+$ServiceName}
    Write-Host "AIHerd is installed and running with automatic startup."
    Write-Host "aih is available on PATH in new terminals. Open a new PowerShell window to use it."
    if($service){
        Write-Host 'Existing phone pairings and service settings are preserved.'
    } else {
        Write-Host "To pair a phone, sign in and open the pairing link:"
        Write-Host "& '$binary' login$suffix"
        Write-Host "& '$binary' join$suffix"
    }
} finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
