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
  try {
    let addr = @socket.Addr::resolve(cfg.listen_host, port=cfg.listen_port)
    let server = @socket.TcpServer(addr, reuse_addr=true)
    println(
      "[proxy] listening on " +
      cfg.listen_host +
      ":" +
      cfg.listen_port.to_string(),
    )
    println(
      "[proxy] upstream: " +
      cfg.upstream_host +
      ":" +
      cfg.upstream_port.to_string(),
    )
    println("[proxy] intercepting POST */v1/chat/completions")
    server.run_forever((conn, _) => @proxy.handle_connection(conn, cfg))
  } catch {
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
  "A local HTTP proxy that ensures the system message of Chat Completions\n" +
  "requests starts with the required VSCode AI-assistant sentence.\n" +
  "\n" +
  "Options:\n" +
  "  -l, --listen <host:port>    Local address to listen on (default 127.0.0.1:8787)\n" +
  "  -u, --upstream <host:port>  Upstream HTTP API server (default 127.0.0.1:8080)\n" +
  "  -h, --help                  Show this help\n" +
  "\n" +
  "Configuration precedence: CLI flags > environment variables > .env > defaults.\n" +
  "A `.env` file in the working directory is loaded automatically (see .env.example).\n" +
  "\n" +
  "Environment variables:\n" +
  "  HOST / PORT                 Listen address (default 127.0.0.1 / 8787)\n" +
  "  UPSTREAM_HOST / UPSTREAM_PORT  Upstream address (default 127.0.0.1 / 8080)\n" +
  "  VSCODE_CHAT_PROXY_LISTEN    Combined host:port, overrides HOST/PORT\n" +
  "  VSCODE_CHAT_PROXY_UPSTREAM  Combined host:port, overrides UPSTREAM_HOST/UPSTREAM_PORT\n"
}
