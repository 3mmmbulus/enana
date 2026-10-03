param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
. "$PSScriptRoot\common.ps1"
$HomeDir = Split-Path $PSScriptRoot -Parent
if (!$Arguments -or $Arguments.Count -eq 0) {
    # Use the shared terminal console, including its stopped-service status
    # and restart/diagnostics actions. A browser alone cannot recover a worker
    # that failed to start. The console falls back to status when redirected.
    $Arguments = @('console')
}
if ($Arguments[0] -eq 'doctor') {
    & "$PSScriptRoot\diagnostics.ps1" -HomeDir $HomeDir
    if (!(Test-Path -LiteralPath "$HomeDir\runtime\git\bin\bash.exe") -or !(Test-Path -LiteralPath "$HomeDir\runtime\git\usr\bin\cygpath.exe")) {
        Write-Warning 'Private Bash runtime is incomplete. Run the official installer again to repair it.'
        exit 1
    }
}
Invoke-EnanaBash $HomeDir (Join-Path $HomeDir 'enana') $Arguments
$plan=Join-Path $HomeDir '.windows-uninstall'
if(Test-Path -LiteralPath $plan){
    if([IO.File]::ReadAllText($plan,$Utf8).Trim() -ne ''){throw 'Invalid uninstall plan: full removal is required'}
    Assert-NoReparse $HomeDir
    if($HomeDir -eq [IO.Path]::GetPathRoot($HomeDir) -or $HomeDir -eq [Environment]::GetFolderPath('UserProfile')){throw 'Unsafe uninstall directory'}
    Stop-EnanaRuntime $HomeDir
    Remove-Item -LiteralPath $plan
    for($attempt=1;$attempt -le 10;$attempt++){
        try{Remove-Item -LiteralPath $HomeDir -Recurse -Force;break}
        catch{if($attempt -eq 10){throw};Start-Sleep -Milliseconds 500}
    }
    Write-Host 'enana fully uninstalled. All local installation data removed.'
}
