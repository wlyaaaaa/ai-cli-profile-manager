@{
    RootModule        = 'AiCliProfileManager.psm1'
    ModuleVersion     = '0.3.6'
    GUID              = 'a1c11c11-0a11-4c11-b111-a1c110110011'
    Author            = 'AI CLI Profile Manager Contributors'
    CompanyName       = 'Independent'
    Copyright         = 'Copyright (c) 2026 AI CLI Profile Manager Contributors'
    Description       = 'Windows PowerShell profile launcher and sandboxed machine runner for Codex CLI, Claude Code, Qwen Code, OpenCode, and Open Interpreter.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @('Invoke-AiCli', 'aicli', 'Get-AiCliBrand', 'Get-AiCliVersion', 'Get-AiCliAppPaths')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags         = @('Codex', 'Claude', 'QwenCode', 'OpenCode', 'OpenInterpreter', 'Ollama', 'Qwen', 'DeepSeek', 'CLI', 'Windows', 'Profile', 'Sandbox')
            LicenseUri   = 'https://github.com/wlyaaaaa/ai-cli-profile-manager/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/wlyaaaaa/ai-cli-profile-manager'
            ReleaseNotes = '0.3.6：新增隔离 exact codex-qwen3-7-max-paygo → qwen3.7-max-2026-06-08；旧 Qwen3.7 alias/Plus/Profile 继续退役；Responses、max→xhigh、SecretRef 与 no-fallback 封闭。'
        }
    }
}
