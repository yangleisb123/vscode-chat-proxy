///|
test "config: parse_address" {
  assert_eq(parse_address("127.0.0.1:8787"), Ok(("127.0.0.1", 8787)))
  assert_eq(parse_address("[::1]:8080"), Ok(("::1", 8080)))
  assert_eq(parse_address("example.com:80"), Ok(("example.com", 80)))
  assert_true(parse_address("no-port") is Err(_))
  assert_true(parse_address("host:0") is Err(_))
  assert_true(parse_address("host:99999") is Err(_))
  assert_true(parse_address("host:abc") is Err(_))
  assert_true(parse_address(":8080") is Err(_))
}

///|
test "config: defaults" {
  let cfg = parse_config(["prog"], default_config()).unwrap()
  assert_eq(cfg.listen_host, "127.0.0.1")
  assert_eq(cfg.listen_port, 8787)
  assert_eq(cfg.upstream_host, "127.0.0.1")
  assert_eq(cfg.upstream_port, 8080)
}

///|
test "config: overrides" {
  let cfg = parse_config(
    ["prog", "--listen", "0.0.0.0:9000", "-u", "api.local:8081"],
    default_config(),
  ).unwrap()
  assert_eq(cfg.listen_host, "0.0.0.0")
  assert_eq(cfg.listen_port, 9000)
  assert_eq(cfg.upstream_host, "api.local")
  assert_eq(cfg.upstream_port, 8081)
  let cfg2 = parse_config(["prog", "--listen=127.0.0.1:1234"], default_config()).unwrap()
  assert_eq(cfg2.listen_port, 1234)
}

///|
test "config: errors" {
  assert_true(
    parse_config(["prog", "--bogus", "x"], default_config()) is Err(_),
  )
  assert_true(parse_config(["prog", "--listen"], default_config()) is Err(_))
  assert_true(parse_config(["prog", "-l", "bad"], default_config()) is Err(_))
}

///|
test "config: wants_help" {
  assert_true(wants_help(["prog", "--help"]))
  assert_true(wants_help(["prog", "-h"]))
  assert_true(!wants_help(["prog", "--listen", "127.0.0.1:1"]))
}

///|
test "config: web options" {
  let cfg = parse_config(["prog", "--web", "0.0.0.0:9999"], default_config()).unwrap()
  assert_true(cfg.web_enabled)
  assert_eq(cfg.web_host, "0.0.0.0")
  assert_eq(cfg.web_port, 9999)
  let cfg2 = parse_config(["prog", "--no-web"], default_config()).unwrap()
  assert_true(!cfg2.web_enabled)
  let cfg3 = parse_config(["prog", "-w", "off"], default_config()).unwrap()
  assert_true(!cfg3.web_enabled)
  let cfg4 = parse_config(["prog"], default_config()).unwrap()
  assert_true(cfg4.web_enabled)
  assert_eq(cfg4.web_port, 8788)
}
