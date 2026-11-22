# vscode-chat-proxy

一个用 **MoonBit** 编写的本地 HTTP 反向代理：监听本地端口，把请求转发给上游 API 服务器，
并拦截所有 **URL 以 `/v1/chat/completions` 结尾的 POST 请求**（标准 Chat Completions API），
确保其 System message 的第一句是：

> 你是一个AI助手，工作在 vscode 环境中

支持 **Windows** 和 **Linux**（macOS 也可以）。基于官方 [`moonbitlang/async`](https://github.com/moonbitlang/async)
异步运行时（Linux epoll / Windows IOCP），单进程即可并发处理多个连接，**SSE 流式响应实时透传**。

## 拦截规则

对 `POST */v1/chat/completions`（忽略 query string，支持路径带前缀如 `/openai/v1/chat/completions`）：

| 请求体情况 | 处理 |
|---|---|
| 第一条 `role:"system"` 消息的内容**以这句话开头**（允许前导空白，后面可接其他内容） | 原样放行 |
| 有 system 消息但开头不是这句话 | 在该内容**最前面**加上 `你是一个AI助手，工作在 vscode 环境中。` + 换行，其余内容保留 |
| 没有任何 system 消息 | 在 `messages` 数组**最前面插入**一条 `{"role":"system","content":"你是一个AI助手，工作在 vscode 环境中。"}` |
| system 的 content 是多模态数组（`[{type:"text",...},...]`） | 检查/改写第一个 `text` 片段；没有 text 片段则插入一个 |
| 请求体不是合法 JSON | 原样转发（日志给出警告） |

其他请求（GET、其他路径、其他方法）**全部原样透传**，不做任何修改。

转发时会自动：重写 `Host` 为上游地址、按改写后的_body_重算 `Content-Length`、
支持 `Transfer-Encoding: chunked` 请求体解码、处理 `Expect: 100-continue`、
强制 `Connection: close`（每个连接处理一个请求，客户端会自动重连，不影响使用）。

## 快速开始

只需要 MoonBit 工具链（`moon` 已安装即可，**无需其他依赖**）。

```bash
cd vscode-chat-proxy

# 运行（默认 wasm 目标，Windows / Linux 都开箱即用）
moon run cmd/main -- --listen 127.0.0.1:8787 --upstream 127.0.0.1:8080
```

- `--listen` / `-l`：本地监听地址，默认 `127.0.0.1:8787`
- `--upstream` / `-u`：上游 HTTP API 服务器地址，默认 `127.0.0.1:8080`
- 也支持环境变量 `VSCODE_CHAT_PROXY_LISTEN` / `VSCODE_CHAT_PROXY_UPSTREAM`（命令行优先）
- `--help` 查看帮助

然后把客户端（VSCode 插件、CLI 等）的 API Base URL 指向代理，例如：

```
原来: http://127.0.0.1:8080/v1
现在: http://127.0.0.1:8787/v1
```

### 示例

```bash
# 上游是你的 API 网关（one-api / sub2api / new-api 等），监听 8080
moon run cmd/main -- -l 127.0.0.1:8787 -u 127.0.0.1:8080

# 测试：没有 system 消息的请求会被自动插入
curl http://127.0.0.1:8787/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"你好"}]}'
```

代理日志会显示每个拦截请求的处理结果（`injected system prefix` / `system prefix ok, pass through`）。

## 构建独立可执行文件（Linux 推荐）

```bash
moon build --target native --release
# 产物: _build/native/release/build/cmd/main/main.exe   （Linux 下就是 ELF 可执行文件）
./_build/native/release/build/cmd/main/main.exe -l 0.0.0.0:8787 -u 127.0.0.1:8080
```

- **Linux**：native 目标需要 gcc / clang（发行版自带即可），已在 OpenCloudOS 9 + gcc 12 实测通过。
- **Windows**：native 目标按 MoonBit 官方要求需要 **MSVC**（VS Build Tools 的「使用 C++ 的桌面开发」
  工作负载，含 Windows SDK；MinGW 不支持）。**没有 MSVC 也没关系**——默认的 wasm 目标
  由工具链自带的 `moonrun` 运行，功能完全一致，已在 Windows 11 实测通过。
- wasm 目标产物在 `_build/wasm/release/build/cmd/main/main.wasm`，
  可用 `moon run cmd/main --target wasm --release -- <参数>` 运行。

## 测试

```bash
moon test                 # 23 个单元测试（默认 wasm 目标）
moon test --target native # Linux / 有 MSVC 的 Windows

# 端到端测试：先起一个 mock 上游（需要 Node.js）
node test/mock-upstream.mjs 18080
moon run cmd/main -- -l 127.0.0.1:18787 -u 127.0.0.1:18080
# 然后向 18787 发请求，mock 会把收到的请求体原样返回，便于核对改写结果
```

已验证场景（Windows wasm 与 Linux native 双平台）：
无 system 插入、已有前缀放行、其他 system 文本前置注入、多模态 content、
SSE 流式透传、chunked 请求体、GET/其他路径透传、`Authorization` 等头部保留。

## 项目结构

```
prefix.mbt        # 核心逻辑：system message 检查与注入（纯函数，可单测）
http.mbt          # HTTP 请求行/头部解析、目标路径匹配、上游请求头重建
proxy.mbt         # 异步连接处理：读请求 → 改写 → 转发 → 流式回传
config.mbt        # 命令行/地址解析
cmd/main/         # 入口：监听端口，run_forever 并发处理连接
test/             # mock 上游（Node.js，端到端测试用）
```

## 已知限制

- 上游必须是 **HTTP**（明文）。如需代理 HTTPS 上游，可在上游侧放一个 TLS 终结
  （如 nginx/stunnel），或让客户端继续直连 HTTPS、仅把本地 HTTP 网关挂在代理后面。
- 不支持 `CONNECT`（HTTPS 隧道）与 WebSocket/`Upgrade` 请求（分别返回 405/501）。
- 每个连接只处理一个请求（`Connection: close`）；对 API 调用场景无实际影响。
- 请求体缓冲上限 64 MiB。
- 只检查**第一条** system 消息；`developer` role 不视为 system。