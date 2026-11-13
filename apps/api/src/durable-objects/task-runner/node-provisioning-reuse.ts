import { log } from '../../lib/logger';
import {
  findNodeWithCapacity,
  releaseClaimedWarmNode,
  type ReusableNodeSelection,
  tryClaimWarmNode,
  verifyNodeAgentHealthy,
} from './node-selection';
import type { TaskRunnerContext, TaskRunnerState } from './types';

export async function trySelectReusableNodeForProvisioning(
  state: TaskRunnerState,
  rc: TaskRunnerContext
): Promise<ReusableNodeSelection | null> {
  // The provisioning target's pool snapshot was set before this probe. A warm claim
  // overwrites it with the warm node's snapshot, and releasing that claim (unhealthy, or
  // no reservation capacity) resets it to null. Without restoring it, the node created
  // next is unpooled and assertNodeAllocationPlanCurrent refuses it ("Node allocation plan
  // is no longer current", production 2026-11-13).
  const provisioningSnapshot = state.stepResults.capacityPlacementSnapshot;
  const selection = await probeReusableNode(state, rc);
  if (!selection && state.stepResults.capacityPlacementSnapshot !== provisioningSnapshot) {
    state.stepResults.capacityPlacementSnapshot = provisioningSnapshot;
    await rc.ctx.storage.put('state', state);
  }
  return selection;
}

async function probeReusableNode(
  state: TaskRunnerState,
  rc: TaskRunnerContext
): Promise<ReusableNodeSelection | null> {
  const warmNode = await tryClaimWarmNode(state, rc);
  if (warmNode) {
    if (await verifyNodeAgentHealthy(warmNode.nodeId, rc)) return warmNode;
    await releaseClaimedWarmNode(state, rc, warmNode.nodeId);
    log.warn('task_runner_do.node_provisioning.warm_node_unhealthy', {
      taskId: state.taskId,
      nodeId: warmNode.nodeId,
    });
  }

  const existingNode = await findNodeWithCapacity(state, rc);
  if (existingNode) {
    if (await verifyNodeAgentHealthy(existingNode.nodeId, rc)) return existingNode;
    log.warn('task_runner_do.node_provisioning.existing_node_unhealthy', {
      taskId: state.taskId,
      nodeId: existingNode.nodeId,
    });
  }

  return null;
}
