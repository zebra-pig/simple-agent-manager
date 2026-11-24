//! Bounded background session reads for a mounted project list.

use super::{ProjectViewModel, SessionPage, SESSION_PAGE_SIZE};
use crate::error::{Result, UserError};
use crate::session::seg;

impl ProjectViewModel {
    pub(super) async fn refresh_sessions(&self) {
        let mut request = None;
        self.update_data(|s, generation| {
            if !s.project_id.is_empty() && !s.loading {
                *generation += 1;
                request = Some((s.project_id.clone(), *generation));
            }
        });
        let Some((project_id, request_generation)) = request else { return };
        // Poll only the recent window: one bounded request regardless of history
        // size. Explicit loads still enumerate all pages for complete search.
        let page: Result<SessionPage> =
            self.app.get(&format!("/api/projects/{}/sessions?limit={SESSION_PAGE_SIZE}", seg(&project_id))).await;
        self.update_data(|s, generation| {
            if *generation != request_generation || s.project_id != project_id {
                return;
            }
            match page {
                Ok(page) => {
                    let mut sessions = page.sessions;
                    if page.has_more {
                        let recent: std::collections::HashSet<_> = sessions.iter().map(|s| s.id.clone()).collect();
                        sessions.extend(s.sessions.iter().filter(|s| !recent.contains(&s.id)).cloned());
                    }
                    sessions.sort_by(|a, b| b.last_activity().cmp(&a.last_activity()).then_with(|| a.id.cmp(&b.id)));
                    s.sessions = sessions;
                    s.filter_sessions();
                    s.error = None;
                }
                Err(e) => s.error = Some(UserError::from(&e)),
            }
        });
    }
}
