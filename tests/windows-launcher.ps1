$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
. "$repo\windows\common.ps1"
function Assert($Condition,[string]$Message){if(!$Condition){throw $Message};Write-Host "PASS: $Message"}
$testHome=Join-Path $env:TEMP ('enana launcher test '+[Guid]::NewGuid().ToString('N'))
$launcher=$null
try {
    [IO.Directory]::CreateDirectory("$testHome\windows")|Out-Null
    [IO.Directory]::CreateDirectory("$testHome\runtime\node")|Out-Null
    Copy-Item -LiteralPath "$repo\windows\worker-launcher.cs" -Destination "$testHome\windows\worker-launcher.cs"
    & "$repo\windows\build-launcher.ps1" -HomeDir $testHome
    $binary="$testHome\runtime\worker-launcher.exe"
    $bytes=[IO.File]::ReadAllBytes($binary);$pe=[BitConverter]::ToInt32($bytes,0x3c)
    Assert ([BitConverter]::ToUInt16($bytes,$pe+24+68) -eq 2) 'launcher is a Windows GUI executable, without a console subsystem'
    # This is a real console-subsystem child, not a flag/string assertion. Its
    # native console APIs detect inherited, new and pseudo-console attachment.
    Add-Type -OutputAssembly "$testHome\runtime\node\node.exe" -OutputType ConsoleApplication -TypeDefinition @'
using System; using System.IO; using System.Runtime.InteropServices; using System.Threading;
public static class EnanaLauncherProbe {
 [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
 [DllImport("kernel32.dll",SetLastError=true)] static extern uint GetConsoleProcessList([Out] uint[] ids,uint length);
 [DllImport("kernel32.dll")] static extern uint GetCurrentProcessId();
 public static int Main(string[] args) {
   string home=args[1]; uint[] ids=new uint[64]; uint count=GetConsoleProcessList(ids,64); bool shared=count>64;
   for(int i=0;i<Math.Min(count,64);i++)if(ids[i]!=GetCurrentProcessId())shared=true;
   File.WriteAllText(Path.Combine(home,"probe.json"),"{\"consoleWindow\":"+GetConsoleWindow().ToInt64()+",\"consoleProcesses\":"+count+",\"sharedConsole\":"+shared.ToString().ToLowerInvariant()+"}");
   // Fill both pipes beyond their buffer sizes: the GUI launcher must drain
   // them without blocking and without copying raw output into diagnostics.
   Console.Out.Write(new string('x',131072)); Console.Error.Write(new string('y',131072));
   string stop=Path.Combine(home,"stop"); for(int i=0;i<600&&!File.Exists(stop);i++)Thread.Sleep(100);
   return File.Exists(stop)?int.Parse(File.ReadAllText(stop)):99;
 }
}
'@
    $launcher=Start-Process -FilePath $binary -PassThru
    $null=$launcher.Handle
    for($i=0;$i -lt 100 -and !(Test-Path -LiteralPath "$testHome\probe.json");$i++){Start-Sleep -Milliseconds 100}
    $probe=Read-JsonFile "$testHome\probe.json"
    Write-Host "Native probe: consoleWindow=$($probe.consoleWindow), consoleProcesses=$($probe.consoleProcesses), sharedConsole=$($probe.sharedConsole)"
    Assert ($probe.consoleWindow -eq 0 -and !$probe.sharedConsole) 'real console child has no console window and does not share a caller console'
    Assert (!$launcher.HasExited) 'launcher stays alive while its child runs'
    Write-Utf8 "$testHome\stop" '37'
    Assert ($launcher.WaitForExit(15000)) 'launcher waits for pipe drain and exits after its child'
    Assert ($launcher.ExitCode -eq 37) 'launcher preserves nonzero child exit status for scheduler restart'
    $log=Get-Content -LiteralPath "$testHome\launcher.log" -Raw
    Assert ($log -match 'launcher.exited' -and $log -match '"code":37' -and $log -notmatch 'xxx|yyy') 'launcher logs bounded metadata without raw child output'
    Remove-Item -LiteralPath "$testHome\runtime\node\node.exe"
    $launcher=Start-Process -FilePath $binary -PassThru
    $null=$launcher.Handle
    Assert ($launcher.WaitForExit(15000) -and $launcher.ExitCode -eq 1) 'missing runtime fails without hanging or opening a terminal'
    Assert ((Get-Content "$testHome\launcher.log" -Raw) -match 'launcher.failed') 'failure before Node starts is available in diagnostics'
} finally {
    if($launcher -and !$launcher.HasExited){& taskkill.exe /PID $launcher.Id /T /F | Out-Null}
    Remove-Item -LiteralPath $testHome -Recurse -Force -ErrorAction SilentlyContinue
}
