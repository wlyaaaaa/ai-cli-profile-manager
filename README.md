# AICLI（AI 命令行启动与配置工具）

- **这是什么：**在 Windows 上统一配置和启动 Codex、Claude Code 等 AI 工具，保留它们原来的界面和会话。
- **我怎么用：**已安装时打开 PowerShell 7，运行 `aicli`，选择要用的工具和模型。
- **怎么知道它正常：**运行 `aicli doctor` 看检查结果，再实际发一个简单任务，确认能完成。
- **坏了怎么提醒我：**启动或检查失败会显示原因；没有自动提醒，出问题直接跟 AI 说。
- **让 AI 做什么：**帮我选配置、检查故障和更新工具，保留已有登录、模型选择和原会话。

首次安装：在本目录运行 `pwsh -File .\scripts\Install.ps1`，新开 PowerShell 7 后运行 `aicli setup`。
当前版本 0.3.18。Gemini 暂时停用。
