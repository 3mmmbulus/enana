# Test the real entry script with an isolated Bash bridge. No browser or
# installed services are touched; also runs in PowerShell on macOS.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('enana-cli-test-'+[Guid]::NewGuid().ToString('N'))
$win = Join-Path $scratch 'windows'
[IO.Directory]::CreateDirectory($win) | Out-Null
try {
    Copy-Item -LiteralPath "$repo/windows/cli.ps1" -Destination "$win/cli.ps1"
    [IO.File]::WriteAllText("$win/common.ps1", @'
$ErrorActionPreference='Stop'
function Start-Process { throw 'The CLI unexpectedly opened a browser' }
function Invoke-EnanaBash([string]$HomeDir,[string]$Script,[string[]]$Arguments) {
    [IO.File]::WriteAllText((Join-Path $HomeDir 'observed.json'),(ConvertTo-Json -InputObject @($Arguments) -Compress))
}
'@)
    & "$win/cli.ps1"
    $seen = @(Get-Content "$scratch/observed.json" -Raw | ConvertFrom-Json)
    if ($seen.Count -ne 1 -or $seen[0] -ne 'console') { throw 'No-argument CLI did not dispatch the terminal console' }
    Write-Host 'PASS: no arguments dispatch the terminal console without opening a browser'
    & "$win/cli.ps1" -Arguments @('network-mode','system')
    $seen = @(Get-Content "$scratch/observed.json" -Raw | ConvertFrom-Json)
    if ($seen.Count -ne 2 -or $seen[0] -ne 'network-mode' -or $seen[1] -ne 'system') { throw 'Explicit command arguments changed' }
    Write-Host 'PASS: explicit command arguments are preserved'
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
