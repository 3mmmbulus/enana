param([Parameter(Mandatory=$true)][string]$Action, [Parameter(Mandatory=$true)][string]$HomeDir, [string]$Value = '')
. "$PSScriptRoot\common.ps1"
$HomeDir = [IO.Path]::GetFullPath($HomeDir)
$sid = Get-EnanaSid
$taskName = "Enana Dashboard $sid"
$root = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) "enana\$sid"
$tunName = "Enana Enhanced $sid"
$s = Read-EnanaSettings $HomeDir
$proxyKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$connectionKey = "$proxyKey\Connections"

function Initialize-WinInet {
    if ('EnanaWinInet' -as [type]) { return }
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class EnanaWinInet {
 [StructLayout(LayoutKind.Sequential)] struct Option { public int key; public IntPtr value; }
 [StructLayout(LayoutKind.Sequential)] struct List { public int size; public IntPtr connection; public int count; public int error; public IntPtr options; }
 [DllImport("wininet.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool InternetSetOption(IntPtr h, int n, IntPtr p, int size);
 [DllImport("wininet.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool InternetQueryOption(IntPtr h, int n, IntPtr p, ref int size);
 public static long Flags() {
   int optionSize=Marshal.SizeOf(typeof(Option)), length=Marshal.SizeOf(typeof(List));
   IntPtr option=Marshal.AllocHGlobal(optionSize), list=Marshal.AllocHGlobal(length);
   try {
     Marshal.StructureToPtr(new Option {key=1,value=IntPtr.Zero},option,false);
     Marshal.StructureToPtr(new List {size=length,count=1,options=option},list,false);
     if(!InternetQueryOption(IntPtr.Zero,75,list,ref length)) throw new System.ComponentModel.Win32Exception();
     return ((Option)Marshal.PtrToStructure(option,typeof(Option))).value.ToInt64();
   } finally { Marshal.FreeHGlobal(option);Marshal.FreeHGlobal(list); }
 }
 public static void Notify() {
   if (!InternetSetOption(IntPtr.Zero,39,IntPtr.Zero,0) || !InternetSetOption(IntPtr.Zero,37,IntPtr.Zero,0)) throw new System.ComponentModel.Win32Exception();
 }
 public static void Set(string server,string bypass) {
   if (IntPtr.Size!=8) throw new Exception("Use 64-bit PowerShell");
   IntPtr a=Marshal.StringToHGlobalUni(server), b=Marshal.StringToHGlobalUni(bypass);
   int size=Marshal.SizeOf(typeof(Option)); IntPtr options=Marshal.AllocHGlobal(size*3), list=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(List)));
   try {
     Marshal.StructureToPtr(new Option {key=1,value=new IntPtr(3)},options,false);
     Marshal.StructureToPtr(new Option {key=2,value=a},IntPtr.Add(options,size),false);
     Marshal.StructureToPtr(new Option {key=3,value=b},IntPtr.Add(options,size*2),false);
     List x=new List {size=Marshal.SizeOf(typeof(List)),count=3,options=options}; Marshal.StructureToPtr(x,list,false);
     if (!InternetSetOption(IntPtr.Zero,75,list,x.size)) throw new System.ComponentModel.Win32Exception(); Notify();
   } finally { Marshal.FreeHGlobal(a);Marshal.FreeHGlobal(b);Marshal.FreeHGlobal(options);Marshal.FreeHGlobal(list); }
 }
}
'@
}
function Get-ProxySnapshot {
    $out = [ordered]@{}
    foreach ($entry in @(@($proxyKey,'ProxyEnable'),@($proxyKey,'ProxyServer'),@($proxyKey,'ProxyOverride'),@($proxyKey,'AutoConfigURL'),@($connectionKey,'DefaultConnectionSettings'),@($connectionKey,'SavedLegacySettings'))) {
        $key = Get-Item -LiteralPath $entry[0] -ErrorAction SilentlyContinue
        $id = $entry[0] + '|' + $entry[1]
        if ($key -and $key.GetValueNames() -contains $entry[1]) {
            $kind = $key.GetValueKind($entry[1]).ToString(); $v = $key.GetValue($entry[1],$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($kind -eq 'Binary') { $v = [Convert]::ToBase64String($v) }
            $out[$id] = [ordered]@{kind=$kind; value=$v}
        } else { $out[$id] = $null }
    }
    return $out
}
function Restore-ProxySnapshot($Snapshot) {
    foreach ($prop in $Snapshot.PSObject.Properties) {
        $parts = $prop.Name.Split('|'); $v = $prop.Value
        if ($null -eq $v) { Remove-ItemProperty -LiteralPath $parts[0] -Name $parts[1] -ErrorAction SilentlyContinue; continue }
        if (!(Test-Path -LiteralPath $parts[0])) { New-Item -Path $parts[0] | Out-Null }
        $value = $v.value; if ($v.kind -eq 'Binary') { $value = [Convert]::FromBase64String($value) }
        New-ItemProperty -LiteralPath $parts[0] -Name $parts[1] -PropertyType $v.kind -Value $value -Force | Out-Null
    }
    Initialize-WinInet; [EnanaWinInet]::Notify()
}
function Get-ProxyFingerprint {
    # Connection blobs contain OS-maintained counters. Compare supported active
    # WinINet flags and user settings, not those changing bookkeeping bytes.
    Initialize-WinInet
    $p=Get-ItemProperty -LiteralPath $proxyKey -ErrorAction SilentlyContinue
    return ([ordered]@{flags=[EnanaWinInet]::Flags();enabled=$p.ProxyEnable;server=$p.ProxyServer;bypass=$p.ProxyOverride;pac=$p.AutoConfigURL}|ConvertTo-Json -Compress)
}
function Test-ProxyMine {
    $p = Get-ItemProperty -LiteralPath $proxyKey -ErrorAction SilentlyContinue
    return ($p -and $p.ProxyEnable -eq 1 -and $p.ProxyServer -eq "http=127.0.0.1:$($s.PORT);https=127.0.0.1:$($s.PORT)")
}
function Get-TunInfo {
    $task = Get-ScheduledTask -TaskName $tunName -ErrorAction SilentlyContinue
    $status=$null;try{$status=Read-JsonFile "$root\status.json"}catch{}
    $core=$null
    if($status -and ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()-$status.updated) -lt 12000){$core=Get-Process -Id $status.pid -ErrorAction SilentlyContinue}
    return @($(if ($task) {1} else {0}), $(if ($task -and $task.State -eq 'Running' -and $core) {1} else {0}), $(if ($core) {$core.Id} else {''}))
}
function Get-AppName([string]$Exe, [string]$Fallback = '') {
    switch -Regex ([IO.Path]::GetFileName($Exe)) {
        '^chrome\.exe$' { return 'Google Chrome' }
        '^msedge\.exe$' { return 'Microsoft Edge' }
        '^firefox\.exe$' { return 'Firefox' }
        '^claude\.exe$' { return 'Claude' }
        '^chatgpt\.exe$' { return 'ChatGPT' }
        '^gemini\.exe$' { return 'Gemini' }
    }
    if ($Fallback -and $Fallback -notmatch '[|"\\/\x00-\x1f]' -and $Fallback.Length -le 80) { return $Fallback }
    return [IO.Path]::GetFileNameWithoutExtension($Exe)
}
function Get-Apps {
    $apps = @{}; $shell = New-Object -ComObject WScript.Shell
    foreach ($folder in @([Environment]::GetFolderPath('StartMenu'),[Environment]::GetFolderPath('CommonStartMenu'))) {
        Get-ChildItem -LiteralPath $folder -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            try { $target = $shell.CreateShortcut($_.FullName).TargetPath
                if ($target -match '\.exe$' -and $target -notmatch '\\(unins[^\\]*|uninstall|update)\.exe$' -and (Test-Path -LiteralPath $target -PathType Leaf)) {
                    $name = Get-AppName $target $_.BaseName; if (!$apps.ContainsKey($name)) { $apps[$name] = $target.Replace('\','/') }
                }
            } catch {}
        }
    }
    foreach ($key in @('HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        Get-ItemProperty $key -ErrorAction SilentlyContinue | ForEach-Object {
            if (!$_.DisplayIcon) { return }
            $target = [Environment]::ExpandEnvironmentVariables(($_.DisplayIcon -replace ',\s*-?\d+$','').Trim('"'))
            if ($target -match '\.exe$' -and (Test-Path -LiteralPath $target -PathType Leaf)) {
                $name = Get-AppName $target $_.DisplayName
                if ($name -notmatch '[|"\\/\x00-\x1f]' -and $name.Length -le 80 -and !$apps.ContainsKey($name)) { $apps[$name] = $target.Replace('\','/') }
            }
        }
    }
    Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'ChatGPT|Claude|Gemini' } | ForEach-Object {
        try { [xml]$manifest = [IO.File]::ReadAllText((Join-Path $_.InstallLocation 'AppxManifest.xml'))
            foreach ($application in $manifest.Package.Applications.Application) {
                $exe = Join-Path $_.InstallLocation $application.Executable
                if ($exe -match '\.exe$') { $name = Get-AppName $exe; $apps[$name] = $exe.Replace('\','/') }
            }
        } catch {}
    }
    foreach ($name in $apps.Keys | Sort-Object) { "$name`t$($apps[$name])" }
}
function Inspect-App([string]$Path) {
    $p = $Path.Trim('"').Replace('\','/')
    if ($p -notmatch '^[A-Za-z]:/' -or $p -match '[|"\x00-\x1f]' -or $p -notmatch '\.exe$' -or !(Test-Path -LiteralPath $p -PathType Leaf)) {
        return @{valid=$false; path=$p; reason='Enter the full path to an existing Windows .exe file.'}
    }
    $item = Get-Item -LiteralPath $p; $name = Get-AppName $p; $sig = Get-AuthenticodeSignature -LiteralPath $p
    $known = @(); if (Test-Path -LiteralPath "$HomeDir\.apps.now") { $known = [IO.File]::ReadAllLines("$HomeDir\.apps.now",$Utf8) | ForEach-Object { ($_ -split "`t")[0] } }
    return [ordered]@{valid=$true;kind='bin';name=$name;bundle_id='';version=$item.VersionInfo.FileVersion;path=$p;exec=$item.Name;signed=($sig.Status -eq 'Valid');authority=$(if ($sig.SignerCertificate) {$sig.SignerCertificate.Subject} else {''});team='';icon='';exists=($known -contains $name);matches_running=([bool](Get-CimInstance Win32_Process -Filter "Name='$($item.Name.Replace("'","''"))'" -ErrorAction SilentlyContinue | Where-Object {$_.ExecutablePath -eq $item.FullName}))}
}
switch ($Action) {
    'version' { [Environment]::OSVersion.Version.ToString() }
    'program-data' { [Environment]::GetFolderPath('CommonApplicationData') }
    'admin' { if (Test-EnanaAdmin) {'1'} else {'0'} }
    'task-register' {
        $node = Join-Path $HomeDir 'runtime\node\node.exe'; $worker = Join-Path $HomeDir 'windows\worker.js'
        $spec = "$HomeDir|$((Get-FileHash -LiteralPath $worker).Hash)|$((Get-FileHash -LiteralPath $node).Hash)"
        $file = Join-Path $HomeDir 'runtime\task.spec'
        if ((Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $file) -and [IO.File]::ReadAllText($file) -eq $spec) { 'unchanged'; break }
        $taskAction = New-ScheduledTaskAction -Execute $node -Argument ('"{0}" "{1}"' -f $worker,$HomeDir) -WorkingDirectory $HomeDir
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $sid
        $principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
        $opts = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $trigger -Principal $principal -Settings $opts -Force | Out-Null
        Write-Utf8 $file $spec; 'changed'
    }
    'worker-start' { Start-ScheduledTask -TaskName $taskName }
    'cleanup-core' {
        foreach($proc in Get-CimInstance Win32_Process -Filter "Name='sing-box.exe'" -ErrorAction SilentlyContinue){
            if($proc.ExecutablePath -eq "$HomeDir\sing-box.exe" -and $proc.CommandLine.Contains("$HomeDir\config.json")){
                $owner=Invoke-CimMethod -InputObject $proc -MethodName GetOwnerSid
                if($owner.Sid -eq $sid){Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue}
            }
        }
    }
    'core-upgrade' {
        if($Value -notin @('','latest','1.14.2')){throw 'This Windows release approves sing-box 1.14.2. Update enana before selecting another core version.'}
        $arch=if(($env:PROCESSOR_ARCHITEW6432,$env:PROCESSOR_ARCHITECTURE) -contains 'ARM64'){'arm64'}else{'amd64'}
        $pin=(Read-JsonFile "$HomeDir\windows\runtime-pins.json").core.$arch
        $archive="$HomeDir\runtime\cache\core.zip"
        if(!(Test-Path -LiteralPath $archive) -or (Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant() -ne $pin.sha256){Get-VerifiedDownload @($pin.url) $archive $pin.sha256}
        $stage="$HomeDir\runtime\core-upgrade-$([Guid]::NewGuid().ToString('N'))"
        try{
            Expand-SafeZip $archive $stage
            $exe=@(Get-ChildItem -LiteralPath $stage -Filter 'sing-box.exe' -Recurse);if($exe.Count -ne 1){throw 'Invalid official core archive'}
            & $exe[0].FullName check -c "$HomeDir\config.json";if($LASTEXITCODE -ne 0){throw 'New core did not accept the saved configuration'}
            & "$HomeDir\runtime\node\node.exe" "$HomeDir\windows\helper.js" control $HomeDir stop
            if($LASTEXITCODE -ne 0){throw 'Could not stop the owned user core'}
            Copy-Item -LiteralPath $exe[0].FullName -Destination "$HomeDir\sing-box.exe" -Force
            Remove-Item -LiteralPath "$HomeDir\.core-version" -ErrorAction SilentlyContinue
        }finally{Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue}
    }
    'worker-remove' { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue }
    'shortcut-install' {
        $bin=Join-Path $HomeDir 'bin';$old=[Environment]::GetEnvironmentVariable('Path','User');if(!$old){$old=''}
        if(!($old.Split(';') -contains $bin)){[Environment]::SetEnvironmentVariable('Path',($old.TrimEnd(';')+';'+$bin).TrimStart(';'),'User')}
        $env:Path="$bin;$env:Path"
        Add-Type @'
using System;using System.Runtime.InteropServices;
public static class EnanaEnvironment {
 [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr SendMessageTimeout(IntPtr h,uint m,IntPtr w,string l,uint f,uint t,out IntPtr result);
}
'@
        $result=[IntPtr]::Zero;[EnanaEnvironment]::SendMessageTimeout([IntPtr]0xffff,0x1a,[IntPtr]::Zero,'Environment',2,2000,[ref]$result)|Out-Null
    }
    'shortcut-remove' {
        $bin=Join-Path $HomeDir 'bin';$old=[Environment]::GetEnvironmentVariable('Path','User')
        if($old){[Environment]::SetEnvironmentVariable('Path',(($old.Split(';')|Where-Object{$_ -ne $bin}) -join ';'),'User')}
        Remove-Item -LiteralPath "$HomeDir\bin\enana.cmd" -ErrorAction SilentlyContinue
    }
    'self-update' { & "$HomeDir\get.ps1" -Upgrade -NoOpen -HomeDir $HomeDir; if($LASTEXITCODE -and $LASTEXITCODE -ne 0){throw 'Windows update failed'} }
    'sysproxy-ok' { if (Test-ProxyMine) {exit 0} else {exit 1} }
    'sysproxy-foreign' { $p = Get-ItemProperty -LiteralPath $proxyKey -ErrorAction SilentlyContinue; if ($p -and (($p.ProxyEnable -eq 1 -and !(Test-ProxyMine)) -or $p.AutoConfigURL)) {'Windows user proxy/PAC'} }
    'sysproxy-on' {
        $policy = Get-ItemProperty 'HKLM:\Software\Policies\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
        if ($policy -and $policy.ProxySettingsPerUser -eq 0) { throw 'Proxy settings are controlled by machine policy. Use Enhanced/TUN or contact your administrator.' }
        $file = Join-Path $HomeDir 'windows-proxy-backup.json'; $before = Get-ProxySnapshot
        $backup = $null; if (Test-Path -LiteralPath $file) { $backup = Read-JsonFile $file }
        if ($backup -and $backup.fingerprint -and (Get-ProxyFingerprint) -eq $backup.fingerprint) { break }
        $bypass = '<local>;localhost;127.*;[::1];10.*;192.168.*;169.254.*;' + ((16..31 | ForEach-Object {"172.$_.*"}) -join ';')
        try { Initialize-WinInet; [EnanaWinInet]::Set("http=127.0.0.1:$($s.PORT);https=127.0.0.1:$($s.PORT)",$bypass)
            Write-Utf8 $file (@{original=$before; expected=(Get-ProxySnapshot);fingerprint=(Get-ProxyFingerprint)} | ConvertTo-Json -Depth 8 -Compress)
        } catch { Restore-ProxySnapshot ($before | ConvertTo-Json -Depth 8 | ConvertFrom-Json); throw }
    }
    'sysproxy-off' {
        $file = Join-Path $HomeDir 'windows-proxy-backup.json'
        if (!(Test-Path -LiteralPath $file)) { break }
        $b = Read-JsonFile $file
        $mine=if($b.fingerprint){(Get-ProxyFingerprint) -eq $b.fingerprint}else{((Get-ProxySnapshot)|ConvertTo-Json -Depth 8 -Compress) -eq ($b.expected|ConvertTo-Json -Depth 8 -Compress)}
        if (!$mine) { Write-Warning 'Proxy settings changed outside enana; they were preserved.'; break }
        Restore-ProxySnapshot $b.original; Remove-Item -LiteralPath $file
    }
    'sysproxy-diagnostics' { $p = Get-ItemProperty -LiteralPath $proxyKey -ErrorAction SilentlyContinue; "sysproxy.enabled=$($p.ProxyEnable)"; "sysproxy.server=$($p.ProxyServer)"; "sysproxy.pac_present=$([bool]$p.AutoConfigURL)" }
    'apps' { Get-Apps }
    'app-inspect' { Inspect-App $Value | ConvertTo-Json -Depth 4 -Compress }
    'app-browser' { if ([IO.Path]::GetFileName($Value) -match '^(chrome|msedge|firefox|brave|opera|vivaldi|arc)\.exe$') { exit 0 } else { exit 1 } }
    'icons' {
        Add-Type -AssemblyName System.Drawing
        foreach ($line in [IO.File]::ReadAllLines($Value,$Utf8)) {
            $parts = $line -split "`t",2
            if ($parts.Count -ne 2 -or $parts[0] -notmatch '^[A-Za-z0-9._-]+$') { continue }
            try { $icon = [Drawing.Icon]::ExtractAssociatedIcon($parts[1]); $bitmap = $icon.ToBitmap()
                $bitmap.Save((Join-Path $HomeDir "ui\appicons\$($parts[0]).png"),[Drawing.Imaging.ImageFormat]::Png); $bitmap.Dispose(); $icon.Dispose()
            } catch {}
        }
    }
    'open' { Start-Process -FilePath $Value }
    'tun-info' { (Get-TunInfo) -join ' ' }
    'tun-ready' {
        $info = Get-TunInfo; if ($info[1] -ne 1) { exit 1 }
        $adapter = Get-NetAdapter -Name "enana-$($sid.Split('-')[-1])" -ErrorAction SilentlyContinue
        if (!$adapter -or $adapter.Status -ne 'Up') { exit 1 }
        if (!(Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {$_.IPAddress -eq '172.19.0.1'})) { exit 1 }
        foreach ($ip in @('1.1.1.1','2606:4700:4700::1111')) {
            $route = Find-NetRoute -RemoteIPAddress $ip -ErrorAction SilentlyContinue | Where-Object { $_.PSObject.Properties.Name -contains 'DestinationPrefix' } | Select-Object -First 1
            if (!$route -or $route.InterfaceIndex -ne $adapter.InterfaceIndex) { exit 1 }
        }
        foreach ($ip in @('127.0.0.1','::1')) {
            $local = Find-NetRoute -RemoteIPAddress $ip -ErrorAction SilentlyContinue | Where-Object { $_.PSObject.Properties.Name -contains 'DestinationPrefix' } | Select-Object -First 1
            if (!$local -or $local.InterfaceIndex -eq $adapter.InterfaceIndex) { exit 1 }
        }
    }
    'tun-install' {
        $arg = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Action install -Sid "{1}" -Stage "{2}" -AutoStart {3}' -f (Join-Path $Value 'tun.ps1'),$sid,$Value,$s.AUTOSTART
        $p = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -ArgumentList $arg -PassThru
        # RunAs returns after UAC approval; cancellation leaves the user core.
        & "$HomeDir\runtime\node\node.exe" "$HomeDir\windows\helper.js" control $HomeDir stop
        if($LASTEXITCODE -ne 0){throw 'Could not stop the owned user core'}
        Write-Utf8 (Join-Path $Value 'user-stopped') 'ready'
        $p.WaitForExit()
        if ($p.ExitCode -ne 0) { throw "Enhanced/TUN installation failed (exit $($p.ExitCode))." }
    }
    {$_ -in 'tun-stop','tun-remove'} {
        $task=Get-ScheduledTask -TaskName $tunName -ErrorAction SilentlyContinue
        if (!$task -or ($Action -eq 'tun-stop' -and $task.State -ne 'Running')) { break }
        $helper = Join-Path $root 'tun.ps1'
        $arg = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Action {1} -Sid "{2}"' -f $helper,$Action.Substring(4),$sid
        $p = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -ArgumentList $arg -PassThru -Wait
        if ($p.ExitCode -ne 0) { throw 'Enhanced/TUN could not stop. The previous configuration was retained.' }
    }
    'local-ip' { Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {$_.IPAddress -notmatch '^(127\.|169\.254\.|172\.19\.0\.)'} | Select-Object -First 1 -ExpandProperty IPAddress }
    'dns-system' { if ($Value -notmatch '^[a-zA-Z0-9.-]{1,253}$') { throw 'Invalid DNS name' }; ([Net.Dns]::GetHostAddresses($Value) | Select-Object -First 4 | ForEach-Object {$_.IPAddressToString}) -join ' ' }
    'diagnostics' {
        "windows.version=$([Environment]::OSVersion.Version)"; "windows.arch=$env:PROCESSOR_ARCHITECTURE"; "windows.elevated=$(Test-EnanaAdmin)"
        "windows.worker_task=$((Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State)"
        "windows.tun_task=$((Get-ScheduledTask -TaskName $tunName -ErrorAction SilentlyContinue).State)"
        foreach ($ip in @('1.1.1.1','2606:4700:4700::1111','127.0.0.1')) {
            $r = Find-NetRoute -RemoteIPAddress $ip -ErrorAction SilentlyContinue | Where-Object {$_.PSObject.Properties.Name -contains 'DestinationPrefix'} | Select-Object -First 1
            "capture.route.$ip.interface=$($r.InterfaceAlias)"
        }
        'capture.socket.udp_remote_visibility=unavailable-on-Windows'; 'capture.socket.status=TCP snapshot only; bypass is a candidate, not proof'
        $patterns=@{}
        & "$HomeDir\runtime\node\node.exe" "$HomeDir\windows\helper.js" regex-map $HomeDir | ForEach-Object {$p=$_ -split "`t",2;if($p.Count -eq 2){$patterns[$p[0]]=($p[1]|ConvertFrom-Json)}}
        $processes = @{}; Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {$processes[[int]$_.ProcessId]=$_.ExecutablePath}
        $pinApps=@();if(Test-Path -LiteralPath "$HomeDir\overrides.tsv"){$pinApps=[IO.File]::ReadAllLines("$HomeDir\overrides.tsv",$Utf8)|Where-Object{$_ -match '^app\|[^|]+\|pin\|'}|ForEach-Object{($_ -split '\|')[1]}}
        foreach ($c in Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue) {
            if ($c.RemoteAddress -match '^(127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|::1$|[fF][cCdDeE])') { continue }
            $exe=$processes[[int]$c.OwningProcess];if(!$exe){continue}
            foreach ($app in $pinApps) {if($patterns.ContainsKey($app) -and $exe -match $patterns[$app]) {
                "capture.socket.app=$app pid=$($c.OwningProcess) remote=$($c.RemoteAddress):$($c.RemotePort) status=$(if($s.NETWORK_MODE -eq 'system'){'possible_system_proxy_bypass'}else{'tun_os_socket_observed'})"
            }}
        }
    }
    default { throw "Unsupported Windows action: $Action" }
}
