import { useEffect, useRef } from 'react';
import { useSearchParams } from 'react-router';

import type { SessionToolAction, SessionToolId } from './session-tool-actions';

/** Native clients hand off tools they do not yet render. Only open panels/composers;
 * a URL must never complete/cancel a task or submit a retry by itself. The existing
 * action list remains the authority for availability and viewer permissions. */
const HANDOFF_TOOLS = new Set<SessionToolId>([
  'related',
  'automation',
  'comments',
  'share',
  'retry',
  'fork',
  'report',
]);

export function useRequestedSessionTool(
  sessionId: string,
  ready: boolean,
  actions: SessionToolAction[],
  selectTool: (id: SessionToolId) => void
) {
  const [params, setParams] = useSearchParams();
  const handled = useRef<string | null>(null);
  const requested = params.get('tool');
  useEffect(() => {
    if (!requested) {
      handled.current = null;
      return;
    }
    if (!ready) return;
    const action = actions.find((candidate) => candidate.id === requested);
    if (!action || action.disabled || !HANDOFF_TOOLS.has(action.id)) return;
    const key = `${sessionId}:${requested}`;
    if (handled.current === key) return;
    handled.current = key;
    const next = new URLSearchParams(params);
    next.delete('tool');
    setParams(next, { replace: true });
    selectTool(action.id);
  }, [sessionId, ready, requested, actions, selectTool, params, setParams]);
}
