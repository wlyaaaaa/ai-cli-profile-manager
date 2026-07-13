# Text UI helpers — no fullscreen TUI.

function Write-AiCliInfo {
    param([string]$Message)
    Write-Host (Protect-AiCliSecretText $Message)
}

function Write-AiCliWarn {
    param([string]$Message)
    Write-Host (Protect-AiCliSecretText $Message) -ForegroundColor Yellow
}

function Write-AiCliErrorLine {
    param([string]$Message)
    Write-Host (Protect-AiCliSecretText $Message) -ForegroundColor Red
}

function Write-AiCliSuccess {
    param([string]$Message)
    Write-Host (Protect-AiCliSecretText $Message) -ForegroundColor Green
}

function Write-AiCliJson {
    param($Object)
    $safe = Protect-AiCliObject -InputObject $Object
    $json = $safe | ConvertTo-Json -Depth 100
    # Use console stdout so function return value stays a pure exit code
    [Console]::Out.WriteLine($json)
}

function Read-AiCliSecret {
    [CmdletBinding()]
    param([string]$Prompt = '请输入 API Key（输入时不回显）')
    Write-Host $Prompt
    $secure = Read-Host -AsSecureString
    if ($null -eq $secure) { return $null }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Confirm-AiCliAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [switch]$Yes
    )
    if ($Yes) { return $true }
    Write-Host $Message
    $ans = Read-Host '确认请输入 yes'
    return ($ans -eq 'yes')
}

function Show-AiCliMenu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string[]]$Choices
    )
    Write-Host ''
    Write-Host $Title
    for ($i = 0; $i -lt $Choices.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $Choices[$i])
    }
    Write-Host '  [0] 取消'
    $sel = Read-Host '选择编号'
    $n = 0
    if (-not [int]::TryParse($sel, [ref]$n)) { return $null }
    if ($n -eq 0) { return $null }
    if ($n -lt 1 -or $n -gt $Choices.Count) { return $null }
    return ($n - 1)
}

function New-AiCliResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][ValidateSet('通过','可用','可用但有限制','不可用')][string]$OverallStatus,
        [hashtable[]]$Checks = @(),
        [hashtable]$Extra = @{}
    )
    $brand = Get-AiCliBrand
    $obj = [ordered]@{
        schemaVersion  = $brand.SchemaVersion
        command        = $Command
        overallStatus  = $OverallStatus
        timestampUtc   = (Get-Date).ToUniversalTime().ToString('o')
        productVersion = $brand.Version
        checks         = @($Checks)
    }
    foreach ($k in $Extra.Keys) { $obj[$k] = $Extra[$k] }
    return $obj
}

function Get-AiCliExitCodeFromStatus {
    param([string]$OverallStatus)
    switch ($OverallStatus) {
        '通过' { return (Get-AiCliExitCode Success) }
        '可用' { return (Get-AiCliExitCode Success) }
        '可用但有限制' { return (Get-AiCliExitCode Limited) }
        '不可用' { return (Get-AiCliExitCode Unavailable) }
        default { return (Get-AiCliExitCode InternalError) }
    }
}

function Write-AiCliDoctorText {
    param($Result)
    Write-Host ("命令：{0}" -f $Result.command)
    Write-Host ("结论：{0}" -f $Result.overallStatus)
    Write-Host ("时间：{0}" -f $Result.timestampUtc)
    Write-Host ''
    foreach ($c in @($Result.checks)) {
        $status = Get-AiCliProperty $c 'status'
        $id = Get-AiCliProperty $c 'id'
        $summary = Get-AiCliProperty $c 'summary'
        $next = Get-AiCliProperty $c 'nextStep'
        $mark = switch ($status) {
            '通过' { '[通过]' }
            '可用' { '[可用]' }
            '可用但有限制' { '[限制]' }
            '不可用' { '[失败]' }
            default { '[?]' }
        }
        Write-Host ("{0} {1}  {2}" -f $mark, $id, $summary)
        if ($next) {
            Write-Host ("       下一步：{0}" -f $next)
        }
    }
}
