///|
/// The sentence forced to be the first sentence of the Chat Completions
/// system message unless overridden by `SYSTEM_PROMPT` / `--system-prompt`.
pub let default_system_prompt : String = "你是一个AI助手，工作在 vscode 环境中"

///|
pub(all) struct Config {
  listen_host : String
  listen_port : Int32
  upstream_host : String
  upstream_port : Int32
  /// true = forward proxy (mitmproxy-style): destination derived from each
  /// request (absolute-form URL / Host header / CONNECT authority).
  /// false = reverse proxy pinned to upstream_host:upstream_port.
  forward : Bool
  web_enabled : Bool
  web_host : String
  web_port : Int32
  /// Sentence forced to open the first `system` message.
  system_prompt : String
  /// Initial value of the interception switch (runtime-toggleable in the
  /// monitor UI). false = pure pass-through proxy.
  intercept : Bool
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
    forward: true,
    web_enabled: true,
    web_host: "127.0.0.1",
    web_port: 8788,
    system_prompt: default_system_prompt,
    intercept: true,
  }
}

///|
/// Trim a user-supplied prompt; blank input means "keep the default".
fn normalize_prompt(raw : String) -> String? {
  let v = raw.clamped_view().trim()
  if v.is_empty() {
    None
  } else {
    Some(v.to_owned())
  }
}

///|
/// Read the configurable system prompt from `SYSTEM_PROMPT` (preferred) or
/// `VSCODE_CHAT_PROXY_SYSTEM_PROMPT`, falling back to `default`.
fn system_prompt_from_env(default : String) -> String {
  for name in ["SYSTEM_PROMPT", "VSCODE_CHAT_PROXY_SYSTEM_PROMPT"] {
    match @env.get_env_var(name) {
      Some(raw) =>
        match normalize_prompt(raw) {
          Some(prompt) => return prompt
          None => ()
        }
      None => ()
    }
  }
  default
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
/// Parse an on/off environment variable (`1/0/true/false/on/off/yes/no`),
/// falling back to `default` when missing or unrecognised.
fn parse_env_bool(name : String, default : Bool) -> Bool {
  match @env.get_env_var(name) {
    Some(s) => parse_bool_value(s.clamped_view().trim(), default)
    None => default
  }
}

///|
/// Interpret a boolean CLI/env token; unrecognised values keep `default`.
fn parse_bool_value(v : StringView, default : Bool) -> Bool {
  if v.equal_ignore_ascii_case("1") ||
    v.equal_ignore_ascii_case("true") ||
    v.equal_ignore_ascii_case("on") ||
    v.equal_ignore_ascii_case("yes") {
    true
  } else if v.equal_ignore_ascii_case("0") ||
    v.equal_ignore_ascii_case("false") ||
    v.equal_ignore_ascii_case("off") ||
    v.equal_ignore_ascii_case("no") {
    false
  } else {
    default
  }
}

///|
/// Build the base config from environment variables (call after `load_env`).
///
/// Individual variables: `HOST`, `PORT`, `UPSTREAM_HOST`, `UPSTREAM_PORT`,
/// `WEB_HOST`, `WEB_PORT`, and `SYSTEM_PROMPT` (the sentence forced to open
/// the `system` message).
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
    Some(h) if !h.is_empty() =>
      cfg = { ..cfg, upstream_host: h, forward: false, }
    _ => ()
  }
  match @env.get_env_var("UPSTREAM_PORT") {
    Some(_) => cfg = { ..cfg, forward: false, }
    None => ()
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
        Ok((h, p)) =>
          cfg = { ..cfg, upstream_host: h, upstream_port: p, forward: false, }
        Err(_) => ()
      }
    None => ()
  }
  match @env.get_env_var("WEB_HOST") {
    Some(h) if !h.is_empty() => cfg = { ..cfg, web_host: h, }
    _ => ()
  }
  cfg = { ..cfg, web_port: parse_env_port("WEB_PORT", cfg.web_port), }
  cfg = { ..cfg, system_prompt: system_prompt_from_env(cfg.system_prompt), }
  cfg = {
    ..cfg,
    intercept: parse_env_bool(
      "INTERCEPT",
      parse_env_bool("VSCODE_CHAT_PROXY_INTERCEPT", cfg.intercept),
    ),
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
    if v.equal_ignore_ascii_case("--no-web") {
      cfg = { ..cfg, web_enabled: false, }
      i += 1
      continue
    }
    if v.equal_ignore_ascii_case("--forward") || v.equal_ignore_ascii_case("-f") {
      cfg = { ..cfg, forward: true, }
      i += 1
      continue
    }
    if v.equal_ignore_ascii_case("--no-intercept") {
      cfg = { ..cfg, intercept: false, }
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
        cfg = { ..cfg, upstream_host: h, upstream_port: p, forward: false, }
      }
      "--web" | "-w" =>
        if value.clamped_view().equal_ignore_ascii_case("off") ||
          value.clamped_view().equal_ignore_ascii_case("none") {
          cfg = { ..cfg, web_enabled: false, }
        } else {
          let (h, p) = split_host_port(value)
          cfg = { ..cfg, web_enabled: true, web_host: h, web_port: p, }
        }
      "--system-prompt" | "--prompt" | "-s" =>
        match normalize_prompt(value) {
          Some(prompt) => cfg = { ..cfg, system_prompt: prompt, }
          None => raise ConfigError("empty value for " + name)
        }
      "--intercept" =>
        cfg = {
          ..cfg,
          intercept: parse_bool_value(
            value.clamped_view().trim(),
            cfg.intercept,
          ),
        }
      _ => raise ConfigError("unknown option: " + name)
    }
    i += 1
  }
  cfg
}
