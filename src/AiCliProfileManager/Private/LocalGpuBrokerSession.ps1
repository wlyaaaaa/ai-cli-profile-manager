# Opt-in LocalGpuBroker session binding for Codex machine runs.

$script:AiCliLocalGpuBrokerBindingSchema = 'aicli.local-gpu-broker-binding.v1'
$script:AiCliLocalGpuBrokerBindingObservationSchema = 'aicli.local-gpu-broker-binding-observation.v1'
$script:AiCliLocalGpuBrokerAuthorityPreludeSchema = 'aicli.authority-prelude.v1'
$script:AiCliLocalGpuBrokerReceiptSchema = 'aicli.local-gpu-broker-session-receipt.v1'
$script:AiCliLocalGpuBrokerSchema = 'pcconfig.local-gpu-broker.ollama-session.v1'
$script:AiCliLocalGpuBrokerRegistrySourceSchema = 'aicli.profile-registry-source.v1'
$script:AiCliLocalGpuBrokerLeaseEnvironment = 'AICLI_LOCAL_GPU_BROKER_LEASE_ID'
$script:AiCliLocalGpuBrokerCapabilityEnvironment = 'AICLI_LOCAL_GPU_BROKER_CAPABILITY'
$script:AiCliLocalGpuBrokerLeaseHeader = 'X-LocalGpuBroker-Lease-Id'
$script:AiCliLocalGpuBrokerCapabilityHeader = 'X-LocalGpuBroker-Capability'

function Resolve-AiCliLocalGpuBrokerSessionConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][string]$Endpoint
    )

    $configurationFields = if ($Configuration -is [System.Collections.IDictionary]) {
        @($Configuration.Keys | ForEach-Object { [string]$_ })
    } elseif ($Configuration -is [pscustomobject]) {
        @($Configuration.PSObject.Properties.Name | ForEach-Object { [string]$_ })
    } else {
        throw 'LocalGpuBroker machine session contract must be an object.'
    }
    $allowedFields = @('contractVersion', 'requiredForMachineRun', 'managementOrigin')
    foreach ($field in $configurationFields) {
        if ($allowedFields -cnotcontains [string]$field) {
            throw "LocalGpuBroker machine session contract contains an unknown field: $field"
        }
    }
    foreach ($field in $allowedFields) {
        if ($configurationFields -cnotcontains $field) {
            throw "LocalGpuBroker machine session contract is missing: $field"
        }
    }

    $contractVersion = Get-AiCliProperty $Configuration 'contractVersion'
    $required = [bool](
        Get-AiCliProperty $Configuration 'requiredForMachineRun' $false
    )
    $originText = [string](
        Get-AiCliProperty $Configuration 'managementOrigin'
    )
    if ([int]$contractVersion -ne 1 -or -not $required) {
        throw 'LocalGpuBroker machine session contract is not supported.'
    }
    if ([string]::IsNullOrWhiteSpace($originText)) {
        throw 'LocalGpuBroker management origin is required.'
    }
    $originText = $originText.TrimEnd('/')
    try {
        $origin = [Uri]$originText
    } catch {
        throw 'LocalGpuBroker management origin is invalid.'
    }
    $originValid = $origin.IsAbsoluteUri -and
        $origin.Scheme -ceq 'http' -and
        $origin.Host -ceq '127.0.0.1' -and
        $origin.Port -ge 1 -and $origin.Port -le 65535 -and
        $origin.AbsolutePath -ceq '/' -and
        [string]::IsNullOrEmpty($origin.Query) -and
        [string]::IsNullOrEmpty($origin.Fragment) -and
        [string]::IsNullOrEmpty($origin.UserInfo) -and
        $origin.GetLeftPart([UriPartial]::Authority) -ceq $originText
    if (-not $originValid) {
        throw 'LocalGpuBroker management origin must be an exact 127.0.0.1 HTTP origin.'
    }
    $normalizedEndpoint = $Endpoint.TrimEnd('/')
    if ($normalizedEndpoint -cne "$originText/v1") {
        throw 'LocalGpuBroker session origin does not match the Codex provider endpoint.'
    }
    return [ordered]@{
        contractVersion = 1
        requiredForMachineRun = $true
        managementOrigin = $originText
    }
}

function Get-AiCliLocalGpuBrokerSessionConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$MergedProfile)

    $compatibility = Get-AiCliProperty $MergedProfile 'compatibility'
    $configuration = Get-AiCliProperty $compatibility 'localGpuBrokerSession'
    if ($null -eq $configuration) { return $null }
    return Resolve-AiCliLocalGpuBrokerSessionConfiguration `
        -Configuration $configuration `
        -Endpoint ([string](Get-AiCliProperty $MergedProfile 'endpoint'))
}

function Get-AiCliLocalGpuBrokerHeaderEnvironmentMap {
    return [ordered]@{
        $script:AiCliLocalGpuBrokerLeaseHeader = $script:AiCliLocalGpuBrokerLeaseEnvironment
        $script:AiCliLocalGpuBrokerCapabilityHeader = $script:AiCliLocalGpuBrokerCapabilityEnvironment
    }
}

function Get-AiCliLocalGpuBrokerShellExcludes {
    return @(
        $script:AiCliLocalGpuBrokerLeaseEnvironment,
        $script:AiCliLocalGpuBrokerCapabilityEnvironment
    )
}

function Get-AiCliLocalGpuBrokerTextSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    try {
        return 'sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($bytes)
        ).ToLowerInvariant()
    } finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Get-AiCliLocalGpuBrokerRegistrySource {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)

    $profileId = [string](Get-AiCliProperty $Plan 'profileId')
    if ($profileId -notmatch '^[a-z0-9][a-z0-9-]{0,63}$') {
        throw 'LocalGpuBroker registry source requires a safe profile id.'
    }
    $relativePath = "providers/$profileId.json"
    $manifestPath = Get-AiCliDataPath -Relative (
        Join-Path 'providers' "$profileId.json"
    )
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw 'LocalGpuBroker registry source manifest is unavailable.'
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 30
    if ([string](Get-AiCliProperty $manifest 'id') -cne $profileId) {
        throw 'LocalGpuBroker registry source manifest id is invalid.'
    }
    return [ordered]@{
        schema = $script:AiCliLocalGpuBrokerRegistrySourceSchema
        kind = 'bundled-provider-manifest'
        id = $profileId
        relative_path = $relativePath
        sha256 = 'sha256:' + (
            Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
    }
}

function New-AiCliLocalGpuBrokerExecutionBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$RequestText,
        [Parameter(Mandatory)][long]$OwnerPid
    )

    $profileFingerprint = [string](Get-AiCliProperty $Plan 'profileFingerprint')
    if ($profileFingerprint -notmatch '^[0-9a-f]{64}$') {
        throw 'LocalGpuBroker execution binding requires the immutable profile fingerprint.'
    }
    $registrySource = Get-AiCliLocalGpuBrokerRegistrySource -Plan $Plan
    $requestSha256 = Get-AiCliLocalGpuBrokerTextSha256 -Text $RequestText
    $jobSource = [ordered]@{
        schema = 'aicli.local-gpu-broker-job-binding.v1'
        owner_pid = $OwnerPid
        request_sha256 = $requestSha256
        profile_id = [string](Get-AiCliProperty $Plan 'profileId')
        profile_fingerprint = "sha256:$profileFingerprint"
        model = [string](Get-AiCliProperty $Plan 'model')
        model_provider = [string](Get-AiCliProperty $Plan 'modelProvider')
        registry_source_sha256 = [string]$registrySource.sha256
    }
    $jobId = Get-AiCliLocalGpuBrokerTextSha256 -Text (
        $jobSource | ConvertTo-Json -Depth 10 -Compress
    )
    return [ordered]@{
        OwnerPid = $OwnerPid
        RequestSha256 = $requestSha256
        JobId = $jobId
        ExecutionId = [guid]::NewGuid().ToString('N')
        RegistrySource = $registrySource
    }
}

function Get-AiCliLocalGpuBrokerBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$ExecutionBinding
    )

    $runtime = Get-AiCliProperty $Plan 'machineRuntime'
    $configuration = Get-AiCliProperty $runtime 'localGpuBrokerSession'
    if ($null -eq $configuration) {
        throw 'The machine launch plan has no LocalGpuBroker session binding.'
    }
    $resolved = Resolve-AiCliLocalGpuBrokerSessionConfiguration `
        -Configuration $configuration `
        -Endpoint ([string](Get-AiCliProperty $Plan 'endpoint'))
    $fingerprint = [string](Get-AiCliProperty $Plan 'profileFingerprint')
    if ($fingerprint -notmatch '^[0-9a-f]{64}$') {
        throw 'LocalGpuBroker binding requires the immutable profile fingerprint.'
    }
    $source = [ordered]@{
        broker_origin = [string]$resolved.managementOrigin
        endpoint = ([string](Get-AiCliProperty $Plan 'endpoint')).TrimEnd('/')
        engine = [string](Get-AiCliProperty $Plan 'engine')
        execution_id = [string]$ExecutionBinding.ExecutionId
        job_id = [string]$ExecutionBinding.JobId
        model = [string](Get-AiCliProperty $Plan 'model')
        model_provider = [string](Get-AiCliProperty $Plan 'modelProvider')
        owner_pid = [long]$ExecutionBinding.OwnerPid
        profile_fingerprint = "sha256:$fingerprint"
        profile_id = [string](Get-AiCliProperty $Plan 'profileId')
        registry_source = $ExecutionBinding.RegistrySource
        request_sha256 = [string]$ExecutionBinding.RequestSha256
        schema = $script:AiCliLocalGpuBrokerBindingSchema
        wire = [string](Get-AiCliProperty $Plan 'wire')
    }
    foreach ($requiredValue in @(
        $source.engine,
        $source.model,
        $source.model_provider,
        $source.execution_id,
        $source.job_id,
        $source.profile_id,
        $source.request_sha256,
        $source.wire
    )) {
        if ([string]::IsNullOrWhiteSpace([string]$requiredValue)) {
            throw 'LocalGpuBroker binding source is incomplete.'
        }
    }
    $json = $source | ConvertTo-Json -Depth 10 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    try {
        $sha256 = 'sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($bytes)
        ).ToLowerInvariant()
    } finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
    return [pscustomobject]@{
        Source = $source
        Sha256 = $sha256
        ManagementOrigin = [string]$resolved.managementOrigin
    }
}

function New-AiCliLocalGpuBrokerBindingObservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Binding,
        [Parameter(Mandatory)]$Response
    )

    $source = $Binding.Source
    $observationSource = [ordered]@{
        schema = $script:AiCliLocalGpuBrokerBindingObservationSchema
        broker_instance_id = [string]$Response.broker_instance_id
        lease_id = [string]$Response.lease_id
        owner_pid = [long]$Response.owner_pid
        binding_sha256 = [string]$Binding.Sha256
        binding_schema = $script:AiCliLocalGpuBrokerBindingSchema
        job_id = [string]$source.job_id
        execution_id = [string]$source.execution_id
        request_sha256 = [string]$source.request_sha256
        profile_id = [string]$source.profile_id
        profile_fingerprint = [string]$source.profile_fingerprint
        model = [string]$source.model
        model_provider = [string]$source.model_provider
        registry_source = $source.registry_source
    }
    $observationSha256 = Get-AiCliLocalGpuBrokerTextSha256 -Text (
        $observationSource | ConvertTo-Json -Depth 20 -Compress
    )
    $observation = [ordered]@{}
    foreach ($key in $observationSource.Keys) {
        $observation[$key] = $observationSource[$key]
    }
    $observation['observation_sha256'] = $observationSha256
    return $observation
}

function Assert-AiCliLocalGpuBrokerBindingObservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Observation,
        $Session = $null
    )

    $expectedKeys = @(
        'schema', 'broker_instance_id', 'lease_id', 'owner_pid',
        'binding_sha256', 'binding_schema', 'job_id', 'execution_id',
        'request_sha256', 'profile_id', 'profile_fingerprint', 'model',
        'model_provider', 'registry_source', 'observation_sha256'
    )
    $actualKeys = if ($Observation -is [Collections.IDictionary]) {
        @($Observation.Keys | ForEach-Object { [string]$_ })
    } else {
        @($Observation.PSObject.Properties.Name)
    }
    $actualKeySet = @($actualKeys | Sort-Object) -join "`n"
    $expectedKeySet = @($expectedKeys | Sort-Object) -join "`n"
    if ($actualKeySet -cne $expectedKeySet) {
        throw 'LocalGpuBroker binding observation fields are invalid.'
    }
    $registrySource = Get-AiCliProperty $Observation 'registry_source'
    $registryKeys = @('schema', 'kind', 'id', 'relative_path', 'sha256')
    $actualRegistryKeys = if ($registrySource -is [Collections.IDictionary]) {
        @($registrySource.Keys | ForEach-Object { [string]$_ })
    } else {
        @($registrySource.PSObject.Properties.Name)
    }
    $actualRegistryKeySet = @($actualRegistryKeys | Sort-Object) -join "`n"
    $expectedRegistryKeySet = @($registryKeys | Sort-Object) -join "`n"
    if ($actualRegistryKeySet -cne $expectedRegistryKeySet -or
        [string](Get-AiCliProperty $Observation 'schema') -cne
            $script:AiCliLocalGpuBrokerBindingObservationSchema -or
        [string](Get-AiCliProperty $Observation 'binding_schema') -cne
            $script:AiCliLocalGpuBrokerBindingSchema -or
        [string](Get-AiCliProperty $Observation 'broker_instance_id') -notmatch '^[a-f0-9]{32}$' -or
        [string](Get-AiCliProperty $Observation 'lease_id') -notmatch '^[a-f0-9]{32}$' -or
        [string](Get-AiCliProperty $Observation 'execution_id') -notmatch '^[a-f0-9]{32}$' -or
        [string](Get-AiCliProperty $Observation 'binding_sha256') -notmatch '^sha256:[a-f0-9]{64}$' -or
        [string](Get-AiCliProperty $Observation 'job_id') -notmatch '^sha256:[a-f0-9]{64}$' -or
        [string](Get-AiCliProperty $Observation 'request_sha256') -notmatch '^sha256:[a-f0-9]{64}$' -or
        [string](Get-AiCliProperty $Observation 'profile_fingerprint') -notmatch '^sha256:[a-f0-9]{64}$' -or
        [string](Get-AiCliProperty $Observation 'observation_sha256') -notmatch '^sha256:[a-f0-9]{64}$' -or
        [string](Get-AiCliProperty $registrySource 'schema') -cne
            $script:AiCliLocalGpuBrokerRegistrySourceSchema -or
        [string](Get-AiCliProperty $registrySource 'kind') -cne
            'bundled-provider-manifest' -or
        [string](Get-AiCliProperty $registrySource 'sha256') -notmatch '^sha256:[a-f0-9]{64}$') {
        throw 'LocalGpuBroker binding observation identity is invalid.'
    }
    $observationSource = [ordered]@{}
    foreach ($key in $expectedKeys | Where-Object { $_ -cne 'observation_sha256' }) {
        $observationSource[$key] = Get-AiCliProperty $Observation $key
    }
    $expectedSha256 = Get-AiCliLocalGpuBrokerTextSha256 -Text (
        $observationSource | ConvertTo-Json -Depth 20 -Compress
    )
    if ([string](Get-AiCliProperty $Observation 'observation_sha256') -cne $expectedSha256) {
        throw 'LocalGpuBroker binding observation content hash is invalid.'
    }
    if ($Session) {
        $bindingSource = Get-AiCliProperty $Session 'BindingSource'
        $observationRegistryJson = (
            Get-AiCliProperty $Observation 'registry_source'
        ) | ConvertTo-Json -Depth 10 -Compress
        $bindingRegistryJson = (
            Get-AiCliProperty $bindingSource 'registry_source'
        ) | ConvertTo-Json -Depth 10 -Compress
        if ([long](Get-AiCliProperty $Observation 'owner_pid') -ne
                [long](Get-AiCliProperty $Session 'OwnerPid') -or
            [string](Get-AiCliProperty $Observation 'broker_instance_id') -cne
                [string](Get-AiCliProperty $Session 'BrokerInstanceId') -or
            [string](Get-AiCliProperty $Observation 'lease_id') -cne
                [string](Get-AiCliProperty $Session 'LeaseId') -or
            [string](Get-AiCliProperty $Observation 'binding_sha256') -cne
                [string](Get-AiCliProperty $Session 'BindingSha256') -or
            [string](Get-AiCliProperty $Observation 'job_id') -cne
                [string](Get-AiCliProperty $bindingSource 'job_id') -or
            [string](Get-AiCliProperty $Observation 'execution_id') -cne
                [string](Get-AiCliProperty $bindingSource 'execution_id') -or
            [string](Get-AiCliProperty $Observation 'request_sha256') -cne
                [string](Get-AiCliProperty $bindingSource 'request_sha256') -or
            [string](Get-AiCliProperty $Observation 'profile_id') -cne
                [string](Get-AiCliProperty $bindingSource 'profile_id') -or
            [string](Get-AiCliProperty $Observation 'profile_fingerprint') -cne
                [string](Get-AiCliProperty $bindingSource 'profile_fingerprint') -or
            [string](Get-AiCliProperty $Observation 'model') -cne
                [string](Get-AiCliProperty $bindingSource 'model') -or
            [string](Get-AiCliProperty $Observation 'model_provider') -cne
                [string](Get-AiCliProperty $bindingSource 'model_provider') -or
            $observationRegistryJson -cne $bindingRegistryJson) {
            throw 'LocalGpuBroker binding observation does not match its authority session.'
        }
    }
    return $Observation
}

function Write-AiCliLocalGpuBrokerAuthorityPrelude {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Observation,
        [IO.TextWriter]$Writer = [Console]::Out
    )

    if ($null -eq $Writer) {
        throw 'LocalGpuBroker authority prelude stdout writer is unavailable.'
    }
    $null = Assert-AiCliLocalGpuBrokerBindingObservation `
        -Observation $Observation
    $frame = [ordered]@{
        schema = $script:AiCliLocalGpuBrokerAuthorityPreludeSchema
        sequence = 1
        kind = 'local-gpu-broker.binding'
        observation_sha256 = [string](
            Get-AiCliProperty $Observation 'observation_sha256'
        )
        binding_observation = $Observation
    }
    $line = $frame | ConvertTo-Json -Depth 30 -Compress
    if ($line -match '(?i)capability') {
        throw 'LocalGpuBroker authority prelude contains a forbidden capability field.'
    }
    $Writer.WriteLine($line)
    $Writer.Flush()
}

function Invoke-AiCliLocalGpuBrokerHttp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST')][string]$Method,
        [Parameter(Mandatory)][string]$ManagementOrigin,
        [Parameter(Mandatory)][string]$Path,
        $Body = $null
    )

    if ($Path -notmatch '^/_gpu_broker/ollama-session/(?:acquire|renew|close|status)(?:\?lease_id=[a-f0-9]{32})?$') {
        throw 'LocalGpuBroker management path is invalid.'
    }
    $null = Resolve-AiCliLocalGpuBrokerSessionConfiguration `
        -Configuration ([ordered]@{
            contractVersion = 1
            requiredForMachineRun = $true
            managementOrigin = $ManagementOrigin
        }) `
        -Endpoint ($ManagementOrigin.TrimEnd('/') + '/v1')

    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseProxy = $false
    $client = [Net.Http.HttpClient]::new($handler, $true)
    $client.Timeout = [TimeSpan]::FromSeconds(5)
    $request = [Net.Http.HttpRequestMessage]::new(
        [Net.Http.HttpMethod]::$Method,
        ($ManagementOrigin.TrimEnd('/') + $Path)
    )
    try {
        if ($Method -eq 'POST') {
            $json = $Body | ConvertTo-Json -Depth 10 -Compress
            $request.Content = [Net.Http.StringContent]::new(
                $json,
                [Text.Encoding]::UTF8,
                'application/json'
            )
        }
        $response = $client.Send($request)
        try {
            $raw = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            try {
                $payload = $raw | ConvertFrom-Json -AsHashtable -Depth 20
            } catch {
                throw 'LocalGpuBroker management response is not valid JSON.'
            }
            if (-not $response.IsSuccessStatusCode) {
                $reason = [string](Get-AiCliProperty $payload 'reason' 'request_failed')
                throw "LocalGpuBroker management request failed: $reason"
            }
            return $payload
        } finally {
            $response.Dispose()
        }
    } finally {
        $request.Dispose()
        $client.Dispose()
    }
}

function Assert-AiCliLocalGpuBrokerResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Response,
        [Parameter(Mandatory)][string]$BindingSha256,
        [string]$BrokerInstanceId,
        [string]$LeaseId,
        [long]$OwnerPid = 0,
        [string]$OwnerProcessCreationTokenSha256,
        $PreviousResponse = $null,
        [switch]$Terminal
    )

    if ([string](Get-AiCliProperty $Response 'schema') -cne $script:AiCliLocalGpuBrokerSchema -or
        -not [bool](Get-AiCliProperty $Response 'ok' $false)) {
        throw 'LocalGpuBroker response schema or success state is invalid.'
    }
    foreach ($requiredName in @(
        'broker_instance_id', 'lease_id', 'owner', 'owner_pid',
        'owner_process_creation_token_sha256',
        'owner_process_exit_detected_at', 'binding_sha256', 'state',
        'active_requests', 'accepted_requests', 'completed_requests',
        'accepted_model_requests', 'completed_model_requests',
        'request_chain_sha256', 'acquired_at', 'expires_at', 'released_at',
        'release_reason'
    )) {
        if (-not (Test-AiCliMapHasKey -Map $Response -Key $requiredName)) {
            throw "LocalGpuBroker response field is missing: $requiredName"
        }
    }
    $actualInstance = [string](Get-AiCliProperty $Response 'broker_instance_id')
    $actualLease = [string](Get-AiCliProperty $Response 'lease_id')
    $actualBinding = [string](Get-AiCliProperty $Response 'binding_sha256')
    $actualOwnerPidValue = Get-AiCliProperty $Response 'owner_pid'
    $ownerPidIsInteger = $actualOwnerPidValue -is [sbyte] -or
        $actualOwnerPidValue -is [byte] -or
        $actualOwnerPidValue -is [int16] -or
        $actualOwnerPidValue -is [uint16] -or
        $actualOwnerPidValue -is [int32] -or
        $actualOwnerPidValue -is [uint32] -or
        $actualOwnerPidValue -is [int64] -or
        $actualOwnerPidValue -is [uint64]
    if (-not $ownerPidIsInteger) {
        throw 'LocalGpuBroker response owner pid is invalid.'
    }
    try {
        $actualOwnerPid = [Convert]::ToInt64(
            $actualOwnerPidValue,
            [Globalization.CultureInfo]::InvariantCulture
        )
    } catch {
        throw 'LocalGpuBroker response owner pid is invalid.'
    }
    $actualOwnerTokenSha256 = [string](
        Get-AiCliProperty $Response 'owner_process_creation_token_sha256'
    )
    if ($actualInstance -notmatch '^[a-f0-9]{32}$' -or
        $actualLease -notmatch '^[a-f0-9]{32}$' -or
        $actualBinding -cne $BindingSha256 -or
        [string](Get-AiCliProperty $Response 'owner') -cne 'aicli-machine-run' -or
        $actualOwnerPid -le 4 -or $actualOwnerPid -gt [uint32]::MaxValue -or
        ($OwnerPid -gt 0 -and $actualOwnerPid -ne $OwnerPid) -or
        $actualOwnerTokenSha256 -notmatch '^sha256:[a-f0-9]{64}$' -or
        ($OwnerProcessCreationTokenSha256 -and
            $actualOwnerTokenSha256 -cne $OwnerProcessCreationTokenSha256)) {
        throw 'LocalGpuBroker response identity or binding is invalid.'
    }
    if ($BrokerInstanceId -and $actualInstance -cne $BrokerInstanceId) {
        throw 'LocalGpuBroker instance changed during the machine run.'
    }
    if ($LeaseId -and $actualLease -cne $LeaseId) {
        throw 'LocalGpuBroker lease changed during the machine run.'
    }
    $state = [string](Get-AiCliProperty $Response 'state')
    if ($state -notin @('acquired', 'closing', 'released')) {
        throw 'LocalGpuBroker response state is invalid.'
    }
    $counts = [ordered]@{}
    foreach ($countName in @(
        'active_requests',
        'accepted_requests',
        'completed_requests',
        'accepted_model_requests',
        'completed_model_requests'
    )) {
        $value = Get-AiCliProperty $Response $countName
        $isIntegerType = $value -is [sbyte] -or $value -is [byte] -or
            $value -is [int16] -or $value -is [uint16] -or
            $value -is [int32] -or $value -is [uint32] -or
            $value -is [int64] -or $value -is [uint64]
        if (-not $isIntegerType) {
            throw "LocalGpuBroker response count is invalid: $countName"
        }
        try {
            $count = [Convert]::ToInt64(
                $value,
                [Globalization.CultureInfo]::InvariantCulture
            )
        } catch {
            throw "LocalGpuBroker response count is invalid: $countName"
        }
        if ($count -lt 0) {
            throw "LocalGpuBroker response count is invalid: $countName"
        }
        $counts[$countName] = $count
    }
    if ($counts.completed_requests -gt $counts.accepted_requests -or
        $counts.completed_model_requests -gt $counts.accepted_model_requests -or
        $counts.accepted_model_requests -gt $counts.accepted_requests -or
        $counts.completed_model_requests -gt $counts.completed_requests) {
        throw 'LocalGpuBroker response completion counts are invalid.'
    }
    $outstandingRequests = $counts.accepted_requests - $counts.completed_requests
    $outstandingModelRequests = (
        $counts.accepted_model_requests - $counts.completed_model_requests
    )
    if ($counts.active_requests -ne $outstandingRequests -or
        $counts.active_requests -gt 1 -or
        $outstandingModelRequests -gt $counts.active_requests) {
        throw 'LocalGpuBroker response active-request counts are invalid.'
    }
    if ([string](Get-AiCliProperty $Response 'request_chain_sha256') -notmatch
        '^sha256:[0-9a-f]{64}$') {
        throw 'LocalGpuBroker request-chain receipt is invalid.'
    }
    $readTimestamp = {
        param([string]$Name, [bool]$AllowNull)
        $timeValue = Get-AiCliProperty $Response $Name
        if ($null -eq $timeValue -and $AllowNull) { return $null }
        $isNumericType = $timeValue -is [sbyte] -or $timeValue -is [byte] -or
            $timeValue -is [int16] -or $timeValue -is [uint16] -or
            $timeValue -is [int32] -or $timeValue -is [uint32] -or
            $timeValue -is [int64] -or $timeValue -is [uint64] -or
            $timeValue -is [single] -or $timeValue -is [double] -or
            $timeValue -is [decimal]
        if (-not $isNumericType) {
            throw "LocalGpuBroker response time is invalid: $Name"
        }
        try {
            $time = [Convert]::ToDouble(
                $timeValue,
                [Globalization.CultureInfo]::InvariantCulture
            )
        } catch {
            throw "LocalGpuBroker response time is invalid: $Name"
        }
        if ([double]::IsNaN($time) -or [double]::IsInfinity($time) -or $time -le 0) {
            throw "LocalGpuBroker response time is invalid: $Name"
        }
        return $time
    }
    $acquiredAt = & $readTimestamp 'acquired_at' $false
    $expiresAt = & $readTimestamp 'expires_at' $false
    $releasedAt = & $readTimestamp 'released_at' $true
    $ownerExitDetectedAt = & $readTimestamp 'owner_process_exit_detected_at' $true
    $releaseReasonValue = Get-AiCliProperty $Response 'release_reason'
    $releaseReason = if ($null -eq $releaseReasonValue) {
        $null
    } else {
        [string]$releaseReasonValue
    }
    $allowedReleaseReasons = @(
        'normal', 'cancelled', 'timeout', 'launch_failed', 'cleanup_failed',
        'expired', 'owner-exited'
    )
    if ($expiresAt -le $acquiredAt -or
        ($state -ceq 'acquired' -and
            ($null -ne $releaseReason -or $null -ne $releasedAt -or
                $null -ne $ownerExitDetectedAt)) -or
        ($state -ceq 'closing' -and
            ($releaseReason -notin $allowedReleaseReasons -or $null -ne $releasedAt)) -or
        ($state -ceq 'released' -and
            ($releaseReason -notin $allowedReleaseReasons -or $null -eq $releasedAt)) -or
        ($releaseReason -ceq 'owner-exited' -and
            ($null -eq $ownerExitDetectedAt -or
                $ownerExitDetectedAt -lt $acquiredAt)) -or
        ($null -ne $ownerExitDetectedAt -and $releaseReason -cne 'owner-exited') -or
        ($null -ne $releasedAt -and $releasedAt -lt $acquiredAt) -or
        ($releaseReason -ceq 'expired' -and $null -ne $releasedAt -and
            $releasedAt -lt $expiresAt) -or
        ($releaseReason -ceq 'owner-exited' -and $null -ne $releasedAt -and
            $releasedAt -lt $ownerExitDetectedAt)) {
        throw 'LocalGpuBroker response state, time, or release provenance is invalid.'
    }
    if ($PreviousResponse) {
        $null = Assert-AiCliLocalGpuBrokerResponse `
            -Response $PreviousResponse -BindingSha256 $BindingSha256 `
            -BrokerInstanceId $BrokerInstanceId -LeaseId $LeaseId `
            -OwnerPid $OwnerPid `
            -OwnerProcessCreationTokenSha256 $OwnerProcessCreationTokenSha256
        foreach ($identityName in @(
            'broker_instance_id', 'lease_id', 'owner', 'owner_pid',
            'owner_process_creation_token_sha256', 'binding_sha256', 'acquired_at'
        )) {
            if ([string](Get-AiCliProperty $Response $identityName) -cne
                [string](Get-AiCliProperty $PreviousResponse $identityName)) {
                throw "LocalGpuBroker response identity drifted: $identityName"
            }
        }
        $previousExpiresAt = [double](Get-AiCliProperty $PreviousResponse 'expires_at')
        if ($expiresAt -lt $previousExpiresAt) {
            throw 'LocalGpuBroker response expiry regressed.'
        }
        foreach ($countName in @(
            'accepted_requests', 'completed_requests',
            'accepted_model_requests', 'completed_model_requests'
        )) {
            if ($counts[$countName] -lt
                [long](Get-AiCliProperty $PreviousResponse $countName)) {
                throw "LocalGpuBroker response count regressed: $countName"
            }
        }
        $previousState = [string](Get-AiCliProperty $PreviousResponse 'state')
        $validStateTransition = switch ($previousState) {
            'acquired' { $state -in @('acquired', 'closing', 'released'); break }
            'closing' { $state -in @('closing', 'released'); break }
            'released' { $state -ceq 'released'; break }
            default { $false }
        }
        if (-not $validStateTransition) {
            throw 'LocalGpuBroker response state regressed.'
        }
        $previousReasonValue = Get-AiCliProperty $PreviousResponse 'release_reason'
        $previousReason = if ($null -eq $previousReasonValue) {
            $null
        } else {
            [string]$previousReasonValue
        }
        if ($null -ne $previousReason -and $releaseReason -cne $previousReason) {
            throw 'LocalGpuBroker response release provenance changed.'
        }
        $previousDetected = Get-AiCliProperty $PreviousResponse 'owner_process_exit_detected_at'
        if ($null -ne $previousDetected -and
            [double]$ownerExitDetectedAt -ne [double]$previousDetected) {
            throw 'LocalGpuBroker owner-exit detection time changed.'
        }
        $previousReleased = Get-AiCliProperty $PreviousResponse 'released_at'
        if ($null -ne $previousReleased -and
            [double]$releasedAt -ne [double]$previousReleased) {
            throw 'LocalGpuBroker release time changed.'
        }
        $previousCompleted = [long](
            Get-AiCliProperty $PreviousResponse 'completed_requests'
        )
        $previousChain = [string](
            Get-AiCliProperty $PreviousResponse 'request_chain_sha256'
        )
        $actualChain = [string](Get-AiCliProperty $Response 'request_chain_sha256')
        if (($counts.completed_requests -eq $previousCompleted -and
                $actualChain -cne $previousChain) -or
            ($counts.completed_requests -gt $previousCompleted -and
                $actualChain -ceq $previousChain)) {
            throw 'LocalGpuBroker request-chain provenance is inconsistent.'
        }
    }
    if ($Terminal -and
        ($state -cne 'released' -or
            $counts.active_requests -ne 0 -or
            $counts.accepted_requests -ne $counts.completed_requests -or
            $counts.accepted_model_requests -ne $counts.completed_model_requests)) {
        throw 'LocalGpuBroker terminal receipt is incomplete.'
    }
    return $Response
}

function Open-AiCliLocalGpuBrokerSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$RequestText,
        [int]$TimeoutMs = 0
    )

    $ownerPid = [long][Environment]::ProcessId
    $executionBinding = New-AiCliLocalGpuBrokerExecutionBinding `
        -Plan $Plan -RequestText $RequestText -OwnerPid $ownerPid
    $binding = Get-AiCliLocalGpuBrokerBinding -Plan $Plan `
        -ExecutionBinding $executionBinding
    $acquired = Invoke-AiCliLocalGpuBrokerHttp -Method POST `
        -ManagementOrigin $binding.ManagementOrigin `
        -Path '/_gpu_broker/ollama-session/acquire' `
        -Body ([ordered]@{
            owner = 'aicli-machine-run'
            owner_pid = $ownerPid
            binding_sha256 = $binding.Sha256
            ttl_seconds = 30
        })
    $null = Assert-AiCliLocalGpuBrokerResponse -Response $acquired `
        -BindingSha256 $binding.Sha256 -OwnerPid $ownerPid
    $capability = [string](Get-AiCliProperty $acquired 'capability')
    if ($capability -notmatch '^[A-Za-z0-9_-]{32,256}$') {
        throw 'LocalGpuBroker returned an invalid opaque capability.'
    }
    $session = [ordered]@{
        ManagementOrigin = $binding.ManagementOrigin
        BindingSource = $binding.Source
        BindingSha256 = $binding.Sha256
        BrokerInstanceId = [string]$acquired.broker_instance_id
        LeaseId = [string]$acquired.lease_id
        OwnerPid = $ownerPid
        OwnerProcessCreationTokenSha256 = [string](
            Get-AiCliProperty $acquired 'owner_process_creation_token_sha256'
        )
        OwnerProcessExitDetectedAt = Get-AiCliProperty $acquired `
            'owner_process_exit_detected_at'
        Capability = $capability
        Renewed = $false
        LastVerifiedResponse = $acquired
        BindingObservation = $null
        CloseRequested = $false
        CloseReason = $null
        CloseResponse = $null
        CloseAttemptError = $null
        TerminalReceipt = $null
    }
    $renewTtlSeconds = if ($TimeoutMs -gt 0) {
        [Math]::Min(86400, [Math]::Max(300, [Math]::Ceiling($TimeoutMs / 1000) + 300))
    } else {
        86400
    }
    try {
        $renewed = Invoke-AiCliLocalGpuBrokerHttp -Method POST `
            -ManagementOrigin $session.ManagementOrigin `
            -Path '/_gpu_broker/ollama-session/renew' `
            -Body ([ordered]@{
                lease_id = $session.LeaseId
                capability = $session.Capability
                binding_sha256 = $session.BindingSha256
                ttl_seconds = [int]$renewTtlSeconds
            })
        $null = Assert-AiCliLocalGpuBrokerResponse -Response $renewed `
            -BindingSha256 $session.BindingSha256 `
            -BrokerInstanceId $session.BrokerInstanceId `
            -LeaseId $session.LeaseId -OwnerPid $session.OwnerPid `
            -OwnerProcessCreationTokenSha256 `
                $session.OwnerProcessCreationTokenSha256 `
            -PreviousResponse $session.LastVerifiedResponse
        if ([string]$renewed.state -cne 'acquired') {
            throw 'LocalGpuBroker session did not remain acquired after renewal.'
        }
        $session.LastVerifiedResponse = $renewed
        $session.Renewed = $true
        $session.BindingObservation = New-AiCliLocalGpuBrokerBindingObservation `
            -Binding $binding -Response $renewed
        $null = Assert-AiCliLocalGpuBrokerBindingObservation `
            -Observation $session.BindingObservation -Session $session
        return $session
    } catch {
        try {
            $null = Request-AiCliLocalGpuBrokerSessionClose `
                -Session $session -Reason launch_failed
        } catch {}
        throw
    }
}

function Set-AiCliLocalGpuBrokerSessionEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$EnvironmentDelta,
        [Parameter(Mandatory)]$Session
    )

    foreach ($name in @(
        $script:AiCliLocalGpuBrokerLeaseEnvironment,
        $script:AiCliLocalGpuBrokerCapabilityEnvironment
    )) {
        if ($EnvironmentDelta.ContainsKey($name)) {
            throw "Reserved LocalGpuBroker child environment already exists: $name"
        }
    }
    $EnvironmentDelta[$script:AiCliLocalGpuBrokerLeaseEnvironment] = [string]$Session.LeaseId
    $EnvironmentDelta[$script:AiCliLocalGpuBrokerCapabilityEnvironment] = [string]$Session.Capability
}

function Clear-AiCliLocalGpuBrokerSessionEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$EnvironmentDelta,
        [Parameter(Mandatory)]$Session
    )

    foreach ($name in @(
        $script:AiCliLocalGpuBrokerLeaseEnvironment,
        $script:AiCliLocalGpuBrokerCapabilityEnvironment
    )) {
        if ($EnvironmentDelta.ContainsKey($name)) {
            [void]$EnvironmentDelta.Remove($name)
        }
    }
    $Session.Capability = $null
}

function Request-AiCliLocalGpuBrokerSessionClose {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]
        [ValidateSet('normal', 'cancelled', 'timeout', 'launch_failed', 'cleanup_failed')]
        [string]$Reason
    )

    if ([bool]$Session.CloseRequested) {
        return $Session.CloseResponse
    }
    $response = Invoke-AiCliLocalGpuBrokerHttp -Method POST `
        -ManagementOrigin ([string]$Session.ManagementOrigin) `
        -Path '/_gpu_broker/ollama-session/close' `
        -Body ([ordered]@{
            lease_id = [string]$Session.LeaseId
            capability = [string]$Session.Capability
            binding_sha256 = [string]$Session.BindingSha256
            reason = $Reason
        })
    $null = Assert-AiCliLocalGpuBrokerResponse -Response $response `
        -BindingSha256 ([string]$Session.BindingSha256) `
        -BrokerInstanceId ([string]$Session.BrokerInstanceId) `
        -LeaseId ([string]$Session.LeaseId) `
        -OwnerPid ([long]$Session.OwnerPid) `
        -OwnerProcessCreationTokenSha256 `
            ([string]$Session.OwnerProcessCreationTokenSha256) `
        -PreviousResponse $Session.LastVerifiedResponse
    if ([string]$response.state -notin @('closing', 'released')) {
        throw 'LocalGpuBroker rejected the session close transition.'
    }
    $Session.CloseRequested = $true
    $Session.CloseReason = $Reason
    $Session.CloseResponse = $response
    $Session.LastVerifiedResponse = $response
    return $response
}

function New-AiCliLocalGpuBrokerBeforeStopAction {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $closeSession = (
        Get-Command -Name Request-AiCliLocalGpuBrokerSessionClose `
            -CommandType Function -ErrorAction Stop
    ).ScriptBlock
    return {
        param($Reason, $Process)
        try {
            $null = & $closeSession `
                -Session $Session -Reason $Reason
        } catch {
            $Session.CloseAttemptError = $_.Exception.GetType().FullName
            throw
        }
    }.GetNewClosure()
}

function Complete-AiCliLocalGpuBrokerSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]
        [ValidateSet('normal', 'cancelled', 'timeout', 'launch_failed', 'cleanup_failed')]
        [string]$Reason
    )

    $response = if ([bool]$Session.CloseRequested) {
        $Session.CloseResponse
    } else {
        Request-AiCliLocalGpuBrokerSessionClose -Session $Session -Reason $Reason
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([string]$response.state -cne 'released') {
        if ([DateTime]::UtcNow -ge $deadline) {
            throw 'LocalGpuBroker session did not reach a terminal state after cleanup.'
        }
        Start-Sleep -Milliseconds 50
        $previousResponse = $response
        $response = Invoke-AiCliLocalGpuBrokerHttp -Method GET `
            -ManagementOrigin ([string]$Session.ManagementOrigin) `
            -Path ('/_gpu_broker/ollama-session/status?lease_id=' + [string]$Session.LeaseId)
        $null = Assert-AiCliLocalGpuBrokerResponse -Response $response `
            -BindingSha256 ([string]$Session.BindingSha256) `
            -BrokerInstanceId ([string]$Session.BrokerInstanceId) `
            -LeaseId ([string]$Session.LeaseId) `
            -OwnerPid ([long]$Session.OwnerPid) `
            -OwnerProcessCreationTokenSha256 `
                ([string]$Session.OwnerProcessCreationTokenSha256) `
            -PreviousResponse $previousResponse
        $Session.LastVerifiedResponse = $response
    }
    $null = Assert-AiCliLocalGpuBrokerResponse -Response $response `
        -BindingSha256 ([string]$Session.BindingSha256) `
        -BrokerInstanceId ([string]$Session.BrokerInstanceId) `
        -LeaseId ([string]$Session.LeaseId) `
        -OwnerPid ([long]$Session.OwnerPid) `
        -OwnerProcessCreationTokenSha256 `
            ([string]$Session.OwnerProcessCreationTokenSha256) -Terminal
    $null = Assert-AiCliLocalGpuBrokerBindingObservation `
        -Observation $Session.BindingObservation -Session $Session
    $requestedReason = [string]$Session.CloseReason
    $releaseReason = [string]$response.release_reason
    if ($requestedReason -notin @(
        'normal', 'cancelled', 'timeout', 'launch_failed', 'cleanup_failed'
    ) -or ($releaseReason -cne $requestedReason -and $releaseReason -cne 'expired')) {
        throw 'LocalGpuBroker terminal release reason does not match its first-writer provenance.'
    }
    $receipt = [pscustomobject][ordered]@{
        schema = $script:AiCliLocalGpuBrokerReceiptSchema
        verified = $true
        broker_schema = $script:AiCliLocalGpuBrokerSchema
        broker_instance_id = [string]$response.broker_instance_id
        lease_id = [string]$response.lease_id
        owner = [string]$response.owner
        owner_pid = [long]$response.owner_pid
        owner_process_creation_token_sha256 = [string](
            Get-AiCliProperty $response 'owner_process_creation_token_sha256'
        )
        owner_process_exit_detected_at = Get-AiCliProperty $response `
            'owner_process_exit_detected_at'
        binding_sha256 = [string]$response.binding_sha256
        binding_source = $Session.BindingSource
        binding_observation = $Session.BindingObservation
        state = [string]$response.state
        active_requests = [long]$response.active_requests
        accepted_requests = [long]$response.accepted_requests
        completed_requests = [long]$response.completed_requests
        accepted_model_requests = [long]$response.accepted_model_requests
        completed_model_requests = [long]$response.completed_model_requests
        request_chain_sha256 = [string]$response.request_chain_sha256
        acquired_at = [double]$response.acquired_at
        expires_at = [double]$response.expires_at
        released_at = [double]$response.released_at
        release_reason = [string]$response.release_reason
        close_reason_requested = [string]$Session.CloseReason
        renewed = [bool]$Session.Renewed
    }
    $Session.TerminalReceipt = $receipt
    return $receipt
}
