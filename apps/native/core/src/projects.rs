//! The project list: the app's home screen.

use crate::api::{Project, ProjectPage};
use crate::error::UserError;
use crate::session::seg;

#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct ProjectListState {
    pub projects: Vec<Project>,
    pub loading: bool,
    pub error: Option<UserError>,
}

observable!(ProjectListViewModel, ProjectListState, ProjectListObserver);

/// Stop following cursors after this many pages; nobody scrolls past it on a phone.
const MAX_PAGES: usize = 10;

#[uniffi::export(async_runtime = "tokio")]
impl ProjectListViewModel {
    /// Intent: (re)load every project the user can see.
    pub async fn load(&self) {
        self.update(|s| s.loading = true);
        let result = async {
            let mut projects = Vec::new();
            let mut cursor: Option<String> = None;
            for _ in 0..MAX_PAGES {
                let path = match &cursor {
                    Some(c) => format!("/api/projects?cursor={}", seg(c)),
                    None => "/api/projects".to_owned(),
                };
                let page: ProjectPage = self.app.get(&path).await?;
                let empty = page.projects.is_empty();
                projects.extend(page.projects);
                match page.next_cursor {
                    Some(next) if !next.is_empty() && !empty && cursor.as_ref() != Some(&next) => cursor = Some(next),
                    _ => break,
                }
            }
            Ok::<_, crate::error::CoreError>(projects)
        }
        .await;
        self.update(|s| {
            s.loading = false;
            match result {
                Ok(projects) => {
                    s.projects = projects;
                    s.error = None;
                }
                Err(e) => s.error = Some(UserError::from(&e)),
            }
        });
    }

    pub fn reset(&self) {
        self.update(|s| *s = ProjectListState::default());
    }
}
