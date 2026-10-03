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
    $manifest=Invoke-RestMethod -Uri 'https://install.enana.cc/dl/windows-manifest.json' -TimeoutSec 30
    if($manifest.platform -ne 'windows' -or $manifest.version -ne $version){throw 'Published Windows version does not match this checkout'}
    $bootstrap=Join-Path $work 'get.ps1'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://install.enana.cc/get.ps1' -OutFile $bootstrap -TimeoutSec 30
    if((Get-FileHash $bootstrap).Hash -ne (Get-FileHash "$repo\get.ps1").Hash){throw 'Published installer does not match reviewed source'}
    $env:ENANA_WINDOWS_HOME=$HomeDir; $env:ENANA_BOOTSTRAP_ACCEPTANCE_SOURCE=$bootstrap; $env:ENANA_BOOTSTRAP_ACCEPTANCE_VERSION=$version
    # EncodedCommand avoids PS 5.1 native nested-quote rewriting. Restricted is
    # process-scoped; the bootstrap must launch its verified installer itself.
    $code=@'
$ErrorActionPreference='Stop'
if((Get-ExecutionPolicy) -ne 'Restricted'){throw 'Expected Restricted child shell'}
& ([scriptblock]::Create([IO.File]::ReadAllText($env:ENANA_BOOTSTRAP_ACCEPTANCE_SOURCE))) -NoOpen -Lang en
if([IO.File]::ReadAllText((Join-Path $env:ENANA_WINDOWS_HOME 'VERSION')).Trim() -ne $env:ENANA_BOOTSTRAP_ACCEPTANCE_VERSION){throw 'Wrong installed version'}
'@
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Restricted -EncodedCommand $encoded
    if($LASTEXITCODE -ne 0){throw 'Official bootstrap failed in a Restricted shell'}
    . "$repo\windows\common.ps1"
    $s=Read-EnanaSettings $HomeDir
    $response=Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$($s.API_PORT)/enana/admin/" -TimeoutSec 20
    if($response.StatusCode -ne 200){throw 'Downloaded installation did not start the dashboard'}
    & "$HomeDir\sing-box.exe" check -c "$HomeDir\config.json"
    if($LASTEXITCODE -ne 0){throw 'Downloaded installation configuration is invalid'}
    Write-Host 'PASS: official HTTPS bootstrap installs and starts the dashboard from a Restricted shell'
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
    Remove-Item Env:\ENANA_WINDOWS_HOME,Env:\ENANA_BOOTSTRAP_ACCEPTANCE_SOURCE,Env:\ENANA_BOOTSTRAP_ACCEPTANCE_VERSION -ErrorAction SilentlyContinue
}
