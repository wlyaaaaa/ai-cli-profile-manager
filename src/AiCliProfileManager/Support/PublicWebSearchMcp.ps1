#Requires -Version 7.2
# Native Codex owns this stdio MCP process. The model adapter never executes it.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
[Console]::InputEncoding=[Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'PublicWebSearch.ps1')
while ($null -ne ($line=[Console]::In.ReadLine())) {
    $id=$null;$hasId=$false
    try {
        if ($line.Length -gt 65536) { throw 'request_too_large' }
        $request=$line|ConvertFrom-Json -AsHashtable -Depth 30
        if ($request -isnot [Collections.IDictionary] -or $request['jsonrpc'] -cne '2.0') { throw 'invalid_request' }
        $hasId=$request.Contains('id');if($hasId){$id=$request['id']}
        if (-not $hasId) { continue }
        $result=$null
        switch -CaseSensitive ([string]$request['method']) {
            'initialize' {
                $version=[string]$request['params']['protocolVersion']
                if ($version -notin @('2024-11-05','2025-03-26','2025-06-18')) { $version='2025-06-18' }
                $result=@{protocolVersion=$version;capabilities=@{tools=@{listChanged=$false}};serverInfo=@{name='aicli-public-web-search';version='1.0.0'}}
            }
            'ping' { $result=@{} }
            'tools/list' {
                $spec=Get-BridgePublicWebSearchToolSpec
                $result=@{tools=@(@{name=$spec.name;description=$spec.description;inputSchema=$spec.inputSchema;annotations=@{readOnlyHint=$true;destructiveHint=$false;openWorldHint=$true}})}
            }
            'tools/call' {
                if ($request['params']['name'] -cne 'public_web_search') { throw 'unknown_tool' }
                try {
                    $search=Invoke-BridgePublicWebSearch -Arguments $request['params']['arguments']
                    $result=@{content=@($search.contentItems|ForEach-Object {@{type='text';text=$_.text}});isError=$false}
                } catch {
                    # Provider diagnostics may echo the query. Never relay them.
                    $result=@{content=@(@{type='text';text='Public web search failed or its arguments were invalid. No result has been verified.'});isError=$true}
                }
            }
            default {
                [Console]::Out.WriteLine((@{jsonrpc='2.0';id=$id;error=@{code=-32601;message='Method not found'}}|ConvertTo-Json -Depth 30 -Compress))
                [Console]::Out.Flush();continue
            }
        }
        [Console]::Out.WriteLine((@{jsonrpc='2.0';id=$id;result=$result}|ConvertTo-Json -Depth 40 -Compress))
    } catch {
        if ($hasId) { [Console]::Out.WriteLine((@{jsonrpc='2.0';id=$id;error=@{code=-32602;message='Invalid request'}}|ConvertTo-Json -Compress)) }
    }
    [Console]::Out.Flush()
}
