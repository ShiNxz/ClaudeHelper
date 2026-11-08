//! Read-only checks Relay runs before it writes anything.
use crate::util::Result;
use serde_json::Value;
use std::path::Path;

/// Problems with a parsed sidebar file. Empty means it is safe to edit.
pub fn session_problems(v: &Value, file: &Path) -> Vec<String> {
    let Some(d) = v.as_object() else { return vec!["not a JSON object".into()] };
    let mut out = Vec::new();
    let stem = file.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
    match d.get("sessionId") {
        Some(Value::String(s)) if !s.is_empty() => {
            if *s != stem {
                out.push(format!("sessionId \"{s}\" does not match the file name"));
            }
        }
        None => out.push("missing sessionId".into()),
        _ => out.push("sessionId is not a string".into()),
    }
    match d.get("cliSessionId") {
        Some(Value::String(s)) if !s.is_empty() => {}
        None => out.push("missing cliSessionId".into()),
        _ => out.push("cliSessionId is not a string".into()),
    }
    for key in ["isArchived", "isStarred"] {
        if let Some(v) = d.get(key) {
            if !v.is_boolean() {
                out.push(format!("{key} is not true/false"));
            }
        }
    }
    if let Some(t) = d.get("title") {
        if !t.is_string() {
            out.push("title is not a string".into());
        }
    }
    out
}

/// Parse `archived-sessions.idx`. Only `{"v":1,"archived":["local_...", ...]}` is accepted.
pub fn parse_archived_index(data: &[u8]) -> (Option<Vec<String>>, Option<String>) {
    let Ok(v) = serde_json::from_slice::<Value>(data) else { return (None, Some("not valid JSON".into())) };
    let Some(d) = v.as_object() else { return (None, Some("not a JSON object".into())) };
    let mut keys: Vec<&String> = d.keys().collect();
    keys.sort();
    if keys != ["archived", "v"] {
        let names: Vec<String> = keys.iter().map(|k| k.to_string()).collect();
        return (None, Some(format!("expected exactly the keys v and archived, found: {}", names.join(", "))));
    }
    match &d["v"] {
        Value::Number(n) if n.as_u64() == Some(1) => {}
        other => return (None, Some(format!("v is {other}, expected 1"))),
    }
    let Some(arr) = d["archived"].as_array() else { return (None, Some("archived is not an array".into())) };
    let mut ids = Vec::new();
    for item in arr {
        match item.as_str() {
            Some(s) => ids.push(s.to_string()),
            None => return (None, Some("archived contains a non-string entry".into())),
        }
    }
    (Some(ids), None)
}

/// The compact form Claude writes: sorted, no duplicates, no newline.
pub fn encode_archived_index(ids: &[String]) -> Result<Vec<u8>> {
    let mut list: Vec<&String> = ids.iter().collect();
    list.sort();
    list.dedup();
    Ok(format!("{{\"v\":1,\"archived\":{}}}", serde_json::to_string(&list)?).into_bytes())
}

/// The only file names Relay ever writes, moves or backs up inside a session folder.
pub fn is_managed_name(name: &str) -> bool {
    if name.contains('/') || name.contains('\\') {
        return false;
    }
    name == "archived-sessions.idx" || name.starts_with("deleted_") || (name.starts_with("local_") && name.ends_with(".json"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn archived_index_rules() {
        assert_eq!(parse_archived_index(br#"{"v":1,"archived":["local_a"]}"#).0, Some(vec!["local_a".to_string()]));
        assert!(parse_archived_index(br#"{"v":2,"archived":[]}"#).1.is_some());
        assert!(parse_archived_index(br#"{"v":1,"archived":[],"x":1}"#).1.is_some());
        let ids = vec!["local_b".to_string(), "local_a".to_string(), "local_b".to_string()];
        assert_eq!(encode_archived_index(&ids).unwrap(), br#"{"v":1,"archived":["local_a","local_b"]}"#);
    }
}
