# 第三方组件声明 / Third-party Notices

AI CLI Profile Manager 本身采用 MIT License。它可以调用或下载下列第三方软件；这些组件仍适用各自的许可证、服务条款、隐私政策和账号规则。

| 组件 | 上游 | 本产品如何使用 |
|------|------|----------------|
| Codex CLI | [OpenAI](https://github.com/openai/codex) | 用户自行安装；本产品启动原生 CLI，不默认再分发 |
| Claude Code | [Anthropic](https://code.claude.com/docs/en/overview) | 用户自行安装；本产品启动原生 CLI |
| Open Interpreter Rust | [Open Interpreter](https://github.com/openinterpreter/openinterpreter) | 用户自行安装官方 Rust `0.0.21+`；旧 Python 版不支持 |
| Ollama | [Ollama](https://github.com/ollama/ollama) | 用户自行安装；公共模板连接本机默认端口 |
| 千问百炼 | [阿里云 Model Studio](https://help.aliyun.com/zh/model-studio/) | 可选云端 Provider；用户自行提供账号和 Key |
| DeepSeek API | [DeepSeek](https://api-docs.deepseek.com/) | 可选云端 Provider；用户自行提供账号和 Key |
| claude-code-proxy | [raine/claude-code-proxy](https://github.com/raine/claude-code-proxy) | 可选受管代理；只有命中批准 SHA256 时才下载执行 |
| CLIProxyAPI | [router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) | 可选受管代理；只有命中批准 SHA256 时才下载执行 |

Release 若实际捆绑任何第三方二进制，必须同时附带其许可证正文、精确版本、asset 名、来源和摘要。当前设计默认不把 Codex、Claude Code、Open Interpreter 或 Ollama 二进制装进本产品 ZIP。

两个 ChatGPT 代理均为第三方方案，不是 OpenAI 或 Anthropic 官方能力；演示或兼容性记录也不构成官方背书。

本项目与上述厂商、项目和作者均无官方隶属关系。
