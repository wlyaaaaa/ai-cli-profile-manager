@{
    RootModule        = 'AiCliProfileManager.psm1'
    ModuleVersion     = '0.3.12'
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
            ReleaseNotes = '0.3.12：新增显式 Agent Live 验收，以可恢复 exact thread 完成隔离文件任务并由独立 verifier 判定。'
        }
    }
}
