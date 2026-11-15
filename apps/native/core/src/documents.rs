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

const ATTACHMENT_HEADER: &str = "\n\n## Attached Files\n\nThe following files have been uploaded to the workspace:\n";
const ATTACHMENT_FOOTER: &str = "\nThese are absolute paths inside your workspace container, outside the repository. Open the exact paths listed above to read the attachments; do not look for them relative to the repository.";

/// Recognize only the server's complete attachment envelope, never arbitrary Markdown.
pub(crate) fn user_message(content: &str) -> (String, Vec<ChatDocument>) {
    let Some((message, rest)) = content.rsplit_once(ATTACHMENT_HEADER) else { return (content.to_owned(), vec![]) };
    let Some((files, suffix)) = rest.split_once(ATTACHMENT_FOOTER) else { return (content.to_owned(), vec![]) };
    let mut documents = Vec::new();
    for line in files.trim().lines() {
        let Some((path, details)) = line.strip_prefix("- `").and_then(|s| s.split_once("` (")) else { return (content.to_owned(), vec![]) };
        let Some((upload, filename)) = path.strip_prefix("/workspaces/.private/").and_then(|p| p.split_once('/')) else { return (content.to_owned(), vec![]) };
        let Some((size, mime)) = details.strip_suffix(')').and_then(|s| s.split_once(" bytes, ")) else { return (content.to_owned(), vec![]) };
        let Ok(size) = size.parse::<u64>() else { return (content.to_owned(), vec![]) };
        if upload.len() != 26 || !upload.bytes().all(|b| b.is_ascii_alphanumeric()) || filename.is_empty()
            || filename.contains(['/', '\\']) || filename == "." || filename == ".." {
            return (content.to_owned(), vec![]);
        }
        documents.push(ChatDocument { file_id: format!("attachment:{upload}/{filename}"), filename: filename.to_owned(), mime_type: mime.to_owned(), size_bytes: Some(size), caption: String::new(), unavailable: false });
    }
    if documents.is_empty() { return (content.to_owned(), vec![]) }
    // Preserve any unrelated text after the generated envelope.
    let bootstrap = "IMPORTANT: Before starting any work, you MUST call the `get_instructions` tool from the sam-mcp MCP server. This provides your task context, project information, output branch name, and instructions for reporting progress. Do not proceed until you have called this tool and read its response.";
    let message = if message == crate::attachments::DEFAULT_ATTACHMENT_MESSAGE { "" } else { message };
    let text = format!("{message}{}", if suffix.trim().is_empty() || suffix.trim() == bootstrap { "" } else { suffix });
    (text.trim_end().to_owned(), documents)
}

pub(crate) fn from_attachment(a: &crate::attachments::Attachment) -> Option<ChatDocument> {
    Some(ChatDocument { file_id: format!("attachment:{}/{}", a.upload_id.as_ref()?, a.filename), filename: a.filename.clone(), mime_type: a.content_type.clone(), size_bytes: Some(a.size), caption: String::new(), unavailable: false })
}

#[cfg(test)]
mod attachment_message_tests {
    use super::*;
    fn envelope(text: &str) -> String {
        format!("{text}{ATTACHMENT_HEADER}- `/workspaces/.private/01M7FSHXZ07Z2V7660M26N06SY/photo.png` (100 bytes, image/png)\n{ATTACHMENT_FOOTER}\n")
    }
    #[test]
    fn only_complete_generated_envelopes_are_hidden() {
        let (text, files) = user_message(&envelope("Look at this"));
        assert_eq!(text, "Look at this");
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].file_id, "attachment:01M7FSHXZ07Z2V7660M26N06SY/photo.png");
        assert_eq!(files[0].size_bytes, Some(100));
        for content in ["Explain ## Attached Files", "hello\n\n## Attached Files\n\nnotes", &envelope("hello").replace("/photo.png", "/../secret")] {
            assert_eq!(user_message(content), (content.to_owned(), vec![]));
        }
        assert_eq!(user_message(&envelope(crate::attachments::DEFAULT_ATTACHMENT_MESSAGE)).0, "");
    }
}
