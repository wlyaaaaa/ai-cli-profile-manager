# 受管 Codex 模型目录

这里保存 AICLI 随安装包发布、再按内容哈希复制到真实 `CODEX_HOME` 的静态模型目录。目录文件不含 API Key；认证仍由 DPAPI `secretRef` 在启动目标子进程时注入 `env_key`。

`deepseek-v4-flash.json` 取自 DeepSeek 官方 Windows Codex setup 脚本中的 `models.json`，仅保留当前已获官方 Codex Responses 支持的 `deepseek-v4-flash` 条目：

- 来源：<https://cdn.deepseek.com/api-docs/codex-deepseek-setup-en.ps1>
- 取证日期：2026-08-01
- 上游脚本 SHA-256：`806f7018da07359c39b8c256a10e17130f8c1eeaf76a2481ebdda5c9d39a0283`
- 版本名：DeepSeek V4 Flash 0731；API slug 仍为 `deepseek-v4-flash`

`deepseek-v4-pro` 只在 Provider Manifest 的 `models.reserved` 中占位，不进入此活动目录、候选列表或启动参数。未来只有在官方确认 Codex 支持后，才可把新条目加入目录和候选列表，并重新执行目录解析、秘密隔离与真实 Live 验收。
