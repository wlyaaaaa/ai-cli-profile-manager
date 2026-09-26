# Gemini 接入：冻结与恢复边界

本人于 2026-09-18 明确冻结 Antigravity consumer → Codex 接入。日用交付未完成，后来的文档整理、Git 提交和 AICLI 发行都不构成重开。

- 只冻结这条 Gemini 接入；AICLI、其他 Provider、官方 Antigravity 安装和登录继续各自管理。
- 源码 `Support/GeminiIntegrationState.json` 为 frozen；部署应保持 disabled/frozen。默认模型发现、CLI 启动、凭据助手、后台 host、Install、UpdateModels 和 Live Test 在认证、编译或调用模型前拒绝。
- 旧 enabled 记录、新模型目录或静态测试通过不能绕过冻结。Status、Disable/Freeze 保留用于诊断与可逆停用，不删除官方登录、原 Codex 会话、用户 Profile 或其他模型。
- 保留已完成的生命周期修复、模型资料、确定性测试及失败证据，不盲目回滚其他 Provider。最后真实桌面文件任务遇到 `structured_decision_invalid`；冷启动、隔夜认证与长期日用稳定性未被证明。
- 网络错误、地区错误和模型格式失败分开报告，不从一次连接失败推定整体网络不可用，也不把 fixture 通过说成 Gemini 已可日用。
- 重开须本人新的明确决定及具体新证据；只改 enabled 不够。原目标仍是官方 consumer 登录、Codex 唯一负责工具/历史/权限、不改用 API Key、不换账号/出口/模型兜底。
- 保留的协议与取舍见 [V2 设计](designs/D-036-v2-frozen.md)，模型资料与回退流程见 [型号维护](Gemini-model-upgrades.md)。两者只是重开时的输入，不是持续施工指令。
- 本机冻结回执和必要恢复输入位于 `%LOCALAPPDATA%\AiCliProfileManager\gemini\freeze-20260918`；部署版本及是否存在须现场读取，不能用历史 Cache 路径或文档哈希当现状。机器恢复说明归 PCConfig 的 `docs/recovery/aicli-gemini-freeze.md`。

只读核查：`scripts/Install-GeminiCodexBridge.ps1 -Mode Status`。实际停用用同入口 `-Mode Freeze`；它不等于恢复 Gemini 能力。原安装、部署、运行进程和真实任务结果应分别回读。
