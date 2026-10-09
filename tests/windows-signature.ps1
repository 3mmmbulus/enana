# Signature checks for get.ps1 (PowerShell 5.1 / 7). Extracts the verification block from get.ps1
# itself, so the tested code is exactly what the installer runs.
# Usage: pwsh -NoProfile -File tests/windows-signature.ps1 -Data <file> -Sig <der-file> [-Pub <pem>]
#        (no -Pub = use the built-in release key)
param([Parameter(Mandatory)][string]$Data, [Parameter(Mandatory)][string]$Sig, [string]$Pub = '')
$ErrorActionPreference = 'Stop'
$src = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '../get.ps1')
$start = $src.IndexOf('# ---------- release signature')
$end = $src.IndexOf('function Get-SignedWindowsManifest')
if ($start -lt 0 -or $end -lt $start) { throw 'verification block not found in get.ps1' }
. ([ScriptBlock]::Create($src.Substring($start, $end - $start)))
if ($Pub) { $env:ENANA_RELEASE_PUBKEY_FILE = $Pub }
$bytes = [IO.File]::ReadAllBytes($Data); $sig = [IO.File]::ReadAllBytes($Sig)
try { Write-Output ('RESULT:' + [bool](Test-ReleaseSignature $bytes $sig)) }
catch { Write-Output ('RESULT:THROW ' + $_.Exception.Message) }
