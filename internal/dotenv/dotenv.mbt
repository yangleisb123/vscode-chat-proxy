///|
/// 简易 `.env` 文件加载（参考 moonbit_claude_proxy 的用户配置模式）。
/// 支持 KEY=VALUE、`#` 注释、空行、引号包裹的值、`export` 前缀与行内注释。
/// 已存在的环境变量不会被覆盖。

///|
/// Load environment variables from a `.env` file (default: `./.env`).
/// Missing or unreadable files are silently ignored.
pub async fn load_env(path~ : String = ".env") -> Unit {
  let text = try {
    let data = @fs.read_file(path)
    data.text()
  } catch {
    _ => return
  }
  for line in text.split("\n") {
    let line_str = line.trim().to_owned()
    if line_str == "" || line_str.has_prefix("#") {
      continue
    }
    parse_env_line(line_str)
  }
}

///|
fn parse_env_line(line : String) -> Unit {
  let mut content = line.clamped_view()
  // Strip the `export ` prefix.
  if content.has_prefix("export ") {
    content = content.clamped_view(start=7)
  }
  match content.split_once("=") {
    Some((k, v)) => {
      let key = k.trim().to_owned()
      // Skip empty keys and variables already present in the environment.
      if key == "" || @env.get_env_var(key) is Some(_) {
        return
      }
      let mut value = v.trim()
      if value.has_prefix("\"") || value.has_prefix("'") {
        // Quoted value: take the content up to the matching closing quote;
        // anything after it (e.g. an inline comment) is ignored.
        let quote = value.clamped_view(end=1)
        match value.clamped_view(start=1).find(quote) {
          Some(end) => value = value.clamped_view(start=1, end=end + 1)
          None => () // unterminated quote: keep the raw value
        }
      } else {
        // Strip inline comments for unquoted values.
        match value.find("#") {
          Some(pos) if pos > 0 => value = value.clamped_view(end=pos).trim()
          _ => ()
        }
      }
      @env.set_env_var(key, value.to_owned())
    }
    None => ()
  }
}
