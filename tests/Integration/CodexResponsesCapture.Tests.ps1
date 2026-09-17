#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Codex Responses loopback capture' -Tag 'Integration' {
    It 'keeps max effort and effective catalog instructions for <Model>' -ForEach @(
        @{ Model = 'qwen3.6-35b:256k'; Catalog = '' },
        @{ Model = 'deepseek-flash'; Catalog = 'deepseek-flash.json' },
        @{ Model = 'glm-5.3-flash'; Catalog = 'glm-5.3-flash-codex.json' }
    ) {
        $codexCommand = Get-Command codex -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $codexCommand -or -not $codexCommand.Path) {
            Set-ItResult -Skipped -Because 'Codex CLI is not installed on this test host.'
            return
        }

        $extension = [IO.Path]::GetExtension($codexCommand.Path)
        if ($extension -notin @('.ps1', '.exe')) {
            Set-ItResult -Skipped -Because "Unsupported Codex launcher type for loopback capture: $extension"
            return
        }

        $portProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $portProbe.Start()
        $port = ([Net.IPEndPoint]$portProbe.LocalEndpoint).Port
        $portProbe.Stop()

        $listener = [Net.HttpListener]::new()
        $listener.Prefixes.Add("http://127.0.0.1:$port/")
        $process = $null
        try {
            $listener.Start()
            $contextTask = $listener.GetContextAsync()

            $codeHome = Join-Path $TestDrive 'codex-home'
            $workspace = Join-Path $TestDrive 'workspace'
            New-Item -ItemType Directory -Path $codeHome, $workspace -Force | Out-Null

            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            if ($extension -eq '.ps1') {
                $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
                [void]$startInfo.ArgumentList.Add('-NoProfile')
                [void]$startInfo.ArgumentList.Add('-File')
                [void]$startInfo.ArgumentList.Add($codexCommand.Path)
            } else {
                $startInfo.FileName = $codexCommand.Path
            }
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.CreateNoWindow = $true
            $startInfo.Environment['CODEX_HOME'] = $codeHome
            $startInfo.Environment['AICLI_CAPTURE_KEY'] = 'ollama'

            $codexArgs = @(
                'exec'
                '--ephemeral'
                '--ignore-user-config'
                '--ignore-rules'
                '--skip-git-repo-check'
                '--sandbox'
                'read-only'
                '-C'
                $workspace
                '-c'
                ('model="' + $Model + '"')
                '-c'
                'model_provider="aicli_capture"'
                '-c'
                'model_providers.aicli_capture.name="AICLI loopback capture"'
                '-c'
                "model_providers.aicli_capture.base_url=`"http://127.0.0.1:$port/v1`""
                '-c'
                'model_providers.aicli_capture.env_key="AICLI_CAPTURE_KEY"'
                '-c'
                'model_providers.aicli_capture.wire_api="responses"'
                '-c'
                'model_reasoning_effort="max"'
                'Reply with exactly PONG.'
            )
            if ($Catalog) {
                $catalogPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) ('data/model-catalogs/' + $Catalog)
                $codexArgs = $codexArgs[0..($codexArgs.Count - 2)] + @('-c', ('model_catalog_json=' + ($catalogPath | ConvertTo-Json -Compress)), $codexArgs[-1])
            }
            foreach ($argument in $codexArgs) {
                [void]$startInfo.ArgumentList.Add($argument)
            }

            $process = [Diagnostics.Process]::new()
            $process.StartInfo = $startInfo
            [void]$process.Start()
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()

            $contextTask.Wait(10000) | Should -BeTrue -Because 'Codex should send one Responses request to the loopback endpoint.'
            $context = $contextTask.GetAwaiter().GetResult()
            $encoding = if ($context.Request.ContentEncoding) {
                $context.Request.ContentEncoding
            } else {
                [Text.Encoding]::UTF8
            }
            $reader = [IO.StreamReader]::new($context.Request.InputStream, $encoding)
            try {
                $requestBody = $reader.ReadToEnd()
            } finally {
                $reader.Dispose()
            }
            $requestMethod = $context.Request.HttpMethod
            $requestPath = $context.Request.Url.AbsolutePath

            $responseBytes = [Text.Encoding]::UTF8.GetBytes(
                '{"error":{"message":"captured","type":"invalid_request_error"}}'
            )
            $context.Response.StatusCode = 400
            $context.Response.ContentType = 'application/json'
            $context.Response.ContentLength64 = $responseBytes.Length
            $context.Response.OutputStream.Write($responseBytes, 0, $responseBytes.Length)
            $context.Response.Close()

            if (-not $process.WaitForExit(10000)) {
                $process.Kill($true)
                $process.WaitForExit()
            }
            $null = $stdoutTask.GetAwaiter().GetResult()
            $null = $stderrTask.GetAwaiter().GetResult()

            $request = $requestBody | ConvertFrom-Json
            $requestMethod | Should -Be 'POST'
            $requestPath | Should -Be '/v1/responses'
            $request.model | Should -BeExactly $Model
            $request.reasoning.effort | Should -Be 'max'
            if ($Catalog) {
                $entry = (Get-Content $catalogPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100).models[0]
                $request.instructions | Should -BeExactly $entry.model_messages.instructions_template
                $request.instructions | Should -Match 'AICLI user-visible summary presentation'
            }
        } finally {
            if ($process) {
                if (-not $process.HasExited) {
                    $process.Kill($true)
                    $process.WaitForExit()
                }
                $process.Dispose()
            }
            if ($listener.IsListening) {
                $listener.Stop()
            }
            $listener.Close()
        }
    }
}
