///|
pub(all) struct Config {
  listen_host : String
  listen_port : Int32
  upstream_host : String
  upstream_port : Int32
}

///|
pub(all) suberror ConfigError {
  ConfigError(String)
}

///|
pub fn default_config() -> Config {
  {
    listen_host: "127.0.0.1",
    listen_port: 8787,
    upstream_host: "127.0.0.1",
    upstream_port: 8080,
  }
}

///|
/// Parse an environment variable as a port number, falling back to `default`
/// when missing, invalid or out of range.
fn parse_env_port(name : String, default : Int32) -> Int32 {
  match @env.get_env_var(name) {
    Some(s) => {
      let n = @string.parse_int(s.clamped_view().trim()) catch {
        _ => return default
      }
      if n < 1 || n > 65535 {
        default
      } else {
        n
      }
    }
    None => default
  }
}

///|
/// Build the base config from environment variables (call after `load_env`).
///
/// Individual variables: `HOST`, `PORT`, `UPSTREAM_HOST`, `UPSTREAM_PORT`.
/// Combined `host:port` variables `VSCODE_CHAT_PROXY_LISTEN` /
/// `VSCODE_CHAT_PROXY_UPSTREAM` take precedence over the individual ones.
pub fn config_from_env() -> Config {
  let mut cfg = default_config()
  match @env.get_env_var("HOST") {
    Some(h) if !h.is_empty() => cfg = { ..cfg, listen_host: h, }
    _ => ()
  }
  cfg = { ..cfg, listen_port: parse_env_port("PORT", cfg.listen_port), }
  match @env.get_env_var("UPSTREAM_HOST") {
    Some(h) if !h.is_empty() => cfg = { ..cfg, upstream_host: h, }
    _ => ()
  }
  cfg = {
    ..cfg,
    upstream_port: parse_env_port("UPSTREAM_PORT", cfg.upstream_port),
  }
  match @env.get_env_var("VSCODE_CHAT_PROXY_LISTEN") {
    Some(v) =>
      match parse_address(v) {
        Ok((h, p)) => cfg = { ..cfg, listen_host: h, listen_port: p, }
        Err(_) => ()
      }
    None => ()
  }
  match @env.get_env_var("VSCODE_CHAT_PROXY_UPSTREAM") {
    Some(v) =>
      match parse_address(v) {
        Ok((h, p)) => cfg = { ..cfg, upstream_host: h, upstream_port: p, }
        Err(_) => ()
      }
    None => ()
  }
  cfg
}

///|
/// Split `host:port` (also supports `[ipv6]:port`).
fn split_host_port(s : String) -> (String, Int32) raise ConfigError {
  let v = s.clamped_view()
  let (host, port_str) = if v.has_prefix("[") {
    match v.split_once("]:") {
      Some((h, p)) => (h.clamped_view(start=1).to_owned(), p.to_owned())
      None => raise ConfigError("invalid address: " + s)
    }
  } else {
    match v.split_once(":") {
      Some((h, p)) => (h.to_owned(), p.to_owned())
      None => raise ConfigError("expected host:port, got: " + s)
    }
  }
  if host.is_empty() {
    raise ConfigError("empty host in: " + s)
  }
  let port = @string.parse_int(port_str.clamped_view().trim()) catch {
    _ => raise ConfigError("invalid port in: " + s)
  }
  if port < 1 || port > 65535 {
    raise ConfigError("port out of range in: " + s)
  }
  (host, port)
}

///|
/// Public wrapper of `split_host_port` for environment variable handling.
pub fn parse_address(s : String) -> Result[(String, Int32), String] {
  Ok(split_host_port(s)) catch {
    ConfigError(msg) => Err(msg)
  }
}

///|
/// Whether the user asked for help.
pub fn wants_help(args : Array[String]) -> Bool {
  for arg in args {
    if arg == "--help" || arg == "-h" {
      return true
    }
  }
  false
}

///|
/// Parse CLI arguments (as returned by `@env.args()`, i.e. including the
/// program name at index 0) on top of a base config.
pub fn parse_config(
  args : Array[String],
  base : Config,
) -> Result[Config, String] {
  Ok(parse_config_exn(args, base)) catch {
    ConfigError(msg) => Err(msg)
  }
}

///|
fn parse_config_exn(
  args : Array[String],
  base : Config,
) -> Config raise ConfigError {
  let mut cfg = base
  let mut i = 1
  while i < args.length() {
    let arg = args[i]
    let v = arg.clamped_view()
    if v.equal_ignore_ascii_case("--help") || v.equal_ignore_ascii_case("-h") {
      i += 1
      continue
    }
    let (name, inline) = match v.split_once("=") {
      Some((n, val)) => (n.to_owned(), Some(val.to_owned()))
      None => (arg, None)
    }
    let value = match inline {
      Some(val) => val
      None => {
        i += 1
        if i >= args.length() {
          raise ConfigError("missing value for " + name)
        }
        args[i]
      }
    }
    match name {
      "--listen" | "-l" => {
        let (h, p) = split_host_port(value)
        cfg = { ..cfg, listen_host: h, listen_port: p, }
      }
      "--upstream" | "-u" => {
        let (h, p) = split_host_port(value)
        cfg = { ..cfg, upstream_host: h, upstream_port: p, }
      }
      _ => raise ConfigError("unknown option: " + name)
    }
    i += 1
  }
  cfg
}
