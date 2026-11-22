///|
/// Facade re-exports: keep the historical root-package API stable while
/// the implementation lives in layered sub-packages.
pub using @proxy_impl {
  ensure_system_prefix,
  required_prefix,
  handle_connection,
  type ProxyError,
}

///|
pub using @config_impl {
  type Config,
  type ConfigError,
  default_config,
  config_from_env,
  parse_config,
  parse_address,
  wants_help,
}

///|
pub using @monitor_impl {type Flow, type FlowStore, run_web_server}

///|
pub using @dotenv_impl {load_env}
