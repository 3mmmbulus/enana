# enana Windows bootstrap: irm https://install.enana.cc/get.ps1 | iex
# Saved script options: -Upgrade -NoOpen -Force -Lang zh|en
param([switch]$Upgrade, [switch]$NoOpen, [switch]$Force, [ValidateSet('zh','en')][string]$Lang = '', [string]$HomeDir = '')
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ([Environment]::OSVersion.Platform -ne 'Win32NT' -or ![Environment]::Is64BitOperatingSystem -or ![Environment]::Is64BitProcess) { throw 'Use 64-bit PowerShell on Windows 10/11 (x64 or ARM64).' }
if ($PSVersionTable.PSVersion -lt [Version]'5.1') { throw 'PowerShell 5.1 or later is required.' }
if ([Environment]::OSVersion.Version.Build -lt 19041) { throw 'Windows 10 version 2004 (build 19041) or later is required.' }
if (!$HomeDir) { $HomeDir = if ($env:ENANA_WINDOWS_HOME) {$env:ENANA_WINDOWS_HOME} else {Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'enana'} }
if (!$Lang) { $Lang = if ((Get-Culture).Name -like 'zh*') {'zh'} else {'en'} }
$base = if ($env:ENANA_INSTALL_BASE) {$env:ENANA_INSTALL_BASE.TrimEnd('/')} else {'https://install.enana.cc'}
$github = 'https://github.com/3mmmbulus/enana'
if ($base -notmatch '^https://') { throw 'Install source requires HTTPS.' }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$manifests = @()
foreach ($url in @("$base/dl/windows-manifest.json","$github/releases/latest/download/windows-manifest.json")) {
    try { $m = Invoke-RestMethod -Uri $url -TimeoutSec 20; $manifests += $m } catch { Write-Verbose "Manifest source unavailable: $url" }
}
if ($manifests.Count -eq 0) { throw 'Windows release is unavailable. Check the download service and retry.' }
$m = $manifests[0]
if ($m.platform -ne 'windows' -or $m.version -notmatch '^\d+\.\d+\.\d+$' -or $m.sha256 -notmatch '^[0-9a-f]{64}$' -or $m.size -le 0 -or $m.size -gt 104857600 -or $m.url -ne "/dl/enana-$($m.version)-windows.zip") { throw 'Invalid Windows manifest; installation stopped.' }
foreach ($other in $manifests) { if ($other.platform -ne 'windows' -or $other.version -ne $m.version -or $other.sha256 -ne $m.sha256 -or $other.size -ne $m.size -or $other.url -ne $m.url) { throw 'Windows manifests disagree; installation stopped.' } }
if ($Upgrade -and !$Force -and (Test-Path -LiteralPath "$HomeDir\VERSION") -and [IO.File]::ReadAllText("$HomeDir\VERSION").Trim() -eq $m.version) { Write-Host "enana $($m.version) is already installed."; return }
$stage = Join-Path ([IO.Path]::GetTempPath()) ('enana-get-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($stage) | Out-Null
try {
    $archive = Join-Path $stage 'package.zip'; $verified=$false
    foreach ($url in @("$base$($m.url)","$github/releases/download/v$($m.version)/enana-$($m.version)-windows.zip")) {
        for ($attempt=1; $attempt -le 3; $attempt++) {
            Write-Host "Downloading enana $($m.version) for Windows (attempt $attempt/3)"
            try { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $archive -TimeoutSec 300
                if ((Get-Item -LiteralPath $archive).Length -ne $m.size -or (Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant() -ne $m.sha256) { throw 'Package failed size/SHA-256 verification' }
                $verified=$true; break
            } catch { Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue; Write-Warning $_.Exception.Message }
        }
        if ($verified) { break }
    }
    if (!$verified) { throw 'No verified Windows package could be downloaded.' }
    # No package code executes until the digest AND all ZIP paths pass.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::OpenRead($archive); $target=Join-Path $stage 'src'; $prefix=[IO.Path]::GetFullPath($target)+'\'
    try {
        $seen=@{}; [long]$total=0
        foreach ($entry in $zip.Entries) {
            $name=$entry.FullName.Replace('/','\');$dest=[IO.Path]::GetFullPath([IO.Path]::Combine($prefix,$name))
            if (!$name -or $name.StartsWith('\') -or $name.Contains(':') -or !$dest.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or $seen.ContainsKey($dest) -or ($entry.ExternalAttributes -shr 16 -band 0xF000) -eq 0xA000) { throw 'Unsafe ZIP entry' }
            foreach ($part in $name.TrimEnd('\').Split('\')) { if (!$part -or $part -eq '.' -or $part -eq '..' -or $part -match '[. ]$|[<>"|?*\x00-\x1f]|^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\.|$)') { throw 'Unsafe ZIP path' } }
            $seen[$dest]=$true; $total+=$entry.Length;if($total -gt 268435456 -or $zip.Entries.Count -gt 10000){throw 'ZIP extraction limit exceeded'}
        }
        foreach ($entry in $zip.Entries) {
            $dest=[IO.Path]::Combine($prefix,$entry.FullName.Replace('/','\'))
            if ($entry.FullName.EndsWith('/')) {[IO.Directory]::CreateDirectory($dest)|Out-Null;continue}
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest))|Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$dest,$false)
        }
    } finally { $zip.Dispose() }
    $source=Join-Path $target "enana-$($m.version)"
    if (!(Test-Path -LiteralPath "$source\windows\install.ps1") -or [IO.File]::ReadAllText("$source\VERSION").Trim() -ne $m.version) { throw 'Package version/entry point mismatch.' }
    & "$source\windows\install.ps1" -SourceDir $source -HomeDir $HomeDir -Upgrade:$Upgrade -NoOpen:$NoOpen -Lang $Lang
} finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
