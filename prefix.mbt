///|
/// The required opening sentence of the system message.
pub let required_prefix : String = "你是一个AI助手，工作在 vscode 环境中"

///|
/// The sentence injected when the prefix is missing (with a full stop).
fn injected_sentence() -> String {
  required_prefix + "。"
}

///|
/// Whether `text` already opens with the required sentence
/// (leading whitespace is ignored).
fn starts_with_required(text : String) -> Bool {
  text.clamped_view().trim_start().has_prefix(required_prefix)
}

///|
/// Prepend the required sentence as the new first sentence.
fn prepend_sentence(text : String) -> String {
  if text.is_empty() {
    injected_sentence()
  } else {
    injected_sentence() + "\n" + text
  }
}

///|
/// Ensure the first `system` message of a Chat Completions request body
/// starts with `required_prefix`.
///
/// - first system message already starts with it: unchanged;
/// - otherwise the sentence is prepended to its content (plain string
///   content, or the first `text` part of multimodal content);
/// - no system message at all: one is inserted at the front of `messages`.
///
/// Returns `true` when the JSON was modified.
pub fn ensure_system_prefix(root : Json) -> Bool {
  match root {
    Object(obj) =>
      match obj.get("messages") {
        Some(Array(messages)) => ensure_in_messages(messages)
        _ => false
      }
    _ => false
  }
}

///|
fn ensure_in_messages(messages : Array[Json]) -> Bool {
  for msg in messages {
    match msg {
      Object(m) if m.get("role") is Some(String("system")) =>
        return ensure_in_content(m)
      _ => ()
    }
  }
  // No system message: insert one at the front.
  let sys : Map[String, Json] = {
    "role": Json::string("system"),
    "content": Json::string(injected_sentence()),
  }
  messages.insert(0, Json::object(sys))
  true
}

///|
fn ensure_in_content(msg : Map[String, Json]) -> Bool {
  match msg.get("content") {
    Some(String(text)) =>
      if starts_with_required(text) {
        false
      } else {
        msg.set("content", Json::string(prepend_sentence(text)))
        true
      }
    Some(Array(parts)) => {
      // Multimodal content: check the first `text` part.
      for part in parts {
        match part {
          Object(p) if p.get("type") is Some(String("text")) =>
            match p.get("text") {
              Some(String(text)) =>
                if starts_with_required(text) {
                  return false
                } else {
                  p.set("text", Json::string(prepend_sentence(text)))
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
        "text": Json::string(injected_sentence()),
      }
      parts.insert(0, Json::object(p))
      true
    }
    _ => {
      // Missing or unusual content: replace with the plain sentence.
      msg.set("content", Json::string(injected_sentence()))
      true
    }
  }
}
