# Gemini 接入：冻结与收尾记录

**状态：已冻结。当前 Antigravity consumer → Codex 日用交付未完成；本次完成的是可逆停用与收尾，不是接入成功。**

用户于 2026-09-18 明确批准冻结。该状态优先于实施归档中的阶段性可交验收描述。AICLI 本项目、其他 Provider、原生 Codex、官方 Antigravity 安装和登录不在冻结范围内。

## 已采取的措施

- Gemini 不再出现在 Codex 动态模型菜单和 AICLI 默认可用 Profile 列表；`--available` 保留只读已冻结说明，不删除用户 Profile。
- 正式部署 `enabled=false`、`lifecycle=frozen`，原 release 与回退资料保留；不维持 Gemini Bridge、supervisor 或模型后台请求。旧会话选择已冻结模型时失败关闭，不静默换成别的模型。
- 安装模块随包保留 `Support/GeminiIntegrationState.json`。恢复旧 `enabled=true` 部署记录也不能绕过冻结。凭据助手和 service-host 在读取 token、启动模型前拒绝。
- `Install`、`UpdateModels` 及候选 Live Test 在编译、模型调用、生成候选或切换安装前返回 `gemini_integration_frozen`。没有一键强行解冻开关，模型/CLI 新版本不会自动重开。
- `Status` 与 `Disable`/`Freeze` 仍可用于诊断和清理；停用不删除官方 CLI、官方登录、Codex 原会话、其他模型或派生资料。固定型号元数据、生成器、协议代码、确定性测试和必要失败证据保留。

## 保留成果与未解决问题

普通用户凭据助手 EOF、短命父进程与长期后端解耦、旧 PID 回收、后端退出后重新启动、安装副本一致性等已有针对性修复；不因冻结而盲目回滚。Codex thread/history/compaction 唯一事实源、原生工具执行、公开摘要和未来型号数据化的实现保留为研究材料。

最新真实 Desktop 文件任务仍失败于 `structured_decision_invalid`，未生成期望文件。新增解析诊断源码尚未在真实失败上定位根因。早先工具往返或 fixture 通过不能替代产品验收；电脑冷启动、隔夜认证刷新和长期完整任务稳定性未被证明。

本机特定自动化请求的连接超时不代表用户网络整体不可用；用户已报告正常使用无连接问题，两者差异未排除。本冻结决定不以账号条款或网络/MCP 故障作为技术不可能的证明。

## 审计和恢复

```powershell
# 不启动模型，区分保留安装与已启用状态。
.\scripts\Install-GeminiCodexBridge.ps1 -Mode Status

# 可重复冻结/停用；原件、登录、历史和模型快照保留。
.\scripts\Install-GeminiCodexBridge.ps1 -Mode Freeze
```

`GeminiFreeze.Tests.ps1` 验证默认关闭、旧启用记录恢复仍不开放、冷启动/host 拒绝、Live Test 与安装早停。旧引擎/换型测试只在隔离 fixture 下运行，用于保留研究代码，不自动执行模型。

未来重开需要用户明确决定及具体新依据，例如精确根因和同类完整请求上的修复证据，或经过验证的新传输实现。届时先审阅本文件与保留的 D-036 V2，再显式更新源码生命周期和本机部署状态，重新完成真实桌面/恢复验收。修改一个 `enabled` 字段或新增模型目录不构成重开。

冻结没有授予 Git 发布许可。本次本地源码、安装状态与恢复记录分开验收；其他工作区已有改动保持原样，不用 `git add .` 或回退全仓库来制造干净状态。
## 最终收尾审计（2026-09-18）

本轮业务结果是 **冻结完成**；Gemini consumer → Codex 的原日用接入结果仍为 **未交付**。不再排队调试，不因新型号、重启或候选测试通过自动恢复。只有用户明确重新启动并有新的具体依据才进入新实施。

- 实际部署 `enabled=false / lifecycle=frozen`；保留 `790c630db90ec172` 与回退版本 `254f96516d206f83`，9 个发布文件哈希回读一致。Bridge / supervisor 进程数与原端口监听数均为 0。
- 实际已安装 PowerShell 模块、新导出的 Desktop 模型列表及默认 Profile 列表均无 Gemini。只读全量列表显示原 Profile“已冻结”。其他 8 个自定义模型入口仍在，原生 OpenAI 入口不由本冻结更改。
- 真实安装凭据助手与直接 service-host 均在约 0.8 秒返回 `gemini_integration_frozen`，无 bearer 输出，不启动模型。Install/UpdateModels 和模型候选 Live Test 保持早停。审计额外封闭了维护测试程序 `GeminiNativeTransactions.py --live` 与 C# 三个 live 模式，拒绝发生在文件创建或模型启动之前；确定性/假模型测试仍可使用。
- Status 分别暴露 moduleLifecycle、deploymentLifecycle、deploymentEnabled 及有效 enabled，区分保留安装、源码冻结与本机冻结，避免状态掩盖。恢复旧 enabled 部署的 fixture 仍无法启动。
- 最终 53 项 Pester 通过、0 失败；88 项 C# 离线检查通过、0 失败、构建 0 警告；3 个 C# live 入口拒绝测试通过。以上均是冻结和保留代码的离线验证，不是 Gemini 能力或用户任务验收。
- 独立本地审查已读取并逐项裁决：接受 Status 分层可见性；不接受“Stop 可能重新启用”的无代码依据猜测，也不合并业务冻结与部署事实。最终继续保持可重复清理入口。审查与实际状态回读分开，不把审查文字当 E2E。
- 清理 33 个已登记 Gemini 调试临时目录及本轮缓存，共 26,367 个文件、483,305,354 字节。只清除对应任务生成物，不删除用户 Codex 原历史、官方登录或其他项目构建目录。此前 3 个有明确 owned-storage journal 的模型测试数据库按原清理契约处理并保留回执。
- 必要失败证据、原设计、源代码与安装前像保留。小型本机回退/审计包归位到 `%LOCALAPPDATA%\AiCliProfileManager\gemini\freeze-20260918`，其中 `final-audit.json`、`cleanup-receipt.json` 与 `independent-audit-resolution.json` 是最终本机回读记录。历史文档中的原 Cache 路径仅作历史引用，不再是可执行恢复入口。

官方 Antigravity 可执行文件与独立官方会话没有停止、卸载或注销；`Gemini Memory Backup` 属其他项目，保持启用。当前桌面正在使用其他模型，本轮没有强制重启、换模型或发送消息；旧进程如果仍缓存 Gemini 菜单，冻结助手会拒绝，新读取的菜单不再提供它。

PCConfig 恢复注意事项同步到 `docs/recovery/aicli-gemini-freeze.md`。不更新全局 E 规则、不新增定时任务、监听器或监控。未执行 Git commit、push、PR 或 Release，未回退其他任务已有的源码/配置变动。当前确认结束的是本次可逆冻结与本地收尾，不是整个 AICLI 仓库的其它并行任务。
最终复核补记：同任务晚到的离线检查已全部结束，扩展到 AntigravityProbeContract 后 Pester 为 **70/70**，重复 C# 为 **88/88**，没有新增 Gemini 模型调用。晚到检查重新生成的缓存已再次清理（另 86 个文件、4554779 字节），结果摘要已归档。补充独立审查的三项指控与实际冻结前置检查/固定发布路径校验不符，未据此扩大修改范围。最终累计清理 26453 个文件、487860133 字节，以 final-audit.json 和两份清理回执为准。

## 已有改动的本地 Git 收口（2026-09-22 UTC）

用户明确要求处理并提交遗留未提交改动。本轮仅保全冻结实现、设计与收尾记录；独立只读审查未发现阻断该提交的可复现问题。相关 16 个 Pester 文件共 189/189 通过，Gemini C# 离线检查 88/88 通过；这些结果不属于模型 Live 或日用交付验收。生成的 .NET bin/obj 加入忽略规则，既有运行内容保持。

当前源码和部署仍为 frozen、部署 enabled=false。未安装、启用、重启或调用 Gemini；此次 Git 收口不恢复调试义务。仓库为公开可见，本轮按用户不公开发布的边界仅作本地提交，不 push、PR 或 Release。前文未提交的描述保留为 2026-09-18 的历史事实。
