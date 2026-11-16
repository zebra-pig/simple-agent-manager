use super::{Row, ToolCall, ToolUpdate};
use std::collections::{HashMap, HashSet};

struct Resolved {
    call: ToolCall,
    row_id: String,
    page: usize,
}

/// Resolve updates globally, but render a call in the newest loaded page that
/// already contains it. Fetching its older start event must not replace the
/// existing card or render the same call twice across a page boundary.
pub(super) fn resolve(rows: &[Row], boundaries: &HashSet<String>) -> HashMap<String, ToolCall> {
    let mut calls: HashMap<(bool, String), Resolved> = HashMap::new();
    let mut page = 0;
    for row in rows {
        if boundaries.contains(&row.id) {
            page += 1;
        }
        if row.role != "tool" || row.document.is_some() {
            continue;
        }
        let meta = row.tool_metadata.as_ref().and_then(serde_json::Value::as_object);
        let update = ToolUpdate::from(row, meta);
        // A row without a call ID remains independent of named calls.
        let key = (update.call_id.is_some(), update.call_id.clone().unwrap_or_else(|| row.id.clone()));
        if let Some(resolved) = calls.get_mut(&key) {
            update.apply(&mut resolved.call);
            if page > resolved.page {
                resolved.page = page;
                resolved.row_id = row.id.clone();
            }
        } else {
            calls.insert(key, Resolved { call: update.into_call(&row.id), row_id: row.id.clone(), page });
        }
    }
    calls.into_values().map(|resolved| (resolved.row_id, resolved.call)).collect()
}
