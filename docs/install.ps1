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
    $backup=Join-Path $work 'previous'
    New-Item -ItemType Directory $backup | Out-Null
    $wasRunning=$service -and $service.State -ne 'Stopped'
    foreach($program in $programs){
        $installed=Join-Path $InstallDir $program
        if(Test-Path -LiteralPath $installed){Copy-Item -LiteralPath $installed -Destination (Join-Path $backup $program)}
    }
    if($wasRunning){
        & $binary service stop --name $ServiceName
        if($LASTEXITCODE -ne 0){throw 'Service stop failed; executable was not replaced.'}
    }
    $created=$false
    try {
        foreach($program in $programs){
            $installed=Join-Path $InstallDir $program
            if(Test-Path -LiteralPath $installed){Remove-Item -LiteralPath $installed -Force}
            Copy-Item -LiteralPath (Join-Path $work $program) -Destination $installed
        }
        if(-not $service){
            $installArgs=@('service','install','--name',$ServiceName,'--root',$Root,'--proxy',$Relay)
            if($Scratch){$installArgs+='--scratch'}
            & $binary @installArgs
            if($LASTEXITCODE -ne 0){throw 'Service installation failed.'}
            $created=$true
        }
        & $binary service start --name $ServiceName
        if($LASTEXITCODE -ne 0){throw 'Service start failed.'}
        $running=$false
        for($i=0;$i -lt 30;$i++){
            Start-Sleep -Milliseconds 500
            if((Get-Service $ServiceName).Status -eq 'Running'){$running=$true;break}
        }
        if(-not $running){throw 'Service failed to reach Running.'}
    } catch {
        $failure=$_
        Stop-Service $ServiceName -ErrorAction SilentlyContinue
        if($created){& $binary service uninstall --name $ServiceName | Out-Null}
        foreach($program in $programs){
            $installed=Join-Path $InstallDir $program
            $previous=Join-Path $backup $program
            if(Test-Path -LiteralPath $previous){Copy-Item -LiteralPath $previous -Destination $installed -Force}
            elseif(Test-Path -LiteralPath $installed){Remove-Item -LiteralPath $installed -Force}
        }
        if($wasRunning){& $binary service start --name $ServiceName | Out-Null}
        throw $failure
    }
    $suffix=if($ServiceName -eq 'AIHerd'){''}else{' --socket \\.\pipe\aiherd-service-'+$ServiceName}
    Write-Host "AIHerd is installed and running as LocalService (automatic startup)."
    Write-Host "Complete browser sign-in, then pair your phone:"
    Write-Host "& '$binary' login$suffix"
    Write-Host "& '$binary' join$suffix"
    Write-Host 'Upgrades preserve service settings and credentials; existing shells close during restart.'
} finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
