//! Files attached to the next message: a new task (project screen) or a
//! follow-up (chat screen). Each file uploads as soon as it is added, the way
//! the web app does it (apps/web/src/pages/project-chat/useAttachments.ts):
//!
//! 1. `POST /api/projects/:id/tasks/request-upload` returns a presigned R2 URL,
//! 2. the bytes go straight to R2 with a `PUT` (no cookie, the URL is the grant),
//! 3. the message carries `attachments: [{uploadId, filename, size, contentType}]`,
//!    which the server checks against R2 and copies into the agent's workspace.
//!
//! The shell only picks or receives files (file picker, photos, drag and drop)
//! and hands each one over as an `AttachmentSource`; the core reads it once,
//! off the main thread, after the limits are checked.

use std::sync::atomic::{AtomicU64, Ordering};

use serde::{Deserialize, Serialize};
use unicode_normalization::UnicodeNormalization;

use crate::error::{CoreError, Result, UserError};
use crate::session::{seg, App};

/// The server's defaults (`ATTACHMENT_DEFAULTS` in packages/shared/src/types/task.ts).
/// A deployment can set them lower; the server's answer then says so.
pub const ATTACHMENT_MAX_BYTES: u64 = 50 * 1024 * 1024;
pub const ATTACHMENT_BATCH_MAX_BYTES: u64 = 200 * 1024 * 1024;
pub const ATTACHMENT_MAX_FILES: u32 = 20;

/// What the agent is asked when the message has files but no text
/// (`DEFAULT_ATTACHMENT_MESSAGE` in the web app). It is prompt text for the
/// agent, not app copy, so it lives here and is not translated.
pub(crate) const DEFAULT_ATTACHMENT_MESSAGE: &str = "Please read the attached files.";

/// `MAX_SANITIZED_FILENAME_LENGTH` in packages/shared/src/filename.ts.
const MAX_FILENAME_LENGTH: usize = 255;
const MAX_KEPT_EXTENSION_LENGTH: usize = 16;

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum AttachmentStatus {
    Uploading,
    /// Uploaded; goes out with the next message.
    Ready,
    /// Not uploaded (too large, empty, unreadable, or the upload failed). It
    /// blocks sending until the user removes it.
    Failed {
        error: UserError,
    },
}

/// One file in the composer.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Attachment {
    /// Local id, for `remove_attachment`.
    pub id: String,
    /// The name the agent sees (made safe, e.g. `Screen Shot 1.png` -> `Screen_Shot_1.png`).
    pub filename: String,
    pub size: u64,
    pub content_type: String,
    pub status: AttachmentStatus,
    /// Set once uploaded.
    pub upload_id: Option<String>,
    /// Local, bounded thumbnail; never included in upload requests.
    pub thumbnail: Option<Vec<u8>>,
}

/// A file the shell picked or received by drag and drop. `read` runs once, on
/// a core worker thread, and only when the file is within the limits.
#[uniffi::export(callback_interface)]
pub trait AttachmentSource: Send + Sync {
    /// The file's bytes, or `None` when it can't be read (anymore).
    fn read(&self) -> Option<Vec<u8>>;
    /// Best-effort platform thumbnail, at most 1 MiB. Called before read.
    fn thumbnail(&self) -> Option<Vec<u8>> { None }
}

/// `TaskAttachment` in packages/shared/src/types/task.ts.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TaskAttachment {
    pub upload_id: String,
    pub filename: String,
    pub size: u64,
    pub content_type: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RequestUpload<'a> {
    filename: &'a str,
    size: u64,
    content_type: &'a str,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct UploadGrant {
    upload_id: String,
    upload_url: String,
}

/// Checks `filename`/`size` against the limits and what is already attached.
/// `Ok` is the new entry: `Uploading`, or `Failed` for a file that can't go
/// (kept in the list so the user sees which one). `Err` adds nothing.
pub(crate) fn stage(attached: &[Attachment], filename: &str, content_type: &str, size: u64) -> std::result::Result<Attachment, UserError> {
    if attached.len() >= ATTACHMENT_MAX_FILES as usize {
        return Err(UserError::TooManyFiles { max: ATTACHMENT_MAX_FILES });
    }
    static NEXT_ID: AtomicU64 = AtomicU64::new(1);
    let mut attachment = Attachment {
        id: format!("attachment-{}", NEXT_ID.fetch_add(1, Ordering::Relaxed)),
        filename: sanitize_filename(filename),
        size,
        content_type: content_type_or_default(content_type),
        status: AttachmentStatus::Uploading,
        upload_id: None,
        thumbnail: None,
    };
    if size == 0 {
        attachment.status = AttachmentStatus::Failed { error: UserError::FileEmpty };
    } else if size > ATTACHMENT_MAX_BYTES {
        attachment.status = AttachmentStatus::Failed { error: UserError::FileTooLarge { max_bytes: ATTACHMENT_MAX_BYTES } };
    } else {
        let total: u64 = attached.iter().filter(|a| !matches!(a.status, AttachmentStatus::Failed { .. })).map(|a| a.size).sum();
        if total + size > ATTACHMENT_BATCH_MAX_BYTES {
            return Err(UserError::AttachmentsTooLarge { max_bytes: ATTACHMENT_BATCH_MAX_BYTES });
        }
    }
    Ok(attachment)
}

/// Reads `source` and uploads it for `project_id`. On success the entry's
/// final size and upload id.
pub(crate) async fn upload(
    app: &App,
    project_id: &str,
    attachment: &Attachment,
    source: std::sync::Arc<dyn AttachmentSource>,
) -> Result<TaskAttachment> {
    let data = tokio::task::spawn_blocking(move || source.read())
        .await
        .map_err(|e| CoreError::Unexpected(format!("reading the file: {e}")))?
        .ok_or(CoreError::Unreadable)?;
    // The shell's size was a hint; what was read is what is uploaded.
    let size = data.len() as u64;
    if size == 0 {
        return Err(CoreError::FileEmpty);
    }
    if size > ATTACHMENT_MAX_BYTES {
        return Err(CoreError::FileTooLarge(ATTACHMENT_MAX_BYTES));
    }
    let grant: UploadGrant = app
        .post(
            &format!("/api/projects/{}/tasks/request-upload", seg(project_id)),
            &RequestUpload { filename: &attachment.filename, size, content_type: &attachment.content_type },
        )
        .await?;
    // The URL is signed for this length and content type.
    app.put_presigned(&grant.upload_url, &attachment.content_type, data).await?;
    Ok(TaskAttachment {
        upload_id: grant.upload_id,
        filename: attachment.filename.clone(),
        size,
        content_type: attachment.content_type.clone(),
    })
}

/// What goes out with the message: every attachment, once all are uploaded.
pub(crate) fn ready(attached: &[Attachment]) -> std::result::Result<Vec<TaskAttachment>, UserError> {
    attached
        .iter()
        .map(|a| match (&a.status, &a.upload_id) {
            (AttachmentStatus::Ready, Some(upload_id)) => Ok(TaskAttachment {
                upload_id: upload_id.clone(),
                filename: a.filename.clone(),
                size: a.size,
                content_type: a.content_type.clone(),
            }),
            _ => Err(UserError::AttachmentsNotReady),
        })
        .collect()
}

/// The text to send: what the user typed, or the default ask when only files go.
pub(crate) fn message_text(typed: &str, has_files: bool) -> String {
    match typed.trim() {
        "" if has_files => DEFAULT_ATTACHMENT_MESSAGE.to_owned(),
        text => text.to_owned(),
    }
}

/// `observable_attachments!(Vm, State)`: the attachment intents for a view model
/// whose state has `project_id: String` and `attachments: Vec<Attachment>`.
/// A state reset (another project or session) empties the list, so an upload
/// that finishes afterwards finds no entry and is dropped.
macro_rules! observable_attachments {
    ($vm:ident) => {
        #[uniffi::export(async_runtime = "tokio")]
        impl $vm {
            /// Intent: attach a file to the next message. It uploads right away;
            /// follow it in `state.attachments`. `size` is the file's size as the
            /// shell sees it (checked before `source` is read); `content_type` may
            /// be empty when unknown.
            pub async fn add_attachment(
                &self,
                filename: String,
                content_type: String,
                size: u64,
                source: Box<dyn crate::attachments::AttachmentSource>,
            ) {
                let mut staged = None;
                let mut project_id = String::new();
                self.update(|s| {
                    if s.project_id.is_empty() {
                        return; // nothing loaded yet
                    }
                    project_id = s.project_id.clone();
                    match crate::attachments::stage(&s.attachments, &filename, &content_type, size) {
                        Ok(a) => {
                            s.attachments.push(a.clone());
                            staged = Some(a);
                        }
                        Err(e) => s.error = Some(e),
                    }
                });
                let Some(attachment) = staged else { return };
                if attachment.status != crate::attachments::AttachmentStatus::Uploading {
                    return;
                }
                let is_image = attachment.content_type.starts_with("image/");
                let source: std::sync::Arc<dyn crate::attachments::AttachmentSource> = source.into();
                let preview_source = source.clone();
                let thumbnail = tokio::task::spawn_blocking(move || {
                    if is_image {
                        preview_source.thumbnail().filter(|data| data.len() <= 1024 * 1024)
                    } else { None }
                }).await.unwrap_or(None);
                self.update(|s| {
                    if let Some(a) = s.attachments.iter_mut().find(|a| a.id == attachment.id) {
                        a.thumbnail = thumbnail;
                    }
                });
                let result = crate::attachments::upload(&self.app, &project_id, &attachment, source).await;
                self.update(|s| {
                    let Some(a) = s.attachments.iter_mut().find(|a| a.id == attachment.id) else { return };
                    match result {
                        Ok(uploaded) => {
                            a.size = uploaded.size;
                            a.upload_id = Some(uploaded.upload_id);
                            a.status = crate::attachments::AttachmentStatus::Ready;
                        }
                        Err(e) => a.status = crate::attachments::AttachmentStatus::Failed { error: crate::error::UserError::from(&e) },
                    }
                });
            }

            /// Intent: take a file off the next message.
            pub fn remove_attachment(&self, id: String) {
                self.update(|s| s.attachments.retain(|a| a.id != id));
            }
        }
    };
}

fn content_type_or_default(content_type: &str) -> String {
    match content_type.trim() {
        "" => "application/octet-stream".to_owned(),
        t => t.to_owned(),
    }
}

/// `sanitizeFilename` (packages/shared/src/filename.ts): accents folded, every
/// run of other characters to `_`, at most 255 characters keeping the
/// extension, and `file` when nothing usable is left. The server accepts only
/// `[a-zA-Z0-9._\- ]+`.
pub(crate) fn sanitize_filename(name: &str) -> String {
    let mut cleaned = String::new();
    let mut in_run = false;
    for c in name.trim().nfkd().filter(|c| !('\u{300}'..='\u{36f}').contains(c)) {
        if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') {
            cleaned.push(c);
            in_run = false;
        } else if !in_run {
            // A run of other characters becomes one `_`.
            cleaned.push('_');
            in_run = true;
        }
    }
    let bounded = truncate_filename(&cleaned);
    if bounded.chars().any(|c| c.is_ascii_alphanumeric()) {
        bounded
    } else {
        "file".to_owned()
    }
}

fn truncate_filename(name: &str) -> String {
    if name.len() <= MAX_FILENAME_LENGTH {
        return name.to_owned();
    }
    let extension = match name.rfind('.') {
        Some(dot) if dot > 0 && name.len() - dot <= MAX_KEPT_EXTENSION_LENGTH => &name[dot..],
        _ => "",
    };
    format!("{}{extension}", &name[..MAX_FILENAME_LENGTH - extension.len()])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitizes_like_the_web_app() {
        assert_eq!(sanitize_filename("CleanShot 12.22.51@2x.png"), "CleanShot_12.22.51_2x.png");
        assert_eq!(sanitize_filename("  résumé final.pdf "), "resume_final.pdf");
        assert_eq!(sanitize_filename("a  &  b.txt"), "a_b.txt");
        assert_eq!(sanitize_filename("ok-name_1.rs"), "ok-name_1.rs");
        assert_eq!(sanitize_filename(".."), "file");
        assert_eq!(sanitize_filename("日本語"), "file");
        let long = format!("{}.json", "x".repeat(300));
        let short = sanitize_filename(&long);
        assert_eq!(short.len(), 255);
        assert!(short.ends_with(".json"));
    }

    fn ready_file(size: u64) -> Attachment {
        Attachment {
            id: "a".into(),
            filename: "f".into(),
            size,
            content_type: "text/plain".into(),
            status: AttachmentStatus::Ready,
            upload_id: Some("u".into()),
            thumbnail: None,
        }
    }

    #[test]
    fn stages_within_the_limits() {
        let a = stage(&[], "notes.txt", "", 10).unwrap();
        assert_eq!(a.status, AttachmentStatus::Uploading);
        assert_eq!(a.content_type, "application/octet-stream");

        let empty = stage(&[], "empty.txt", "text/plain", 0).unwrap();
        assert_eq!(empty.status, AttachmentStatus::Failed { error: UserError::FileEmpty });
        let big = stage(&[], "big.bin", "", ATTACHMENT_MAX_BYTES + 1).unwrap();
        assert!(matches!(big.status, AttachmentStatus::Failed { error: UserError::FileTooLarge { .. } }));

        let full: Vec<_> = (0..ATTACHMENT_MAX_FILES).map(|_| ready_file(1)).collect();
        assert_eq!(stage(&full, "one-more", "", 1), Err(UserError::TooManyFiles { max: ATTACHMENT_MAX_FILES }));

        let heavy = vec![ready_file(ATTACHMENT_BATCH_MAX_BYTES - 5)];
        assert!(matches!(stage(&heavy, "x", "", 10), Err(UserError::AttachmentsTooLarge { .. })));
        assert!(stage(&heavy, "x", "", 5).is_ok());
    }

    #[test]
    fn sends_only_when_everything_is_uploaded() {
        assert_eq!(ready(&[]).unwrap(), vec![]);
        assert_eq!(ready(&[ready_file(3)]).unwrap()[0].upload_id, "u");
        let uploading = Attachment { status: AttachmentStatus::Uploading, upload_id: None, ..ready_file(3) };
        assert_eq!(ready(&[ready_file(3), uploading]), Err(UserError::AttachmentsNotReady));

        assert_eq!(message_text("  ", true), DEFAULT_ATTACHMENT_MESSAGE);
        assert_eq!(message_text("  ", false), "");
        assert_eq!(message_text(" look ", true), "look");
    }
}
