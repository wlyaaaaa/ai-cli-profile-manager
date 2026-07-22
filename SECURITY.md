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
- `aicli run` 必须经过 Codex Windows 外层沙箱并禁用外网；内部 CLI 可自动批准的前提是外层已把写权限限制在指定工作区或一次性运行目录。没有可用沙箱时拒绝运行，不无沙箱降级。
- machine run 的任务正文只走 stdin，不进入进程参数；临时 Qwen/Codex/Claude/OpenCode 配置在任务结束后删除。

## 不属于本产品的保证

本项目不能保证模型输出正确、第三方 Provider 永久在线或订阅代理符合所有账号条款。`workspace-write` 仍允许智能体修改指定工作区，因此上层调用者应提供隔离 worktree/暂存目录，不应把不可恢复的 canonical raw 数据直接放入可写根。
