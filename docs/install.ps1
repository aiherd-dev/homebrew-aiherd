#Requires -Version 5.1
[CmdletBinding(DefaultParameterSetName='Download')]
param(
    [string]$Version,
    [string]$InstallDir = "$env:ProgramFiles\AIHerd",
    [string]$Root = "$env:ProgramData\AIHerd",
    [ValidatePattern('^[A-Za-z0-9-]+$')][string]$ServiceName = 'AIHerd',
    [string]$Relay = 'wss://oci01.aiherd.dev',
    [Parameter(Mandatory=$true,ParameterSetName='Offline')][string]$ArchivePath,
    [Parameter(Mandatory=$true,ParameterSetName='Offline')][string]$ChecksumPath,
    # For isolated acceptance rigs only; persisted in the service command line.
    [switch]$Scratch
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this installer in PowerShell as Administrator.'
}
$arch = $env:PROCESSOR_ARCHITECTURE
if($env:PROCESSOR_ARCHITEW6432){$arch=$env:PROCESSOR_ARCHITEW6432}
if($arch -ne 'AMD64'){throw 'This package requires x64 Windows.'}
if([Environment]::OSVersion.Version.Build -lt 17763){throw 'Windows 10 1809 / Server 2019 or newer is required.'}
foreach($path in @($InstallDir,$Root)) {
    if($path -notmatch '^[A-Za-z]:[\\/].+'){throw 'InstallDir and Root must be absolute local paths.'}
    $at=[IO.Path]::GetFullPath($path)
    if($at.TrimEnd('\') -eq [IO.Path]::GetPathRoot($at).TrimEnd('\')){throw 'Use a dedicated subdirectory, not a drive root.'}
    while($at){
        if((Test-Path -LiteralPath $at) -and ((Get-Item -Force -LiteralPath $at).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw "Refusing reparse point: $at"}
        $at=Split-Path -Parent $at
    }
}
$InstallDir=[IO.Path]::GetFullPath($InstallDir)
$Root=[IO.Path]::GetFullPath($Root)
if($InstallDir -eq $Root){throw 'The program directory and service data root must differ.'}
function Add-InstallDirToPath {
    $key=[Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine','Registry64').OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment',$true)
    if(-not $key){throw 'Could not open the machine environment registry key.'}
    try {
        $current=[string]$key.GetValue('Path','',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $target=$InstallDir.TrimEnd([char[]]@('\','/'))
        foreach($entry in ($current -split ';')) {
            $expanded=[Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"')).TrimEnd([char[]]@('\','/'))
            if($expanded -ieq $target){return}
        }
        $updated=$current.TrimEnd(';')+';'+$InstallDir
        if(-not $current){$updated=$InstallDir}
        $kind=if($key.GetValueNames() -contains 'Path'){$key.GetValueKind('Path')}else{[Microsoft.Win32.RegistryValueKind]::ExpandString}
        $key.SetValue('Path',$updated,$kind)
    } finally {$key.Dispose()}
    $env:Path += ';'+$InstallDir
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
$binary=Join-Path $InstallDir 'aih.exe'
$service=Get-CimInstance Win32_Service | Where-Object Name -eq $ServiceName
if($service){
    # Do not take over a same-named service belonging to another installation.
    $command=$service.PathName
    if(-not ($command.StartsWith('"'+$binary+'" ',[StringComparison]::OrdinalIgnoreCase) -or $command.StartsWith($binary+' ',[StringComparison]::OrdinalIgnoreCase))){throw 'Service points to another installation; use its existing InstallDir.'}
    if(-not (Test-Path -LiteralPath $binary)){throw 'Installed service binary is missing.'}
    if($Scratch -and $command -notmatch '(?:^|\s)--scratch(?:\s|$)'){throw 'Refusing to run a scratch upgrade against a real service.'}
} elseif(Test-Path -LiteralPath $Root) {
    throw 'A new service requires a new data root. Existing data was left untouched.'
}
$work=Join-Path ([IO.Path]::GetTempPath()) ('aih-install-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $work | Out-Null
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if($PSCmdlet.ParameterSetName -eq 'Download'){
        if(-not $Version){
            $release=Invoke-RestMethod -Uri 'https://api.github.com/repos/aiherd-dev/homebrew-aiherd/releases/latest' -Headers @{'User-Agent'='AIHerd-Windows-Installer'}
            $Version=$release.tag_name
        }
        $Version=$Version -replace '^v',''
        if($Version -notmatch '^\d+\.\d+\.\d+$'){throw 'Version must be a stable version such as 0.5.21.'}
        $name="aiherd-$Version-x86_64-windows-remote.zip"
        $base="https://github.com/aiherd-dev/homebrew-aiherd/releases/download/v$Version"
        $ArchivePath=Join-Path $work $name
        $ChecksumPath="$ArchivePath.sha256"
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "$base/$name" -OutFile $ArchivePath
            Invoke-WebRequest -UseBasicParsing -Uri "$base/$name.sha256" -OutFile $ChecksumPath
        } catch { throw "Could not download Windows assets for v$Version. Check https://github.com/aiherd-dev/homebrew-aiherd/releases; older releases have no Windows package. $($_.Exception.Message)" }
    }
    $expected=((Get-Content -Raw -LiteralPath $ChecksumPath).Trim() -split '\s+')[0]
    if($expected -notmatch '^[0-9a-fA-F]{64}$'){throw 'Invalid release checksum.'}
    if((Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash -ne $expected){throw 'Release checksum mismatch. Nothing was installed.'}
    # Extract only the expected executables; never follow archive paths.
    $programs=@('aih.exe','aih-rdpauth.exe','aih-tty.exe')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $ArchivePath).Path)
    try {
        foreach($program in $programs){
            $entries=@($zip.Entries | Where-Object FullName -eq $program)
            if($entries.Count -ne 1){throw "Release must contain exactly one $program at its root."}
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0],(Join-Path $work $program))
        }
    } finally { $zip.Dispose() }
    foreach($program in $programs){
        & (Join-Path $work $program) --version
        if($LASTEXITCODE -ne 0){throw "$program failed its version check."}
    }

    # Program files must not be replaceable by unprivileged users. LocalService
    # and desktop users get read/execute here. Credentials remain in separate
    # private data roots; Users must never get write access to service executables.
    New-Item -ItemType Directory -Force $InstallDir | Out-Null
    $acl=[Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true,$false)
    foreach($sid in @('S-1-5-18','S-1-5-32-544','S-1-5-19','S-1-5-32-545')){
        $rights=if($sid -in @('S-1-5-19','S-1-5-32-545')){'ReadAndExecute'}else{'FullControl'}
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),$rights,'ContainerInherit,ObjectInherit','None','Allow'))
    }
    Set-Acl -LiteralPath $InstallDir -AclObject $acl
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
            if($Scratch){$installArgs+='--scratch'}
            & $binary @installArgs
            if($LASTEXITCODE -ne 0){throw 'Service installation failed.'}
            $created=$true
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
    Add-InstallDirToPath
    $suffix=if($ServiceName -eq 'AIHerd'){''}else{' --socket \\.\pipe\aiherd-service-'+$ServiceName}
    Write-Host "AIHerd is installed and running as LocalService (automatic startup)."
    Write-Host "aih is available on PATH in new terminals. Open a new PowerShell window to use it."
    Write-Host "Complete browser sign-in, then pair your phone:"
    Write-Host "& '$binary' login$suffix"
    Write-Host "& '$binary' join$suffix"
    Write-Host 'Upgrades preserve service settings, credentials, and active SSH connections.'
} finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
