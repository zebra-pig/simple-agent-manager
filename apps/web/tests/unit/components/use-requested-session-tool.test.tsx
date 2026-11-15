import { act, renderHook, waitFor } from '@testing-library/react';
import { Info } from 'lucide-react';
import { type ReactNode, StrictMode } from 'react';
import { MemoryRouter, useLocation } from 'react-router';
import { describe, expect, it, vi } from 'vitest';

import type {
  SessionToolAction,
  SessionToolId,
} from '../../../src/components/project-message-view/session-tool-actions';
import { useRequestedSessionTool } from '../../../src/components/project-message-view/useRequestedSessionTool';

const action = (id: SessionToolId): SessionToolAction => ({
  id,
  label: id,
  hint: id,
  icon: Info,
  group: 'workspace',
});
function setup(requested: string, initial: SessionToolAction[] = []) {
  const select = vi.fn();
  const wrapper = ({ children }: { children: ReactNode }) => (
    <StrictMode>
      <MemoryRouter initialEntries={[`/projects/p/chat/s?tool=${requested}&keep=yes`]}>
        {children}
      </MemoryRouter>
    </StrictMode>
  );
  const hook = renderHook(
    ({ ready, actions }) => {
      useRequestedSessionTool('s', ready, actions, select);
      return useLocation();
    },
    { wrapper, initialProps: { ready: false, actions: initial } }
  );
  return { ...hook, select };
}

describe('native chat tool handoff', () => {
  it('waits for the authoritative action list, opens once and preserves other query parameters', async () => {
    const h = setup('comments');
    expect(h.select).not.toHaveBeenCalled();
    act(() => h.rerender({ ready: true, actions: [] }));
    expect(h.select).not.toHaveBeenCalled();
    act(() => h.rerender({ ready: true, actions: [action('comments')] }));
    await waitFor(() => expect(h.select).toHaveBeenCalledExactlyOnceWith('comments'));
    expect(h.result.current.search).toBe('?keep=yes');
    act(() => h.rerender({ ready: true, actions: [action('comments')] }));
    expect(h.select).toHaveBeenCalledTimes(1);
  });
  it.each(['complete', 'cancel', 'unknown'])(
    'never executes an unsafe or unknown URL action: %s',
    (id) => {
      const h = setup(id);
      act(() => h.rerender({ ready: true, actions: [action('complete'), action('cancel')] }));
      expect(h.select).not.toHaveBeenCalled();
    }
  );
  it('does not bypass permission or availability gates', () => {
    const h = setup('share');
    act(() => h.rerender({ ready: true, actions: [{ ...action('share'), disabled: true }] }));
    expect(h.select).not.toHaveBeenCalled();
    act(() => h.rerender({ ready: true, actions: [action('comments')] }));
    expect(h.select).not.toHaveBeenCalled();
  });
  it.each(['related', 'automation', 'share', 'retry', 'fork', 'report'] as const)(
    'opens the requested %s surface',
    async (id) => {
      const h = setup(id);
      act(() => h.rerender({ ready: true, actions: [action(id)] }));
      await waitFor(() => expect(h.select).toHaveBeenCalledExactlyOnceWith(id));
    }
  );
});
