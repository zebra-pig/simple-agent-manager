import Database from 'better-sqlite3';
import { afterEach, describe, expect, it } from 'vitest';

import * as schema from '../../src/db/schema';
import type { Env } from '../../src/env';
import { externalCapacitySourceCredentialId } from '../../src/services/default-capacity-pool-helpers';
import { assertNodeAllocationPlanCurrent } from '../../src/services/nodes';
import { createAllSchemaTables, createSqliteD1 } from '../helpers/sqlite-d1';

// A capacity source backed by a composable (cc_*) credential always carries a secret-free
// anchor credential_id (ensureCapacitySourceCredentialAnchor). The plan guard used to demand
// credential_id IS NULL for these sources, so in production every VM placed through a
// composable credential failed with "Node allocation plan is no longer current" before the
// provider was ever called (2026-11-13, Infomaniak a8-ram16 node 01M7BKGFSM2DJ9DN9BZVCS3MQ9).

const VERSION = 1_700_000_000_000;
const TIMESTAMP = new Date(VERSION).toISOString();
const EXTERNAL_REF = 'cc_attachments:cc-att-1';
const ANCHOR_ID = externalCapacitySourceCredentialId(EXTERNAL_REF, VERSION);

let sqlite: Database.Database | null = null;

function makeEnv(): Env {
  sqlite = new Database(':memory:');
  createAllSchemaTables(sqlite, schema);
  return { DATABASE: createSqliteD1(sqlite) } as Env;
}

/** Seeds the production row shape of a user pool sourced from a composable credential. */
function seedComposablePlan(sourceCredentialId: string | null): void {
  sqlite?.exec(`
    INSERT INTO cc_credentials (id, owner_id, name, kind, encrypted_token, iv, is_active, created_at, updated_at)
    VALUES ('cc-cred-1', 'user-1', 'Infomaniak', 'cloud-provider', 'enc', 'iv', 1, '${TIMESTAMP}', '${TIMESTAMP}');
    INSERT INTO cc_configurations (id, owner_id, name, consumer_kind, consumer_target, credential_id, is_active, created_at, updated_at)
    VALUES ('cc-cfg-1', 'user-1', 'Infomaniak', 'compute', 'infomaniak', 'cc-cred-1', 1, '${TIMESTAMP}', '${TIMESTAMP}');
    INSERT INTO cc_attachments (id, configuration_id, consumer_kind, consumer_target, user_id, project_id, is_active, created_at, updated_at)
    VALUES ('cc-att-1', 'cc-cfg-1', 'compute', 'infomaniak', 'user-1', NULL, 1, '${TIMESTAMP}', '${TIMESTAMP}');

    INSERT INTO credentials
      (id, user_id, project_id, provider, credential_type, is_active, encrypted_token, iv, created_at, updated_at)
    VALUES
      ('${ANCHOR_ID}', 'user-1', NULL, 'infomaniak', 'capacity-source-external-ref', 1, '', '', '${TIMESTAMP}', '${TIMESTAMP}'),
      ('cap-source-external-credential:other', 'user-1', NULL, 'infomaniak', 'capacity-source-external-ref', 1, '', '', '${TIMESTAMP}', '${TIMESTAMP}');

    INSERT INTO capacity_pools
      (id, scope, owner_user_id, owner_project_id, name, is_default, revision, status,
       configuration_state, strategy, exhaustion_policy, migration_state, created_at, updated_at)
    VALUES
      ('pool-1', 'user', 'user-1', NULL, 'User default', 1, 17, 'active',
       'configured-ready', 'balanced', 'queue', 'complete', '${TIMESTAMP}', '${TIMESTAMP}');

    INSERT INTO capacity_sources
      (id, scope, owner_user_id, owner_project_id, source_kind, provider, credential_source,
       credential_id, platform_credential_id, credential_reference, credential_version,
       external_source_ref, status, created_at, updated_at)
    VALUES
      ('source-1', 'user', 'user-1', NULL, 'cloud-provider-credential', 'infomaniak', 'user',
       ${sourceCredentialId === null ? 'NULL' : `'${sourceCredentialId}'`}, NULL,
       'cc_credentials:cc-cred-1', ${VERSION},
       '${EXTERNAL_REF}', 'active', '${TIMESTAMP}', '${TIMESTAMP}');

    INSERT INTO capacity_pool_candidates
      (id, pool_id, capacity_source_id, provider, location, workload_role, provider_instance_type,
       provider_instance_vcpu_count, provider_instance_memory_mb, provider_instance_disk_gb,
       catalog_availability, status, priority, candidate_order, created_at, updated_at)
    VALUES
      ('candidate-1', 'pool-1', 'source-1', 'infomaniak', 'dc4-a', 'workspace', 'a8-ram16-disk20-perf1',
       8, 16384, 80, 'available', 'active', 0, 0, '${TIMESTAMP}', '${TIMESTAMP}');

    INSERT INTO nodes
      (
        id, user_id, name, status, runtime, node_class, node_role, workload_role, cloud_provider,
        vm_location, capacity_pool_id, capacity_pool_scope, capacity_pool_revision,
        capacity_source_id, capacity_source_generation, capacity_source_external_ref,
        capacity_pool_candidate_id, capacity_pool_project_id,
        placement_credential_source, placement_credential_reference, placement_credential_version,
        provider_instance_type, provider_instance_vcpu_count, provider_instance_memory_mb,
        provider_instance_disk_gb
      )
    VALUES
      (
        'node-1', 'user-1', 'node-1', 'creating', 'vm', 'managed', 'workspace', 'workspace', 'infomaniak',
        'dc4-a', 'pool-1', 'user', 17,
        'source-1', ${VERSION}, '${EXTERNAL_REF}',
        'candidate-1', NULL,
        'user', 'cc_credentials:cc-cred-1', ${VERSION},
        'a8-ram16-disk20-perf1', 8, 16384, 80
      );
  `);
}

afterEach(() => {
  sqlite?.close();
  sqlite = null;
});

describe('node allocation plan guard: composable-credential sources', () => {
  it('accepts a source carrying the anchor credential id the reconciler writes', async () => {
    const env = makeEnv();
    seedComposablePlan(ANCHOR_ID);
    await expect(
      assertNodeAllocationPlanCurrent(env, 'node-1', 'user-1', null)
    ).resolves.toBeUndefined();
  });

  it('still accepts a source with no anchor (rows written before anchors existed)', async () => {
    const env = makeEnv();
    seedComposablePlan(null);
    await expect(
      assertNodeAllocationPlanCurrent(env, 'node-1', 'user-1', null)
    ).resolves.toBeUndefined();
  });

  it('rejects a source anchored to a different attachment or credential version', async () => {
    const env = makeEnv();
    seedComposablePlan('cap-source-external-credential:other');
    await expect(assertNodeAllocationPlanCurrent(env, 'node-1', 'user-1', null)).rejects.toThrow(
      'Node allocation plan is no longer current'
    );
  });

  it('rejects once the composable credential is deactivated', async () => {
    const env = makeEnv();
    seedComposablePlan(ANCHOR_ID);
    sqlite?.exec("UPDATE cc_credentials SET is_active = 0 WHERE id = 'cc-cred-1'");
    await expect(assertNodeAllocationPlanCurrent(env, 'node-1', 'user-1', null)).rejects.toThrow(
      'Node allocation plan is no longer current'
    );
  });
});
