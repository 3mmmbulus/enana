param([string]$HomeDir = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'enana'))
# Runs without Git, Node, the dashboard or administrator privileges. Only
# selected runtime metadata is read; account and node files are never opened.
$ErrorActionPreference = 'Continue'
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
Write-Output '== Windows dashboard startup =='
Write-Output "windows.version=$([Environment]::OSVersion.Version)"
Write-Output "windows.arch=$env:PROCESSOR_ARCHITECTURE"
if (Test-Path -LiteralPath "$HomeDir\VERSION") {
    Write-Output "enana.version=$([IO.File]::ReadAllText("$HomeDir\VERSION",$utf8).Trim())"
}
foreach ($name in @('runtime\node\node.exe','runtime\git\bin\bash.exe','runtime\git\usr\bin\cygpath.exe','sing-box.exe','config.json')) {
    Write-Output "runtime.$name.present=$(Test-Path -LiteralPath (Join-Path $HomeDir $name) -PathType Leaf)"
}
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$taskName = "Enana Dashboard $sid"
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
Write-Output "worker.task.present=$([bool]$task)"
if ($task) {
    Write-Output "worker.task.state=$($task.State)"
    $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
    Write-Output ('worker.task.last_result=0x{0:X8}' -f [long]$info.LastTaskResult)
    Write-Output "worker.task.last_run=$($info.LastRunTime.ToString('o'))"
}
$port = 9091
if (Test-Path -LiteralPath "$HomeDir\settings.env") {
    foreach ($line in [IO.File]::ReadAllLines("$HomeDir\settings.env",$utf8)) {
        if ($line -match '^(API_PORT|PORT|NETWORK_MODE|AUTOSTART|PROXY_ENABLED)=([A-Za-z0-9_-]+)$') {
            Write-Output "settings.$line"
            if ($Matches[1] -eq 'API_PORT') { $port = [int]$Matches[2] }
        }
    }
}
if ($port -gt 0 -and $port -le 65535) {
    $listening = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
    Write-Output "worker.api_port=$port"
    Write-Output "worker.api_listening=$([bool]$listening.Count)"
}
foreach ($name in @('worker.log','api.log','check.log','sing-box.log')) {
    if (!(Test-Path -LiteralPath "$HomeDir\$name")) { continue }
    Write-Output "== $name (last 20 lines, redacted) =="
    # Avoid URLs, credentials and full command/environment dumps in reports.
    Get-Content -LiteralPath "$HomeDir\$name" -Encoding UTF8 -Tail 20 | ForEach-Object {
        $line = $_ -replace 'https?://[^\s]+','[URL redacted]'
        $line = $line -replace '(?i)(password|token|secret|authorization|cookie)([=: ]+)\S+','$1$2[redacted]'
        $line = $line -replace 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+','[token redacted]'
        Write-Output $line
    }
}
