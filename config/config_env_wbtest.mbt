///|
test "config: config_from_env individual vars" {
  @env.set_env_var("HOST", "0.0.0.0")
  @env.set_env_var("PORT", "9999")
  @env.set_env_var("UPSTREAM_HOST", "api.local")
  @env.set_env_var("UPSTREAM_PORT", "8081")
  defer @env.unset_env_var("HOST")
  defer @env.unset_env_var("PORT")
  defer @env.unset_env_var("UPSTREAM_HOST")
  defer @env.unset_env_var("UPSTREAM_PORT")
  let cfg = config_from_env()
  assert_eq(cfg.listen_host, "0.0.0.0")
  assert_eq(cfg.listen_port, 9999)
  assert_eq(cfg.upstream_host, "api.local")
  assert_eq(cfg.upstream_port, 8081)
}

///|
test "config: combined vars take precedence over individual ones" {
  @env.set_env_var("HOST", "0.0.0.0")
  @env.set_env_var("PORT", "9999")
  @env.set_env_var("VSCODE_CHAT_PROXY_LISTEN", "127.0.0.1:1234")
  @env.set_env_var("VSCODE_CHAT_PROXY_UPSTREAM", "[::1]:8081")
  defer @env.unset_env_var("HOST")
  defer @env.unset_env_var("PORT")
  defer @env.unset_env_var("VSCODE_CHAT_PROXY_LISTEN")
  defer @env.unset_env_var("VSCODE_CHAT_PROXY_UPSTREAM")
  let cfg = config_from_env()
  assert_eq(cfg.listen_host, "127.0.0.1")
  assert_eq(cfg.listen_port, 1234)
  assert_eq(cfg.upstream_host, "::1")
  assert_eq(cfg.upstream_port, 8081)
}

///|
test "config: invalid env values fall back to defaults" {
  @env.set_env_var("PORT", "not-a-number")
  @env.set_env_var("UPSTREAM_PORT", "99999")
  @env.set_env_var("VSCODE_CHAT_PROXY_LISTEN", "garbage")
  defer @env.unset_env_var("PORT")
  defer @env.unset_env_var("UPSTREAM_PORT")
  defer @env.unset_env_var("VSCODE_CHAT_PROXY_LISTEN")
  let cfg = config_from_env()
  assert_eq(cfg.listen_port, 8787)
  assert_eq(cfg.upstream_port, 8080)
  assert_eq(cfg.listen_host, "127.0.0.1")
}

///|
test "config: web env vars" {
  @env.set_env_var("WEB_HOST", "0.0.0.0")
  @env.set_env_var("WEB_PORT", "9090")
  defer @env.unset_env_var("WEB_HOST")
  defer @env.unset_env_var("WEB_PORT")
  let cfg = config_from_env()
  assert_eq(cfg.web_host, "0.0.0.0")
  assert_eq(cfg.web_port, 9090)
}

///|
test "config: system prompt default and env override" {
  @env.unset_env_var("SYSTEM_PROMPT")
  @env.unset_env_var("VSCODE_CHAT_PROXY_SYSTEM_PROMPT")
  let base = config_from_env()
  assert_eq(base.system_prompt, default_system_prompt)
  @env.set_env_var("SYSTEM_PROMPT", " 你是代码审阅助手 ")
  defer @env.unset_env_var("SYSTEM_PROMPT")
  let cfg = config_from_env()
  assert_eq(cfg.system_prompt, "你是代码审阅助手")
}

///|
test "config: system prompt combined alias" {
  @env.unset_env_var("SYSTEM_PROMPT")
  @env.set_env_var("VSCODE_CHAT_PROXY_SYSTEM_PROMPT", "alias 生效")
  defer @env.unset_env_var("VSCODE_CHAT_PROXY_SYSTEM_PROMPT")
  assert_eq(config_from_env().system_prompt, "alias 生效")
}

///|
test "config: blank system prompt keeps the default" {
  @env.unset_env_var("VSCODE_CHAT_PROXY_SYSTEM_PROMPT")
  @env.set_env_var("SYSTEM_PROMPT", "   ")
  defer @env.unset_env_var("SYSTEM_PROMPT")
  assert_eq(config_from_env().system_prompt, default_system_prompt)
}
