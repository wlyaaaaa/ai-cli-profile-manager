# 安全策略 / Security Policy

## 私下报告漏洞

请使用 GitHub 仓库 **Security** 页中的 **Report a vulnerability / Private vulnerability reporting** 创建私密 Security Advisory 草稿。若当前仓库尚未启用该入口，请等待维护者启用后再提交敏感细节；不要把漏洞利用、API Key、OAuth 数据、机器路径或个人数据发到公开 Issue。

本项目不虚构未配置的安全邮箱。普通、不含敏感信息的缺陷可以使用公开 Issue；安全漏洞应走 GitHub 私密渠道。

## 支持范围

- 当前支持分支：`0.1.x` 及其后续安全修复。
- 平台：Windows 11 x64、PowerShell 7。
- 上游 Codex、Claude Code、Open Interpreter、Ollama 和第三方代理仍受各自安全策略约束。

## 产品安全边界

- API Key 使用 Windows DPAPI CurrentUser 保存，不进入命令参数、Git、日志、Doctor JSON、异常、导出脚本或测试快照。
- Provider 环境只注入目标子进程；不永久改写全局 Provider 变量或用户基础配置。
- 自定义远程明文 HTTP 默认拒绝；仅允许 HTTPS 或 localhost HTTP。
- 受管代理只允许 IPv4 loopback `127.0.0.1`，不开放防火墙或远程管理。
- 第三方代理 Windows artifact 必须匹配产品批准的精确 SHA256，并在安装前通过安全解压与结构验证；启动时还必须通过进程身份、健康响应和 IPv4 loopback 监听验证，才会保存运行状态。`0.1.0` 不执行已安装代理的受管版本切换。
- Live Tool Test 只允许隔离的单用途 nonce 工具；无法证明隔离时跳过并报告限制。
- Open Interpreter 只支持官方 Rust `0.0.21+`；默认不启用审批或沙箱绕过。
- 官方或需模型传输联网的 Codex machine run 使用 Codex 原生 app-server 沙箱；本地 Ollama Codex 及其他适用引擎使用禁网的 Windows 外层沙箱。没有可验证的对应边界时拒绝运行，不无沙箱降级。
- Codex CLI `0.145.x` 的原生 `workspace-write` 必须在 `thread/start` 和 `turn/start` 同时传入 `permissions=:workspace` 与唯一的 `runtimeWorkspaceRoots`，且该根精确等于请求 `cwd`。桥接器回读实际 `workspaceWrite`、`:workspace` 和同一根，并在模型调用前执行写探针；空根、根漂移或探针失败都会提前失败。`approvalPolicy=never` 是固定合同，任何审批或用户输入 RPC 均失败关闭。
- machine run 的调用接口只从 stdin 接收任务正文，不把正文放入进程参数。Codex 原生路径直接通过内存桥接；外层沙箱路径才使用受限 ACL 的随机命名管道。临时 Qwen/Codex/Claude/OpenCode 配置与运行目录在任务结束后删除。
- machine child 的继承环境从 Windows、PowerShell、Node/TLS 所需 allowlist 重建，不继承完整父环境或调试变量。调用计划仍可通过 `EnvironmentDelta` 显式注入目标 Profile 必需的 Provider/运行时变量；因此显式注入属于受信任权限边界，维护者必须避免无关变量进入计划和日志。
- 官方 Codex/Spark 不要求付费 API Key。它使用一次性 `CODEX_HOME` 中的现有 `auth.json` 副本，并且不复制 `config.toml`、rules、skills、sessions 或 history；该副本仍按凭据处理并在运行后清理。

## 不属于本产品的保证

本项目不能保证模型输出正确、第三方 Provider 永久在线或订阅代理符合所有账号条款。`workspace-write` 仍允许智能体修改指定工作区，因此上层调用者应提供隔离 worktree/暂存目录，不应把不可恢复的 canonical raw 数据直接放入可写根。
