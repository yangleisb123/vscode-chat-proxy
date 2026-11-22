///|
/// `.env` loading: parsing is delegated to `spectacleCase/dotenv`
/// (quotes, export prefix, inline comments, BOM, malformed-line skipping).
/// This wrapper only adds the async file read and the project rule that
/// existing process environment variables are never overridden.

///|
/// Load environment variables from a `.env` file (default: `./.env`).
/// Missing or unreadable files are silently ignored.
pub async fn load_env(path~ : String = ".env") -> Unit {
  let text = @fs.read_file(path).text() catch { _ => return }
  let vars = @dotenv_lib.parse(text)
  for key, value in vars {
    if @env.get_env_var(key) is None {
      @env.set_env_var(key, value)
    }
  }
}
