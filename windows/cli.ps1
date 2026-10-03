param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
. "$PSScriptRoot\common.ps1"
$HomeDir = Split-Path $PSScriptRoot -Parent
if (!$Arguments -or $Arguments.Count -eq 0) {
    $settings=Read-EnanaSettings $HomeDir
    Start-Process "http://127.0.0.1:$($settings.API_PORT)/enana/admin/"; exit 0
}
Invoke-EnanaBash $HomeDir (Join-Path $HomeDir 'enana') $Arguments
