# Test the actual bootstrap parameter declaration and culture selector without
# downloading or installing anything. Public end-to-end acceptance separately
# runs the full documented command on native Windows PowerShell 5.1.
param([string]$BootstrapPath = '')
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
if(!$BootstrapPath){$BootstrapPath=Join-Path $repo 'get.ps1'}
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($BootstrapPath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Bootstrap does not parse'}
$selector=@($ast.EndBlock.Statements|Where-Object { $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text -match 'Get-Culture' })
if($selector.Count -ne 1){throw 'Expected one language selector'}
$prefix=$ast.ParamBlock.Extent.Text+"`n"+$selector[0].Extent.Text+"`n"+'Write-Output $Lang'
# Windows PowerShell 5.1 restores the runspace culture between pipelines, so
# changing Thread.CurrentCulture does not control Get-Culture reliably. Supply
# culture fixtures here; the full native installer uses the unmodified cmdlet.
function Get-Culture { [Globalization.CultureInfo]::GetCultureInfo($script:BootstrapTestCulture) }
try{
    foreach($case in @(@('en-US','en'),@('zh-CN','zh'),@('zh-TW','zh'),@('fr-FR','en'))){
        $script:BootstrapTestCulture=$case[0]
        # A new scope models a fresh shell, and a second call models retrying
        # after the old failed installer left a Lang variable in the terminal.
        $result=& {param($source) Invoke-Expression $source} $prefix
        if($result -ne $case[1]){throw "Wrong default language for $($case[0]): $result"}
        $result=& {param($source) Set-Variable -Name Lang -Value ''; Invoke-Expression $source; Invoke-Expression $source} $prefix
        if(@($result).Count -ne 2 -or $result[0] -ne $case[1] -or $result[1] -ne $case[1]){throw "Retry failed for $($case[0])"}
        Write-Host "PASS: no-argument iex and retry select $($case[1]) for $($case[0])"
    }
    foreach($lang in @('auto','zh','en')){
        $result=& ([scriptblock]::Create($prefix)) -Lang $lang
        $expected=if($lang -eq 'auto'){'en'}else{$lang}
        if($result -ne $expected){throw "Saved-script language option failed: $lang"}
    }
    $rejected=$false
    try{& ([scriptblock]::Create($prefix)) -Lang bad|Out-Null}catch{$rejected=$true}
    if(!$rejected){throw 'Invalid explicit language was accepted'}
    Write-Host 'PASS: explicit auto/zh/en work and invalid language is rejected'
}finally{Remove-Item Function:\Get-Culture; Remove-Variable BootstrapTestCulture -Scope Script}
