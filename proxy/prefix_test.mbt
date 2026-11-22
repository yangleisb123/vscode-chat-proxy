///|
/// Parse a JSON fixture written with single quotes (for readability).
/// Fixture content must not contain literal single quotes.
fn fixture(s : String) -> Json raise {
  @json.parse(s.clamped_view().replace_all(old="'", new="\""))
}

///|
fn content_of_first_message(body : Json) -> String? {
  guard body is Object(obj) else { return None }
  guard obj.get("messages") is Some(Array(msgs)) else { return None }
  guard msgs.length() > 0 && msgs[0] is Object(m) else { return None }
  guard m.get("content") is Some(String(s)) else { return None }
  Some(s)
}

///|
test "prefix: constant matches the spec" {
  assert_eq(
    @proxy.required_prefix, "你是一个AI助手，工作在 vscode 环境中",
  )
}

///|
test "prefix: no system message inserts one at the front" {
  let body = fixture(
    "{'model':'m','messages':[{'role':'user','content':'hi'}]}",
  )
  assert_true(@proxy.ensure_system_prefix(body))
  let expected = fixture(
    "{'model':'m','messages':[{'role':'system','content':'你是一个AI助手，工作在 vscode 环境中。'},{'role':'user','content':'hi'}]}",
  )
  assert_true(body == expected)
}

///|
test "prefix: already present is left untouched" {
  let src = "{'messages':[{'role':'system','content':'你是一个AI助手，工作在 vscode 环境中。请简洁回答。'},{'role':'user','content':'hi'}]}"
  let body = fixture(src)
  assert_true(!@proxy.ensure_system_prefix(body))
  assert_true(body == fixture(src))
}

///|
test "prefix: present without punctuation still passes" {
  let body = fixture(
    "{'messages':[{'role':'system','content':'你是一个AI助手，工作在 vscode 环境中，负责写代码'}]}",
  )
  assert_true(!@proxy.ensure_system_prefix(body))
}

///|
test "prefix: leading whitespace is ignored" {
  let body = fixture(
    "{'messages':[{'role':'system','content':'  你是一个AI助手，工作在 vscode 环境中。'}]}",
  )
  assert_true(!@proxy.ensure_system_prefix(body))
}

///|
test "prefix: other system text gets the sentence prepended" {
  let body = fixture(
    "{'messages':[{'role':'system','content':'You are a helpful assistant.'},{'role':'user','content':'hi'}]}",
  )
  assert_true(@proxy.ensure_system_prefix(body))
  assert_eq(
    content_of_first_message(body),
    Some(
      "你是一个AI助手，工作在 vscode 环境中。\nYou are a helpful assistant.",
    ),
  )
}

///|
test "prefix: empty system content becomes the sentence" {
  let body = fixture("{'messages':[{'role':'system','content':''}]}")
  assert_true(@proxy.ensure_system_prefix(body))
  assert_eq(
    content_of_first_message(body),
    Some("你是一个AI助手，工作在 vscode 环境中。"),
  )
}

///|
test "prefix: only the first system message is checked" {
  let src = "{'messages':[{'role':'system','content':'你是一个AI助手，工作在 vscode 环境中。'},{'role':'system','content':'another rule'}]}"
  let body = fixture(src)
  assert_true(!@proxy.ensure_system_prefix(body))
  assert_true(body == fixture(src))
}

///|
test "prefix: multimodal text part gets the sentence prepended" {
  let body = fixture(
    "{'messages':[{'role':'system','content':[{'type':'text','text':'be nice'},{'type':'image_url','image_url':{'url':'x'}}]}]}",
  )
  assert_true(@proxy.ensure_system_prefix(body))
  let expected = fixture(
    "{'messages':[{'role':'system','content':[{'type':'text','text':'你是一个AI助手，工作在 vscode 环境中。\\nbe nice'},{'type':'image_url','image_url':{'url':'x'}}]}]}",
  )
  assert_true(body == expected)
}

///|
test "prefix: multimodal already ok is untouched" {
  let src = "{'messages':[{'role':'system','content':[{'type':'text','text':'你是一个AI助手，工作在 vscode 环境中。'}]}]}"
  let body = fixture(src)
  assert_true(!@proxy.ensure_system_prefix(body))
  assert_true(body == fixture(src))
}

///|
test "prefix: multimodal without text part gets one inserted" {
  let body = fixture(
    "{'messages':[{'role':'system','content':[{'type':'image_url','image_url':{'url':'x'}}]}]}",
  )
  assert_true(@proxy.ensure_system_prefix(body))
  let expected = fixture(
    "{'messages':[{'role':'system','content':[{'type':'text','text':'你是一个AI助手，工作在 vscode 环境中。'},{'type':'image_url','image_url':{'url':'x'}}]}]}",
  )
  assert_true(body == expected)
}

///|
test "prefix: bodies without messages are untouched" {
  let src1 = "{'model':'m'}"
  let body1 = fixture(src1)
  assert_true(!@proxy.ensure_system_prefix(body1))
  assert_true(body1 == fixture(src1))
  let src2 = "{'messages':'not-an-array'}"
  let body2 = fixture(src2)
  assert_true(!@proxy.ensure_system_prefix(body2))
  let body3 = fixture("[1,2,3]")
  assert_true(!@proxy.ensure_system_prefix(body3))
}
