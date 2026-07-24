@{
    RootModule        = 'AiCliProfileManager.psm1'
    ModuleVersion     = '0.3.1'
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
            ReleaseNotes = '0.3.1：增加 Spark xhigh 精确 Profile，并以最小临时 CODEX_HOME 和 Codex 原生沙箱支持官方云模型 machine run。'
        }
    }
}
