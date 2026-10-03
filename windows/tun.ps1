param([ValidateSet('install','run','stop','remove')][string]$Action, [string]$Sid, [string]$Stage = '', [ValidateSet(0,1)][int]$AutoStart = 1)
$ErrorActionPreference = 'Stop'
if ($Sid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') { throw 'Invalid user SID' }
. "$PSScriptRoot\common.ps1"
if (!(Test-EnanaAdmin)) { throw 'Enhanced/TUN requires administrator authorization' }
$base = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'enana'
$root = Join-Path $base $Sid
$taskName = "Enana Enhanced $Sid"
Assert-NoReparse $root
function Stop-Tun {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Disable-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue | Out-Null
    foreach ($proc in Get-CimInstance Win32_Process -Filter "Name='sing-box.exe'" -ErrorAction SilentlyContinue) {
        if ($proc.ExecutablePath -eq (Join-Path $root 'sing-box.exe')) { Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath "$root\status.json" -ErrorAction SilentlyContinue
}
if ($Action -eq 'stop' -or $Action -eq 'remove') {
    Stop-Tun
    if ($Action -eq 'remove') { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue; if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
    exit 0
}
if ($Action -eq 'run') {
    # Only an administrator-owned snapshot is used at logon. No user scripts,
    # environment settings or mutable user executable paths are executed here.
    $core = Join-Path $root 'sing-box.exe'; $config = Join-Path $root 'config.json'
    $child = Start-Process -FilePath $core -ArgumentList ('run -c "{0}" -D "{1}"' -f $config,$root) -WorkingDirectory $root -PassThru -WindowStyle Hidden -RedirectStandardError "$root\startup.log" -RedirectStandardOutput "$root\stdout.log"
    try {
        while (!$child.HasExited) {
            Write-Utf8 "$root\status.json" (@{pid=$child.Id;updated=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()}|ConvertTo-Json -Compress)
            foreach ($file in @('sing-box.log','startup.log','stdout.log')) {
                $log = Join-Path $root $file
                if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 52428800) {
                    $stream = [IO.File]::Open($log,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
                    try { $stream.SetLength(0) } finally { $stream.Dispose() }
                }
            }
            Start-Sleep -Seconds 5; $child.Refresh()
        }
        exit $child.ExitCode
    } finally { if (!$child.HasExited) { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue } }
}
Assert-NoReparse $Stage
if (!(Test-Path -LiteralPath $Stage -PathType Container)) { throw 'Missing snapshot' }
if (Get-ChildItem -LiteralPath $Stage -Force -Recurse | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) { throw 'Snapshot contains a reparse point' }
$j = Read-JsonFile (Join-Path $Stage 'config.json')
if (!($j.inbounds | Where-Object {$_.type -eq 'tun'}) -or !$j.route.auto_detect_interface) { throw 'Not a TUN configuration' }
if (($j.experimental.clash_api.external_controller -notmatch '^127\.0\.0\.1:\d+$') -or ($j.inbounds | Where-Object { $_.type -ne 'tun' -and $_.listen -ne '127.0.0.1' })) { throw 'Snapshot must only expose loopback listeners' }
foreach ($r in $j.route.rule_set) { if ($r.type -ne 'local' -or !([IO.Path]::GetFullPath($r.path).StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase))) { throw 'Rule file escapes protected snapshot' } }
function Assert-ConfigPaths($Object) {
    if($null -eq $Object -or $Object -is [string] -or $Object.GetType().IsValueType){return}
    if($Object -is [Array]){foreach($item in $Object){Assert-ConfigPaths $item};return}
    foreach($property in $Object.PSObject.Properties){
        if(($property.Name -in @('path','output') -or $property.Name.EndsWith('_path')) -and $property.Value -is [string]){
            if(!([IO.Path]::GetFullPath($property.Value).StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase))){throw 'Config path escapes protected snapshot'}
        }else{Assert-ConfigPaths $property.Value}
    }
}
Assert-ConfigPaths $j
# Re-extract the pinned official archive instead of elevating a user-writable EXE.
$arch = (Read-JsonFile (Join-Path $Stage 'snapshot.json')).arch
if ($arch -notin @('amd64','arm64')) { throw 'Unsupported architecture' }
$expected = if ($arch -eq 'amd64') {'c2d8bfff918755808781dfdeeb8581b6c91eb3a243d9a7b55483cfc0c0684d32'} else {'2bb467039310452380958b821983d5bb4f78fb70a2583914e4bea8b011582b64'}
# Protect the parent even if an ordinary user pre-created it. Setting this ACL
# does not rewrite other users' independently protected snapshot ACLs.
Set-PrivateDirectory $base 'S-1-5-32-544'
$next = Join-Path $base ($Sid+'.next'); $previous = Join-Path $base ($Sid+'.previous')
Assert-NoReparse $next; Assert-NoReparse $previous
if (Test-Path -LiteralPath $next) { Remove-Item -LiteralPath $next -Recurse -Force }
Set-PrivateDirectory $next $Sid -ReadOnlyUser
# Verify the protected copy, avoiding a swap of the mutable staging archive
# between hashing and privileged extraction.
$archive = Join-Path $next 'core.zip'
Copy-Item -LiteralPath "$Stage\core.zip" -Destination $archive
if ((Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant() -ne $expected) { throw 'Privileged core archive failed SHA-256 verification' }
$extracted = Join-Path $next 'core'; Expand-SafeZip $archive $extracted
$binary = @(Get-ChildItem -LiteralPath $extracted -Filter 'sing-box.exe' -Recurse)
if ($binary.Count -ne 1) { throw 'Official archive did not contain exactly one core' }
Copy-Item -LiteralPath $binary[0].FullName -Destination "$next\sing-box.exe"
Remove-Item -LiteralPath $extracted -Recurse -Force
Remove-Item -LiteralPath $archive
foreach ($name in @('rules','certs')) { if (Test-Path -LiteralPath "$Stage\$name") { Copy-Item -LiteralPath "$Stage\$name" -Destination "$next\$name" -Recurse } }
Copy-Item -LiteralPath "$Stage\config.json" -Destination "$next\config.json"
Copy-Item -LiteralPath "$PSScriptRoot\tun.ps1" -Destination "$next\tun.ps1"
Copy-Item -LiteralPath "$PSScriptRoot\common.ps1" -Destination "$next\common.ps1"
if (Get-ChildItem -LiteralPath $next -Force -Recurse | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) { throw 'Copied snapshot contains a reparse point' }
$j=Read-JsonFile "$next\config.json"; Assert-ConfigPaths $j
if (!($j.inbounds | Where-Object {$_.type -eq 'tun'}) -or !$j.route.auto_detect_interface -or ($j.experimental.clash_api.external_controller -notmatch '^127\.0\.0\.1:\d+$') -or ($j.inbounds | Where-Object { $_.type -ne 'tun' -and $_.listen -ne '127.0.0.1' })) { throw 'Copied snapshot failed listener validation' }
# Every inherited child ACL is reset after copying; no user-writable script is
# installed as SYSTEM. The only command line is this protected supervisor.
Get-ChildItem -LiteralPath $next -Recurse -Force | ForEach-Object {
    $acl = Get-Acl -LiteralPath $_.FullName; $acl.SetAccessRuleProtection($false,$false)
    foreach ($rule in @($acl.Access | Where-Object {!$_.IsInherited})) { $acl.RemoveAccessRuleSpecific($rule) }
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544'))); Set-Acl -LiteralPath $_.FullName -AclObject $acl
}
$hadTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$taskXml = if ($hadTask) { Export-ScheduledTask -TaskName $taskName } else { $null }
$wasRunning = $hadTask -and $hadTask.State -eq 'Running'
try {
    for($i=0;$i -lt 80 -and !(Test-Path -LiteralPath "$Stage\user-stopped");$i++){Start-Sleep -Milliseconds 500}
    if(!(Test-Path -LiteralPath "$Stage\user-stopped")){throw 'User core handoff timed out'}
    Stop-Tun
    if (Test-Path -LiteralPath $previous) { Remove-Item -LiteralPath $previous -Recurse -Force }
    if (Test-Path -LiteralPath $root) { Move-Item -LiteralPath $root -Destination $previous }
    Move-Item -LiteralPath $next -Destination $root
    & "$root\sing-box.exe" check -c "$root\config.json" *> "$root\check.log"
    if ($LASTEXITCODE -ne 0) { throw 'Privileged snapshot failed configuration check' }
    $program = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Action run -Sid "{1}"' -f "$root\tun.ps1",$Sid
    $taskAction = New-ScheduledTaskAction -Execute $program -Argument $arguments -WorkingDirectory $root
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $opts = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    $task = New-ScheduledTask -Action $taskAction -Principal $principal -Settings $opts
    if ($AutoStart -eq 1) { $task.Triggers = @(New-ScheduledTaskTrigger -AtLogOn -User $Sid) }
    Register-ScheduledTask -TaskName $taskName -InputObject $task -Force | Out-Null
    $scheduler = New-Object -ComObject Schedule.Service; $scheduler.Connect()
    $scheduler.GetFolder('\').GetTask($taskName).SetSecurityDescriptor("D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGX;;;$Sid)",0)
    Start-ScheduledTask -TaskName $taskName
    $adapterName = "enana-$($Sid.Split('-')[-1])"; $ready = $false
    for ($i=0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        $adapter = Get-NetAdapter -Name $adapterName -ErrorAction SilentlyContinue
        if (!$adapter -or $adapter.Status -ne 'Up') { continue }
        if (!(Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {$_.IPAddress -eq '172.19.0.1'})) { continue }
        $ready = $true
        foreach ($ip in @('1.1.1.1','2606:4700:4700::1111')) {
            $route = Find-NetRoute -RemoteIPAddress $ip -ErrorAction SilentlyContinue | Where-Object {$_.PSObject.Properties.Name -contains 'DestinationPrefix'} | Select-Object -First 1
            if (!$route -or $route.InterfaceIndex -ne $adapter.InterfaceIndex) { $ready=$false }
        }
        foreach ($ip in @('127.0.0.1','::1')) {
            $local=Find-NetRoute -RemoteIPAddress $ip -ErrorAction SilentlyContinue | Where-Object {$_.PSObject.Properties.Name -contains 'DestinationPrefix'} | Select-Object -First 1
            if (!$local -or $local.InterfaceIndex -eq $adapter.InterfaceIndex) { $ready=$false }
        }
        if ($ready) { break }
    }
    if (!$ready) { throw 'TUN routes did not become ready; restoring previous snapshot' }
    if (Test-Path -LiteralPath $previous) { Remove-Item -LiteralPath $previous -Recurse -Force }
} catch {
    Stop-Tun
    if (Test-Path -LiteralPath $previous) {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        Move-Item -LiteralPath $previous -Destination $root
    }
    if ($taskXml) { Register-ScheduledTask -TaskName $taskName -Xml $taskXml -Force | Out-Null; if ($wasRunning) { Start-ScheduledTask -TaskName $taskName } }
    else { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue }
    throw
}
