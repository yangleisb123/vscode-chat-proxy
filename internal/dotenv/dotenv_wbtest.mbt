///|
/// Blackbox-ish tests of the load_env wrapper semantics (file parsing itself
/// is covered by spectacleCase/dotenv's own suite).
async test "dotenv: loads assignments, export prefix, quotes, comments" {
  let path = ".env.test-tmp"
  defer @fs.remove(path, allow_missing=true)
  defer @env.unset_env_var("VSCP_DOTENV_TEST_A")
  defer @env.unset_env_var("VSCP_DOTENV_TEST_B")
  defer @env.unset_env_var("VSCP_DOTENV_TEST_C")
  defer @env.unset_env_var("VSCP_DOTENV_TEST_D")
  let file = @fs.open(path, mode=WriteOnly, create_mode=CreateOrTruncate)
  file.write(
    "# comment line\r\n\r\nVSCP_DOTENV_TEST_A=1\r\nexport VSCP_DOTENV_TEST_B=\"two words\" # note\r\nVSCP_DOTENV_TEST_C='single quoted'\r\nVSCP_DOTENV_TEST_D=value # trailing\r\n",
  )
  file.close()
  load_env(path~)
  assert_eq(@env.get_env_var("VSCP_DOTENV_TEST_A"), Some("1"))
  assert_eq(@env.get_env_var("VSCP_DOTENV_TEST_B"), Some("two words"))
  assert_eq(@env.get_env_var("VSCP_DOTENV_TEST_C"), Some("single quoted"))
  assert_eq(@env.get_env_var("VSCP_DOTENV_TEST_D"), Some("value"))
}

///|
async test "dotenv: existing env vars are not overridden" {
  let path = ".env.test-tmp2"
  defer @fs.remove(path, allow_missing=true)
  defer @env.unset_env_var("VSCP_DOTENV_TEST_E")
  @env.set_env_var("VSCP_DOTENV_TEST_E", "original")
  let file = @fs.open(path, mode=WriteOnly, create_mode=CreateOrTruncate)
  file.write("VSCP_DOTENV_TEST_E=replaced\n")
  file.close()
  load_env(path~)
  assert_eq(@env.get_env_var("VSCP_DOTENV_TEST_E"), Some("original"))
}

///|
async test "dotenv: missing file is ignored" {
  load_env(path=".env.does-not-exist")
}
