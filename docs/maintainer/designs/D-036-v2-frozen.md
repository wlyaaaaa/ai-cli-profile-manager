# D-036 V2：Gemini 作为 Codex 模型后端的最终施工设计

状态：设计冻结，实施进行中；不代表运行时已启用或用户 E2E 已通过。
冻结依据：2026-09-17 用户要求继续完成既有成果、由 Owner 独立判断实现，并支持未来 Gemini 快速换型。
范围：AICLI 的 Gemini managed-proxy、模型资料、必要的桌面接线和相关测试；不重做 Codex，不更改其他 Provider。
本稿取代第 22 节中与 V2 冲突的实现选择，不擦除 V1 的成功/失败事实。设计变化必须留下具体证据与变更说明，不静默改写本稿；普通参数、型号资料和实施进度不要求重开架构讨论。

## 1. 用户实际要的结果

在同一个 Codex Desktop 会话中使用 Gemini 推理，像现有 GLM 一样看见自然中文公开摘要、真实命令/文件/MCP/搜索/子代理记录与最终答案。继续、取消后再问、关闭后恢复以及上下文压缩均由原生 Codex 管理。Google 使用已有官方 consumer 登录，不改用 API Key，不逆向登录，不暗中换模型、账号、出口或付费方式。

用户不需要 Antigravity 自己记得历史；也不需要 AICLI 建立第二套聊天数据库。未来更换 Gemini，只要上游协议不变，应是模型资料更新和有界验收，而非重写驱动。

## 2. 已有资产与实际改动范围

保留已有 Responses HTTP/SSE 框架、标准 function/custom tool 转换与参数验证、公开摘要增量解码、中文沟通策略、受管 OAuth 子进程环境隔离、Windows 网络配置继承、本地 bearer 鉴权、端口分配、安装回退、精确拥有的上游落盘清理及有价值的回归测试。

替换 AntigravityBackend 的 conversation 字典、亲和键历史复用、增量 history append、跨请求 usage 差分、地区判定自动重建和每个模型请求之前的额外模型自检。旧代码只在需要回退或迁移时保留，不同时维护两个默认后端。

不修改其他 Owner 的 GLM/DeepSeek 摘要工程。共用沟通策略从现有唯一实现取用，不复制一套新规则或由 Gemini 输出原始隐藏推理。

## 3. 唯一历史与一次性模型事务

正常数据路径：Codex 当前 Responses 请求 → 无损语义转换 → 全新 Antigravity 进程及 conversation → 一次模型结果 → Responses 事件 → Codex 执行工具并记录 → 下一次全新模型事务。

每一次 provider 请求（包括同一个用户 turn 内的多次工具往返、压缩请求）都是独立事务。一个 agy 进程最多收到一条用户型模型输入，获得终态后关闭 stdin、退出并清理；不传 --continue/--conversation，不把 task/thread/cache key 映射为 Antigravity 历史。

Bridge 不读取 Codex JSONL/SQLite 来拼历史，不自行压缩或恢复，不把失去的会话原文再捞回来。它只消费本次 instructions、input、tools、tool_choice 和受支持设置；工具 schema、调用 ID、namespace、原始结果和消息角色不得改义。OpenAI 专用加密推理不能伪造给 Gemini；不认识的有效输入类型必须明确失败，不能静默丢弃。

Bridge 可以常驻，登录凭据由官方组件复用；常驻 agy 进程换 conversation 没有已验证的公开 reset 合同，故不作为交付前提。预热“尚未收过请求”的进程池仅是后续实测优化；无收益或引入副作用就不实现。V2 首版不靠该优化维持正确性。

## 4. 模型资料与快速换型

唯一可维护来源为 data/gemini-models.json，版本化 schema aicli.gemini-model-set.v1。每个模型记录：稳定模型组 ID、独立 Profile ID、用户显示名、默认思考档、显式 effort→exact upstream model ID/CLI effort 映射、Codex 入口 ID、上下文窗口、自动压缩参数、文本/摘要/工具能力，以及公开证据引用。

初始条目延续 Gemini 3.8 Flash，默认 High，现有 exact ID 兼容。不从型号字符串切片猜版本、窗口或档位，不把所有将来型号都假定具有 low/medium/high。模型组 ID、入口 ID、Profile、alias 冲突在同步前报错。

驱动启动时加载不可变的模型资料快照；请求只能解析到该快照中的明确型号/档位。已有流式请求不受目录更新影响。未知模型、未知 effort、请求与实际 init model 不符均失败；不通过 latest、模糊匹配或降档做 fallback。

资料同步复用现有 Profile/桌面 catalog 生成逻辑；代码只识别 Google Antigravity provider/adapter 特征，不按某个具体型号写分支。新增第二个测试型号必须在不改 C# 驱动和路由逻辑的前提下完成解析、生成和选择测试。

换型流程：增加/修改资料 → schema/交叉身份校验 → 生成隔离候选 → exact model/effort、摘要和 nonce 往返实测 → 原子激活模型资料与派生目录 → 回读菜单/实际 init。保留旧资料与上一个部署用于回退。单纯换模型不重编译驱动、不重新证明没变化的工具隔离；上游 CLI、Hook 或驱动协议变化则重新验证对应兼容性。

不把旧 ID 悄悄指向新模型。旧模型仍可用则并存；已退役则旧会话明确提示选择新模型，保留原 Codex thread。是否允许同 Provider 在原 thread 显式换型以原生 Codex 实测为准，不能创建新 thread 冒充恢复。新增模态或全新思考语义不算“只改型号”，必须增补驱动兼容性。

## 5. 工具唯一执行者与隔离

模型只输出工具意图，Bridge 完整解析并验证后生成 Responses function_call/custom_tool_call；Codex 决定权限、执行、并行、结果和工具 UI。未知工具、错误 schema、违反 tool_choice、重复身份、越权原生工具事件均明确失败。部分 JSON 或未校验的工具意图不得开始执行。

保留 custom agent 无主动工具配置与全工具 PreToolUse deny Hook。init 的工具名称目录不是执行隔离证明；不能将“有 57 个名字”或“这次没调用”分别误报为隔离失败或成功。

将模型式隔离自检移出每个业务请求，改为独立的兼容性验证。证据绑定 CLI 哈希、Agent/Hook 模板版本与实际 bytes、Hook 解释器身份；模板含动态工作目录时以规范模板及现场确定性生成的 bytes 校验，不比较不同临时路径的整段命令字符串。正常请求仍检查实际 init 身份、Hook 装载回执和原生工具事件；有原生尝试立即终止，绝不将其包装成 Codex 工具。

隔离测试必须在隔离工作区实际证明调用前拒绝、无测试副作用和清理完成。伪造 receipt、将普通问答成功当隔离 PASS 均禁止。未知上游/模板版本不能沿用旧证据；不能为性能删掉拒绝 Hook。

## 6. 输出、摘要与界面

延续显式决策字段 visible_summary / kind / tool_calls / final_text；公开摘要是模型明确给用户的解释，不是隐藏 CoT。优先流出 visible_summary，引用已经取得的证据或解释下一步目的，最终答案独立。普通直接问答不强制造摘要；需要查个人事实时不能借测试资料假答，必须经可见的 Codex 授权工具。

Responses summary 事件需要完整 added/delta/done 生命周期、稳定 item ID/output index、严格序号和最终一致性；只把真实模型摘要映射进去。验证必须同时观察原生事件、持久 history 和实际 Desktop 展示，不能把收到一个 delta 当成全套 UI 已通过。参考 GLM 的表达质量，不照搬其专属 raw reasoning 修补。

模型启动/排队/网络重试不冒充思考摘要；必要状态由独立运行状态表达。SSE heartbeat 只保连接。截断、空 SUCCESS、畸形/重复 JSON 字段、最终摘要不一致必须报具体错误；不能清洗成看似成功的回答。

## 7. Codex 原生压缩

以原生 Codex 对当前第三方 Provider 的实际能力为准：优先验证其本地 history compaction 是否通过普通 Responses 模型请求完成；不凭配置存在或 OpenAI API 的 /responses/compact 文档宣布兼容。

Bridge 不自建压缩器、不要求 Antigravity 压缩、不从 OpenAI 加密 compact 数据捏造摘要。若安装 Codex 走了自定义 Provider 未支持的 compact 路径，必须在启用前调整其受支持配置或报告明确的不兼容，不直接补一个假 /compact。

按模型资料设置窗口和项目约定的 90% 自动压缩，另核对工具包装/输出与 tokenizer 差异所需余量。初始 1M 资料不是已实测满窗口可用的证明。低阈值强制 compact、保留关键标记/工具结果、后续 fresh 模型调用与 exact Codex resume 是独立必测项目。

## 8. 生命周期、失败和资源

单事务始终完整上下文，不复用上次 Antigravity usage。正确归因 input/output/cache/thinking，不把 thinking 额外叠加两次。结果未完成不报 completed；终态错误保留固定分类及非正文运行指标。

正常关闭、取消、请求断线、服务退出均结束其独占子进程，保留失败清理 journal；恢复时只清理确认为本驱动拥有的上游会话，不能删账号登录或其他 Antigravity 会话。清理失败作为真实未完成义务，不悄悄扔掉 journal。

可选重试只限没有任何公开摘要、工具意图或最终内容的明确 transport failure，最多一次 fresh 事务且共享总 deadline。auth/额度/地区/协议/空输出/原生工具尝试不自动重试。最初实现可以零重试，不把有限重试当成功门槛。不能恢复已中止 agy 会话或重放已执行的 Codex 工具。

Provider 凭据只在官方子进程需要的范围使用；不改全局环境，不输出授权码/账号/上游原文。登录故障由明确可管理的登录流程处理，模型目录发现和启动预检不反复打开浏览器。

## 9. 启用门槛与增量实施顺序

A. 冻结本稿，建立模型资料 schema 和未来第二型号测试；保留 V1 可用资产与失败证据。
B. 实现每请求独占进程、完整输入、取消/清理；没有 affinity/suffix/地区恢复依赖。
C. 独立隔离验证、真实中文直接答复和 nonce 两次往返；每次 upstream conversation 都不同，Codex thread 相同。
D. 真实命令/文件/搜索与公开摘要，连续追问、较大中文规则/结果输入、取消后继续、进程重启 exact resume。
E. 低阈值触发 Codex compaction 后继续与恢复；验证能力、实际输入、摘要与工具结果。
F. 模型资料更新/回退演练，旧 ID 不被重指向，未知 model/effort 清楚失败。
G. 安装完整性、无账号/代理全局污染、实际 Desktop 摘要/工具可见；用户最终 E2E。

以上阶段是内部施工顺序，不逐阶段索取开工许可；不重跑与变更无关的全部项目。源码/离线/协议/安装/UI/用户反馈各自记录，不互相代替。当前停用状态在候选未满足对应门槛前保持；所有未知项真实保留，不再凭单次 nonce 成功称“只剩用户验收”。

## 10. 证据与受控变更

动态入口只用于核对能力，现场 CLI/原生 Codex 版本与实验结果为最终兼容性证据：
- Google headless： https://antigravity.google/docs/cli/headless/
- Google custom agents： https://antigravity.google/docs/cli/commands/agents/
- OpenAI Codex 原生源码： https://github.com/openai/codex

模型资料变化只更新其数据与派生目录，不改本稿。协议/隔离/权限或用户可见结果边界改变时，先留下原因、证据、影响与回退，再追加 V2 修订；不能以“冻结”为由保留已证错误，也不能借重设计回到从零开始。
