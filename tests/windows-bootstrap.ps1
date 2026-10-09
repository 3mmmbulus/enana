# Native release acceptance: exercise the published PowerShell entry from a
# Restricted child shell, with a private home and cleanup of only owned state.
param([string]$HomeDir = (Join-Path $env:TEMP 'enana-download-acceptance'))
$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'
$repo=Split-Path $PSScriptRoot -Parent
$version=[IO.File]::ReadAllText("$repo\VERSION").Trim()
$oldPath=[Environment]::GetEnvironmentVariable('Path','User')
$work=Join-Path $env:TEMP ('enana-bootstrap-test-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($work)|Out-Null
try{
    # The release is uploaded after the tag is pushed: wait (up to 10 minutes) until the published version matches this checkout.
    $deadline=(Get-Date).AddMinutes(10)
    while($true){
        try{ $manifest=Invoke-RestMethod -Uri 'https://install.enana.cc/dl/windows-manifest.json' -TimeoutSec 30; if($manifest.version -eq $version){break} } catch { Write-Host "manifest not ready: $($_.Exception.Message)" }
        if((Get-Date) -gt $deadline){break}
        Start-Sleep -Seconds 20
    }
    if($manifest.platform -ne 'windows' -or $manifest.version -ne $version){throw 'Published Windows version does not match this checkout'}
    $bootstrap=Join-Path $work 'get.ps1'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://install.enana.cc/get.ps1' -OutFile $bootstrap -TimeoutSec 30
    if((Get-FileHash $bootstrap).Hash -ne (Get-FileHash "$repo\get.ps1").Hash){throw 'Published installer does not match reviewed source'}
    $env:ENANA_WINDOWS_HOME=$HomeDir; $env:ENANA_BOOTSTRAP_ACCEPTANCE_SOURCE=$bootstrap; $env:ENANA_BOOTSTRAP_ACCEPTANCE_VERSION=$version
    # Exercise the documented no-argument irm | iex command. Passing -Lang en
    # to a scriptblock hides default-parameter validation failures in iex.
    # Each policy runs in a fresh child; the second run also checks reinstall.
    # EncodedCommand avoids PS 5.1 native nested-quote rewriting.
    $code=@'
$ErrorActionPreference='Stop'
if((Get-ExecutionPolicy) -ne $env:ENANA_BOOTSTRAP_ACCEPTANCE_POLICY){throw 'Wrong child execution policy'}
irm https://install.enana.cc/get.ps1 | iex
if([IO.File]::ReadAllText((Join-Path $env:ENANA_WINDOWS_HOME 'VERSION')).Trim() -ne $env:ENANA_BOOTSTRAP_ACCEPTANCE_VERSION){throw 'Wrong installed version'}
'@
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    foreach($policy in @('Restricted','Bypass')){
        $env:ENANA_BOOTSTRAP_ACCEPTANCE_POLICY=$policy
        & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy $policy -EncodedCommand $encoded
        if($LASTEXITCODE -ne 0){throw "Official no-argument bootstrap failed in a $policy shell"}
        Write-Host "PASS: documented irm | iex command completes in a $policy shell"
    }
    . "$repo\windows\common.ps1"
    $s=Read-EnanaSettings $HomeDir
    $response=Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$($s.API_PORT)/enana/admin/" -TimeoutSec 20
    if($response.StatusCode -ne 200){throw 'Downloaded installation did not start the dashboard'}
    & "$HomeDir\sing-box.exe" check -c "$HomeDir\config.json"
    if($LASTEXITCODE -ne 0){throw 'Downloaded installation configuration is invalid'}
    Write-Host 'PASS: official HTTPS bootstrap installs and reinstalls with no language argument, and starts the dashboard'
    & "$HomeDir\windows\cli.ps1" -Arguments @('uninstall','--yes')
    if(Test-Path -LiteralPath $HomeDir){throw 'Downloaded installation did not uninstall'}
    Write-Host 'PASS: downloaded installation uninstalls its owned runtime and task'
}finally{
    if(Test-Path -LiteralPath "$HomeDir\windows\platform.ps1"){
        & "$HomeDir\windows\platform.ps1" -Action sysproxy-off -HomeDir $HomeDir
        if(Test-Path -LiteralPath "$HomeDir\runtime\node\node.exe"){& "$HomeDir\runtime\node\node.exe" "$HomeDir\windows\helper.js" control $HomeDir shutdown}
        & "$HomeDir\windows\platform.ps1" -Action worker-remove -HomeDir $HomeDir
    }
    [Environment]::SetEnvironmentVariable('Path',$oldPath,'User')
    Remove-Item -LiteralPath $work -Recurse -Force
    Remove-Item Env:\ENANA_WINDOWS_HOME,Env:\ENANA_BOOTSTRAP_ACCEPTANCE_SOURCE,Env:\ENANA_BOOTSTRAP_ACCEPTANCE_VERSION,Env:\ENANA_BOOTSTRAP_ACCEPTANCE_POLICY -ErrorAction SilentlyContinue
}
