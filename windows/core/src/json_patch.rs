//! Edits top-level keys of a JSON object in place, leaving every other byte of the file untouched
//! (key order, number formatting, escaping). Every patch is checked by parsing the result again.
use crate::util::{err, Error, Result};
use serde_json::{Map, Value};

struct Member {
    key: String,
    value: std::ops::Range<usize>,
}

fn members(b: &[u8]) -> Result<(Vec<Member>, usize)> {
    let mut i = 0usize;
    let fail = |what: &str, i: usize| Error(format!("JSON patch: {what} at byte {i}"));
    fn ws(b: &[u8], i: &mut usize) {
        while *i < b.len() && matches!(b[*i], b' ' | b'\n' | b'\r' | b'\t') {
            *i += 1;
        }
    }
    fn skip_string(b: &[u8], i: &mut usize) -> bool {
        if *i >= b.len() || b[*i] != b'"' {
            return false;
        }
        *i += 1;
        while *i < b.len() {
            match b[*i] {
                b'\\' => *i += 2,
                b'"' => {
                    *i += 1;
                    return true;
                }
                _ => *i += 1,
            }
        }
        false
    }
    fn skip_value(b: &[u8], i: &mut usize) -> bool {
        if *i >= b.len() {
            return false;
        }
        match b[*i] {
            b'"' => skip_string(b, i),
            b'{' | b'[' => {
                let mut depth = 0i32;
                while *i < b.len() {
                    let c = b[*i];
                    if c == b'"' {
                        if !skip_string(b, i) {
                            return false;
                        }
                        continue;
                    }
                    if c == b'{' || c == b'[' {
                        depth += 1;
                    }
                    if c == b'}' || c == b']' {
                        depth -= 1;
                        if depth == 0 {
                            *i += 1;
                            return true;
                        }
                    }
                    *i += 1;
                }
                false
            }
            _ => {
                while *i < b.len() && !matches!(b[*i], b',' | b'}' | b']' | b' ' | b'\n' | b'\r' | b'\t') {
                    *i += 1;
                }
                true
            }
        }
    }

    ws(b, &mut i);
    if i >= b.len() || b[i] != b'{' {
        return Err(fail("expected {", i));
    }
    i += 1;
    let mut out = Vec::new();
    loop {
        ws(b, &mut i);
        if i >= b.len() {
            return Err(fail("unexpected end", i));
        }
        if b[i] == b'}' {
            return Ok((out, i));
        }
        let key_start = i;
        if !skip_string(b, &mut i) {
            return Err(fail("expected string", i));
        }
        let key: String = serde_json::from_slice(&b[key_start..i]).map_err(|_| fail("bad key", i))?;
        ws(b, &mut i);
        if i >= b.len() || b[i] != b':' {
            return Err(fail("expected :", i));
        }
        i += 1;
        ws(b, &mut i);
        let v_start = i;
        if !skip_value(b, &mut i) {
            return Err(fail("bad value", i));
        }
        out.push(Member { key, value: v_start..i });
        ws(b, &mut i);
        if i >= b.len() {
            return Err(fail("unexpected end", i));
        }
        match b[i] {
            b',' => i += 1,
            b'}' => return Ok((out, i)),
            _ => return Err(fail("expected , or }", i)),
        }
    }
}

fn object(data: &[u8]) -> Result<Map<String, Value>> {
    match serde_json::from_slice::<Value>(data) {
        Ok(Value::Object(m)) => Ok(m),
        _ => err("JSON patch: not a JSON object"),
    }
}

/// Set top-level keys to new values. Existing keys keep their place; new keys go at the end.
pub fn patch(data: &[u8], changes: &[(&str, Value)]) -> Result<Vec<u8>> {
    let mut bytes = data.to_vec();
    for (key, value) in changes {
        let value_bytes = serde_json::to_vec(value)?;
        let (list, close) = members(&bytes)?;
        if let Some(m) = list.iter().find(|m| m.key == *key) {
            bytes.splice(m.value.clone(), value_bytes);
        } else {
            let mut insert = Vec::new();
            if !list.is_empty() {
                insert.push(b',');
            }
            insert.extend(serde_json::to_vec(&Value::String(key.to_string()))?);
            insert.push(b':');
            insert.extend(value_bytes);
            bytes.splice(close..close, insert);
        }
    }
    let mut expected = object(data)?;
    for (k, v) in changes {
        expected.insert(k.to_string(), v.clone());
    }
    if object(&bytes)? != expected {
        return err("JSON patch verification failed");
    }
    Ok(bytes)
}

/// Remove top-level keys (and the comma that separated them), leaving every other byte untouched.
pub fn remove(data: &[u8], keys: &[&str]) -> Result<Vec<u8>> {
    let mut bytes = data.to_vec();
    for key in keys {
        let (list, _) = members(&bytes)?;
        let Some(idx) = list.iter().position(|m| m.key == *key) else { continue };
        // The member starts at its key: walk back from the value to the key's opening quote.
        let mut start = list[idx].value.start;
        let mut quotes = 0;
        while start > 0 {
            start -= 1;
            if bytes[start] == b'"' && (start == 0 || bytes[start - 1] != b'\\') {
                quotes += 1;
                if quotes == 2 {
                    break;
                }
            }
        }
        let mut end = list[idx].value.end;
        if idx < list.len() - 1 {
            while end < bytes.len() && bytes[end] != b',' {
                end += 1;
            }
            end += 1;
        } else if idx > 0 {
            while start > 0 && bytes[start - 1] != b',' {
                start -= 1;
            }
            start -= 1;
        }
        bytes.drain(start..end);
    }
    let mut expected = object(data)?;
    for k in keys {
        expected.remove(*k);
    }
    if object(&bytes)? != expected {
        return err("JSON remove verification failed");
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const ORIGINAL: &str = r#"{"sessionId":"local_p1","cliSessionId":"c-p1","cwd":"/tmp/project","isArchived":true,"title":"Old","isStarred":false,"spawnedFrom":{"title":"nested title must not change"},"cost":0.30594340000000001}"#;

    #[test]
    fn patch_sets_top_level_only() {
        let out = patch(ORIGINAL.as_bytes(), &[("title", json!("New \"quoted\" / text")), ("titleSource", json!("user"))]).unwrap();
        let v: Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["title"], "New \"quoted\" / text");
        assert_eq!(v["spawnedFrom"]["title"], "nested title must not change");
        assert!(String::from_utf8(out).unwrap().contains("0.30594340000000001"), "number formatting kept");
    }

    #[test]
    fn noop_patch_keeps_bytes() {
        assert_eq!(patch(ORIGINAL.as_bytes(), &[("isArchived", json!(true))]).unwrap(), ORIGINAL.as_bytes());
        assert_eq!(patch(ORIGINAL.as_bytes(), &[("isArchived", json!(false))]).unwrap().len(), ORIGINAL.len() + 1);
    }

    #[test]
    fn remove_first_middle_last() {
        let j = br#"{"a":1,"b":"x","c":[1,2],"d":{"e":1}}"#;
        assert_eq!(remove(j, &["b"]).unwrap(), br#"{"a":1,"c":[1,2],"d":{"e":1}}"#);
        assert_eq!(remove(j, &["d"]).unwrap(), br#"{"a":1,"b":"x","c":[1,2]}"#);
        assert_eq!(remove(j, &["a"]).unwrap(), br#"{"b":"x","c":[1,2],"d":{"e":1}}"#);
    }
}
