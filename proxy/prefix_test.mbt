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
    @proxy.required_prefix, "You are an expert AI programming assistant, working with a user in the VS Code editor.",
  )
}

///|
test "prefix: no system message inserts one at the front" {
  let body = fixture(
    "{'model':'m','messages':[{'role':'user','content':'hi'}]}",
  )
  assert_true(@proxy.ensure_system_prefix(body))
  let expected = fixture(
    "{'model':'m','messages':[{'role':'system','content':'You are an expert AI programming assistant, working with a user in the VS Code editor.'},{'role':'user','content':'hi'}]}",
  )
  assert_true(body == expected)
}

///|
test "prefix: already present is left untouched" {
  let src = "{'messages':[{'role':'system','content':'You are an expert AI programming assistant, working with a user in the VS Code editor. Please answer concisely.'},{'role':'user','content':'hi'}]}"
  let body = fixture(src)
  assert_true(!@proxy.ensure_system_prefix(body))
  assert_true(body == fixture(src))
}

///|
test "prefix: default sentence followed by more text passes" {
  let body = fixture(
    "{'messages':[{'role':'system','content':'You are an expert AI programming assistant, working with a user in the VS Code editor. Write clean code.'}]}",
  )
  assert_true(!@proxy.ensure_system_prefix(body))
}

///|
test "prefix: leading whitespace is ignored" {
  let body = fixture(
    "{'messages':[{'role':'system','content':'  You are an expert AI programming assistant, working with a user in the VS Code editor.'}]}",
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
      "You are an expert AI programming assistant, working with a user in the VS Code editor.\nYou are a helpful assistant.",
    ),
  )
}

///|
test "prefix: empty system content becomes the sentence" {
  let body = fixture("{'messages':[{'role':'system','content':''}]}")
  assert_true(@proxy.ensure_system_prefix(body))
  assert_eq(
    content_of_first_message(body),
    Some(
      "You are an expert AI programming assistant, working with a user in the VS Code editor.",
    ),
  )
}

///|
test "prefix: only the first system message is checked" {
  let src = "{'messages':[{'role':'system','content':'You are an expert AI programming assistant, working with a user in the VS Code editor.'},{'role':'system','content':'another rule'}]}"
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
    "{'messages':[{'role':'system','content':[{'type':'text','text':'You are an expert AI programming assistant, working with a user in the VS Code editor.\\nbe nice'},{'type':'image_url','image_url':{'url':'x'}}]}]}",
  )
  assert_true(body == expected)
}

///|
test "prefix: multimodal already ok is untouched" {
  let src = "{'messages':[{'role':'system','content':[{'type':'text','text':'You are an expert AI programming assistant, working with a user in the VS Code editor.'}]}]}"
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
    "{'messages':[{'role':'system','content':[{'type':'text','text':'You are an expert AI programming assistant, working with a user in the VS Code editor.'},{'type':'image_url','image_url':{'url':'x'}}]}]}",
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

///|
test "custom prefix: injected when no system message" {
  let body = fixture(
    "{'model':'m','messages':[{'role':'user','content':'hi'}]}",
  )
  assert_true(
    @proxy.ensure_system_prefix_with(body, "你是代码审阅助手"),
  )
  let expected = fixture(
    "{'model':'m','messages':[{'role':'system','content':'你是代码审阅助手。'},{'role':'user','content':'hi'}]}",
  )
  assert_true(body == expected)
}

///|
test "custom prefix: already present passes through" {
  let src = "{'messages':[{'role':'system','content':'  你是代码审阅助手。请简洁回答。'},{'role':'user','content':'hi'}]}"
  let body = fixture(src)
  assert_true(
    !@proxy.ensure_system_prefix_with(body, "你是代码审阅助手"),
  )
  assert_true(body == fixture(src))
}

///|
test "custom prefix: other system text gets it prepended" {
  let body = fixture(
    "{'messages':[{'role':'system','content':'You are helpful.'},{'role':'user','content':'hi'}]}",
  )
  assert_true(
    @proxy.ensure_system_prefix_with(body, "You are an AI assistant in VSCode"),
  )
  assert_eq(
    content_of_first_message(body),
    Some("You are an AI assistant in VSCode.\nYou are helpful."),
  )
}

///|
test "custom prefix: trailing punctuation is not doubled" {
  let body = fixture("{'messages':[{'role':'user','content':'hi'}]}")
  assert_true(
    @proxy.ensure_system_prefix_with(body, "You are a helpful assistant."),
  )
  assert_eq(
    content_of_first_message(body),
    Some("You are a helpful assistant."),
  )
  let body2 = fixture("{'messages':[{'role':'user','content':'hi'}]}")
  assert_true(@proxy.ensure_system_prefix_with(body2, "请用中文回答！"))
  assert_eq(content_of_first_message(body2), Some("请用中文回答！"))
}

///|
test "custom prefix: blank falls back to the built-in sentence" {
  let body = fixture("{'messages':[{'role':'user','content':'hi'}]}")
  assert_true(@proxy.ensure_system_prefix_with(body, "   "))
  assert_eq(
    content_of_first_message(body),
    Some(
      "You are an expert AI programming assistant, working with a user in the VS Code editor.",
    ),
  )
}

///|
/// Verify byte-level fast path produces semantically identical JSON to full DOM
/// parse + `ensure_system_prefix_with`.
fn assert_fast_rewrite_matches_dom(
  raw : String,
  prompt : String,
  expect_modified : Bool,
) -> Unit raise {
  let raw_bytes = @utf8.encode(raw)
  let dom = @json.parse(raw)
  let dom_mod = @proxy.ensure_system_prefix_with(dom, prompt)
  assert_eq(dom_mod, expect_modified)
  match @proxy.rewrite_chat_body_bytes(raw_bytes, prompt) {
    Ok(Some(out_bytes)) => {
      assert_true(expect_modified)
      let got = @json.parse(@utf8.decode(out_bytes))
      assert_eq(got, dom)
    }
    Ok(None) => assert_true(!expect_modified)
    Err(msg) => fail("unexpected rewrite error: " + msg)
  }
}

///|
test "fast rewrite: matches DOM across common, unicode, multimodal and edge cases" {
  let p = @proxy.required_prefix
  // No system message -> insert at front
  assert_fast_rewrite_matches_dom(
    "{\"model\":\"m\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}", p,
    true,
  )
  // Empty messages array -> insert single system element (no trailing comma)
  assert_fast_rewrite_matches_dom("{\"model\":\"m\",\"messages\":[]}", p, true)
  // Already has prefix -> unchanged (zero alloc)
  assert_fast_rewrite_matches_dom(
    "{\"messages\":[{\"role\":\"system\",\"content\":\"" +
    p +
    " Be concise.\"},{\"role\":\"user\",\"content\":\"hi\"}]}",
    p,
    false,
  )
  // Leading spaces before prefix -> unchanged
  assert_fast_rewrite_matches_dom(
    "{\"messages\":[{\"role\":\"system\",\"content\":\"   " + p + "\"}]}",
    p,
    false,
  )
  // Leading escaped newline before prefix -> falls back & unchanged
  assert_fast_rewrite_matches_dom(
    "{\"messages\":[{\"role\":\"system\",\"content\":\"\\n  " + p + "\"}]}",
    p,
    false,
  )
  // Existing different system text -> prepended
  assert_fast_rewrite_matches_dom(
    "{\"tools\":[{\"type\":\"function\",\"fn\":{\"name\":\"a\"}}],\"messages\":[{\"role\":\"system\",\"content\":\"Be helpful.\\\"quoted\\\"\"},{\"role\":\"user\",\"content\":\"hello\"}],\"stream\":true}",
    p, true,
  )
  // Empty system content -> becomes injected sentence
  assert_fast_rewrite_matches_dom(
    "{\"messages\":[{\"role\":\"system\",\"content\":\"\"}]}", p, true,
  )
  // Multimodal system content -> fallback matches DOM
  assert_fast_rewrite_matches_dom(
    "{\"messages\":[{\"role\":\"system\",\"content\":[{\"type\":\"text\",\"text\":\"be nice\"}]}]}",
    p, true,
  )
  // CJK custom prompt
  assert_fast_rewrite_matches_dom(
    "{\"messages\":[{\"role\":\"system\",\"content\":\"你是助手\"}]}", "你是代码审阅助手",
    true,
  )
  assert_fast_rewrite_matches_dom(
    "{\"messages\":[{\"role\":\"system\",\"content\":\"你是代码审阅助手。其他内容\"}]}",
    "你是代码审阅助手", false,
  )
  // No messages field
  assert_fast_rewrite_matches_dom("{\"model\":\"m\"}", p, false)
  // Malformed JSON -> Err
  assert_true(
    @proxy.rewrite_chat_body_bytes(@utf8.encode("{\"messages\":["), p) is Err(_),
  )
  assert_true(
    @proxy.rewrite_chat_body_bytes(
      @utf8.encode(
        "{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}], bad}",
      ),
      p,
    )
    is Err(_),
  )
}
