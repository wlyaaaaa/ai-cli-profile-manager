#Requires -Version 7.0
# Dev launcher — same router as installed module; no duplicated logic.
$ErrorActionPreference = 'Stop'
$moduleManifest = Join-Path $PSScriptRoot '..\src\AiCliProfileManager\AiCliProfileManager.psd1'
Import-Module $moduleManifest -Force
# Force real string[] — single arg must not become [string] (else $Tokens[0] is first char)
$tokenList = [System.Collections.Generic.List[string]]::new()
foreach ($a in @($args)) {
    if ($null -ne $a) { [void]$tokenList.Add([string]$a) }
}
$code = Invoke-AiCli -Tokens ([string[]]$tokenList.ToArray())
exit $code
