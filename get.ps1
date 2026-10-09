# enana Windows bootstrap: irm https://install.enana.cc/get.ps1 | iex
# Saved script options: -Upgrade -NoOpen -Force -Lang auto|zh|en
# Invoke-Expression validates defaults too: an empty Lang outside ValidateSet
# fails before any download. Keep auto valid, then resolve the user's culture.
param([switch]$Upgrade, [switch]$NoOpen, [switch]$Force, [ValidateSet('auto','zh','en')][string]$Lang = 'auto', [string]$HomeDir = '')
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ([Environment]::OSVersion.Platform -ne 'Win32NT' -or ![Environment]::Is64BitOperatingSystem -or ![Environment]::Is64BitProcess) { throw 'Use 64-bit PowerShell on Windows 10/11 (x64 or ARM64).' }
if ($PSVersionTable.PSVersion -lt [Version]'5.1') { throw 'PowerShell 5.1 or later is required.' }
if ([Environment]::OSVersion.Version.Build -lt 19041) { throw 'Windows 10 version 2004 (build 19041) or later is required.' }
if (!$HomeDir) { $HomeDir = if ($env:ENANA_WINDOWS_HOME) {$env:ENANA_WINDOWS_HOME} else {Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'enana'} }
if ($Lang -eq 'auto') { $Lang = if ((Get-Culture).Name -like 'zh*') {'zh'} else {'en'} }
$base = if ($env:ENANA_INSTALL_BASE) {$env:ENANA_INSTALL_BASE.TrimEnd('/')} else {'https://install.enana.cc'}
$github = 'https://github.com/3mmmbulus/enana'
if ($base -notmatch '^https://') { throw 'Install source requires HTTPS.' }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
# ---------- release signature (ECDSA P-256; the same key and format as tools/sign-release.sh) ----------
# The release manifest is trusted only if its signature verifies with this public key.
# ENANA_RELEASE_PUBKEY_FILE overrides the key for tests only; a normal install never sets it.
$ReleasePublicKeyPem = @'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE4dmCCdutTP+gEoaT413bGYJWib/0
olPxbogWv3Z5lftak+4Mndh9O5PWbWzDR3QyArxxFc0NQzqOBR8o20HsJQ==
-----END PUBLIC KEY-----
'@
function Get-ReleasePublicKeyPem {
    if ($env:ENANA_RELEASE_PUBKEY_FILE) { return [IO.File]::ReadAllText($env:ENANA_RELEASE_PUBKEY_FILE) }
    return $ReleasePublicKeyPem
}
function Find-ByteSequence([byte[]]$haystack, [byte[]]$needle) {
    for ($i = 0; $i -le $haystack.Length - $needle.Length; $i++) {
        $match = $true
        for ($j = 0; $j -lt $needle.Length; $j++) { if ($haystack[$i + $j] -ne $needle[$j]) { $match = $false; break } }
        if ($match) { return $true }
    }
    return $false
}
function Get-ReleasePublicPoint([string]$pem) {
    # SubjectPublicKeyInfo for P-256: ecPublicKey + prime256v1 OIDs, then BIT STRING 00 04 X Y (last 65 bytes).
    $b64 = (($pem -split "`r?`n") | Where-Object { $_ -and $_ -notmatch '^-----' }) -join ''
    $der = [Convert]::FromBase64String($b64); $n = $der.Length
    $ecPublicKey = [byte[]](0x06,0x07,0x2A,0x86,0x48,0xCE,0x3D,0x02,0x01)
    $prime256v1 = [byte[]](0x06,0x08,0x2A,0x86,0x48,0xCE,0x3D,0x03,0x01,0x07)
    if ($n -lt 91 -or $der[$n-66] -ne 0x00 -or $der[$n-65] -ne 0x04 -or !(Find-ByteSequence $der $ecPublicKey) -or !(Find-ByteSequence $der $prime256v1)) {
        throw 'Unsupported release public key (expected an uncompressed P-256 key).'
    }
    $x = New-Object byte[] 32; $y = New-Object byte[] 32
    [Array]::Copy($der, $n-64, $x, 0, 32); [Array]::Copy($der, $n-32, $y, 0, 32)
    return @{ X = $x; Y = $y }
}
function ConvertFrom-DerEcdsaSignature([byte[]]$der) {
    # SEQUENCE { INTEGER r, INTEGER s } -> IEEE P1363 (r || s, 32 bytes each), the format .NET expects.
    if ($der.Length -lt 8 -or $der[0] -ne 0x30 -or $der[1] -gt 0x7f) { throw 'Bad signature encoding.' }
    $pos = 2; $out = New-Object byte[] 64
    for ($k = 0; $k -lt 2; $k++) {
        if ($der[$pos] -ne 0x02) { throw 'Bad signature encoding.' }
        $len = [int]$der[$pos + 1]; $start = $pos + 2
        if ($len -lt 1 -or $start + $len -gt $der.Length) { throw 'Bad signature encoding.' }
        $val = [byte[]]$der[$start..($start + $len - 1)]
        while ($val.Length -gt 32 -and $val[0] -eq 0) { $val = [byte[]]$val[1..($val.Length - 1)] }
        if ($val.Length -gt 32) { throw 'Bad signature encoding.' }
        [Array]::Copy($val, 0, $out, $k * 32 + (32 - $val.Length), $val.Length)
        $pos = $start + $len
    }
    return $out
}
function Test-ReleaseSignature([byte[]]$data, [byte[]]$sigDer) {
    $point = Get-ReleasePublicPoint (Get-ReleasePublicKeyPem)
    $p1363 = ConvertFrom-DerEcdsaSignature $sigDer
    if ([Environment]::OSVersion.Platform -eq 'Win32NT') {
        # Windows PowerShell 5.1 / .NET Framework: import the public point as an ECCPublicBlob (magic ECS1, cbKey=32).
        $blob = New-Object byte[] 72
        [Array]::Copy([byte[]](0x45,0x43,0x53,0x31,0x20,0x00,0x00,0x00), 0, $blob, 0, 8)
        [Array]::Copy($point.X, 0, $blob, 8, 32); [Array]::Copy($point.Y, 0, $blob, 40, 32)
        $cng = [Security.Cryptography.CngKey]::Import($blob, [Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob)
        $ecdsa = New-Object Security.Cryptography.ECDsaCng $cng
        try { $ecdsa.HashAlgorithm = [Security.Cryptography.CngAlgorithm]::Sha256; return [bool]$ecdsa.VerifyData($data, $p1363) }
        finally { $ecdsa.Dispose(); $cng.Dispose() }
    }
    # Non-Windows (PowerShell 7 / .NET Core), used by the signature tests.
    $q = New-Object Security.Cryptography.ECPoint; $q.X = $point.X; $q.Y = $point.Y
    $params = New-Object Security.Cryptography.ECParameters; $params.Curve = [Security.Cryptography.ECCurve]::CreateFromValue('1.2.840.10045.3.1.7'); $params.Q = $q
    $ecdsa = [Security.Cryptography.ECDsa]::Create($params)
    try { return [bool]$ecdsa.VerifyData($data, $p1363, [Security.Cryptography.HashAlgorithmName]::SHA256) }
    finally { $ecdsa.Dispose() }
}
function Get-SignedWindowsManifest([string]$baseUrl) {
    # Downloads manifest + signature, verifies BEFORE parsing; returns the parsed manifest or throws.
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('enana-sig-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    try {
        $mf = Join-Path $dir 'manifest.json'; $sf = Join-Path $dir 'manifest.json.sig'
        Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/windows-manifest.json" -OutFile $mf -TimeoutSec 20
        Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/windows-manifest.json.sig" -OutFile $sf -TimeoutSec 20
        $data = [IO.File]::ReadAllBytes($mf); $sig = [IO.File]::ReadAllBytes($sf)
        if (!(Test-ReleaseSignature $data $sig)) { throw "Manifest signature is invalid: $baseUrl" }
        return (ConvertFrom-Json ([Text.Encoding]::UTF8.GetString($data)))
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}
$manifests = @()
foreach ($source in @("$base/dl","$github/releases/latest/download")) {
    try { $manifests += (Get-SignedWindowsManifest $source) } catch { Write-Warning "Manifest source rejected: $($_.Exception.Message)" }
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
    # irm | iex works in a default Restricted shell, but invoking a saved .ps1
    # from that shell does not. Bypass only this verified installer process;
    # never alter the user's persistent execution policy.
    $installerArgs=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',"$source\windows\install.ps1",'-SourceDir',$source,'-HomeDir',$HomeDir,'-Lang',$Lang)
    if($Upgrade){$installerArgs+='-Upgrade'};if($NoOpen){$installerArgs+='-NoOpen'}
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @installerArgs
    if($LASTEXITCODE -ne 0){throw "Windows installation failed (exit $LASTEXITCODE)."}
    $env:Path="$(Join-Path $HomeDir 'bin');$env:Path"
} finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
