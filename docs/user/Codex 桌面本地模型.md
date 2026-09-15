# Codex 桌面本地模型

此功能让现有 Codex 桌面版使用 AICLI 统一集合中的本地模型。界面、对话历史、工具执行和官方登录仍由原版 Codex 负责。

## 使用

安装并重新启动桌面版后，在**新任务的模型选择器**中选择模型。当前配置对应：

- **Qwen3.8 27B**
- **Qwen3.6 35B**
- **Qwen3.8 27B 去限制版**
- **Qwen3.6 35B Abliterated（去限制版）**

这四个本地模型可以在同一本地任务中切换。官方模型在每次桌面引擎启动前由原版引擎重新发现，再与本地元数据合并载入；不维护固定的 OpenAI 模型名单。当前进程使用本次启动快照，新增模型在下一次正常启动时刷新。

模型服务在任务创建时确定。原生 Codex 会把服务保存在任务中，重新打开任务也不会更换它。因此，从官方模型改用本地模型，或从本地改回官方模型，应新建任务再选择。适配器会明确提示这种情况，保留原任务，避免把请求发给错误的服务。

旧 AICLI 运行标签可显示为具体模型名加“旧配置”；它仅用于准确显示已有任务。选择没有此标记的模型即可使用当前配置，适配器不会暗中改写旧模型标识。

## 安装与关闭

需要 Windows 11、PowerShell 7、.NET 10 SDK（构建时）及 .NET 10 Runtime（运行时），并已安装 AICLI、Codex 桌面版和所选本地模型。使用 AICLI 当前配置的本地公共网关，沿用已有 GPU 管理。

在项目根目录运行：

```powershell
pwsh -NoProfile -File scripts/Set-CodexDesktopLocalModels.ps1 -Mode Build
pwsh -NoProfile -File scripts/Set-CodexDesktopLocalModels.ps1 -Mode Enable
```

然后正常退出并重新打开 Codex 桌面版。安装器不会关闭正在执行的任务。

检查状态或关闭接入：

```powershell
pwsh -NoProfile -File scripts/Set-CodexDesktopLocalModels.ps1 -Mode Status
pwsh -NoProfile -File scripts/Set-CodexDesktopLocalModels.ps1 -Mode Disable
```

关闭后重新启动桌面版，恢复安装前的引擎入口。安装器记录并恢复原 `CODEX_CLI_PATH`；如果用户随后另行修改该变量，关闭操作会停止并说明冲突，不覆盖新值。本地 provider 定义保留，以便旧任务继续找到自己的连接。

## 配置与维护

日常增减统一使用[本地模型统一配置](本地模型统一配置.md)的同步命令。

- 本地模型和显示名来自当前 AICLI Profile（配置档案）及模型目录，由 `data/local-model-set.json` 的 `profiles` 选择。这些是稳定的内部 ID，界面显示具体型号。
- `GetDesktopModelPlan.ps1` 在启动时重新解析当前安装的 AICLI 和 Codex 引擎。`ResolveDesktopEngine.ps1` 对照当前 AppX 安装包的引擎哈希复用匹配缓存；新版本尚未缓存时复制当前包的引擎及伴随程序到 AICLI 缓存，不按旧目录或修改时间猜版本。
- 桌面入口使用官方应用已有的 `CODEX_CLI_PATH`。安装文件位于 AICLI 本地数据目录下的 `desktop/releases/`，并保留启停状态与配置备份。
- 在启动原生 app-server **之前**载入完整合并目录，包含模型指令、工具能力和上下文元数据。仅把名称追加到界面会使未知模型落入通用回退路径，导致完整工具说明被展开进输入；启动级载入使原生按需工具搜索正常生效。
- `model/list` 的内容、分页及 `config/read` 都直接来自原生引擎。没有单独的显示目录或虚拟配置层，也不写用户全局 `model_catalog_json`。原生官方元数据完整保留，原版引擎仍直接管理官方认证和请求。
- 本地任务通过原生 `thread/start` / `thread/resume` 传入本地连接，并按已载入元数据设置窗口，避免继承大于本地容量的全局上下文设置。本地任务使用同一连接，因此这些本地模型可以直接切换。
- 适配器按标准输入输出转发原生 app-server 协议，未知方法、通知、服务端请求和错误继续透传。它不修改桌面安装包或上游 CLI，也不创建后台计划任务或独立聊天界面。

普通模型增减只做配置同步与必要读回，不要求整套 E2E。使用中出现问题时再验证和修复受影响路径；未运行的测试不标为通过。

模型目录装载发生在引擎启动时。升级适配器后需正常重启桌面版；此前用通用回退指令建立的失败任务应新建后验证，已有历史不会被改写。
