param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
. "$PSScriptRoot\common.ps1"
$HomeDir = Split-Path $PSScriptRoot -Parent
if (!$Arguments -or $Arguments.Count -eq 0) {
    $settings=Read-EnanaSettings $HomeDir
    Start-Process "http://127.0.0.1:$($settings.API_PORT)/enana/admin/"; exit 0
}
Invoke-EnanaBash $HomeDir (Join-Path $HomeDir 'enana') $Arguments
$plan=Join-Path $HomeDir '.windows-uninstall'
if(Test-Path -LiteralPath $plan){
    $keep=[IO.File]::ReadAllText($plan,$Utf8).Trim();if($keep -notin @('','keep')){throw 'Invalid uninstall plan'}
    Assert-NoReparse $HomeDir
    if($HomeDir -eq [IO.Path]::GetPathRoot($HomeDir) -or $HomeDir -eq [Environment]::GetFolderPath('UserProfile')){throw 'Unsafe uninstall directory'}
    Remove-Item -LiteralPath $plan
    if($keep -eq 'keep'){Write-Host "enana services and command removed; data kept at $HomeDir"}
    else{
        for($attempt=1;$attempt -le 10;$attempt++){
            try{Remove-Item -LiteralPath $HomeDir -Recurse -Force;break}
            catch{if($attempt -eq 10){throw};Start-Sleep -Milliseconds 500}
        }
        Write-Host 'enana uninstalled.'
    }
}
