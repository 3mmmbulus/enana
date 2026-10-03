# Windows PowerShell 5.1 compatible. ASCII source avoids its BOM-less UTF-8 trap.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue' # Keep explicit stages; PS 5.1 web progress is very slow.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$Utf8 = New-Object System.Text.UTF8Encoding($false)
function Read-JsonFile([string]$Path) { return ([IO.File]::ReadAllText($Path, $Utf8) | ConvertFrom-Json) }
function Write-Utf8([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, $Utf8) }
function Get-EnanaSid { return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
function Test-EnanaAdmin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Assert-NoReparse([string]$Path) {
    $p = [IO.Path]::GetFullPath($Path)
    while ($p) {
        if (Test-Path -LiteralPath $p) {
            if ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point is not allowed: $p" }
        }
        $p = [IO.Path]::GetDirectoryName($p)
    }
}
function Set-PrivateDirectory([string]$Path, [string]$Sid = (Get-EnanaSid), [switch]$ReadOnlyUser) {
    Assert-NoReparse $Path
    [IO.Directory]::CreateDirectory($Path) | Out-Null
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier($(if ($ReadOnlyUser) {'S-1-5-32-544'} else {$Sid}))))
    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    foreach ($id in @('S-1-5-18','S-1-5-32-544',$Sid) | Select-Object -Unique) {
        $rights = if ($ReadOnlyUser -and $id -eq $Sid) {'ReadAndExecute'} else {'FullControl'}
        $rule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($id)), $rights, $inherit, 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Expand-SafeZip([string]$Archive, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Assert-NoReparse $Destination
    $root = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $seen = @{}; [long]$total = 0
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('/', '\')
            if (!$name -or $name.StartsWith('\') -or $name.Contains(':') -or ($entry.ExternalAttributes -shr 16 -band 0xF000) -eq 0xA000) { throw 'Unsafe ZIP entry' }
            foreach ($part in $name.TrimEnd('\').Split('\')) {
                if (!$part -or $part -eq '.' -or $part -eq '..' -or $part -match '[. ]$|[<>"|?*\x00-\x1f]' -or $part -match '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\.|$)') { throw 'Unsafe ZIP path' }
            }
            $dest = [IO.Path]::GetFullPath([IO.Path]::Combine($root, $name))
            if (!$dest.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or $seen.ContainsKey($dest)) { throw 'Duplicate or escaping ZIP entry' }
            $seen[$dest] = $true; $total += $entry.Length
            if ($total -gt 1073741824 -or $zip.Entries.Count -gt 30000) { throw 'ZIP extraction limit exceeded' }
        }
        foreach ($entry in $zip.Entries) {
            $dest = [IO.Path]::Combine($root, $entry.FullName.Replace('/', '\'))
            if ($entry.FullName.EndsWith('/')) { [IO.Directory]::CreateDirectory($dest) | Out-Null; continue }
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest)) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $false)
        }
    } finally { $zip.Dispose() }
}
function Get-VerifiedDownload([string[]]$Urls, [string]$Path, [string]$Sha256, [long]$Size = 0) {
    if ($Sha256 -notmatch '^[0-9a-f]{64}$') { throw 'Missing or invalid SHA-256 pin' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    foreach ($url in $Urls) {
        if ($url -notmatch '^https://') { throw 'Downloads require HTTPS' }
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            Write-Host "Downloading $([IO.Path]::GetFileName($url)) (attempt $attempt/3)"
            try {
                Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $Path -TimeoutSec 300
                if ($Size -gt 0 -and (Get-Item -LiteralPath $Path).Length -ne $Size) { throw 'Downloaded size mismatch' }
                if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Sha256) { throw 'SHA-256 mismatch' }
                return
            } catch {
                Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
                if ($attempt -eq 3) { Write-Warning "Download failed: $($_.Exception.Message)" } else { Start-Sleep -Seconds $attempt }
            }
        }
    }
    throw 'Every download source failed; no unverified file was installed.'
}
function Read-EnanaSettings([string]$HomeDir) {
    $values = @{PORT='7890'; UI_PORT='9090'; API_PORT='9091'; SPEED_PORT='7892'; NETWORK_MODE='system'; AUTOSTART='1'}
    $file = Join-Path $HomeDir 'settings.env'
    if (Test-Path -LiteralPath $file) {
        foreach ($line in [IO.File]::ReadAllLines($file, $Utf8)) {
            if ($line -match '^([A-Z_]+)=(.*)$') { $values[$Matches[1]] = $Matches[2] }
        }
    }
    return $values
}
function Set-EnanaEnvironment([string]$HomeDir) {
    $env:ENANA_WINDOWS_HOME = $HomeDir
    $env:ENANA_API_PIPE = '1'
    $env:ENANA_WINDOWS_SID = Get-EnanaSid
    $env:ENANA_WINDOWS_ARCH = if (($env:PROCESSOR_ARCHITEW6432,$env:PROCESSOR_ARCHITECTURE) -contains 'ARM64') {'arm64'} else {'amd64'}
    $git = Join-Path $HomeDir 'runtime\git'
    $env:PATH = "$HomeDir\runtime\node;$git\usr\bin;$git\ucrt64\bin;$git\mingw64\bin;$git\mingw32\bin;$git\clangarm64\bin;$env:PATH"
    $bash = Join-Path $git 'bin\bash.exe'
    $env:ENANA_HOME = (& (Join-Path $git 'usr\bin\cygpath.exe') -u $HomeDir).Trim()
    return $bash
}
function Invoke-EnanaBash([string]$HomeDir, [string]$Script, [string[]]$Arguments) {
    $bash = Set-EnanaEnvironment $HomeDir
    $posix = (& (Join-Path $HomeDir 'runtime\git\usr\bin\cygpath.exe') -u $Script).Trim()
    & $bash $posix @Arguments
    if ($LASTEXITCODE -ne 0) { throw "enana command failed (exit $LASTEXITCODE)." }
}
