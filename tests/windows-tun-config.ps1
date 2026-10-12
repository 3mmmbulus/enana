# Cases for the elevated TUN snapshot validator: Assert-TunConfig in
# windows/common.ps1, which windows/tun.ps1 runs as an administrator before
# sing-box runs the snapshot as SYSTEM. Everything happens in memory: the
# protected root is only a string, nothing on disk is read or written and
# nothing is elevated. Windows path rules, so it runs on Windows only.
$ErrorActionPreference = 'Stop'
. "$(Split-Path $PSScriptRoot -Parent)\windows\common.ps1"
if ([IO.Path]::DirectorySeparatorChar -ne '\') { throw 'This test needs Windows path rules; run it on Windows' }
$root = 'C:\ProgramData\enana\S-1-5-21-1-2-3-4'
$failures = 0
# A minimal enana-style TUN snapshot, one entry per top-level key ($null = left
# out). @ROOT@ is the root written as enana stages it (forward slashes), @OUT@
# a directory outside it. JSON \u escapes keep this file ASCII.
$mixed = '{"type":"mixed","tag":"in","listen":"127.0.0.1","listen_port":7890}'
$tun = '{"type":"tun","tag":"tun-in","interface_name":"enana-4","address":["172.19.0.1/30","fdfe:dcba:9876::1/126"],"mtu":1500,"auto_route":true,"strict_route":true}'
$sections = [ordered]@{
    log = '{"level":"info","timestamp":true,"output":"@ROOT@/sing-box.log"}'
    dns = '{"servers":[{"type":"local","tag":"dns-local"}],"final":"dns-local"}'
    certificate = $null
    endpoints = $null
    inbounds = '[' + $mixed + ',{"type":"mixed","tag":"speed-in","listen":"127.0.0.1","listen_port":7892},' + $tun + ']'
    outbounds = '[{"type":"direct","tag":"direct"}]'
    route = '{"rule_set":[{"type":"local","tag":"geosite-cn","format":"binary","path":"@ROOT@/rules/geosite/geosite-cn.srs"}],"rules":[{"rule_set":["geosite-cn"],"action":"route","outbound":"direct"}],"final":"direct","auto_detect_interface":true}'
    experimental = '{"cache_file":{"enabled":true,"path":"@ROOT@/cache.db"},"clash_api":{"external_controller":"127.0.0.1:9090","default_mode":"Rule"}}'
}
function New-TestConfig([hashtable]$Change) {
    foreach ($key in $Change.Keys) { if (!$sections.Contains($key)) { throw "Unknown test section: $key" } }
    $parts = foreach ($key in $sections.Keys) {
        $text = if ($Change.ContainsKey($key)) { $Change[$key] } else { $sections[$key] }
        if ($null -ne $text) { '"' + $key + '":' + $text }
    }
    $json = '{' + ($parts -join ',') + '}'
    return $json.Replace('@ROOT@', $root.Replace('\', '/')).Replace('@OUT@', 'C:/Windows/Temp/enana-outside')
}
function Write-Result([string]$Name, [bool]$Ok, [string]$Outcome) {
    if ($Ok) { $status = 'PASS' } else { $status = 'FAIL'; $script:failures++ }
    Write-Host ('{0}: {1} -> {2}' -f $status, $Name, $Outcome)
}
function Test-Case([string]$Name, [string]$Refusal, [hashtable]$Change = @{}) {
    # $Refusal '' means the snapshot must pass; otherwise it must be refused
    # with a message matching that pattern. Windows PowerShell 5.1
    # ConvertFrom-Json already rejects keys that differ only in ASCII case, and
    # tun.ps1 parses the snapshot the same way, so a parse error is a refusal.
    $outcome = $null
    try { $config = New-TestConfig $Change | ConvertFrom-Json }
    catch { $outcome = 'refused while parsing: ' + $_.Exception.Message }
    if ($null -eq $outcome) {
        try { $null = Assert-TunConfig $config $root; $outcome = 'accepted' }
        catch { $outcome = 'refused: ' + $_.Exception.Message }
    }
    if ($Refusal) { $ok = $outcome -like 'refused while parsing: *' -or ($outcome -like 'refused: *' -and $outcome -match $Refusal) }
    else { $ok = $outcome -ceq 'accepted' }
    Write-Result $Name $ok $outcome
}
$escapes = 'Config path escapes protected snapshot'
$folding = 'after case folding'
$loopback = 'Snapshot must only expose loopback listeners'
$inboundType = 'Snapshot inbounds must be tun or loopback mixed'
$noTun = 'Not a TUN configuration'
$ruleFile = 'Rule file escapes protected snapshot'

# Accepted
Test-Case 'enana-style snapshot: tun and loopback mixed inbounds, log, cache and rule set under the root' ''
Test-Case 'tun plus one mixed inbound on 127.0.0.1' '' @{ inbounds = '[' + $mixed + ',' + $tun + ']' }
Test-Case 'hosts path list with every entry under the root' '' @{ dns = '{"servers":[{"type":"local","tag":"dns-local"},{"type":"hosts","tag":"dns-hosts","path":["@ROOT@/hosts","C:\\ProgramData\\enana\\S-1-5-21-1-2-3-4\\hosts2"]}],"final":"dns-local"}' }
Test-Case 'keys spelled in other cases or with U+017F still reach every check' '' @{
    log = '{"Level":"info","OUTPUT":"@ROOT@/sing-box.log"}'
    inbounds = '[{"Type":"mixed","Tag":"in","Li\u017Ften":"127.0.0.1","Listen_Port":7890},' + $tun + ']'
    route = '{"Rule_Set":[{"TYPE":"local","Tag":"geosite-cn","Format":"binary","Path":"@ROOT@/rules/geosite/geosite-cn.srs"}],"Auto_Detect_Interface":true}'
    experimental = '{"Cache_File":{"Enabled":true,"Path":"@ROOT@/cache.db"},"Clash_API":{"External_Controller":"127.0.0.1:9090"}}'
}

# path is a file only inside a local rule set or a hosts DNS server; elsewhere it
# is a URL path, which every default configuration has (DNS-over-HTTPS servers)
Test-Case 'DNS-over-HTTPS server with path /dns-query (the default DNS)' '' @{ dns = '{"servers":[{"type":"local","tag":"dns-local"},{"type":"https","tag":"dns-global","server":"1.1.1.1","path":"/dns-query"}],"final":"dns-local"}' }
Test-Case 'WebSocket transport with path /ws' '' @{ outbounds = '[{"type":"direct","tag":"direct"},{"type":"vless","tag":"v","server":"a.example","server_port":443,"transport":{"type":"ws","path":"/ws"}}]' }
Test-Case 'hosts DNS server with a string path outside the root' $escapes @{ dns = '{"servers":[{"type":"local","tag":"dns-local"},{"type":"hosts","tag":"dns-hosts","path":"@OUT@/hosts"}],"final":"dns-local"}' }
Test-Case 'cache_file path outside the root' $escapes @{ experimental = '{"cache_file":{"enabled":true,"path":"@OUT@/cache.db"},"clash_api":{"external_controller":"127.0.0.1:9090"}}' }
Test-Case 'Cache_File Path (folded) outside the root' $escapes @{ experimental = '{"Cache_File":{"Enabled":true,"Path":"@OUT@/cache.db"},"clash_api":{"external_controller":"127.0.0.1:9090"}}' }

# A: a file-key suffix that is not lower case
Test-Case 'key_Path (upper-case suffix) outside the root' $escapes @{ outbounds = '[{"type":"direct","tag":"direct"},{"type":"trojan","tag":"t","tls":{"enabled":true,"key_Path":"@OUT@/client.key"}}]' }
# B, C: a decoy next to a U+017F spelling, which sing-box would use instead
Test-Case 'decoy listen 127.0.0.1 next to a U+017F listen 0.0.0.0' $folding @{ inbounds = '[{"type":"mixed","tag":"in","listen":"127.0.0.1","li\u017Ften":"0.0.0.0","listen_port":7890},' + $tun + ']' }
Test-Case 'decoy clash_api next to a U+017F clash_api on 0.0.0.0' $folding @{ experimental = '{"cache_file":{"enabled":true,"path":"@ROOT@/cache.db"},"clash_api":{"external_controller":"127.0.0.1:9090"},"cla\u017Fh_api":{"external_controller":"0.0.0.0:9090"}}' }
# D: external_ui, wherever it points
Test-Case 'external_ui even inside the root' 'external UI' @{ experimental = '{"cache_file":{"enabled":true,"path":"@ROOT@/cache.db"},"clash_api":{"external_controller":"127.0.0.1:9090","external_ui":"@ROOT@/ui"}}' }
# E: file keys given as lists
Test-Case 'client_certificate_path list with one entry outside the root' $escapes @{ outbounds = '[{"type":"direct","tag":"direct"},{"type":"trojan","tag":"t","tls":{"enabled":true,"client_certificate_path":["@ROOT@/certs/a.crt","@OUT@/b.crt"]}}]' }
Test-Case 'hosts DNS path list outside the root' $escapes @{ dns = '{"servers":[{"type":"local","tag":"dns-local"},{"type":"hosts","tag":"dns-hosts","path":["@OUT@/hosts"]}],"final":"dns-local"}' }
Test-Case 'certificate_directory_path list outside the root' $escapes @{ certificate = '{"store":"system","certificate_directory_path":["@OUT@"]}' }
# F: directory keys
Test-Case 'tls acme data_directory outside the root' $escapes @{ outbounds = '[{"type":"direct","tag":"direct"},{"type":"trojan","tag":"t","tls":{"enabled":true,"acme":{"data_directory":"@OUT@/acme"}}}]' }
Test-Case 'tailscale state_directory outside the root' $escapes @{ endpoints = '[{"type":"tailscale","tag":"ts","state_directory":"@OUT@/tailscale"}]' }
Test-Case 'a key named directory outside the root' $escapes @{ outbounds = '[{"type":"direct","tag":"direct","x":{"directory":"@OUT@"}}]' }
# Folded spellings and collisions
Test-Case 'log Output (upper case) outside the root' $escapes @{ log = '{"level":"info","Output":"@OUT@/sing-box.log"}' }
Test-Case 'key_path spelled with U+212A outside the root' $escapes @{ outbounds = '[{"type":"direct","tag":"direct"},{"type":"trojan","tag":"t","tls":{"enabled":true,"\u212Aey_path":"@OUT@/client.key"}}]' }
Test-Case 'key_path next to a U+212A key_path, both inside the root' $folding @{ outbounds = '[{"type":"direct","tag":"direct"},{"type":"trojan","tag":"t","tls":{"enabled":true,"key_path":"@ROOT@/certs/a.key","\u212Aey_path":"@ROOT@/certs/b.key"}}]' }
Test-Case 'output next to Output, both inside the root' $folding @{ log = '{"level":"info","output":"@ROOT@/a.log","Output":"@ROOT@/b.log"}' }
Test-Case 'a file key that is not a path (null output)' 'is not a path' @{ log = '{"level":"info","output":null}' }
# Listeners and inbound types
Test-Case 'mixed inbound listening on 0.0.0.0' $loopback @{ inbounds = '[{"type":"mixed","tag":"in","listen":"0.0.0.0","listen_port":7890},' + $tun + ']' }
Test-Case 'clash_api on every interface' $loopback @{ experimental = '{"cache_file":{"enabled":true,"path":"@ROOT@/cache.db"},"clash_api":{"external_controller":"0.0.0.0:9090"}}' }
Test-Case 'hysteria2 inbound on 127.0.0.1 (a masquerade serves files)' $inboundType @{ inbounds = '[' + $mixed + ',{"type":"hysteria2","tag":"hy2","listen":"127.0.0.1","listen_port":8443},' + $tun + ']' }
Test-Case 'no tun inbound' $noTun @{ inbounds = '[' + $mixed + ']' }
Test-Case 'inbound type TUN (sing-box types are case-sensitive)' $noTun @{ inbounds = '[' + $mixed + ',{"type":"TUN","tag":"tun-in"}]' }
Test-Case 'route without auto_detect_interface' $noTun @{ route = '{"final":"direct"}' }
# Rule sets
Test-Case 'remote rule set' $ruleFile @{ route = '{"rule_set":[{"type":"remote","tag":"r","format":"binary"}],"auto_detect_interface":true}' }
Test-Case 'local rule set outside the root' $ruleFile @{ route = '{"rule_set":[{"type":"local","tag":"r","format":"binary","path":"@OUT@/r.srs"}],"auto_detect_interface":true}' }
Test-Case 'rule set type Local (not local)' $ruleFile @{ route = '{"rule_set":[{"type":"Local","tag":"r","format":"binary","path":"@ROOT@/rules/r/r.srs"}],"auto_detect_interface":true}' }

# The validator returns the folded copy.
try {
    $folded = Assert-TunConfig (New-TestConfig @{ inbounds = '[{"Type":"mixed","Li\u017Ften":"127.0.0.1"},' + $tun + ']' } | ConvertFrom-Json) $root
    $names = @($folded.inbounds[0].PSObject.Properties | ForEach-Object { $_.Name }) -join ','
    Write-Result 'Assert-TunConfig returns the copy with folded keys' ([string]::Equals($names, 'type,listen', [StringComparison]::Ordinal)) "inbound keys: $names"
} catch { Write-Result 'Assert-TunConfig returns the copy with folded keys' $false ('refused: ' + $_.Exception.Message) }

if ($failures) { throw "$failures TUN snapshot validator case(s) failed" }
Write-Host 'PASS: every TUN snapshot validator case behaved as expected'
