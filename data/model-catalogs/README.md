# 受管 Codex 模型目录

这里保存 AICLI 随安装包发布、再按内容哈希复制到真实 `CODEX_HOME` 的静态模型目录。目录文件不含 API Key；认证仍由 DPAPI `secretRef` 在启动目标子进程时注入 `env_key`。

`glm-5.3-codex.json` 与 `glm-5.3-flash-codex.json` 对应智谱中国区 Codex Responses exact Profile：模型 ID 分别为 `glm-5.3` / `glm-5.3-flash`，上下文 1048576、有效窗口 95%、自动压缩线 943718（最大上下文 90%），推理档位固定 `low/high/max`。两者不包含凭据、不声明 alias 或 fallback，并启用 Codex 延迟工具搜索；Flash 目录只声明 Codex 当前使用的文本和图像输入。

`deepseek-v4-flash.json` 与 `deepseek-v4-pro.json` 从 DeepSeek 官方 Windows/Linux Codex setup 脚本内同一份双模型 `models.json` 按 slug 确定性抽取，各自只保留一个 exact 条目：

- 来源：<https://cdn.deepseek.com/api-docs/codex-deepseek-setup-en.ps1>
- 取证日期：2026-08-13；上游 Windows 脚本版本 `1.1.0`
- 上游 Windows 脚本 SHA-256：`239c5e7e4a24a5216cf03756cc66d7459c748a46d1d4bf084418d2b58ef54a36`
- 上游双模型 `models.json` SHA-256：`b459a6e438d6a9939d01fd0dbb4693f165ed732bc8e4fd58d7145d9d94bd49a4`
- 官方规范化单条目 SHA-256：Flash `8065e17700fe1a88bed911114c10f3e792eac48601aa765e067bec13eb0ae1d4`；Pro `16e8716359c27ade5f748e586e2b25886f5a7257ab4e9795436e11f9c4fdeedf`
- alias 到版本的映射由官方 Models & Pricing 页分别固定为 Flash 0731 与 Pro 0813；setup catalog 自身只写 alias。
- AICLI 唯一策略覆盖是把两条目录的 `default_reasoning_level` 从官方示例 `high` 提升为用户最高档 `max`；其余字段必须通过上述单条目哈希校验。

`scripts/Build-DeepSeekCodexCatalog.ps1` 负责上述抽取和哈希绑定。Flash 与 Pro 目录、Provider ID 和 Profile 指纹互相隔离；任何一方的 Live 回执不能证明另一方。

`qwen3.8-max-0902-codex.json` 由 `scripts/Build-QwenCodexCatalog.ps1 -CatalogKind qwen38max0902` 确定性生成：

- 精确 slug `qwen3.8-max-0902`、Responses 能力与 983616 输入窗口来自[阿里云 Responses 文档](https://www.alibabacloud.com/help/en/model-studio/qwen-api-via-openai-responses)及模型页；
- `effective_context_window_percent=95`、`auto_compact_token_limit=885254`（最大上下文 90%）；用户 `max` 在 Profile 层映射为模型原生最高 `xhigh`；
- Workspace 按量 Profile 不包含 preview、Token Plan 或其他候选；
- 基础指令与 `model_messages` 复用同一发布版 `deepseek-v4-flash.json` 中的通用 Codex 0.146 指令，避免阿里云最小示例的空 `base_instructions` 覆盖 Codex Agent 行为；其余能力与限制由生成器白名单逐项声明，不随 DeepSeek 目录静默漂移。

`qwen3.7-max-2026-06-08-codex.json` 由同一生成器的 `-CatalogKind qwen37max0608` 确定性生成，只服务 `codex-qwen3-7-max-paygo`：

- 精确 slug `qwen3.7-max-2026-06-08`；供应商 Responses 列表与模型发布页确认该 06-08 快照，北京 Workspace 按量接入；
- 983616 输入窗口、95% 有效窗口、885254（最大上下文 90%）自动压缩阈值，用户 `max` 映射原生最高 `xhigh`；
- 目录为单模型，不包含通用 alias、05-20、preview、Plus 或 Token Plan 候选。

除上述 06-08 exact Codex Profile 外，Qwen3.7 Max/Plus 云入口与目录继续退役；旧用户 Profile 或原生 `--model` 参数会失败关闭，不会自动改投新入口、Qwen3.8 或其他模型。

`qwen3.6-35b-codex.json` 由同一生成器的 `-CatalogKind local` 模式生成，只包含本机 LocalGpuBroker 登记的 `qwen3.6-35b:256k`：

- `context_window=max_context_window=262144`，默认 effort 为 `max`，只列 `low` / `medium` / `high` / `max`；
- `auto_compact_token_limit=235929`，即最大上下文的 90%；
- 与云千问 983616 目录分离，避免把套餐或上下文事实跨 Provider 复用；
- 目录内容寻址发布后，用当前 Codex `debug models` 回读唯一 slug、窗口和非空基础指令，不发起模型请求。

`qwen3.8-27b-codex.json` 由同一生成器的 `-CatalogKind localQwen38_27b` 模式生成，服务同一模型的 `codex-ollama-main` 与 `codex-ollama-qwen3-8-27b`：

- 上游模型为 <https://huggingface.co/Qwen/Qwen3.8-27B>，公开权重提交 `1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0`，原生 context 为 262144；1M YaRN 只作为可选扩展事实，不进入本机默认目录；
- 官方基础标签是 `qwen3.8:27b` Q4_K_M，manifest digest `sha256:22130167c4c20e20c7b71454612966ca8e8171e9b3cc8ab6ce8aa6cbfec79643`；运行标签是 `qwen3.8-27b:256k`，manifest digest `sha256:8040835723046ec2631b64b960d44414636ea5147942a7d68eaaa7ccdb492e20`，参数层固定 `num_ctx 262144`；
- 两个标签共用 config digest `sha256:492b2922d38e553cabc2d319345644ed482874fbf5e5c9e4495cbf8e17b0cf5f`、模型 blob digest `sha256:f5f1dd8920d417aac2718b0bda3403da274301efdd6760b4f0f4b864ff2ad57d` 与 projector digest `sha256:ac3714bfdddeca31351f2752bf1a63f266f4df87c0b68c895e44945ca704448e`；
- `context_window=max_context_window=262144`，输入支持 text/image，默认 effort 为 `max`，只列 `low` / `medium` / `high` / `max`；
- `auto_compact_token_limit=235929`，即最大上下文的 90%；
- 与云端 `qwen3.8-max-0902` 及本地 `qwen3.6-35b:256k` 分离，避免把供应商套餐、模型权重或上下文事实互相冒充。

目录生成后必须运行 Manifest/CodexAdapter 离线测试，并确认再次运行生成器不产生 diff；任何提示版本升级都要重新绑定并验证，不能把旧基础指令无限沿用。
