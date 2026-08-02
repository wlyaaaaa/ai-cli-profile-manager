# 受管 Codex 模型目录

这里保存 AICLI 随安装包发布、再按内容哈希复制到真实 `CODEX_HOME` 的静态模型目录。目录文件不含 API Key；认证仍由 DPAPI `secretRef` 在启动目标子进程时注入 `env_key`。

`deepseek-v4-flash.json` 取自 DeepSeek 官方 Windows Codex setup 脚本中的 `models.json`，仅保留当前已获官方 Codex Responses 支持的 `deepseek-v4-flash` 条目：

- 来源：<https://cdn.deepseek.com/api-docs/codex-deepseek-setup-en.ps1>
- 取证日期：2026-08-01
- 上游脚本 SHA-256：`806f7018da07359c39b8c256a10e17130f8c1eeaf76a2481ebdda5c9d39a0283`
- 版本名：DeepSeek V4 Flash 0731；API slug 仍为 `deepseek-v4-flash`

`deepseek-v4-pro` 只在 Provider Manifest 的 `models.reserved` 中占位，不进入此活动目录、候选列表或启动参数。未来只有在官方确认 Codex 支持后，才可把新条目加入目录和候选列表，并重新执行目录解析、秘密隔离与真实 Live 验收。

`qwen3.7-codex.json` 由 `scripts/Build-QwenCodexCatalog.ps1` 确定性生成：

- 模型 slug、Responses 能力与 983616 输入窗口来自[阿里云 Codex 接入文档](https://help.aliyun.com/zh/model-studio/codex)及 Qwen3.7 Max/Plus 官方模型页；
- `context_window=max_context_window=983616`、`effective_context_window_percent=95`、`auto_compact_token_limit=null`，由当前 Codex 在约 90% 处派生保护；
- 六个条目精确覆盖两份 Qwen Codex Manifest 的唯一候选，不改变默认模型，也不加入 Coding Plan；
- 基础指令与 `model_messages` 复用同一发布版 `deepseek-v4-flash.json` 中的通用 Codex 0.146 指令，避免阿里云最小示例的空 `base_instructions` 覆盖 Codex Agent 行为；其余能力与限制由生成器白名单逐项声明，不随 DeepSeek 目录静默漂移。

`qwen-main-v1-codex.json` 由同一生成器的 `-CatalogKind local` 模式生成，只包含本机 LocalGpuBroker 登记的 `qwen-main-v1`：

- `context_window=max_context_window=262144`，默认 effort 为 `max`，只列 `low` / `medium` / `high` / `max`；
- 与云千问 983616 目录分离，避免把套餐或上下文事实跨 Provider 复用；
- 目录内容寻址发布后，用当前 Codex `debug models` 回读唯一 slug、窗口和非空基础指令，不发起模型请求。

目录生成后必须运行 Manifest/CodexAdapter 离线测试，并确认再次运行生成器不产生 diff；任何提示版本升级都要重新绑定并验证，不能把旧基础指令无限沿用。
