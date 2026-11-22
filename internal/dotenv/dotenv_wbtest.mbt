///|
test "dotenv: parse basic KEY=VALUE" {
  defer @env.unset_env_var("VSCP_DOTENV_TEST_A")
  parse_env_line("VSCP_DOTENV_TEST_A=hello")
  assert_eq(@env.get_env_var("VSCP_DOTENV_TEST_A"), Some("hello"))
}

///|
test "dotenv: export prefix and spaces" {
  defer @env.unset_env_var("VSCP_DOTENV_TEST_B")
  parse_env_line("export VSCP_DOTENV_TEST_B = world")
  assert_eq(@env.get_env_var("VSCP_DOTENV_TEST_B"), Some("world"))
}

///|
test "dotenv: quoted values" {
  defer @env.unset_env_var("VSCP_DOTENV_TEST_C")
  defer @env.unset_env_var("VSCP_DOTENV_TEST_D")
  parse_env_line("VSCP_DOTENV_TEST_C=\"two words\"")
  parse_env_line("VSCP_DOTENV_TEST_D='single quoted'")
  assert_eq(@env.get_env_var("VSCP_DOTENV_TEST_C"), Some("two words"))
  assert_eq(@env.get_env_var("VSCP_DOTENV_TEST_D"), Some("single quoted"))
}

///|
test "dotenv: inline comment stripped for unquoted values" {
  defer @env.unset_env_var("VSCP_DOTENV_TEST_E")
  parse_env_line("VSCP_DOTENV_TEST_E=value # a comment")
  assert_eq(@env.get_env_var("VSCP_DOTENV_TEST_E"), Some("value"))
}

///|
test "dotenv: existing env vars are not overridden" {
  defer @env.unset_env_var("VSCP_DOTENV_TEST_F")
  @env.set_env_var("VSCP_DOTENV_TEST_F", "original")
  parse_env_line("VSCP_DOTENV_TEST_F=replaced")
  assert_eq(@env.get_env_var("VSCP_DOTENV_TEST_F"), Some("original"))
}

///|
test "dotenv: invalid lines are ignored" {
  parse_env_line("no equals sign")
  parse_env_line("=empty-key")
  assert_eq(@env.get_env_var(""), None)
}

///|
async test "dotenv: load_env reads a file with comments and CRLF" {
  let path = ".env.test-tmp"
  defer @fs.remove(path, allow_missing=true)
  defer @env.unset_env_var("VSCP_DOTENV_TEST_G")
  defer @env.unset_env_var("VSCP_DOTENV_TEST_H")
  let file = @fs.open(path, mode=WriteOnly, create_mode=CreateOrTruncate)
  file.write(
    "# comment line\r\n\r\nVSCP_DOTENV_TEST_G=1\r\nexport VSCP_DOTENV_TEST_H=\"two words\" # note\r\n",
  )
  file.close()
  load_env(path~)
  assert_eq(@env.get_env_var("VSCP_DOTENV_TEST_G"), Some("1"))
  assert_eq(@env.get_env_var("VSCP_DOTENV_TEST_H"), Some("two words"))
}

///|
async test "dotenv: missing file is ignored" {
  load_env(path=".env.does-not-exist")
}
