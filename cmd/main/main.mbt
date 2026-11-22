///|
/// Entry point: parse config, listen, and proxy connections forever.
/// Run with `moon run cmd/main -- --listen 127.0.0.1:8787 --upstream 127.0.0.1:8080`.
async fn main {
  let args = @env.args()
  if @proxy.wants_help(args) {
    println(usage())
    return
  }
  // Load `.env` (existing environment variables win), then build the base
  // config from the environment; CLI flags override everything.
  @proxy.load_env()
  let base = @proxy.config_from_env()
  let cfg = match @proxy.parse_config(args, base) {
    Ok(cfg) => cfg
    Err(msg) => {
      println("[proxy] " + msg)
      println(usage())
      @env.exit(1)
    }
  }
  // Monitor flows live in the system temp directory so they survive proxy
  // restarts; `--no-web` keeps the historical memory-only behaviour.
  let store = if cfg.web_enabled {
    let dir = @proxy.default_store_dir(port=cfg.web_port)
    let store = @proxy.FlowStore::open(dir)
    let actual = store.data_dir()
    if actual.is_empty() {
      println("[monitor] cannot use " + dir + ", falling back to memory")
    } else {
      println("[monitor] data dir: " + actual)
    }
    store
  } else {
    @proxy.FlowStore::new()
  }
  store.set_intercept_enabled(cfg.intercept)
  try
    @async.with_task_group() <| group => {
      // Batched monitor persistence off the proxy hot path.
      group.spawn_bg(allow_failure=true) <| () => { store.run_flusher() }
      // Monitor web UI (mitmweb style). Its failure must not kill the proxy.
      if cfg.web_enabled {
        group.spawn_bg(allow_failure=true) <| () => {
          try {
            println(
              "[web] monitor UI on http://" +
              cfg.web_host +
              ":" +
              cfg.web_port.to_string(),
            )
            @proxy.run_web_server(cfg.web_host, cfg.web_port, store)
          } catch {
            e => println("[web] monitor UI failed: " + e.to_string())
          }
        }
      }
      let addr = @socket.Addr::resolve(cfg.listen_host, port=cfg.listen_port)
      let server = @socket.TcpServer(addr, reuse_addr=true)
      println(
        "[proxy] listening on " +
        cfg.listen_host +
        ":" +
        cfg.listen_port.to_string(),
      )
      if cfg.forward {
        println(
          "[proxy] mode: forward (mitmproxy-style, destination from each request)",
        )
        println("[proxy] CONNECT: blind tunnel (HTTPS passes through, no MITM)")
      } else {
        println(
          "[proxy] mode: reverse, upstream: " +
          cfg.upstream_host +
          ":" +
          cfg.upstream_port.to_string(),
        )
      }
      println("[proxy] system prompt: \"" + cfg.system_prompt + "\"")
      println(
        "[proxy] intercept: " +
        (if cfg.intercept { "on" } else { "off (pass-through)" }),
      )
      println("[proxy] intercepting POST */v1/chat/completions")
      server.run_forever((conn, peer) => {
        @proxy.handle_connection(conn, cfg, store, peer.to_string())
      })
    }
  catch {
    e => {
      println("[proxy] fatal: " + e.to_string())
      @env.exit(1)
    }
  }
}

///|
fn usage() -> String {
  "Usage: vscode-chat-proxy [options]\n" +
  "\n" +
  "A local forward proxy (mitmproxy-style): point your application's HTTP\n" +
  "proxy setting at it and requests are forwarded to their original address,\n" +
  "with the Chat Completions system message rewritten on the way.\n" +
  "HTTPS (CONNECT) is tunneled blindly: encrypted bodies are not inspectable.\n" +
  "With --upstream it instead acts as a reverse proxy pinned to that server.\n" +
  "\n" +
  "Options:\n" +
  "  -l, --listen <host:port>    Local address to listen on (default 127.0.0.1:8787)\n" +
  "  -u, --upstream <host:port>  Pin a fixed upstream (reverse-proxy mode);\n" +
  "                              omit for forward mode (default)\n" +
  "  -f, --forward               Force forward mode even if .env pins an upstream\n" +
  "      --intercept on|off      Initial interception switch (default on);\n" +
  "                              also toggleable live in the monitor UI\n" +
  "      --no-intercept          Start as pure pass-through (intercept off)\n" +
  "  -w, --web <host:port|off>   Monitor web UI address (default 127.0.0.1:8788)\n" +
  "      --no-web                Disable the monitor web UI\n" +
  "  -s, --system-prompt <text>  Sentence forced to open the system message\n" +
  "                              (alias --prompt; default: \"你是一个AI助手，工作在 vscode 环境中\")\n" +
  "  -h, --help                  Show this help\n" +
  "\n" +
  "Configuration precedence: CLI flags > environment variables > .env > defaults.\n" +
  "A `.env` file in the working directory is loaded automatically (see .env.example).\n" +
  "\n" +
  "Environment variables:\n" +
  "  HOST / PORT                 Listen address (default 127.0.0.1 / 8787)\n" +
  "  UPSTREAM_HOST / UPSTREAM_PORT  Pin upstream (reverse mode); unset = forward\n" +
  "  WEB_HOST / WEB_PORT         Monitor UI address (default 127.0.0.1 / 8788)\n" +
  "  MONITOR_DIR                 Monitor data directory (default: system temp\n" +
  "                              directory / vscode-chat-proxy-monitor-<WEB_PORT>)\n" +
  "  SYSTEM_PROMPT               Sentence forced to open the system message\n" +
  "  VSCODE_CHAT_PROXY_LISTEN    Combined host:port, overrides HOST/PORT\n" +
  "  VSCODE_CHAT_PROXY_UPSTREAM  Combined host:port, overrides UPSTREAM_HOST/UPSTREAM_PORT\n"
}
