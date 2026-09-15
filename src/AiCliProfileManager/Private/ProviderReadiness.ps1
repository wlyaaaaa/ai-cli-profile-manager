# Bounded, zero-generation readiness checks for selected local Provider routes.

function Test-AiCliLocalProviderModelId {
    param(
        [Parameter(Mandatory)][string]$Expected,
        [Parameter(Mandatory)][string]$Actual
    )
    if ($Actual -ceq $Expected) { return $true }
    return (-not $Expected.Contains(':') -and $Actual -ceq ($Expected + ':latest'))
}

function Test-AiCliSelectedLocalProviderReadiness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$MergedProfile,
        [ValidateRange(1, 30)][int]$ConnectTimeoutSeconds = 2,
        [ValidateRange(1, 60)][int]$TotalTimeoutSeconds = 5
    )

    if ([string](Get-AiCliProperty $MergedProfile 'provider') -cne 'ollama') {
        return [pscustomobject]@{ Applicable = $false; Ready = $true; Reason = 'not_local_provider'; Summary = '' }
    }

    $endpoint = [string](Get-AiCliProperty $MergedProfile 'endpoint')
    $model = [string](Get-AiCliProperty (Get-AiCliProperty $MergedProfile 'models') 'primary')
    try {
        Assert-AiCliEndpointSafe -Url $endpoint
        $endpointUri = [Uri]$endpoint
        if ($endpointUri.Scheme -cne 'http' -or -not $endpointUri.IsLoopback -or
            [string]::IsNullOrWhiteSpace($model)) {
            throw 'selected_local_provider_contract_invalid'
        }

        $compatibility = Get-AiCliProperty $MergedProfile 'compatibility'
        $broker = Get-AiCliProperty $compatibility 'localGpuBrokerSession'
        $brokerOrigin = if ($broker) { [string](Get-AiCliProperty $broker 'managementOrigin') } else { '' }
        if ($broker) {
            $null = Resolve-AiCliLocalGpuBrokerSessionConfiguration -Configuration $broker -Endpoint $endpoint
        }

        $handler = [Net.Http.SocketsHttpHandler]::new()
        $handler.UseProxy = $false
        $handler.ConnectTimeout = [TimeSpan]::FromSeconds($ConnectTimeoutSeconds)
        $client = [Net.Http.HttpClient]::new($handler, $true)
        $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
        $cancel = [Threading.CancellationTokenSource]::new()
        $cancel.CancelAfter([TimeSpan]::FromSeconds($TotalTimeoutSeconds))
        try {
            $requests = @()
            if (-not [string]::IsNullOrWhiteSpace($brokerOrigin)) {
                $requests += [pscustomobject]@{ Kind = 'broker_status'; Uri = ($brokerOrigin.TrimEnd('/') + '/_gpu_broker/status') }
            }
            $modelsBase = $endpoint.TrimEnd('/')
            if ($endpointUri.AbsolutePath.TrimEnd('/') -eq '') { $modelsBase += '/v1' }
            $requests += [pscustomobject]@{ Kind = 'models'; Uri = ($modelsBase + '/models') }

            foreach ($request in $requests) {
                $response = $null
                try {
                    $response = $client.GetAsync([string]$request.Uri, [Net.Http.HttpCompletionOption]::ResponseContentRead, $cancel.Token).GetAwaiter().GetResult()
                    if (-not $response.IsSuccessStatusCode) {
                        return [pscustomobject]@{ Applicable = $true; Ready = $false; Reason = "$($request.Kind)_http_$([int]$response.StatusCode)"; Summary = "$($request.Kind) 返回 HTTP $([int]$response.StatusCode)" }
                    }
                    $body = $response.Content.ReadAsStringAsync($cancel.Token).GetAwaiter().GetResult()
                    if ([string]::IsNullOrWhiteSpace($body)) {
                        return [pscustomobject]@{ Applicable = $true; Ready = $false; Reason = "$($request.Kind)_body_empty"; Summary = "$($request.Kind) 未返回完整 JSON 正文" }
                    }
                    try { $payload = $body | ConvertFrom-Json -AsHashtable -Depth 30 } catch {
                        return [pscustomobject]@{ Applicable = $true; Ready = $false; Reason = "$($request.Kind)_json_invalid"; Summary = "$($request.Kind) 正文不是完整 JSON" }
                    }
                    if ($request.Kind -eq 'broker_status' -and (Get-AiCliProperty $payload 'ok') -ne $true) {
                        return [pscustomobject]@{ Applicable = $true; Ready = $false; Reason = 'broker_status_not_ready'; Summary = '本机 GPU 网关报告未就绪' }
                    }
                    if ($request.Kind -eq 'models') {
                        $modelIds = @(
                            Get-AiCliProperty $payload 'data' | ForEach-Object {
                                [string](Get-AiCliProperty $_ 'id')
                            } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                        )
                        if (@($modelIds | Where-Object { Test-AiCliLocalProviderModelId -Expected $model -Actual $_ }).Count -ne 1) {
                            return [pscustomobject]@{ Applicable = $true; Ready = $false; Reason = 'models_exact_identity_missing'; Summary = "models 未列出选定模型 $model" }
                        }
                    }
                } finally {
                    if ($response) { $response.Dispose() }
                }
            }
        } finally {
            $cancel.Dispose()
            $client.Dispose()
        }
    } catch [OperationCanceledException] {
        return [pscustomobject]@{ Applicable = $true; Ready = $false; Reason = 'response_timeout'; Summary = "本地 Provider 未在 $TotalTimeoutSeconds 秒内返回完整正文" }
    } catch {
        return [pscustomobject]@{ Applicable = $true; Ready = $false; Reason = 'response_unavailable'; Summary = "本地 Provider 就绪检查失败: $($_.Exception.Message)" }
    }
    return [pscustomobject]@{ Applicable = $true; Ready = $true; Reason = 'ready'; Summary = "本地 Provider 已返回选定模型 $model 的完整 JSON" }
}
