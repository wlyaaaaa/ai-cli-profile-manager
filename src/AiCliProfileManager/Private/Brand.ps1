# UTF-8 BOM required for Chinese constants
# Brand and product constants — single source of truth

$script:AiCliBrand = [ordered]@{
    ProductName   = 'AI CLI Profile Manager'
    CommandName   = 'aicli'
    ModuleName    = 'AiCliProfileManager'
    Version       = '0.3.12'
    SchemaVersion = 1
    License       = 'MIT'
    HomeHint      = 'Local PowerShell module; GitHub remote not required for first install'
}

function Get-AiCliBrand {
    [CmdletBinding()]
    param()
    return $script:AiCliBrand
}

function Get-AiCliProductName {
    return $script:AiCliBrand.ProductName
}

function Get-AiCliCommandName {
    return $script:AiCliBrand.CommandName
}

function Get-AiCliVersion {
    return $script:AiCliBrand.Version
}

# Exit codes per implementation plan §6.5
$script:AiCliExitCode = [ordered]@{
    Success           = 0
    UsageError        = 2
    Limited           = 3
    Unavailable       = 4
    InternalError     = 5
    Cancelled         = 6
}

function Get-AiCliExitCode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Success','UsageError','Limited','Unavailable','InternalError','Cancelled')]
        [string]$Name
    )
    return [int]$script:AiCliExitCode[$Name]
}

# Product status vocabulary (closed set)
$script:AiCliStatus = @{
    Pass    = '通过'
    Ready   = '可用'
    Limited = '可用但有限制'
    Fail    = '不可用'
}

function Get-AiCliStatusLabel {
    param([ValidateSet('Pass','Ready','Limited','Fail')][string]$Key)
    return $script:AiCliStatus[$Key]
}

# Variables that can hijack official Claude / Codex providers
$script:AiCliClaudeProviderVars = @(
    'ANTHROPIC_API_KEY',
    'ANTHROPIC_AUTH_TOKEN',
    'ANTHROPIC_BASE_URL',
    'ANTHROPIC_MODEL',
    'ANTHROPIC_DEFAULT_HAIKU_MODEL',
    'ANTHROPIC_DEFAULT_SONNET_MODEL',
    'ANTHROPIC_DEFAULT_OPUS_MODEL',
    'ANTHROPIC_SMALL_FAST_MODEL',
    'CLAUDE_CODE_USE_BEDROCK',
    'CLAUDE_CODE_USE_VERTEX',
    'CLAUDE_CODE_USE_FOUNDRY'
)

$script:AiCliCodexProviderVars = @(
    'OPENAI_API_KEY',
    'OPENAI_BASE_URL',
    'CODEX_API_KEY',
    'DASHSCOPE_API_KEY',
    'QWEN_API_KEY'
)

# Reserved Codex provider IDs that must not be overridden by custom templates
$script:AiCliCodexReservedProviderIds = @('openai', 'ollama', 'lmstudio')

# Proxy IDs
$script:AiCliProxyIds = @('ccp', 'cliproxy')
