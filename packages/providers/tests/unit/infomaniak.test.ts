import { afterEach, describe, expect, it, vi } from 'vitest';

import {
  classifyInfomaniakError,
  InfomaniakProvider,
  mapInfomaniakStatus,
} from '../../src/infomaniak';
import { ProviderError } from '../../src/types';

const AUTH_URL = 'https://identity.test/v3';
const COMPUTE = 'https://compute.test/v2.1/project';
const VOLUME = 'https://volume.test/v3/project';
const IMAGE = 'https://image.test';
const NETWORK = 'https://network.test';

function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', ...headers },
  });
}
function auth(
  catalog = [
    { type: 'compute', endpoints: [{ region: 'dc4-a', interface: 'public', url: COMPUTE }] },
    { type: 'volumev3', endpoints: [{ region: 'dc4-a', interface: 'public', url: VOLUME }] },
    { type: 'image', endpoints: [{ region: 'dc4-a', interface: 'public', url: IMAGE }] },
    { type: 'network', endpoints: [{ region: 'dc4-a', interface: 'public', url: NETWORK }] },
  ]
): Response {
  return json({ token: { project: { id: 'project' }, catalog } }, 201, {
    'x-subject-token': 'subject-token',
  });
}
function volume(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: 'vol-1',
    name: 'data',
    size: 20,
    status: 'available',
    attachments: [],
    volume_type: 'CEPH_1_perf1',
    created_at: '2026-07-25T00:00:00Z',
    metadata: { env: 'e1' },
    ...overrides,
  };
}

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

describe('InfomaniakProvider', () => {
  it('authenticates with explicit Keystone application credentials and validates the full catalog', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce(auth());
    const provider = new InfomaniakProvider('credential-id', 'one-time-secret', {
      authUrl: AUTH_URL,
    });
    await expect(provider.validateToken()).resolves.toBe(true);
    expect(fetchMock).toHaveBeenCalledWith(
      `${AUTH_URL}/auth/tokens`,
      expect.objectContaining({
        method: 'POST',
        body: JSON.stringify({
          auth: {
            identity: {
              methods: ['application_credential'],
              application_credential: { id: 'credential-id', secret: 'one-time-secret' },
            },
          },
        }),
      })
    );
  });

  it('rejects malformed Keystone catalogs at runtime', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce(auth([]));
    const provider = new InfomaniakProvider('id', 'secret', { authUrl: AUTH_URL });
    await expect(provider.validateToken()).rejects.toThrow('catalog is missing compute');
  });

  it('creates a Cinder volume with exact region/type/metadata payload', async () => {
    const fetchMock = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(auth())
      .mockResolvedValueOnce(json({ volume: volume({ status: 'creating' }) }, 202));
    const provider = new InfomaniakProvider('id', 'secret', {
      authUrl: AUTH_URL,
      volumeType: 'CEPH_1_perf1',
    });
    const result = await provider.createVolume({
      name: 'data',
      sizeGb: 20,
      location: 'dc4-a',
      labels: { env: 'e1' },
    });
    expect(result).toMatchObject({
      id: 'vol-1',
      sizeGb: 20,
      status: 'creating',
      location: 'dc4-a',
      labels: { env: 'e1' },
    });
    expect(fetchMock).toHaveBeenNthCalledWith(
      2,
      `${VOLUME}/volumes`,
      expect.objectContaining({
        method: 'POST',
        headers: expect.objectContaining({ 'X-Auth-Token': 'subject-token' }),
        body: JSON.stringify({
          volume: { name: 'data', size: 20, volume_type: 'CEPH_1_perf1', metadata: { env: 'e1' } },
        }),
      })
    );
  });

  it('refuses attached-volume deletion without issuing DELETE', async () => {
    const fetchMock = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(auth())
      .mockResolvedValueOnce(
        json({ volume: volume({ status: 'in-use', attachments: [{ server_id: 'server-1' }] }) })
      );
    const provider = new InfomaniakProvider('id', 'secret', { authUrl: AUTH_URL });
    await expect(
      provider.deleteVolume({ volumeId: 'vol-1', location: 'dc4-a' })
    ).rejects.toMatchObject({ statusCode: 409 });
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it('requires detach before grow-only resize', async () => {
    vi.spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(auth())
      .mockResolvedValueOnce(
        json({ volume: volume({ status: 'in-use', attachments: [{ server_id: 'server-1' }] }) })
      );
    const provider = new InfomaniakProvider('id', 'secret', { authUrl: AUTH_URL });
    await expect(
      provider.resizeVolume({ volumeId: 'vol-1', location: 'dc4-a', sizeGb: 30 })
    ).rejects.toThrow('Detach');
  });

  it('resolves OpenStack catalogs and creates a Nova server with exact cloud-init payload', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      const url = String(input);
      if (url.endsWith('/auth/tokens')) return auth();
      if (url === `${IMAGE}/v2/images?name=Ubuntu%2024.04%20LTS%20Noble%20Numbat`)
        return json({ images: [{ id: 'image-1', name: 'Ubuntu 24.04 LTS Noble Numbat' }] });
      if (url === `${COMPUTE}/flavors/detail?name=a2-ram4-disk20-perf1`)
        return json({ flavors: [{ id: 'flavor-1', name: 'a2-ram4-disk20-perf1' }] });
      if (url === `${NETWORK}/v2.0/networks?name=ext-net1`)
        return json({ networks: [{ id: 'network-1', name: 'ext-net1' }] });
      if (url === `${COMPUTE}/servers` && init?.method === 'POST')
        return json({ server: { id: 'server-1' } }, 202);
      if (url === `${COMPUTE}/servers/server-1`)
        return json({
          server: {
            id: 'server-1',
            name: 'sam-node',
            status: 'ACTIVE',
            addresses: { 'ext-net1': [{ version: 4, addr: '203.0.113.10' }] },
            flavor: { id: 'flavor-1', original_name: 'a2-ram4-disk20-perf1' },
            created: '2026-07-25T00:00:00Z',
            metadata: { project: 'p1' },
          },
        });
      throw new Error(`Unexpected request ${init?.method ?? 'GET'} ${url}`);
    });
    const provider = new InfomaniakProvider('id', 'secret', { authUrl: AUTH_URL });
    const result = await provider.createVM({
      name: 'sam-node',
      size: 'small',
      location: 'dc4-a',
      image: 'Ubuntu 24.04 LTS Noble Numbat',
      userData: '#cloud-config\nusers: []',
      labels: {
        managed: 'simple-agent-manager',
        env: 'production',
        installation: '0123456789abcdef0123456789abcdef',
      },
    });
    expect(result).toMatchObject({ id: 'server-1', ip: '203.0.113.10', status: 'running' });
    const createCall = fetchMock.mock.calls.find(
      ([input, init]) => String(input) === `${COMPUTE}/servers` && init?.method === 'POST'
    );
    expect(JSON.parse(String(createCall?.[1]?.body))).toEqual({
      server: {
        name: 'sam-node',
        block_device_mapping_v2: [
          {
            boot_index: 0,
            uuid: 'image-1',
            source_type: 'image',
            destination_type: 'volume',
            volume_size: 80,
            delete_on_termination: true,
          },
        ],
        flavorRef: 'flavor-1',
        networks: [{ uuid: 'network-1' }],
        user_data: 'I2Nsb3VkLWNvbmZpZwp1c2VyczogW10=',
        metadata: {
          managed: 'simple-agent-manager',
          env: 'production',
          installation: '0123456789abcdef0123456789abcdef',
          'sam-root-disk-gb': '80',
        },
      },
    });
  });

  it('boots from a volume sized by the larger of the configured and requested disk', async () => {
    // Infomaniak flavors carry a 20 GB local disk, which one devcontainer build filled to 98%
    // in production. The root volume replaces it, and the workload can ask for more.
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      const url = String(input);
      if (url.endsWith('/auth/tokens')) return auth();
      if (url.startsWith(`${IMAGE}/v2/images`))
        return json({ images: [{ id: 'image-1', name: 'Ubuntu 24.04 LTS Noble Numbat' }] });
      if (url.startsWith(`${COMPUTE}/flavors/detail`))
        return json({ flavors: [{ id: 'flavor-2', name: 'a4-ram8-disk20-perf1' }] });
      if (url.startsWith(`${NETWORK}/v2.0/networks`))
        return json({ networks: [{ id: 'network-1', name: 'ext-net1' }] });
      if (url === `${COMPUTE}/servers` && init?.method === 'POST')
        return json({ server: { id: 'server-2' } }, 202);
      if (url === `${COMPUTE}/servers/server-2`) {
        return json({
          server: {
            id: 'server-2',
            name: 'sam-node',
            status: 'ACTIVE',
            addresses: { 'ext-net1': [{ version: 4, addr: '203.0.113.11' }] },
            flavor: { original_name: 'a4-ram8-disk20-perf1', vcpus: 4, ram: 8192, disk: 20 },
            created: '2026-11-13T00:00:00Z',
            metadata: { 'sam-root-disk-gb': '120' },
          },
        });
      }
      throw new Error(`Unexpected request ${init?.method ?? 'GET'} ${url}`);
    });
    const provider = new InfomaniakProvider('id', 'secret', { authUrl: AUTH_URL, rootDiskGb: 60 });
    const vm = await provider.createVM({
      name: 'sam-node',
      location: 'dc4-a',
      userData: '#cloud-config',
      labels: {},
      native: { instanceType: 'a4-ram8-disk20-perf1', bootDiskSizeGb: 120 },
    });
    const create = fetchMock.mock.calls.find(
      ([input, init]) => String(input) === `${COMPUTE}/servers` && init?.method === 'POST'
    );
    const server = JSON.parse(String(create?.[1]?.body)).server;
    expect(server.imageRef).toBeUndefined();
    // Nova rejects block_device_mapping_v2.volume_type below microversion 2.67 ("Additional
    // properties are not allowed ('volume_type' was unexpected)"), and SAM pins 2.47.
    expect(server.block_device_mapping_v2[0]).not.toHaveProperty('volume_type');
    expect(server.block_device_mapping_v2[0]).toMatchObject({
      volume_size: 120,
      delete_on_termination: true,
    });
    expect(server.metadata['sam-root-disk-gb']).toBe('120');
    // The node reports the volume it really boots from, not the flavor's 20 GB.
    expect(vm.observedHardware).toMatchObject({
      resources: { value: { vcpuCount: 4, memoryMb: 8192, diskGb: 120 } },
    });
  });

  it('requests Nova microversion 2.47 so the server body carries flavor resources', async () => {
    // Real Nova behaviour: below 2.47 a server's flavor is only { id, links }; from 2.47 it
    // embeds original_name/vcpus/ram/disk. Without them SAM marks the node "no trusted observed
    // hardware capacity" and placement refuses every workspace on it.
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      const url = String(input);
      if (url.endsWith('/auth/tokens')) return auth();
      if (url === `${COMPUTE}/servers/server-1`) {
        const version = new Headers(init?.headers).get('OpenStack-API-Version') ?? '';
        const microversion = Number(/^compute (\d+\.\d+)$/.exec(version)?.[1] ?? '2.1');
        const flavor =
          microversion >= 2.47
            ? { original_name: 'a4-ram8-disk20-perf1', vcpus: 4, ram: 8192, disk: 20 }
            : { id: '425c947f-114c-4ac2-9011-8d6640b9ccc8' };
        return json({
          server: {
            id: 'server-1',
            name: 'sam-node',
            status: 'ACTIVE',
            addresses: { 'ext-net1': [{ version: 4, addr: '203.0.113.10' }] },
            flavor,
            created: '2026-11-13T00:00:00Z',
            metadata: {},
          },
        });
      }
      throw new Error(`Unexpected request ${init?.method ?? 'GET'} ${url}`);
    });
    const provider = new InfomaniakProvider('id', 'secret', { authUrl: AUTH_URL });
    const vm = await provider.getVM('server-1');
    expect(vm?.serverType).toBe('a4-ram8-disk20-perf1');
    expect(vm?.observedHardware).toMatchObject({
      resources: { value: { vcpuCount: 4, memoryMb: 8192, diskGb: 20 } },
    });
  });

  it('uses config.instanceType as the concrete flavor name when provided', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      const url = String(input);
      if (url.endsWith('/auth/tokens')) return auth();
      if (url === `${IMAGE}/v2/images?name=Ubuntu%2024.04%20LTS%20Noble%20Numbat`)
        return json({ images: [{ id: 'image-1', name: 'Ubuntu 24.04 LTS Noble Numbat' }] });
      if (url === `${COMPUTE}/flavors/detail?name=a8-ram16-disk20-perf1`)
        return json({ flavors: [{ id: 'flavor-custom', name: 'a8-ram16-disk20-perf1' }] });
      if (url === `${NETWORK}/v2.0/networks?name=ext-net1`)
        return json({ networks: [{ id: 'network-1', name: 'ext-net1' }] });
      if (url === `${COMPUTE}/servers` && init?.method === 'POST')
        return json({ server: { id: 'server-1' } }, 202);
      if (url === `${COMPUTE}/servers/server-1`)
        return json({
          server: {
            id: 'server-1',
            name: 'sam-node',
            status: 'ACTIVE',
            addresses: { 'ext-net1': [{ version: 4, addr: '203.0.113.10' }] },
            flavor: { id: 'flavor-custom', original_name: 'a8-ram16-disk20-perf1' },
            created: '2026-07-25T00:00:00Z',
            metadata: {},
          },
        });
      throw new Error(`Unexpected request ${init?.method ?? 'GET'} ${url}`);
    });
    const provider = new InfomaniakProvider('id', 'secret', { authUrl: AUTH_URL });

    await provider.createVM({
      name: 'sam-node',
      size: 'small',
      location: 'dc4-a',
      image: 'Ubuntu 24.04 LTS Noble Numbat',
      instanceType: 'a8-ram16-disk20-perf1',
      userData: '#cloud-config\nusers: []',
    });

    const createCall = fetchMock.mock.calls.find(
      ([input, init]) => String(input) === `${COMPUTE}/servers` && init?.method === 'POST'
    );
    expect(JSON.parse(String(createCall?.[1]?.body)).server.flavorRef).toBe('flavor-custom');
  });

  it('stops IP polling at caller cancellation without another provider read', async () => {
    vi.useFakeTimers();
    let serverReads = 0;
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      const url = String(input);
      if (url.endsWith('/auth/tokens')) return auth();
      if (url.startsWith(`${IMAGE}/v2/images`))
        return json({ images: [{ id: 'image-1', name: 'Ubuntu 24.04 LTS Noble Numbat' }] });
      if (url.startsWith(`${COMPUTE}/flavors/detail`))
        return json({ flavors: [{ id: 'flavor-1', name: 'a2-ram4-disk20-perf1' }] });
      if (url.startsWith(`${NETWORK}/v2.0/networks`))
        return json({ networks: [{ id: 'network-1', name: 'ext-net1' }] });
      if (url === `${COMPUTE}/servers` && init?.method === 'POST')
        return json({ server: { id: 'server-pending' } }, 202);
      if (url === `${COMPUTE}/servers/server-pending`) {
        serverReads += 1;
        return json({
          server: {
            id: 'server-pending',
            name: 'sam-node',
            status: 'BUILD',
            addresses: {},
            flavor: { id: 'flavor-1' },
            created: '2026-08-08T00:00:00Z',
            metadata: {},
          },
        });
      }
      throw new Error(`Unexpected request ${init?.method ?? 'GET'} ${url}`);
    });
    const provider = new InfomaniakProvider('id', 'secret', {
      authUrl: AUTH_URL,
      ipPollTimeoutMs: 1_000,
      ipPollIntervalMs: 100,
    });
    const caller = new AbortController();
    const reason = new ProviderError('infomaniak', 503, 'caller cancelled IP polling');

    const outcome = provider
      .createVM(
        {
          name: 'sam-node',
          size: 'small',
          location: 'dc4-a',
          userData: '#cloud-config',
        },
        { signal: caller.signal }
      )
      .catch((error: unknown) => error);
    await vi.advanceTimersByTimeAsync(0);
    expect(serverReads).toBe(1);

    caller.abort(reason);
    await vi.runAllTimersAsync();

    expect(await outcome).toBe(reason);
    expect(serverReads).toBe(1);
    expect(fetchMock).toHaveBeenCalled();
  });

  it('lists only VMs carrying every exact ownership marker', async () => {
    vi.spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(auth())
      .mockResolvedValueOnce(
        json({
          servers: [
            {
              id: 'owned',
              name: 'node',
              status: 'ACTIVE',
              addresses: {},
              flavor: { id: 'flavor-1' },
              created: '2026-08-12T00:00:00Z',
              metadata: {
                managed: 'simple-agent-manager',
                env: 'production',
                installation: '0123456789abcdef0123456789abcdef',
              },
            },
            {
              id: 'foreign',
              name: 'node',
              status: 'ACTIVE',
              addresses: {},
              flavor: { id: 'flavor-1' },
              created: '2026-08-12T00:00:00Z',
              metadata: {
                managed: 'simple-agent-manager',
                env: 'production',
                installation: 'fedcba9876543210fedcba9876543210',
              },
            },
          ],
        })
      );
    const provider = new InfomaniakProvider('id', 'secret', { authUrl: AUTH_URL });
    await expect(
      provider.listVMs({
        managed: 'simple-agent-manager',
        env: 'production',
        installation: '0123456789abcdef0123456789abcdef',
      })
    ).resolves.toEqual([expect.objectContaining({ id: 'owned' })]);
  });

  it('attaches through Nova with the exact payload and returns stable device discovery data', async () => {
    const fetchMock = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(auth())
      .mockResolvedValueOnce(json({ volumeAttachment: { id: 'attachment-1' } }, 202))
      .mockResolvedValueOnce(
        json({ volume: volume({ status: 'in-use', attachments: [{ server_id: 'server-1' }] }) })
      );
    const provider = new InfomaniakProvider('id', 'secret', { authUrl: AUTH_URL });
    const result = await provider.attachVolume({
      volumeId: 'vol-1',
      serverId: 'server-1',
      location: 'dc4-a',
    });
    expect(fetchMock).toHaveBeenNthCalledWith(
      2,
      `${COMPUTE}/servers/server-1/os-volume_attachments`,
      expect.objectContaining({
        method: 'POST',
        body: JSON.stringify({ volumeAttachment: { volumeId: 'vol-1' } }),
      })
    );
    expect(result).toMatchObject({
      attachedServerId: 'server-1',
      status: 'attached',
      linuxDevice: '/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_vol-1',
    });
  });

  it('extends a detached Cinder volume with the exact grow-only action payload', async () => {
    const fetchMock = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(auth())
      .mockResolvedValueOnce(json({ volume: volume({ size: 20 }) }))
      .mockResolvedValueOnce(new Response(null, { status: 202 }))
      .mockResolvedValueOnce(json({ volume: volume({ size: 40 }) }));
    const provider = new InfomaniakProvider('id', 'secret', { authUrl: AUTH_URL });
    const result = await provider.resizeVolume({
      volumeId: 'vol-1',
      location: 'dc4-a',
      sizeGb: 40,
      currentSizeGb: 20,
    });
    expect(fetchMock).toHaveBeenNthCalledWith(
      3,
      `${VOLUME}/volumes/vol-1/action`,
      expect.objectContaining({
        method: 'POST',
        body: JSON.stringify({ 'os-extend': { new_size: 40 } }),
      })
    );
    expect(result.sizeGb).toBe(40);
  });

  it('normalizes status and errors', () => {
    expect(mapInfomaniakStatus('ACTIVE')).toBe('running');
    expect(mapInfomaniakStatus('SHUTOFF')).toBe('off');
    expect(classifyInfomaniakError(401, '')).toBe('auth_error');
    expect(classifyInfomaniakError(409, 'Quota exceeded')).toBe('quota_exceeded');
    expect(classifyInfomaniakError(503, 'No valid host')).toBe('transient_capacity');
    expect(new ProviderError('infomaniak', 400, 'bad').providerName).toBe('infomaniak');
  });
});
