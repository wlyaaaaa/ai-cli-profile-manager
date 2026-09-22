# 冻结归档：Gemini V2 型号维护与验证

> 当前接入已冻结，见 [冻结与收尾记录](Gemini-integration-freeze.md)。以下保留换型实现说明，不是继续施工或执行 Live Test 的授权。数据的离线验证/生成仍可测试；Install、UpdateModels 和候选实测均已早停，未来新型号不会自动重新启用。

适用设计：[D-036 V2 冻结稿](designs/D-036-v2-frozen.md)。这里说明现有命令，不表示当前部署已经通过用户 E2E。

## 日常更换模型需要改什么

只维护 `data/gemini-models.json`。每一代独立模型组保留独立 `id`、`profileId`、`menuModel`、显示名、上下文参数及显式 `efforts` 映射。模型本身的工具、模态和推理档位以实际上游能力为准，不能按名称猜测，也不把旧 ID 改指新型号。

`menuModel` 是默认档位的精确上游 ID；用户明确选择其他档位时，驱动按同一模型组的 effort→exact model/CLI effort 映射解析。所有活动请求使用启动时已验证的不可变模型资料，更新不改变进行中的请求。

下列情况是数据更新：新增/移除已支持协议下的模型，调整真实显示名，修正已核实的窗口/档位映射。新增图片等模态、改变上游协议、换 CLI 二进制或 Hook 模板不是简单换型，要重做相应兼容性验证。

## 验证与同步命令

在仓库 PowerShell 7 中执行，使用当前有效 Owner 授权；不要在未确认新模型存在时照填占位 ID。

```powershell
# 只校验 schema、唯一身份、默认档位、窗口与能力；不调用模型，不改安装。
.\scripts\Build-GeminiCodexCatalog.ps1 -CheckOnly

# 从唯一型号资料重新生成源代码中的 Profiles 和 Codex model catalogs。
.\scripts\Build-GeminiCodexCatalog.ps1

# 明确指定另一份候选模型资料，只生成隔离文件，不启用。
.\scripts\Build-GeminiCodexCatalog.ps1 `
    -ModelSetPath '<candidate-model-set.json>' `
    -OutputRoot '<new-isolated-output-directory>' -RuntimeBundle
```

`RuntimeBundle` 固定生成 `gemini-models.json` 和 `gemini-codex-catalog.json`，新增型号不增加版本专属驱动文件。目录中的 `entries` 用于桌面投影，`models` 是原生 Codex 目录格式。生成前统一验证，不把半份非法目录写入活动安装。

安装 V2 驱动后，后续纯型号更新使用：

```powershell
.\scripts\Install-GeminiCodexBridge.ps1 -Mode UpdateModels `
    -ModelSetPath '<verified-candidate-model-set.json>' `
    -BuildRoot '<new-task-owned-staging-directory>'
```

该模式复用已安装驱动的字节，不调用编译器；从模型资料生成新快照，实际模型验收通过后才切换版本。独立工具隔离证据可在 CLI、解释器、Agent/Hook 模板未变时复用。未知版本、无验证证据或目标模型不工作，均不静默回退模型。

当前实现会验证目录中注册的模型/档位。增加模型较多时，发布 Owner 可只复用有明确相同驱动/模板/CLI/型号参数身份的旧证据，对新项目做差量实测；这项优化不等于可以省掉新型号的真实调用证明。

更新发现仍有生成中的请求时，旧服务 `/shutdown` 返回 busy，不中断用户回答，也不先删旧配置。调用者在当前生成结束后重试更新；不靠服务强杀抢占端口。新快照激活后，旧版本和回退信息保留。

## 原会话与回退

Codex thread 是唯一历史源。模型目录变动不删除或复制 thread，不从 JSONL 建立另一条对话。旧型号保留时可继续使用；旧型号已退役则明确提示其不可用，由用户显式选取可用模型，不把旧 exact ID 悄悄指向新型号。

回退型号资料时使用上一个保留版本中的 `gemini-models.json` 作为 `UpdateModels` 的输入，并遵守同样的身份、忙碌状态和验收检查。驱动本身发生变化时，则按既有安装回退流程恢复整套版本，不能只换型号资料掩盖协议不兼容。

## 必须区分的证据

schema/生成测试只能证明资料合法；虚构的 future-fixture 模型只能证明代码没有写死版本。真实模型的 exact init、思考档位、公开摘要、工具意图、工具结果回传都要实际验证。

原生 Codex 适配测试与真实模型测试分别报告。使用确定性夹具跑通 compaction/resume 不能当作 Gemini 已通过；两个 fresh Gemini 纯文本调用也不能代替 Codex 工具/界面验收。

## 施工状态

不再保留持续实施/验收任务；原任务 ID 仅见历史归档。重新启动须有明确用户决定和新证据，不能沿用旧 Owner 或候选 PASS。
