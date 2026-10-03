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
    $auth=Invoke-RestMethod -Uri "$url/api/auth/status" -Headers @{'X-Enana'='1'} -TimeoutSec 15
    Assert $auth.ok 'real Bash API responds through Windows TCP bridge'
    try{Invoke-WebRequest -UseBasicParsing -Uri "$url/api/auth/status" -TimeoutSec 15|Out-Null;throw 'Missing-header request was accepted'}catch{Assert ($_.Exception.Response.StatusCode.value__ -eq 403) 'missing X-Enana header is rejected'}
    & "$HomeDir\sing-box.exe" check -c "$HomeDir\config.json";Assert ($LASTEXITCODE -eq 0) 'native Windows sing-box validates installed configuration'
    $config=Read-JsonFile "$HomeDir\config.json";Assert (!($config.inbounds|Where-Object{$_.type -eq 'tun'})) 'fresh install defaults to System Proxy'
    Assert (@($config.route.rule_set|Where-Object{$_.path -notmatch '^[A-Za-z]:/'}).Count -eq 0) 'filesystem paths are native Windows paths'
    $portsBefore=@($s.PORT,$s.UI_PORT,$s.API_PORT,$s.SPEED_PORT) -join ','
    & "$repo\windows\install.ps1" -SourceDir $repo -HomeDir $HomeDir -NoOpen -NoRules -Upgrade -Lang en
    $after=Read-EnanaSettings $HomeDir;Assert (($portsBefore -eq (@($after.PORT,$after.UI_PORT,$after.API_PORT,$after.SPEED_PORT) -join ','))) 'upgrade retains saved ports'
    Assert ($after.NETWORK_MODE -eq 'system') 'upgrade retains capture mode'
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
        Set-ItemProperty -LiteralPath $proxyKey -Name ProxyServer -Value 'http=127.0.0.1:32109;https=127.0.0.1:32109'
        & "$repo\windows\platform.ps1" -Action sysproxy-off -HomeDir $HomeDir
        Assert ((Get-ItemProperty -LiteralPath $proxyKey).ProxyServer -like '*32109*') 'foreign proxy edits are retained on disconnect'
    }finally{Restore-ProxySnapshot $baseline;Remove-Item -LiteralPath "$HomeDir\windows-proxy-backup.json" -ErrorAction SilentlyContinue}
    & "$HomeDir\runtime\node\node.exe" --test "$repo\tests\windows-helper.test.js";Assert ($LASTEXITCODE -eq 0) 'Windows node helper regressions pass natively'
    Invoke-EnanaBash $HomeDir "$repo\tests\windows-routing.sh" @()
    Invoke-EnanaBash $HomeDir "$HomeDir\enana" @('doctor')
    & "$HomeDir\runtime\node\node.exe" "$HomeDir\windows\helper.js" control $HomeDir shutdown
    Assert ($LASTEXITCODE -eq 0) 'owned worker and core stop cleanly'
    Write-Host 'Native acceptance completed. Interactive UAC/TUN and native-app OAuth require separate on-device acceptance.'
} finally {
    if(Test-Path -LiteralPath "$HomeDir\windows\platform.ps1"){
        & "$HomeDir\windows\platform.ps1" -Action sysproxy-off -HomeDir $HomeDir
        if(Test-Path -LiteralPath "$HomeDir\runtime\node\node.exe"){& "$HomeDir\runtime\node\node.exe" "$HomeDir\windows\helper.js" control $HomeDir shutdown}
        & "$HomeDir\windows\platform.ps1" -Action worker-remove -HomeDir $HomeDir
    }
    [Environment]::SetEnvironmentVariable('Path',$oldPath,'User')
}
