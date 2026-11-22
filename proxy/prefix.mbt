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
/// Prepend the required sentence as the new first sentence.
fn prepend_sentence(text : String, prefix : String) -> String {
  if text.is_empty() {
    injected_sentence(prefix)
  } else {
    injected_sentence(prefix) + "\n" + text
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
  let prefix = normalize_prefix(prompt)
  match root {
    Object(obj) =>
      match obj.get("messages") {
        Some(Array(messages)) => ensure_in_messages(messages, prefix)
        _ => false
      }
    _ => false
  }
}

///|
fn ensure_in_messages(messages : Array[Json], prefix : String) -> Bool {
  for msg in messages {
    match msg {
      Object(m) if m.get("role") is Some(String("system")) =>
        return ensure_in_content(m, prefix)
      _ => ()
    }
  }
  // No system message: insert one at the front.
  let sys : Map[String, Json] = {
    "role": Json::string("system"),
    "content": Json::string(injected_sentence(prefix)),
  }
  messages.insert(0, Json::object(sys))
  true
}

///|
fn ensure_in_content(msg : Map[String, Json], prefix : String) -> Bool {
  match msg.get("content") {
    Some(String(text)) =>
      if starts_with_prefix(text, prefix) {
        false
      } else {
        msg.set("content", Json::string(prepend_sentence(text, prefix)))
        true
      }
    Some(Array(parts)) => {
      // Multimodal content: check the first `text` part.
      for part in parts {
        match part {
          Object(p) if p.get("type") is Some(String("text")) =>
            match p.get("text") {
              Some(String(text)) =>
                if starts_with_prefix(text, prefix) {
                  return false
                } else {
                  p.set("text", Json::string(prepend_sentence(text, prefix)))
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
        "text": Json::string(injected_sentence(prefix)),
      }
      parts.insert(0, Json::object(p))
      true
    }
    _ => {
      // Missing or unusual content: replace with the plain sentence.
      msg.set("content", Json::string(injected_sentence(prefix)))
      true
    }
  }
}
