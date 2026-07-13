# 隐私说明 / Privacy

AI CLI Profile Manager 默认不包含产品遥测，也不收集提示或回复正文。

## 本机保存的数据

| 内容 | 默认位置 | 说明 |
|------|----------|------|
| Profile、书签、默认项和非秘密设置 | `%APPDATA%\AiCliProfileManager` | 可随用户配置保存 |
| API Key 密文 | `%LOCALAPPDATA%\AiCliProfileManager\secrets` | Windows DPAPI CurrentUser；失败时不回退明文 |
| 代理二进制、配置、OAuth 数据、状态和缓存 | `%LOCALAPPDATA%\AiCliProfileManager` | 每个代理隔离；本工具不读取 token 正文 |
| 脱敏日志 | `%LOCALAPPDATA%\AiCliProfileManager\logs` | 不保存提示、回复、API Key 或 OAuth 正文 |
| 命令垫片 | `%LOCALAPPDATA%\aicli\bin` | 仅用于从终端找到本工具 |

## 哪些数据会离开本机

取决于你选择的 Profile。启动云端 Profile 或运行 Live Test 时，提示、项目上下文、工具请求和相关数据会发送到 `profile show` 所列的 OpenAI、Anthropic、阿里云百炼、DeepSeek、自定义端点或第三方本地代理。Ollama Profile 默认连接本机 `127.0.0.1:11434`。

Open Interpreter 可在本机执行代码；使用云端 OI Profile 时，模型请求发送到所选 Provider，代码和命令仍可能在本机运行。aicli 将 OI 云端 Key 仅注入目标子进程，并从 OI Shell 工具环境中排除，但这不能代替用户检查 `/permissions` 和项目可信度。

ChatGPT 双代理是可选第三方程序。OAuth 登录由代理自己完成，认证数据保存在每个代理的隔离目录；本产品不读取或展示 refresh token。

## Live Test

Live Test 必须显式使用 `--live`，会联系目标 Provider，并可能消耗 API 或订阅额度。测试在临时空目录运行；产品只保存脱敏的结构化结果、版本、端点、模型和 Profile 指纹，不保存提示或回复正文。

## 删除与远程撤销

普通卸载会移除本工具模块、`aicli` 命令垫片、安装器加入的用户 `PATH` 项和带产品标记的 PowerShell Profile 自动导入块；默认仍保留用户 Profile、DPAPI 密钥和代理数据，便于重装恢复。`aicli uninstall --purge-user-data --yes` 才同时删除本工具的本地数据。

删除本地代理 OAuth 文件不等于远程撤销授权。请另外在对应账号的安全或已授权应用页面确认撤销。

完整操作见《[AI CLI Profile Manager 使用手册](<docs/user/AI CLI Profile Manager 使用手册.md>)》的“卸载、恢复与数据”。
