param([Parameter(Mandatory=$true)][string]$HomeDir)
. "$PSScriptRoot\common.ps1"
$HomeDir = [IO.Path]::GetFullPath($HomeDir)
Assert-NoReparse $HomeDir
# Windows PowerShell 5.1 supplies the .NET Framework compiler/runtime already
# included with Windows. PowerShell Core cannot emit WindowsApplication EXEs.
if ($PSVersionTable.PSEdition -eq 'Core') {
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath -HomeDir $HomeDir
    if ($LASTEXITCODE -ne 0) { throw 'Could not build the background launcher.' }
    return
}
$runtime = Join-Path $HomeDir 'runtime'
[IO.Directory]::CreateDirectory($runtime) | Out-Null
$source = Join-Path $HomeDir 'windows\worker-launcher.cs'
$binary = Join-Path $runtime 'worker-launcher.exe'
$stamp = Join-Path $runtime 'worker-launcher.spec'
$hash = (Get-FileHash -LiteralPath $source).Hash
if ((Test-Path -LiteralPath $binary) -and (Test-Path -LiteralPath $stamp) -and [IO.File]::ReadAllText($stamp) -eq $hash) { return }
$next = Join-Path $runtime ('worker-launcher-'+[Guid]::NewGuid().ToString('N')+'.exe')
try {
    Add-Type -Path $source -OutputAssembly $next -OutputType WindowsApplication
    # A just-stopped task can still be releasing the launcher executable after
    # its Node child exits. Do not replace a running launcher or leave a half
    # compiled executable as the registered task action.
    for ($attempt=1; $attempt -le 20; $attempt++) {
        try { Move-Item -LiteralPath $next -Destination $binary -Force; break }
        catch { if ($attempt -eq 20) { throw }; Start-Sleep -Milliseconds 250 }
    }
    Write-Utf8 $stamp $hash
} finally { Remove-Item -LiteralPath $next -Force -ErrorAction SilentlyContinue }
