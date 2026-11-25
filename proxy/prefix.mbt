///|
/// The built-in required opening sentence of the system message.
///
/// This is only the **default**: the actual sentence comes from the config
/// (`SYSTEM_PROMPT` in `.env` / the environment, or `--system-prompt`), see
/// `@config.Config::system_prompt`.
pub let required_prefix : String = @config.default_system_prompt

///|
/// Normalize a configured prompt: trim surrounding whitespace, fall back to
/// the built-in sentence when it is blank.
fn normalize_prefix(prompt : String) -> String {
  let v = prompt.clamped_view().trim()
  if v.is_empty() {
    required_prefix
  } else {
    v.to_owned()
  }
}

///|
/// Whether `c` already terminates a sentence, in which case no extra `。`
/// is appended to the injected sentence.
fn is_terminator(c : Char) -> Bool {
  match c {
    '。'
    | '．'
    | '！'
    | '？'
    | '；'
    | '：'
    | '…'
    | '.'
    | '!'
    | '?'
    | ';'
    | ':' => true
    _ => false
  }
}

///|
/// The sentence injected when the prefix is missing: `prefix`, with a full
/// stop appended unless it already ends with sentence punctuation. The stop
/// follows the sentence's script (`.` after ASCII text, `。` after CJK).
fn injected_sentence(prefix : String) -> String {
  match prefix.rev_iter().next() {
    Some(c) if is_terminator(c) => prefix
    Some(c) if c.to_int() < 128 => prefix + "."
    _ => prefix + "。"
  }
}

///|
/// Whether `text` already opens with `prefix` (leading whitespace is ignored).
fn starts_with_prefix(text : String, prefix : String) -> Bool {
  text.clamped_view().trim_start().has_prefix(prefix)
}

///|
/// Precomputed prompt metadata (cached across requests since `Config::system_prompt`
/// is immutable after startup).
priv struct PromptSpec {
  raw : String
  prefix : String
  prefix_utf8 : Bytes
  injected : String
  /// JSON-escaped content of `injected` without surrounding quotes.
  injected_json_inner : Bytes
  /// Pre-serialized `{"role":"system","content":"<injected>"}` UTF-8 bytes.
  system_msg_json : Bytes
}

///|
let cached_prompt_spec : Ref[PromptSpec?] = Ref(None)

///|
fn get_prompt_spec(raw : String) -> PromptSpec {
  match cached_prompt_spec.val {
    Some(spec) if spec.raw == raw => spec
    _ => {
      let prefix = normalize_prefix(raw)
      let injected = injected_sentence(prefix)
      let quoted = Json::string(injected).stringify()
      let injected_json_inner = @utf8.encode(
        quoted.clamped_view(start=1, end=quoted.length() - 1),
      )
      let system_msg_json = @utf8.encode(
        "{\"role\":\"system\",\"content\":" + quoted + "}",
      )
      let spec : PromptSpec = {
        raw,
        prefix,
        prefix_utf8: @utf8.encode(prefix),
        injected,
        injected_json_inner,
        system_msg_json,
      }
      cached_prompt_spec.val = Some(spec)
      spec
    }
  }
}

///|
/// Ensure the first `system` message of a Chat Completions request body
/// starts with the built-in `required_prefix`.
///
/// Prefer `ensure_system_prefix_with` with the configured prompt; this wrapper
/// keeps the historical API (and the historical default sentence) stable.
pub fn ensure_system_prefix(root : Json) -> Bool {
  ensure_system_prefix_with(root, required_prefix)
}

///|
/// Ensure the first `system` message of a Chat Completions request body
/// starts with `prompt` (typically `@config.Config::system_prompt`).
///
/// - first system message already starts with it: unchanged;
/// - otherwise the sentence is prepended to its content (plain string
///   content, or the first `text` part of multimodal content);
/// - no system message at all: one is inserted at the front of `messages`.
/// - a blank `prompt` falls back to `required_prefix`.
///
/// Returns `true` when the JSON was modified.
pub fn ensure_system_prefix_with(root : Json, prompt : String) -> Bool {
  let spec = get_prompt_spec(prompt)
  match root {
    Object(obj) =>
      match obj.get("messages") {
        Some(Array(messages)) => ensure_in_messages(messages, spec)
        _ => false
      }
    _ => false
  }
}

///|
fn ensure_in_messages(messages : Array[Json], spec : PromptSpec) -> Bool {
  for msg in messages {
    match msg {
      Object(m) if m.get("role") is Some(String("system")) =>
        return ensure_in_content(m, spec)
      _ => ()
    }
  }
  // No system message: insert one at the front.
  let sys : Map[String, Json] = {
    "role": Json::string("system"),
    "content": Json::string(spec.injected),
  }
  messages.insert(0, Json::object(sys))
  true
}

///|
fn ensure_in_content(msg : Map[String, Json], spec : PromptSpec) -> Bool {
  match msg.get("content") {
    Some(String(text)) =>
      if starts_with_prefix(text, spec.prefix) {
        false
      } else {
        let next = if text.is_empty() {
          spec.injected
        } else {
          spec.injected + "\n" + text
        }
        msg.set("content", Json::string(next))
        true
      }
    Some(Array(parts)) => {
      // Multimodal content: check the first `text` part.
      for part in parts {
        match part {
          Object(p) if p.get("type") is Some(String("text")) =>
            match p.get("text") {
              Some(String(text)) =>
                if starts_with_prefix(text, spec.prefix) {
                  return false
                } else {
                  let next = if text.is_empty() {
                    spec.injected
                  } else {
                    spec.injected + "\n" + text
                  }
                  p.set("text", Json::string(next))
                  return true
                }
              _ => ()
            }
          _ => ()
        }
      }
      // No text part at all: insert one at the front.
      let p : Map[String, Json] = {
        "type": Json::string("text"),
        "text": Json::string(spec.injected),
      }
      parts.insert(0, Json::object(p))
      true
    }
    _ => {
      // Missing or unusual content: replace with the plain sentence.
      msg.set("content", Json::string(spec.injected))
      true
    }
  }
}

///|
priv enum FastRewrite {
  Unchanged
  Rewritten(Bytes)
  Fallback
}

///|
priv enum FastAction {
  NoAction
  AlreadyOk
  InsertSystem(Int32, Bool)
  PrependContent(Int32, Bool)
}

///|
fn is_json_ws(c : Byte) -> Bool {
  c == b' ' || c == b'\t' || c == b'\r' || c == b'\n'
}

///|
fn skip_json_ws(b : Bytes, pos : Int32, len : Int32) -> Int32 {
  let mut i = pos
  while i < len && is_json_ws(b[i]) {
    i += 1
  }
  i
}

///|
fn is_hex_byte(c : Byte) -> Bool {
  (c >= b'0' && c <= b'9') ||
  (c >= b'a' && c <= b'f') ||
  (c >= b'A' && c <= b'F')
}

///|
/// Scan a JSON string starting at opening `"` (`pos`). Returns index right
/// after the closing `"`, or `None` on invalid syntax / unterminated string.
fn scan_json_string(b : Bytes, pos : Int32, len : Int32) -> Int32? {
  if pos >= len || b[pos] != b'"' {
    return None
  }
  let mut i = pos + 1
  while i < len {
    let c = b[i]
    if c == b'"' {
      return Some(i + 1)
    }
    if c == b'\\' {
      if i + 1 >= len {
        return None
      }
      let esc = b[i + 1]
      if esc == b'"' ||
        esc == b'\\' ||
        esc == b'/' ||
        esc == b'b' ||
        esc == b'f' ||
        esc == b'n' ||
        esc == b'r' ||
        esc == b't' {
        i += 2
      } else if esc == b'u' {
        if i + 6 > len ||
          !is_hex_byte(b[i + 2]) ||
          !is_hex_byte(b[i + 3]) ||
          !is_hex_byte(b[i + 4]) ||
          !is_hex_byte(b[i + 5]) {
          return None
        }
        i += 6
      } else {
        return None
      }
    } else if c < b'\x20' {
      return None
    } else {
      i += 1
    }
  }
  None
}

///|
fn bytes_match_at(b : Bytes, offset : Int32, pat : Bytes) -> Bool {
  let plen = pat.length()
  if offset + plen > b.length() {
    return false
  }
  let mut i = 0
  while i < plen {
    if b[offset + i] != pat[i] {
      return false
    }
    i += 1
  }
  true
}

///|
fn json_string_eq_ascii(
  b : Bytes,
  start : Int32,
  end : Int32,
  pat : Bytes,
) -> Bool {
  end - start - 2 == pat.length() && bytes_match_at(b, start + 1, pat)
}

///|
fn json_string_has_backslash(b : Bytes, start : Int32, end : Int32) -> Bool {
  let mut i = start + 1
  let stop = end - 1
  while i < stop {
    if b[i] == b'\\' {
      return true
    }
    i += 1
  }
  false
}

///|
fn scan_json_number(b : Bytes, pos : Int32, len : Int32) -> Int32? {
  let mut i = pos
  if i < len && b[i] == b'-' {
    i += 1
  }
  if i >= len {
    return None
  }
  if b[i] == b'0' {
    i += 1
  } else if b[i] >= b'1' && b[i] <= b'9' {
    i += 1
    while i < len && b[i] >= b'0' && b[i] <= b'9' {
      i += 1
    }
  } else {
    return None
  }
  if i < len && b[i] == b'.' {
    i += 1
    if i >= len || b[i] < b'0' || b[i] > b'9' {
      return None
    }
    while i < len && b[i] >= b'0' && b[i] <= b'9' {
      i += 1
    }
  }
  if i < len && (b[i] == b'e' || b[i] == b'E') {
    i += 1
    if i < len && (b[i] == b'+' || b[i] == b'-') {
      i += 1
    }
    if i >= len || b[i] < b'0' || b[i] > b'9' {
      return None
    }
    while i < len && b[i] >= b'0' && b[i] <= b'9' {
      i += 1
    }
  }
  Some(i)
}

///|
/// Validate and skip one JSON value at raw UTF-8 byte level with zero heap
/// allocations. Returns `None` on syntax error or excessive nesting so callers
/// fall back to `@json.parse`.
fn skip_json_value(
  b : Bytes,
  pos : Int32,
  len : Int32,
  depth : Int32,
) -> Int32? {
  if depth > 64 {
    return None
  }
  let mut i = skip_json_ws(b, pos, len)
  if i >= len {
    return None
  }
  let c = b[i]
  if c == b'"' {
    scan_json_string(b, i, len)
  } else if c == b'{' {
    i = skip_json_ws(b, i + 1, len)
    if i >= len {
      return None
    }
    if b[i] == b'}' {
      return Some(i + 1)
    }
    for ;; {
      match scan_json_string(b, i, len) {
        Some(ke) => i = skip_json_ws(b, ke, len)
        None => return None
      }
      if i >= len || b[i] != b':' {
        return None
      }
      match skip_json_value(b, i + 1, len, depth + 1) {
        Some(ve) => i = skip_json_ws(b, ve, len)
        None => return None
      }
      if i >= len {
        return None
      }
      if b[i] == b',' {
        i = skip_json_ws(b, i + 1, len)
      } else if b[i] == b'}' {
        return Some(i + 1)
      } else {
        return None
      }
    }
  } else if c == b'[' {
    i = skip_json_ws(b, i + 1, len)
    if i >= len {
      return None
    }
    if b[i] == b']' {
      return Some(i + 1)
    }
    for ;; {
      match skip_json_value(b, i, len, depth + 1) {
        Some(ve) => i = skip_json_ws(b, ve, len)
        None => return None
      }
      if i >= len {
        return None
      }
      if b[i] == b',' {
        i = skip_json_ws(b, i + 1, len)
      } else if b[i] == b']' {
        return Some(i + 1)
      } else {
        return None
      }
    }
  } else if c == b't' {
    if bytes_match_at(b, i, b"true") {
      Some(i + 4)
    } else {
      None
    }
  } else if c == b'f' {
    if bytes_match_at(b, i, b"false") {
      Some(i + 5)
    } else {
      None
    }
  } else if c == b'n' {
    if bytes_match_at(b, i, b"null") {
      Some(i + 4)
    } else {
      None
    }
  } else if c == b'-' || (c >= b'0' && c <= b'9') {
    scan_json_number(b, i, len)
  } else {
    None
  }
}

///|
/// Inspect one object element inside `messages` to check whether it has
/// `"role":"system"` and locate its plain-string `"content"` span.
/// Returns `(next_pos, found_system, action)` or `None` to trigger fallback.
fn inspect_message_object(
  b : Bytes,
  pos : Int32,
  len : Int32,
  spec : PromptSpec,
) -> (Int32, Bool, FastAction)? {
  let mut i = skip_json_ws(b, pos + 1, len)
  if i >= len {
    return None
  }
  if b[i] == b'}' {
    return Some((i + 1, false, NoAction))
  }
  let mut is_system = false
  let mut has_role = false
  let mut has_content = false
  let mut content_is_string = false
  let mut content_start : Int32 = 0
  let mut content_end : Int32 = 0
  for ;; {
    let ks = i
    let ke = match scan_json_string(b, ks, len) {
      Some(e) => e
      None => return None
    }
    i = skip_json_ws(b, ke, len)
    if i >= len || b[i] != b':' {
      return None
    }
    let vs = skip_json_ws(b, i + 1, len)
    if vs >= len {
      return None
    }
    // Escaped key names like "\u0072ole" are rare; bail to fallback.
    if json_string_has_backslash(b, ks, ke) {
      return None
    }
    let ve = if json_string_eq_ascii(b, ks, ke, b"role") {
      if has_role {
        return None
      }
      has_role = true
      if b[vs] == b'"' {
        match scan_json_string(b, vs, len) {
          Some(e) => {
            if json_string_has_backslash(b, vs, e) {
              return None
            }
            if json_string_eq_ascii(b, vs, e, b"system") {
              is_system = true
            }
            e
          }
          None => return None
        }
      } else {
        match skip_json_value(b, vs, len, 3) {
          Some(e) => e
          None => return None
        }
      }
    } else if json_string_eq_ascii(b, ks, ke, b"content") {
      if has_content {
        return None
      }
      has_content = true
      if b[vs] == b'"' {
        match scan_json_string(b, vs, len) {
          Some(e) => {
            content_is_string = true
            content_start = vs
            content_end = e
            e
          }
          None => return None
        }
      } else {
        match skip_json_value(b, vs, len, 3) {
          Some(e) => e
          None => return None
        }
      }
    } else {
      match skip_json_value(b, vs, len, 3) {
        Some(e) => e
        None => return None
      }
    }
    i = skip_json_ws(b, ve, len)
    if i >= len {
      return None
    }
    if b[i] == b',' {
      i = skip_json_ws(b, i + 1, len)
    } else if b[i] == b'}' {
      let end_pos = i + 1
      if !is_system {
        return Some((end_pos, false, NoAction))
      }
      if !has_content || !content_is_string {
        // Missing/null/multimodal content: let standard JSON path handle it.
        return None
      }
      // Plain string content: check leading whitespace + prefix directly in UTF-8.
      let inner_start = content_start + 1
      let inner_end = content_end - 1
      let mut p = inner_start
      while p < inner_end && b[p] == b' ' {
        p += 1
      }
      if p < inner_end && (b[p] == b'\\' || b[p] >= b'\xC0') {
        // Escaped whitespace (`\t`/`\n`/`\u...`) or non-ASCII lead byte:
        // check whether it could be Unicode whitespace or escaped prefix.
        if b[p] == b'\\' {
          return None
        }
        // Non-ASCII byte: only safe to skip fallback if prefix itself starts
        // with the exact same byte (so it can't be Unicode whitespace before
        // the prefix unless the prefix starts with that byte, in which case
        // either it matches or needs prepending — except NBSP etc.).
        // Only fall back when the byte could be Unicode whitespace (0xC2, 0xE1, 0xE2, 0xE3).
        let lead = b[p]
        if lead == b'\xC2' ||
          lead == b'\xE1' ||
          lead == b'\xE2' ||
          lead == b'\xE3' {
          return None
        }
      }
      let plen = spec.prefix_utf8.length()
      let check_end = if p + plen < inner_end { p + plen } else { inner_end }
      let mut k = p
      while k < check_end {
        if b[k] == b'\\' {
          return None
        }
        k += 1
      }
      if p + plen <= inner_end && bytes_match_at(b, p, spec.prefix_utf8) {
        return Some((end_pos, true, AlreadyOk))
      }
      let is_empty = inner_start == inner_end
      return Some((end_pos, true, PrependContent(inner_start, is_empty)))
    } else {
      return None
    }
  }
}

///|
fn splice_insert_system(
  body : Bytes,
  insert_pos : Int32,
  has_elems : Bool,
  spec : PromptSpec,
) -> Bytes {
  let len = body.length()
  let msg = spec.system_msg_json
  let mlen = msg.length()
  let extra = mlen + (if has_elems { 1 } else { 0 })
  let out = FixedArray::make(len + extra, b'\x00')
  out.blit_from_bytes(0, body, 0, insert_pos)
  out.blit_from_bytes(insert_pos, msg, 0, mlen)
  if has_elems {
    out[insert_pos + mlen] = b','
  }
  out.blit_from_bytes(insert_pos + extra, body, insert_pos, len - insert_pos)
  out.unsafe_reinterpret_as_bytes()
}

///|
fn splice_prepend_content(
  body : Bytes,
  insert_pos : Int32,
  is_empty : Bool,
  spec : PromptSpec,
) -> Bytes {
  let len = body.length()
  let ins = spec.injected_json_inner
  let ilen = ins.length()
  let extra = ilen + (if is_empty { 0 } else { 2 })
  let out = FixedArray::make(len + extra, b'\x00')
  out.blit_from_bytes(0, body, 0, insert_pos)
  out.blit_from_bytes(insert_pos, ins, 0, ilen)
  if !is_empty {
    out[insert_pos + ilen] = b'\\'
    out[insert_pos + ilen + 1] = b'n'
  }
  out.blit_from_bytes(insert_pos + extra, body, insert_pos, len - insert_pos)
  out.unsafe_reinterpret_as_bytes()
}

///|
fn try_rewrite_chat_bytes(body : Bytes, spec : PromptSpec) -> FastRewrite {
  let len = body.length()
  let mut i = skip_json_ws(body, 0, len)
  if i >= len || body[i] != b'{' {
    return Fallback
  }
  i = skip_json_ws(body, i + 1, len)
  if i >= len {
    return Fallback
  }
  if body[i] == b'}' {
    let tail = skip_json_ws(body, i + 1, len)
    return if tail == len { Unchanged } else { Fallback }
  }
  let mut seen_messages = false
  let mut action : FastAction = NoAction
  for ;; {
    let ks = i
    let ke = match scan_json_string(body, ks, len) {
      Some(e) => e
      None => return Fallback
    }
    if json_string_has_backslash(body, ks, ke) {
      return Fallback
    }
    i = skip_json_ws(body, ke, len)
    if i >= len || body[i] != b':' {
      return Fallback
    }
    let vs = skip_json_ws(body, i + 1, len)
    if vs >= len {
      return Fallback
    }
    let ve = if json_string_eq_ascii(body, ks, ke, b"messages") {
      if seen_messages {
        return Fallback
      }
      seen_messages = true
      if body[vs] != b'[' {
        match skip_json_value(body, vs, len, 1) {
          Some(e) => e
          None => return Fallback
        }
      } else {
        let arr_after_open = vs + 1
        let mut p = skip_json_ws(body, arr_after_open, len)
        if p >= len {
          return Fallback
        }
        if body[p] == b']' {
          action = InsertSystem(arr_after_open, false)
          p + 1
        } else {
          let mut found_system = false
          let mut arr_end : Int32 = 0
          for ;; {
            let next_p = if !found_system && body[p] == b'{' {
              match inspect_message_object(body, p, len, spec) {
                Some((e, is_sys, act)) => {
                  if is_sys {
                    found_system = true
                    action = act
                  }
                  e
                }
                None => return Fallback
              }
            } else {
              match skip_json_value(body, p, len, 2) {
                Some(e) => e
                None => return Fallback
              }
            }
            p = skip_json_ws(body, next_p, len)
            if p >= len {
              return Fallback
            }
            if body[p] == b',' {
              p = skip_json_ws(body, p + 1, len)
            } else if body[p] == b']' {
              arr_end = p + 1
              break
            } else {
              return Fallback
            }
          }
          if !found_system {
            action = InsertSystem(arr_after_open, true)
          }
          arr_end
        }
      }
    } else {
      match skip_json_value(body, vs, len, 1) {
        Some(e) => e
        None => return Fallback
      }
    }
    i = skip_json_ws(body, ve, len)
    if i >= len {
      return Fallback
    }
    if body[i] == b',' {
      i = skip_json_ws(body, i + 1, len)
    } else if body[i] == b'}' {
      let tail = skip_json_ws(body, i + 1, len)
      if tail != len {
        return Fallback
      }
      break
    } else {
      return Fallback
    }
  }
  match action {
    NoAction | AlreadyOk => Unchanged
    InsertSystem(pos, has_elems) =>
      Rewritten(splice_insert_system(body, pos, has_elems, spec))
    PrependContent(pos, is_empty) =>
      Rewritten(splice_prepend_content(body, pos, is_empty, spec))
  }
}

///|
/// Rewrite a raw UTF-8 Chat Completions JSON body so its first `system` message
/// opens with `prompt`. Uses a zero-DOM byte-level surgical splice fast path
/// (5-20x faster on large LLM conversation bodies) and seamlessly falls back
/// to full `@json.parse` + `ensure_system_prefix_with` for multimodal content,
/// escaped prefixes, or invalid JSON.
///
/// Returns `Ok(Some(new_bytes))` when modified, `Ok(None)` when unchanged, or
/// `Err(msg)` when the body is not valid JSON.
pub fn rewrite_chat_body_bytes(
  body : Bytes,
  prompt : String,
) -> Result[Bytes?, String] {
  let spec = get_prompt_spec(prompt)
  match try_rewrite_chat_bytes(body, spec) {
    Unchanged => Ok(None)
    Rewritten(out) => Ok(Some(out))
    Fallback =>
      try {
        let json = @json.parse(@utf8.decode(body))
        if ensure_system_prefix_with(json, prompt) {
          Ok(Some(@utf8.encode(json.stringify())))
        } else {
          Ok(None)
        }
      } catch {
        e => Err(e.to_string())
      }
  }
}
