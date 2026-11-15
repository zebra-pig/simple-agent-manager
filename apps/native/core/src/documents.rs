//! Library cards use the same durable tool metadata as the web transcript.
use crate::timeline::Row;
use serde_json::Value;
use std::collections::HashMap;

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ChatDocument {
    pub file_id: String,
    pub filename: String,
    pub mime_type: String,
    pub size_bytes: Option<u64>,
    pub caption: String,
    pub unavailable: bool,
}

fn payload(v: &Value) -> Option<Value> {
    match v {
        Value::String(s) => serde_json::from_str(s).ok(),
        Value::Array(blocks) => {
            blocks.iter().find_map(|b| b.get("text").and_then(Value::as_str).and_then(|s| serde_json::from_str(s).ok()))
        }
        Value::Object(o) if o.contains_key("content") => payload(&v["content"]),
        Value::Object(_) => Some(v.clone()),
        _ => None,
    }
}
fn text(v: &Value, key: &str) -> String {
    v[key].as_str().unwrap_or_default().to_owned()
}

pub(crate) fn resolve(rows: &mut Vec<Row>) {
    let mut calls: HashMap<String, (usize, Value)> = HashMap::new();
    let mut remove = Vec::new();
    for i in 0..rows.len() {
        if rows[i].role != "tool" {
            continue;
        }
        let Some(mut meta) = rows[i].tool_metadata.clone() else {
            continue;
        };
        let call = text(&meta, "toolCallId");
        let target = if let Some((index, previous)) = calls.get(&call).filter(|_| !call.is_empty()) {
            let mut merged = previous.clone();
            if let (Some(old), Some(new)) = (merged.as_object_mut(), meta.as_object()) {
                for (k, v) in new {
                    if !v.is_null() && v.as_str() != Some("") {
                        old.insert(k.clone(), v.clone());
                    }
                }
            }
            meta = merged;
            *index
        } else {
            i
        };
        if !call.is_empty() {
            calls.insert(call, (target, meta.clone()));
        }
        let name = meta["toolName"].as_str().filter(|s| !s.is_empty()).or_else(|| meta["title"].as_str()).unwrap_or_default();
        let name = name.split("__").flat_map(|s| s.split(['/', '.', ':'])).filter(|s| !s.is_empty()).last().unwrap_or_default();
        if !matches!(name, "display_from_library" | "upload_to_library" | "replace_library_file") {
            continue;
        }
        let input = &meta["rawInput"];
        let output = payload(&meta["rawOutput"])
            .or_else(|| serde_json::from_str::<Value>(&rows[i].content).ok().and_then(|v| payload(&v)))
            .unwrap_or(Value::Null);
        let source = output.get("existingFile").unwrap_or(&output);
        let file_id =
            source["id"].as_str().or_else(|| source["fileId"].as_str()).or_else(|| input["fileId"].as_str()).unwrap_or_default().to_owned();
        let filename = source["filename"]
            .as_str()
            .or_else(|| input["filePath"].as_str().and_then(|p| p.rsplit('/').next()))
            .unwrap_or_default()
            .to_owned();
        rows[target].document = Some(ChatDocument {
            file_id,
            filename,
            mime_type: text(source, "mimeType"),
            size_bytes: source["sizeBytes"].as_u64(),
            caption: input["caption"].as_str().or_else(|| output["caption"].as_str()).unwrap_or_default().to_owned(),
            unavailable: output["error"] == "FILE_NOT_FOUND"
                || (meta["status"] == "failed" && source["id"].as_str().or_else(|| source["fileId"].as_str()).is_none()),
        });
        if target != i {
            remove.push(i);
        }
    }
    for i in remove.into_iter().rev() {
        rows.remove(i);
    }
}
