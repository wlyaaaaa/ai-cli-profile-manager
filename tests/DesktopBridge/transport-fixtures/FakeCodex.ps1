#Requires -Version 7.2

$ErrorActionPreference = 'Stop'
$utf8NoBom = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

$mode = [string]$args[0]
$forwardedArgs = @($args | Select-Object -Skip 1)

if ($mode -eq '--fake-passthrough') {
    if ($env:AICLI_TEST_ARGS_FILE) {
        $captured = [ordered]@{ args = @($forwardedArgs) } | ConvertTo-Json -Depth 5 -Compress
        [IO.File]::WriteAllText($env:AICLI_TEST_ARGS_FILE, $captured, $utf8NoBom)
    }
    [Console]::OpenStandardInput().CopyTo([Console]::OpenStandardOutput())
    [Console]::OpenStandardOutput().Flush()
    exit 23
}

if ($mode -eq '--fake-app-server-stuck') {
    Start-Sleep -Milliseconds 300
    $pidPath = $env:AICLI_TEST_CHILD_PID_FILE
    if (-not $pidPath) { exit 31 }

    $childExe = Join-Path $PSHOME 'pwsh.exe'
    $childStart = [Diagnostics.ProcessStartInfo]::new()
    $childStart.FileName = $childExe
    $childStart.UseShellExecute = $false
    $childStart.ArgumentList.Add('-NoProfile')
    $childStart.ArgumentList.Add('-Command')
    $childStart.ArgumentList.Add('Start-Sleep -Seconds 600')
    $child = [Diagnostics.Process]::Start($childStart)
    if ($null -eq $child) { exit 32 }
    [IO.File]::WriteAllText($pidPath, $child.Id.ToString([Globalization.CultureInfo]::InvariantCulture), $utf8NoBom)

    while ($null -ne [Console]::In.ReadLine()) { }
    exit 0
}

if ($mode -ne '--fake-app-server') { exit 30 }

$script:clientReplyRaw = $null

function Write-FakeRpcLine {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Message)
    $line = $Message | ConvertTo-Json -Depth 100 -Compress
    [Console]::Out.WriteLine($line)
    [Console]::Out.Flush()
    return $line
}

while ($null -ne ($requestLine = [Console]::In.ReadLine())) {
    $request = $requestLine | ConvertFrom-Json -AsHashtable
    switch ([string]$request.method) {
        'test/startup' {
            $catalogArg = @($forwardedArgs | Where-Object { $_ -like 'model_catalog_json=*' } | Select-Object -Last 1)
            $catalog = $null
            if ($catalogArg.Count) {
                $path = ([string]$catalogArg[0]).Substring('model_catalog_json='.Length) | ConvertFrom-Json
                $catalog = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            }
            $null = Write-FakeRpcLine @{ id = $request.id; result = @{ startupInstructions = $catalog.models[0].base_instructions } }
        }
        'thread/read' {
            $null = Write-FakeRpcLine ([ordered]@{
                jsonrpc = '2.0'
                id = 'server-need-client'
                method = 'server/need_input'
                params = @{ prompt = 'reply' }
            })
            $replyLine = [Console]::In.ReadLine()
            if ($null -eq $replyLine) { exit 41 }
            $reply = $replyLine | ConvertFrom-Json -AsHashtable
            if ($reply.id -ne 'server-need-client') { exit 42 }
            $script:clientReplyRaw = $replyLine

            $null = Write-FakeRpcLine ([ordered]@{
                jsonrpc = '2.0'
                id = $request.id
                result = @{
                    modelProvider = 'aicli_desktop_local'
                    model = 'local-model'
                    clientReplyRaw = $script:clientReplyRaw
                    thread = @{
                        id = 'thread-1'
                        modelProvider = 'aicli_desktop_local'
                        model = 'local-model'
                    }
                }
            })
        }
        'thread/resume' {
            if ($request.params.modelProvider -ne 'aicli_desktop_local') {
                $null = Write-FakeRpcLine ([ordered]@{
                    jsonrpc = '2.0'
                    id = $request.id
                    error = @{ code = -32000; message = 'router did not select local provider' }
                })
                continue
            }
            $response = [ordered]@{
                jsonrpc = '2.0'
                id = $request.id
                result = @{
                    modelProvider = 'aicli_desktop_local'
                    model = 'local-model'
                    clientReplyRaw = $script:clientReplyRaw
                    thread = @{
                        id = 'thread-1'
                        modelProvider = 'aicli_desktop_local'
                        model = 'local-model'
                    }
                }
            }
            $null = Write-FakeRpcLine $response
        }
        'client/notice' {
            $null = Write-FakeRpcLine ([ordered]@{
                jsonrpc = '2.0'
                method = 'engine/notice'
                params = @{ text = $request.params.text; receivedRaw = $requestLine }
            })
        }
        'ping' {
            $response = [ordered]@{
                jsonrpc = '2.0'
                id = $request.id
                result = @{ echo = 'pong'; receivedRaw = $requestLine }
            }
            $responseLine = $response | ConvertTo-Json -Depth 100 -Compress
            if ($env:AICLI_TEST_EXPECTED_LINE_FILE) {
                [IO.File]::WriteAllText($env:AICLI_TEST_EXPECTED_LINE_FILE, $responseLine, $utf8NoBom)
            }
            [Console]::Out.WriteLine($responseLine)
            [Console]::Out.Flush()
        }
        default {
            if ($request.Contains('id')) {
                $null = Write-FakeRpcLine ([ordered]@{
                    jsonrpc = '2.0'
                    id = $request.id
                    result = @{}
                })
            }
        }
    }
}

exit 0
