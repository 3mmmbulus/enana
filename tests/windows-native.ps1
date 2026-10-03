param([string]$HomeDir = (Join-Path $env:TEMP 'enana-native-acceptance'))
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
. "$repo\windows\common.ps1"
$oldPath=[Environment]::GetEnvironmentVariable('Path','User')
function Assert($Condition,[string]$Message){if(!$Condition){throw $Message};Write-Host "PASS: $Message"}
$installed=$false
try{
    Get-ChildItem -Path "$repo\windows\*.ps1","$repo\get.ps1" | ForEach-Object {
        $tokens=$null;$errors=$null;[Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$errors)|Out-Null
        Assert ($errors.Count -eq 0) "PowerShell parses $($_.Name)"
    }
    $zipWork=Join-Path $env:TEMP ('enana-zip-test-'+[Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($zipWork)|Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try{
        $i=0
        foreach($bad in @('../escape.txt','C:/escape.txt','file:stream','CON.txt','nested/trailing.','nested/duplicate.txt','Nested/Duplicate.txt')){
            $i++;$archive=Join-Path $zipWork "$i.zip";$dest=Join-Path $zipWork "$i-out"
            $zip=[IO.Compression.ZipFile]::Open($archive,'Create')
            try{$zip.CreateEntry('safe.txt')|Out-Null;$zip.CreateEntry($bad)|Out-Null
                if($bad -like '*duplicate*'){$zip.CreateEntry('nested/DUPLICATE.txt')|Out-Null}
            }finally{$zip.Dispose()}
            $rejected=$false;try{Expand-SafeZip $archive $dest}catch{$rejected=$true}
            Assert ($rejected -and !(Test-Path -LiteralPath "$dest\safe.txt")) "ZIP preflight rejects $bad before extracting any entry"
        }
    }finally{Remove-Item -LiteralPath $zipWork -Recurse -Force}
    # Private scratch registry/state is not used as a substitute for installing
    # the real worker and running the real sing-box Windows executable.
    & "$repo\windows\install.ps1" -SourceDir $repo -HomeDir $HomeDir -NoOpen -NoRules -Lang en
    $installed=$true
    $s=Read-EnanaSettings $HomeDir;$url="http://127.0.0.1:$($s.API_PORT)"
    Assert ((Invoke-WebRequest -UseBasicParsing -Uri "$url/enana/admin/servers" -TimeoutSec 15).StatusCode -eq 200) 'dashboard deep navigation loads'
    $taskName="Enana Dashboard $(Get-EnanaSid)"
    $task=Get-ScheduledTask -TaskName $taskName
    Assert ($task.State -eq 'Running' -and $task.Actions.Execute -contains "$HomeDir\runtime\worker-launcher.exe") 'real dashboard task runs through the console-free launcher'
    $state=Read-JsonFile "$HomeDir\runtime\service.json"
    $worker=Get-CimInstance Win32_Process -Filter "ProcessId=$($state.pid)"
    $parent=Get-CimInstance Win32_Process -Filter "ProcessId=$($worker.ParentProcessId)"
    Assert ($parent.ExecutablePath -eq "$HomeDir\runtime\worker-launcher.exe") 'real worker belongs to the scheduled launcher rather than the installer terminal'
    $callerScript=Join-Path $env:TEMP ('enana-caller-'+[Guid]::NewGuid().ToString('N')+'.ps1')
    $callerReady=$callerScript+'.ready';$terminal=$null
    Write-Utf8 $callerScript @'
param([string]$HomeDir,[string]$Ready)
$ErrorActionPreference='Stop'
& "$HomeDir\windows\cli.ps1" -Arguments @('status')
[IO.File]::WriteAllText($Ready,'ready')
Start-Sleep 120
'@
    try {
        $args='-NoProfile -ExecutionPolicy Bypass -File "{0}" -HomeDir "{1}" -Ready "{2}"' -f $callerScript,$HomeDir,$callerReady
        $terminal=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $args -PassThru
        for($i=0;$i -lt 100 -and !(Test-Path -LiteralPath $callerReady);$i++){Start-Sleep -Milliseconds 100}
        Assert (Test-Path -LiteralPath $callerReady) 'separate caller terminal executes the installed enana CLI'
        Stop-Process -Id $terminal.Id -Force
        Assert ((Invoke-WebRequest -UseBasicParsing -Uri "$url/enana/admin/" -TimeoutSec 15).StatusCode -eq 200) 'dashboard remains available after its CLI caller terminal is closed'
    } finally {
        if($terminal -and !$terminal.HasExited){$terminal.Kill()}
        Remove-Item -LiteralPath $callerScript,$callerReady -Force -ErrorAction SilentlyContinue
    }
    $uiEnv=Invoke-RestMethod -Uri "$url/enana/admin/env.json" -TimeoutSec 15
    Assert ($uiEnv.version -eq [IO.File]::ReadAllText("$repo\VERSION").Trim()) 'dashboard metadata is valid JSON with a clean version scalar'
    $auth=Invoke-RestMethod -Uri "$url/api/auth/status" -Headers @{'X-Enana'='1'} -TimeoutSec 15
    Assert $auth.ok 'real Bash API responds through Windows TCP bridge'
    try{Invoke-WebRequest -UseBasicParsing -Uri "$url/api/auth/status" -TimeoutSec 15|Out-Null;throw 'Missing-header request was accepted'}catch{Assert ($_.Exception.Response.StatusCode.value__ -eq 403) 'missing X-Enana header is rejected'}
    & "$HomeDir\sing-box.exe" check -c "$HomeDir\config.json";Assert ($LASTEXITCODE -eq 0) 'native Windows sing-box validates installed configuration'
    Invoke-EnanaBash $HomeDir "$repo\tests\windows-schema.sh" @()
    $config=Read-JsonFile "$HomeDir\config.json";Assert (!($config.inbounds|Where-Object{$_.type -eq 'tun'})) 'fresh install defaults to System Proxy'
    Assert (@($config.route.rule_set|Where-Object{$_.path -notmatch '^[A-Za-z]:/'}).Count -eq 0) 'filesystem paths are native Windows paths'
    $portsBefore=@($s.PORT,$s.UI_PORT,$s.API_PORT,$s.SPEED_PORT) -join ','
    & "$repo\windows\install.ps1" -SourceDir $repo -HomeDir $HomeDir -NoOpen -NoRules -Upgrade -Lang en
    $after=Read-EnanaSettings $HomeDir;Assert (($portsBefore -eq (@($after.PORT,$after.UI_PORT,$after.API_PORT,$after.SPEED_PORT) -join ','))) 'upgrade retains saved ports'
    Assert ($after.NETWORK_MODE -eq 'system') 'upgrade retains capture mode'
    # A broken proxy must leave a usable dashboard so the user can read logs
    # and repair settings. Exercise the actual task and failed Windows core.
    $savedConfig = [IO.File]::ReadAllText("$HomeDir\config.json",$Utf8)
    try {
        & "$HomeDir\runtime\node\node.exe" "$HomeDir\windows\helper.js" control $HomeDir shutdown
        Assert ($LASTEXITCODE -eq 0) 'worker stops before the failed-start recovery test'
        $broken = $savedConfig | ConvertFrom-Json
        $broken.inbounds[0].listen_port = -1
        Write-Utf8 "$HomeDir\config.json" ($broken | ConvertTo-Json -Depth 40)
        & "$HomeDir\windows\platform.ps1" -Action worker-start -HomeDir $HomeDir
        $failure = $null
        for ($attempt=0; $attempt -lt 40; $attempt++) {
            Start-Sleep -Milliseconds 500
            try { $failure=Read-JsonFile "$HomeDir\runtime\service.json" } catch {}
            if ($failure.coreError) { break }
        }
        Assert ([bool]$failure.coreError -and !$failure.corePid) 'failed native core records an error without a running proxy'
        Assert ((Invoke-WebRequest -UseBasicParsing -Uri "$url/enana/admin/" -TimeoutSec 30).StatusCode -eq 200) 'dashboard remains available after proxy startup fails'
        Assert ((Get-Content "$HomeDir\worker.log" -Raw) -match 'core.failed') 'scheduled task failure is available in the startup log'
    } finally { Write-Utf8 "$HomeDir\config.json" $savedConfig }
    & "$HomeDir\runtime\node\node.exe" "$HomeDir\windows\helper.js" control $HomeDir start
    Assert ($LASTEXITCODE -eq 0) 'restored configuration can start through the surviving worker'
    $recovered = Read-JsonFile "$HomeDir\runtime\service.json"
    Assert ($recovered.corePid -and !$recovered.coreError) 'successful recovery clears the previous startup error'
    $consoleOutput = (& "$HomeDir\windows\cli.ps1" | Out-String)
    Assert ($consoleOutput -match 'sing-box') 'redirected no-argument CLI prints shared terminal status'
    & "$HomeDir\windows\diagnostics.ps1" -HomeDir $HomeDir
    # Exercise native proxy restoration in finally, so the CI host is restored
    # even when an assertion fails. No external traffic is sent in this section.
    & "$repo\windows\platform.ps1" -Action sysproxy-on -HomeDir $HomeDir
    try{
        & "$repo\windows\platform.ps1" -Action sysproxy-ok -HomeDir $HomeDir
        Assert ($LASTEXITCODE -eq 0) 'WinINet user proxy points to the owned mixed listener'
    }finally{& "$repo\windows\platform.ps1" -Action sysproxy-off -HomeDir $HomeDir}
    # A foreign proxy edited while enana is running belongs to the user.
    # Capture the baseline, exercise the conflict, then restore that baseline.
    . "$repo\windows\platform.ps1" -Action version -HomeDir $HomeDir | Out-Null
    $baseline=(Get-ProxySnapshot|ConvertTo-Json -Depth 8|ConvertFrom-Json)
    try{
        & "$repo\windows\platform.ps1" -Action sysproxy-on -HomeDir $HomeDir
        $blob=(Get-ItemProperty -LiteralPath $connectionKey).DefaultConnectionSettings
        if($blob.Length -ge 8){$blob[4]=($blob[4]+1)%256;Set-ItemProperty -LiteralPath $connectionKey -Name DefaultConnectionSettings -Value $blob}
        & "$repo\windows\platform.ps1" -Action sysproxy-off -HomeDir $HomeDir
        Assert (!(Test-Path -LiteralPath "$HomeDir\windows-proxy-backup.json")) 'OS connection bookkeeping does not prevent owned proxy restoration'
        & "$repo\windows\platform.ps1" -Action sysproxy-on -HomeDir $HomeDir
        Set-ItemProperty -LiteralPath $proxyKey -Name ProxyServer -Value 'http=127.0.0.1:32109;https=127.0.0.1:32109'
        & "$repo\windows\platform.ps1" -Action sysproxy-off -HomeDir $HomeDir
        Assert ((Get-ItemProperty -LiteralPath $proxyKey).ProxyServer -like '*32109*') 'foreign proxy edits are retained on disconnect'
    }finally{Restore-ProxySnapshot $baseline;Remove-Item -LiteralPath "$HomeDir\windows-proxy-backup.json" -ErrorAction SilentlyContinue}
    & "$HomeDir\runtime\node\node.exe" --test "$repo\tests\windows-helper.test.js";Assert ($LASTEXITCODE -eq 0) 'Windows node helper regressions pass natively'
    Invoke-EnanaBash $HomeDir "$repo\tests\windows-routing.sh" @()
    Invoke-EnanaBash $HomeDir "$HomeDir\enana" @('doctor')
    & "$HomeDir\runtime\node\node.exe" "$HomeDir\windows\helper.js" control $HomeDir shutdown
    Assert ($LASTEXITCODE -eq 0) 'owned worker and core stop cleanly'
    for($i=0;$i -lt 50 -and (Get-ScheduledTask -TaskName $taskName).State -eq 'Running';$i++){Start-Sleep -Milliseconds 100}
    Assert ((Get-ScheduledTask -TaskName $taskName).State -ne 'Running') 'task finishes after worker shutdown instead of leaving a launcher running'
    Assert ((Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult -eq 0) 'clean worker shutdown gives the scheduler a successful exit code'
    # A detached API job may outlive its supervisor. Cleanup must release its
    # private executable while retaining an unrelated process outside HomeDir.
    $orphan=Start-Process -FilePath "$HomeDir\runtime\node\node.exe" -ArgumentList '-e','setTimeout(()=>{},120000)' -WindowStyle Hidden -PassThru
    $foreign=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList '-NoProfile','-Command','Start-Sleep 120' -WindowStyle Hidden -PassThru
    try{
        & "$HomeDir\windows\cli.ps1" -Arguments @('uninstall','--yes')
        $orphan.Refresh();$foreign.Refresh()
        Assert $orphan.HasExited 'uninstall stops detached processes in its private runtime'
        Assert (!$foreign.HasExited) 'uninstall retains unrelated processes outside its runtime'
    }finally{if(!$foreign.HasExited){$foreign.Kill()};if(!$orphan.HasExited){$orphan.Kill()}}
    Assert (!(Test-Path -LiteralPath $HomeDir)) 'native uninstall removes the private runtime after Bash exits'
    Write-Host 'Native acceptance completed. Interactive UAC/TUN and native-app OAuth require separate on-device acceptance.'
} finally {
    if(Test-Path -LiteralPath "$HomeDir\windows\platform.ps1"){
        & "$HomeDir\windows\platform.ps1" -Action sysproxy-off -HomeDir $HomeDir
        if(Test-Path -LiteralPath "$HomeDir\runtime\node\node.exe"){& "$HomeDir\runtime\node\node.exe" "$HomeDir\windows\helper.js" control $HomeDir shutdown}
        & "$HomeDir\windows\platform.ps1" -Action worker-remove -HomeDir $HomeDir
    }
    [Environment]::SetEnvironmentVariable('Path',$oldPath,'User')
}
