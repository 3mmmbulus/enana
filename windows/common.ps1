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
    # PowerShell's filesystem provider reapplies the complete security
    # descriptor, including audit sections. An ordinary user has no
    # SeSecurityPrivilege. Persist only the access/owner sections modified
    # above through .NET; never read, clear or replace the directory's SACL.
    $directory = New-Object IO.DirectoryInfo($Path)
    if ($PSVersionTable.PSEdition -eq 'Core') {
        [IO.FileSystemAclExtensions]::SetAccessControl($directory, $acl)
    } else {
        $directory.SetAccessControl($acl)
    }
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
    $env:ENANA_WINDOWS_PROGRAMDATA = [Environment]::GetFolderPath('CommonApplicationData')
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
function Stop-EnanaRuntime([string]$HomeDir) {
    # Detached Bash jobs can outlive their API parent. After the command/worker
    # exits, release this installation's private runtime before replacement or
    # removal. Never kill by process name or a caller-supplied PID alone.
    Assert-NoReparse $HomeDir
    $root=[IO.Path]::GetFullPath($HomeDir).TrimEnd('\')
    if(!$root -or $root -eq [IO.Path]::GetPathRoot($root).TrimEnd('\') -or $root -eq [Environment]::GetFolderPath('UserProfile')){throw 'Unsafe runtime directory'}
    $prefix=$root+'\runtime\'; $core=$root+'\sing-box.exe'; $ownerSid=Get-EnanaSid
    for($attempt=0;$attempt -lt 20;$attempt++){
        $owned=@(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            $_.ProcessId -ne $PID -and $_.ExecutablePath -and
            ($_.ExecutablePath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or $_.ExecutablePath -eq $core)
        } | Where-Object {
            (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid -ErrorAction SilentlyContinue).Sid -eq $ownerSid
        })
        if(!$owned.Count){return}
        foreach($proc in $owned){
            # Recheck identity before terminating a tree; PID reuse must not
            # make an unrelated program eligible for runtime cleanup.
            $fresh=Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.ProcessId)" -ErrorAction SilentlyContinue
            if($fresh -and $fresh.CreationDate -eq $proc.CreationDate -and $fresh.ExecutablePath -eq $proc.ExecutablePath -and
                (Invoke-CimMethod -InputObject $fresh -MethodName GetOwnerSid -ErrorAction SilentlyContinue).Sid -eq $ownerSid){
                # A child can exit between the recheck and taskkill. Retry
                # only still-owned processes; a persistent failure retains
                # the files and reports an error after the bounded wait.
                try{& "$env:SystemRoot\System32\taskkill.exe" /PID $proc.ProcessId /T /F 2>$null | Out-Null}catch{}
            }
        }
        Start-Sleep -Milliseconds 250
    }
    throw 'Private enana runtime processes did not stop; files were retained.'
}
# ---- Snapshot configuration checks, run by the elevated tun.ps1 before
# sing-box runs the snapshot as SYSTEM. sing-box decodes JSON like Go
# encoding/json: a key with no exact field match still matches a field
# case-insensitively, where ASCII letters fold together, U+212A KELVIN SIGN
# folds to k and U+017F LATIN SMALL LETTER LONG S folds to s (no other
# non-ASCII character folds to an ASCII letter), and of two spellings in one
# object the later one wins. PowerShell member access ignores ASCII case only,
# so a decoy "listen" next to a U+017F spelling of it would show the checks one
# value and sing-box the other. Every check therefore runs on a copy with
# folded keys (as fold_key / fold_doc in lib/enhanced-root.sh), an object whose
# keys collide after folding is refused, and the copy is read with exact
# ordinal comparisons (-eq and -ceq compare strings culture-aware).
function ConvertTo-FoldedKey([string]$Name) {
    $chars = $Name.ToCharArray()
    for ($i = 0; $i -lt $chars.Length; $i++) {
        $code = [int]$chars[$i] # integer code points: comparisons of [char] ignore case
        if ($code -ge 0x41 -and $code -le 0x5A) { $chars[$i] = [char]($code + 0x20) }
        elseif ($code -eq 0x212A) { $chars[$i] = [char]0x6B }
        elseif ($code -eq 0x017F) { $chars[$i] = [char]0x73 }
    }
    return (-join $chars)
}
function ConvertTo-FoldedConfig($Node) {
    if ($null -eq $Node -or $Node -is [string] -or $Node -is [ValueType]) { return $Node }
    if ($Node -is [Array]) {
        $copy = New-Object 'object[]' $Node.Count
        for ($i = 0; $i -lt $Node.Count; $i++) { $copy[$i] = ConvertTo-FoldedConfig $Node[$i] }
        return ,$copy # the comma keeps PowerShell from unrolling the array
    }
    if ($Node -isnot [System.Management.Automation.PSCustomObject]) { throw 'Unsupported value in snapshot configuration' }
    $copy = New-Object PSObject
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($property in $Node.PSObject.Properties) {
        $name = ConvertTo-FoldedKey $property.Name
        if (!$seen.Add($name)) { throw "Snapshot configuration has two '$name' keys after case folding" }
        $copy.PSObject.Properties.Add([System.Management.Automation.PSNoteProperty]::new($name, (ConvertTo-FoldedConfig $property.Value)))
    }
    return $copy
}
function Get-ConfigMember($Object, [string]$Name) {
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        foreach ($property in $Object.PSObject.Properties) {
            if ([string]::Equals($property.Name, $Name, [StringComparison]::Ordinal)) { return ,$property.Value }
        }
    }
    return $null
}
function Test-ConfigText($Value, [string]$Text) {
    return ($Value -is [string] -and [string]::Equals($Value, $Text, [StringComparison]::Ordinal))
}
function Test-SnapshotPath($Value, [string]$Root) {
    # $Root: the protected snapshot directory, absolute, no trailing backslash.
    if ($Value -isnot [string] -or $Root -notmatch '^[A-Za-z]:\\[^\\]') { return $false }
    try { $full = [IO.Path]::GetFullPath($Value) } catch { return $false }
    return $full.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)
}
function Assert-ConfigPaths($Object, [string]$Root) {
    # $Object is a folded copy (ConvertTo-FoldedConfig). File keys are output,
    # directory, data_directory and names ending in _path, _file, _dir or
    # _directory; path is a file key only inside a local or hosts object (a
    # local rule set, a hosts DNS server), as in lib/enhanced-root.sh.
    # Elsewhere path is a URL path (a WebSocket transport, a DNS-over-HTTPS
    # server, which every default configuration has), not a file; treating it
    # as one refused every such snapshot. experimental.cache_file.path is
    # checked by Assert-TunConfig.
    if ($Object -is [Array]) {
        foreach ($item in $Object) { Assert-ConfigPaths $item $Root }
        return
    }
    if ($Object -isnot [System.Management.Automation.PSCustomObject]) { return }
    $type = Get-ConfigMember $Object 'type'
    $fileType = (Test-ConfigText $type 'local') -or (Test-ConfigText $type 'hosts')
    foreach ($property in $Object.PSObject.Properties) {
        $name = $property.Name; $value = $property.Value
        if ($name -cmatch '^external_ui\z') { throw 'Snapshot must not serve external UI files' }
        if ($name -cmatch '^(?:output|directory|data_directory)\z|_(?:path|file|dir|directory)\z' -or ($fileType -and $name -cmatch '^path\z')) {
            if ($value -is [System.Management.Automation.PSCustomObject]) { Assert-ConfigPaths $value $Root; continue } # e.g. cache_file
            # sing-box takes a string or a list for many file keys (hosts path,
            # client_certificate_path, certificate_directory_path, ...).
            if ($value -isnot [string] -and $value -isnot [Array]) { throw "Config file key '$name' is not a path" }
            foreach ($path in @($value)) { if (!(Test-SnapshotPath $path $Root)) { throw 'Config path escapes protected snapshot' } }
        } else { Assert-ConfigPaths $value $Root }
    }
}
function Assert-TunConfig($Config, [string]$Root) {
    # Returns the folded copy that passed every check.
    $c = ConvertTo-FoldedConfig $Config
    $inbounds = Get-ConfigMember $c 'inbounds'
    $route = Get-ConfigMember $c 'route'
    $hasTun = $false
    foreach ($inbound in $inbounds) { if (Test-ConfigText (Get-ConfigMember $inbound 'type') 'tun') { $hasTun = $true } }
    if (!$hasTun -or !(Get-ConfigMember $route 'auto_detect_interface')) { throw 'Not a TUN configuration' }
    $controller = Get-ConfigMember (Get-ConfigMember (Get-ConfigMember $c 'experimental') 'clash_api') 'external_controller'
    $exposed = !($controller -is [string] -and $controller -cmatch '^127\.0\.0\.1:\d+$')
    foreach ($inbound in $inbounds) {
        if (!(Test-ConfigText (Get-ConfigMember $inbound 'type') 'tun') -and !(Test-ConfigText (Get-ConfigMember $inbound 'listen') '127.0.0.1')) { $exposed = $true }
    }
    if ($exposed) { throw 'Snapshot must only expose loopback listeners' }
    # enana generates only tun and loopback mixed inbounds. Any other type is
    # refused even on 127.0.0.1: a hysteria2 masquerade, for example, makes the
    # SYSTEM core serve a directory as a file server.
    if ($inbounds -isnot [Array]) { throw 'Snapshot inbounds must be tun or loopback mixed' }
    foreach ($inbound in $inbounds) {
        $type = Get-ConfigMember $inbound 'type'
        if (!(Test-ConfigText $type 'tun') -and !(Test-ConfigText $type 'mixed')) { throw 'Snapshot inbounds must be tun or loopback mixed' }
    }
    $ruleSets = Get-ConfigMember $route 'rule_set'
    foreach ($ruleSet in $ruleSets) {
        if (!(Test-ConfigText (Get-ConfigMember $ruleSet 'type') 'local') -or !(Test-SnapshotPath (Get-ConfigMember $ruleSet 'path') $Root)) { throw 'Rule file escapes protected snapshot' }
    }
    # cache_file has no type, so Assert-ConfigPaths does not see its path as a file key.
    $cacheFile = Get-ConfigMember (Get-ConfigMember $c 'experimental') 'cache_file'
    $cachePath = Get-ConfigMember $cacheFile 'path'
    if ($null -ne $cachePath -and !(Test-SnapshotPath $cachePath $Root)) { throw 'Config path escapes protected snapshot' }
    Assert-ConfigPaths $c $Root
    return $c
}
