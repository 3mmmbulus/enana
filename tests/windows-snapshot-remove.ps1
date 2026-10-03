$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
. "$repo\windows\common.ps1"
if (!(Test-EnanaAdmin)) { throw 'This protected-snapshot test requires the administrator CI token.' }
$n=Get-Random -Minimum 1000000 -Maximum 2000000000
$sid="S-1-5-21-$n-$n-$n-12345"
$base=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'enana'
$root=Join-Path $base $sid
$foreign=Join-Path $base ($sid+'-foreign-fixture')
foreach($dir in @($root,$root+'.next',$root+'.previous',$foreign)){if(Test-Path -LiteralPath $dir){throw 'Refusing to overwrite an existing snapshot test path'}}
$baseExisted=Test-Path -LiteralPath $base
try {
    foreach($dir in @($root,$root+'.next',$root+'.previous')) {
        Set-PrivateDirectory $dir $sid -ReadOnlyUser
        Write-Utf8 (Join-Path $dir 'private-fixture.txt') 'placeholder configuration, certificate or cache'
    }
    [IO.Directory]::CreateDirectory($foreign)|Out-Null
    Write-Utf8 "$foreign\sentinel" 'retain unrelated user snapshot'
    if(Get-ScheduledTask -TaskName "Enana Enhanced $sid" -ErrorAction SilentlyContinue){throw 'Unexpected fixture task already exists'}
    & "$repo\windows\tun.ps1" -Action remove -Sid $sid
    if($LASTEXITCODE -ne 0){throw 'Protected snapshot cleanup failed'}
    foreach($dir in @($root,$root+'.next',$root+'.previous')) { if(Test-Path -LiteralPath $dir){throw 'An orphaned protected snapshot remained'} }
    if(!(Test-Path -LiteralPath "$foreign\sentinel")){throw 'Cleanup removed another user snapshot'}
    Write-Host 'PASS: protected orphan/current/next/previous snapshots are removed without a task; unrelated snapshot retained'
} finally {
    foreach($dir in @($root,$root+'.next',$root+'.previous',$foreign)){if(Test-Path -LiteralPath $dir){Remove-Item -LiteralPath $dir -Recurse -Force}}
    if(!$baseExisted -and (Test-Path -LiteralPath $base) -and !(Get-ChildItem -LiteralPath $base -Force)){Remove-Item -LiteralPath $base}
}
