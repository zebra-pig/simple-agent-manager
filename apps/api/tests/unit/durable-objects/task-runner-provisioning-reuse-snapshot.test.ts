import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  tryClaimWarmNode: vi.fn(),
  findNodeWithCapacity: vi.fn(),
  verifyNodeAgentHealthy: vi.fn(),
}));

vi.mock('../../../src/durable-objects/task-runner/node-selection', async () => {
  const warm = await vi.importActual<
    typeof import('../../../src/durable-objects/task-runner/warm-node-claim')
  >('../../../src/durable-objects/task-runner/warm-node-claim');
  return {
    releaseClaimedWarmNode: warm.releaseClaimedWarmNode,
    tryClaimWarmNode: mocks.tryClaimWarmNode,
    findNodeWithCapacity: mocks.findNodeWithCapacity,
    verifyNodeAgentHealthy: mocks.verifyNodeAgentHealthy,
  };
});

import { trySelectReusableNodeForProvisioning } from '../../../src/durable-objects/task-runner/node-provisioning-reuse';
import type {
  TaskRunnerContext,
  TaskRunnerState,
} from '../../../src/durable-objects/task-runner/types';
import { releaseClaimedWarmNode } from '../../../src/durable-objects/task-runner/warm-node-claim';

const provisioningSnapshot = {
  capacityPoolId: 'pool-1',
  capacitySourceId: 'source-1',
  capacityPoolCandidateId: 'candidate-new',
  providerInstanceType: 'a4-ram8-disk20-perf1',
};
const warmSnapshot = { ...provisioningSnapshot, capacityPoolCandidateId: 'candidate-warm' };

function setup() {
  const state = {
    taskId: 'task-1',
    stepResults: {
      nodeId: null,
      claimedWarmNodeId: null,
      autoProvisioned: false,
      workspaceId: null,
      capacityPlacementSnapshot: provisioningSnapshot,
    },
  } as unknown as TaskRunnerState;
  const releaseClaim = vi.fn(async () => ({ released: true, state: { claimedByTask: null } }));
  const rc = {
    env: {
      NODE_LIFECYCLE: { idFromName: (id: string) => id, get: () => ({ releaseClaim }) },
    },
    ctx: { storage: { put: vi.fn(async () => undefined) } },
  } as unknown as TaskRunnerContext;
  return { state, rc, releaseClaim };
}

/** What tryClaimWarmNode does when the claimed warm node cannot admit the task. */
function claimThenReleaseWarmNode() {
  mocks.tryClaimWarmNode.mockImplementation(
    async (state: TaskRunnerState, rc: TaskRunnerContext) => {
      state.stepResults.nodeId = 'warm-node';
      state.stepResults.claimedWarmNodeId = 'warm-node';
      state.stepResults.capacityPlacementSnapshot = warmSnapshot as never;
      await releaseClaimedWarmNode(state, rc, 'warm-node');
      return null;
    }
  );
}

describe('trySelectReusableNodeForProvisioning', () => {
  beforeEach(() => {
    mocks.tryClaimWarmNode.mockReset();
    mocks.findNodeWithCapacity.mockReset().mockResolvedValue(null);
    mocks.verifyNodeAgentHealthy.mockReset().mockResolvedValue(true);
  });

  it('keeps the provisioning pool snapshot after a warm claim is released', async () => {
    claimThenReleaseWarmNode();
    const { state, rc, releaseClaim } = setup();

    await expect(trySelectReusableNodeForProvisioning(state, rc)).resolves.toBeNull();

    expect(releaseClaim).toHaveBeenCalledWith('task-1');
    expect(state.stepResults.nodeId).toBeNull();
    expect(state.stepResults.capacityPlacementSnapshot).toEqual(provisioningSnapshot);
    expect(rc.ctx.storage.put).toHaveBeenCalledWith('state', state);
  });

  it('keeps the warm node snapshot when the warm node is adopted', async () => {
    mocks.tryClaimWarmNode.mockImplementation(async (state: TaskRunnerState) => {
      state.stepResults.capacityPlacementSnapshot = warmSnapshot as never;
      return { nodeId: 'warm-node', capacityPlacementSnapshot: warmSnapshot };
    });
    const { state, rc } = setup();

    await expect(trySelectReusableNodeForProvisioning(state, rc)).resolves.toMatchObject({
      nodeId: 'warm-node',
    });
    expect(state.stepResults.capacityPlacementSnapshot).toEqual(warmSnapshot);
  });

  it('leaves state untouched when no warm node was claimed', async () => {
    mocks.tryClaimWarmNode.mockResolvedValue(null);
    const { state, rc } = setup();

    await expect(trySelectReusableNodeForProvisioning(state, rc)).resolves.toBeNull();
    expect(state.stepResults.capacityPlacementSnapshot).toBe(provisioningSnapshot);
    expect(rc.ctx.storage.put).not.toHaveBeenCalled();
  });
});
