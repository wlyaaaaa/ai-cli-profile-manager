# 贡献指南 / Contributing

感谢参与 AI CLI Profile Manager。首版只支持 Windows 11 与 PowerShell 7。

## 开发环境

```powershell
pwsh -File .\bin\aicli.ps1 version
pwsh -File .\scripts\Test-Release.ps1
```

运行 Pester：

```powershell
Import-Module Pester -MinimumVersion 5.5.0
Invoke-Pester -Path .\tests
```

## 修改原则

- Provider 差异放在无执行能力的 Manifest 与对应 adapter 中，不散落到通用路由。
- 不把秘密、OAuth 数据、真实用户日志、聊天正文、私人绝对路径或截图提交到仓库。
- 不永久写全局 Provider 环境变量，不覆盖用户基础 `config.toml`、`settings.json` 或官方登录。
- 未完成当前版本真实验证的 Provider 不得标成“可用”。
- Codex、Claude Code 和 Open Interpreter 的命令及配置属于动态事实；修改前核对官方文档和本机精确版本。
- 不在 0.1.x 随意扩展 macOS、Linux、GUI、PTY 外壳、自研 Agent 或新协议网关。

## 文档事实源

- 用户产品操作：《[AI CLI Profile Manager 使用手册](<docs/user/AI CLI Profile Manager 使用手册.md>)》
- 三套原生 CLI：《[Codex、Claude Code 与 Open Interpreter CLI 中文手册](<docs/user/Codex、Claude Code 与 Open Interpreter CLI 中文手册.md>)》
- 维护者合同与决策史：[项目设计与实施归档](docs/maintainer/项目设计与实施归档.md)

旧用户页面只作为迁移入口，不能重新复制一套正文。

## 提交前

1. 运行离线 Smoke 与 Pester。
2. 检查未知参数、中文/空格路径、秘密脱敏和子进程环境隔离。
3. 检查两本 canonical 手册、索引顺序、本地链接和官方外链。
4. 确认 Codex 思考入口写明当前构建的 `/reasoning` 与 `/model` 内 reasoning effort，且没有旧 Python Open Interpreter 的参数或安装方式。
5. PUBLIC 发布前执行秘密、私人路径、包内容和第三方许可证审查。

CI 不使用真实 Key，也不运行付费 Live Test。真实 Provider 验收由有权使用对应账号的维护者在临时空目录显式执行。

两本根目录 PDF 由 canonical Markdown 生成。维护者机器需有 Python 3、`markdown`、`pypdf` 和 Edge/Chrome：

```powershell
python -m pip install markdown pypdf
python .\scripts\Build-Pdfs.py
```

脚本会把相对链接改为当前公开版本的 GitHub HTTPS 链接，并拒绝 `file:`、本机用户目录、临时标题或不安全 PDF URI。
