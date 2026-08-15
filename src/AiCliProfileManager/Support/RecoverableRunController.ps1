#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ModuleManifest,
    [Parameter(Mandatory)][string]$RunId,
    [string]$TaskPipeName = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$taskText = $null
if (-not [string]::IsNullOrWhiteSpace($TaskPipeName)) {
    if ($TaskPipeName -notmatch '\Aaicli-recovery-[a-f0-9]{32}\z') {
        throw 'Recoverable controller task pipe name is invalid.'
    }
    $pipe = [IO.Pipes.NamedPipeClientStream]::new(
        '.',
        $TaskPipeName,
        [IO.Pipes.PipeDirection]::In,
        [IO.Pipes.PipeOptions]::Asynchronous
    )
    try {
        $pipe.Connect(10000)
        $reader = [IO.StreamReader]::new(
            $pipe,
            [Text.UTF8Encoding]::new($false, $true),
            $true,
            4096,
            $true
        )
        try { $taskText = $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally {
        $pipe.Dispose()
    }
}

$module = Import-Module -Name $ModuleManifest -Force -PassThru -ErrorAction Stop
$result = & $module {
    param($BoundRunId, $BoundTaskText)
    Invoke-AiCliRecoverableRun -RunId $BoundRunId `
        -InitialTaskText $BoundTaskText
} $RunId $taskText

if ($result.status -eq 'completed') { exit 0 }
if ($result.status -in @(
    'running','interrupted','quota_paused','reconciliation_pending',
    'abort_requested'
)) { exit 75 }
exit 5
