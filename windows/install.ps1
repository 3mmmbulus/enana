param([string]$SourceDir = (Split-Path $PSScriptRoot -Parent), [string]$HomeDir = '', [switch]$Upgrade, [switch]$NoOpen, [switch]$NoRules, [ValidateSet('zh','en')][string]$Lang = 'zh')
. "$PSScriptRoot\common.ps1"
if ([Environment]::OSVersion.Platform -ne 'Win32NT' -or ![Environment]::Is64BitProcess -or [Environment]::OSVersion.Version.Build -lt 19041) { throw 'Use 64-bit PowerShell on Windows 10 (build 19041+) or Windows 11.' }
if (Test-EnanaAdmin) { Write-Warning 'A regular PowerShell window is sufficient. The dashboard task runs without elevation.' }
if (!$HomeDir) { $HomeDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'enana' }
$HomeDir=[IO.Path]::GetFullPath($HomeDir); $SourceDir=[IO.Path]::GetFullPath($SourceDir)
Assert-NoReparse $HomeDir
if ($HomeDir -match '["\r\n]' -or $SourceDir -match '["\r\n]') { throw 'Install paths contain unsupported characters.' }
if (!(Test-Path -LiteralPath "$SourceDir\install.sh") -or !(Test-Path -LiteralPath "$SourceDir\VERSION")) { throw 'Invalid enana source package.' }
$sid=Get-EnanaSid; $mutex=New-Object Threading.Mutex($false,"Local\EnanaInstall-$sid")
if (!$mutex.WaitOne(0)) { $mutex.Dispose(); throw 'An enana installation is already in progress.' }
$installed=Test-Path -LiteralPath "$HomeDir\.enana-home"; $saved=Read-EnanaSettings $HomeDir
$backup=Join-Path $HomeDir ('backups\windows-install-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N'))
$programs=@('lib','data','ui','windows','enana','VERSION','CHANGELOG.md','get.sh','get.ps1','sing-box.exe','config.json','settings.env','rules','overrides.tsv','apps.seen','.apps.now')
$changed=$false; $workerStopped=$false; $taskExisted=$false
try {
    Set-PrivateDirectory $HomeDir
    [IO.Directory]::CreateDirectory("$HomeDir\runtime\cache")|Out-Null
    if ($installed) {
        Set-PrivateDirectory $backup
        foreach ($name in $programs) { if (Test-Path -LiteralPath "$HomeDir\$name") { Copy-Item -LiteralPath "$HomeDir\$name" -Destination "$backup\$name" -Recurse } }
        $taskExisted=[bool](Get-ScheduledTask -TaskName "Enana Dashboard $sid" -ErrorAction SilentlyContinue)
    }
    $arch=if (($env:PROCESSOR_ARCHITEW6432,$env:PROCESSOR_ARCHITECTURE) -contains 'ARM64') {'arm64'} else {'amd64'}
    $env:ENANA_WINDOWS_ARCH=$arch; $env:ENANA_WINDOWS_SID=$sid
    $pins=Read-JsonFile "$SourceDir\windows\runtime-pins.json"
    if (Test-Path -LiteralPath "$HomeDir\runtime\node\node.exe") {
        & "$HomeDir\runtime\node\node.exe" "$HomeDir\windows\helper.js" control $HomeDir shutdown
        if ($LASTEXITCODE -ne 0) { throw 'Could not stop the installed dashboard for upgrade.' }
        $workerStopped=$true
        Start-Sleep -Milliseconds 750
    }
    foreach ($component in @('git','node','core')) {
        $pin=$pins.$component.$arch; $stamp=Join-Path $HomeDir "runtime\$component.pin"
        $executable=if($component -eq 'git'){"$HomeDir\runtime\git\bin\bash.exe"}elseif($component -eq 'node'){"$HomeDir\runtime\node\node.exe"}else{"$HomeDir\sing-box.exe"}
        if ((Test-Path -LiteralPath $stamp) -and [IO.File]::ReadAllText($stamp) -eq $pin.sha256 -and (Test-Path -LiteralPath $executable) -and ($component -ne 'core' -or (Test-Path -LiteralPath "$HomeDir\runtime\cache\core.zip"))) { continue }
        $archive=Join-Path $HomeDir "runtime\cache\$component$(if($component -eq 'git'){'.7z.exe'}else{'.zip'})"
        if (!(Test-Path -LiteralPath $archive) -or (Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant() -ne $pin.sha256) { Get-VerifiedDownload @($pin.url) $archive $pin.sha256 }
        $dest=Join-Path $HomeDir "runtime\$component.next"
        if(Test-Path -LiteralPath $dest){Remove-Item -LiteralPath $dest -Recurse -Force}
        if ($component -eq 'git') {
            Write-Host 'Extracting verified private PortableGit runtime...'
            # Upstream's modified SFX ignores ordinary 7z -o. Its reviewed
            # InstallPath is %%S\PortableGit: a private sibling of the archive.
            # Let its post-install complete there, then move the whole runtime.
            $extracted=Join-Path ([IO.Path]::GetDirectoryName($archive)) 'PortableGit'
            Assert-NoReparse $extracted
            if(Test-Path -LiteralPath $extracted){Remove-Item -LiteralPath $extracted -Recurse -Force}
            $p=Start-Process -FilePath $archive -ArgumentList '-y -gm2' -PassThru
            $null=$p.Handle; $p.WaitForExit(); $p.Refresh()
            if($p.ExitCode -ne 0 -or !(Test-Path -LiteralPath "$extracted\bin\bash.exe")){
                Write-Host "PortableGit exit=$($p.ExitCode), expected Bash exists=$(Test-Path -LiteralPath "$extracted\bin\bash.exe")"
                throw 'PortableGit extraction failed.'
            }
            Move-Item -LiteralPath $extracted -Destination $dest
        } else { Expand-SafeZip $archive $dest }
        $changed=$true
        if($component -eq 'core') {
            $exe=@(Get-ChildItem -LiteralPath $dest -Filter 'sing-box.exe' -Recurse);if($exe.Count -ne 1){throw 'Invalid core archive'}
            Copy-Item -LiteralPath $exe[0].FullName -Destination "$HomeDir\sing-box.exe" -Force
            Remove-Item -LiteralPath $dest -Recurse -Force
        } else {
            if($component -eq 'node'){$child=@(Get-ChildItem -LiteralPath $dest -Directory);if($child.Count -ne 1){throw 'Invalid Node archive'};$final=$child[0].FullName}else{$final=$dest}
            $previous=Join-Path $HomeDir "runtime\$component.previous"
            if(Test-Path -LiteralPath $previous){Remove-Item -LiteralPath $previous -Recurse -Force}
            if(Test-Path -LiteralPath "$HomeDir\runtime\$component"){Move-Item -LiteralPath "$HomeDir\runtime\$component" -Destination $previous}
            Move-Item -LiteralPath $final -Destination "$HomeDir\runtime\$component"
            if(Test-Path -LiteralPath $dest){Remove-Item -LiteralPath $dest -Recurse -Force}
        }
        Write-Utf8 $stamp $pin.sha256
    }
    $changed=$true
    [IO.Directory]::CreateDirectory("$HomeDir\windows")|Out-Null
    Copy-Item -Path "$SourceDir\windows\*" -Destination "$HomeDir\windows" -Recurse -Force
    $bash=Set-EnanaEnvironment $HomeDir
    & $bash -c 'for tool in perl curl openssl ssh ssh-keyscan tar sha256sum awk sed stat; do command -v "$tool" >/dev/null || { printf "Missing runtime tool: %s\n" "$tool" >&2; exit 1; }; done; perl -MJSON::PP -MDigest::SHA -e "print qq(runtime.ready\n)"'
    if($LASTEXITCODE -ne 0){throw 'Portable runtime is incomplete.'}
    & "$HomeDir\sing-box.exe" version; if($LASTEXITCODE -ne 0){throw 'Windows core cannot execute.'}
    if(!$installed){
        $selected=@{}; foreach($key in @('PORT','UI_PORT','API_PORT','SPEED_PORT')){
            $port=[int]$saved[$key];$listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,$port)
            try{$listener.Start();if($selected.ContainsKey($port)){throw 'Port already selected'}}catch{$listener.Stop();$listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port}finally{$listener.Stop()}
            $selected[$port]=$true;$saved[$key]=[string]$port
        }
        Write-Utf8 "$HomeDir\settings.env" (($saved.GetEnumerator()|ForEach-Object{"$($_.Key)=$($_.Value)"}) -join "`n")
    }
    $env:ENANA_SKIP_RULES=if($NoRules){'1'}else{''}
    [IO.Directory]::CreateDirectory("$HomeDir\bin")|Out-Null
    $cmd='@echo off'+"`r`n"+'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\windows\cli.ps1" %*'+"`r`n"
    [IO.File]::WriteAllText("$HomeDir\bin\enana.cmd",$cmd,[Text.Encoding]::ASCII)
    $changed=$true
    Invoke-EnanaBash $HomeDir "$SourceDir\install.sh" @('--yes','--upgrade','--lang',$Lang)
    & "$HomeDir\windows\platform.ps1" -Action shortcut-install -HomeDir $HomeDir
    $url="http://127.0.0.1:$((Read-EnanaSettings $HomeDir).API_PORT)/enana/admin/"
    $response=Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 15
    if($response.StatusCode -ne 200){throw 'Dashboard verification failed.'}
    Write-Host "enana $([IO.File]::ReadAllText("$HomeDir\VERSION").Trim()) installed. Dashboard: $url"
    Write-Host 'System Proxy is the default. Select Enhanced/TUN in dashboard Settings to request UAC.'
    if(!$NoOpen){Start-Process $url}
} catch {
    $failure=$_
    if($installed -and ($changed -or $workerStopped)){
        if(Test-Path -LiteralPath "$HomeDir\runtime\node\node.exe") { & "$HomeDir\runtime\node\node.exe" "$HomeDir\windows\helper.js" control $HomeDir shutdown 2>$null }
        if($changed){foreach($name in $programs){if(Test-Path -LiteralPath "$backup\$name"){
            Remove-Item -LiteralPath "$HomeDir\$name" -Recurse -Force -ErrorAction SilentlyContinue
            Copy-Item -LiteralPath "$backup\$name" -Destination "$HomeDir\$name" -Recurse
        }}}
        foreach($component in @('git','node')){if(Test-Path -LiteralPath "$HomeDir\runtime\$component.previous"){
            Remove-Item -LiteralPath "$HomeDir\runtime\$component" -Recurse -Force -ErrorAction SilentlyContinue
            Move-Item -LiteralPath "$HomeDir\runtime\$component.previous" -Destination "$HomeDir\runtime\$component"
            Remove-Item -LiteralPath "$HomeDir\runtime\$component.pin" -ErrorAction SilentlyContinue
        }}
        if($taskExisted){& "$HomeDir\windows\platform.ps1" -Action task-register -HomeDir $HomeDir; & "$HomeDir\windows\platform.ps1" -Action worker-start -HomeDir $HomeDir}
    } elseif(!$installed){
        if(Test-Path -LiteralPath "$HomeDir\runtime\node\node.exe"){& "$HomeDir\runtime\node\node.exe" "$HomeDir\windows\helper.js" control $HomeDir shutdown 2>$null}
        Unregister-ScheduledTask -TaskName "Enana Dashboard $sid" -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$HomeDir\.enana-home" -ErrorAction SilentlyContinue
    }
    throw $failure
} finally {$mutex.ReleaseMutex();$mutex.Dispose()}
