import { ProviderError } from './types';

/**
 * Infomaniak's general-purpose flavors include only a 20 GB local root disk, which a single
 * devcontainer build can fill. Servers therefore boot from a Cinder volume sized for the
 * workload, deleted together with the server (`delete_on_termination`).
 */
export const DEFAULT_INFOMANIAK_ROOT_DISK_GB = 80;
/** Server metadata key recording the root volume size, read back as observed hardware. */
export const INFOMANIAK_ROOT_DISK_METADATA_KEY = 'sam-root-disk-gb';

/** The root volume is the configured size, or the workload's requested size when larger. */
export function resolveInfomaniakRootDiskGb(
  configuredGb: number,
  requestedGb: number | undefined,
  maxGb: number
): number {
  const sizeGb = Math.max(configuredGb, requestedGb ?? 0);
  if (!Number.isInteger(sizeGb) || sizeGb < 1 || sizeGb > maxGb)
    throw new ProviderError('infomaniak', 400, `Infomaniak root disk must be 1-${maxGb} GB`, {
      category: 'invalid_config',
    });
  return sizeGb;
}

/**
 * Nova `server` fields that boot from a new image-backed volume instead of the flavor disk.
 * No `volume_type`: Nova accepts it in a block device mapping only from microversion 2.67, and
 * SAM pins 2.47 (INFOMANIAK_COMPUTE_MICROVERSION), so the volume gets the project's default type.
 */
export function infomaniakBootVolumeFields(imageRef: string, sizeGb: number) {
  return {
    block_device_mapping_v2: [
      {
        boot_index: 0,
        uuid: imageRef,
        source_type: 'image',
        destination_type: 'volume',
        volume_size: sizeGb,
        delete_on_termination: true,
      },
    ],
  };
}

/** Root disk size SAM recorded at create time, or undefined for servers booted from the flavor. */
export function recordedInfomaniakRootDiskGb(labels: Record<string, string>): number | undefined {
  const raw = labels[INFOMANIAK_ROOT_DISK_METADATA_KEY];
  if (raw === undefined || !/^[1-9]\d*$/.test(raw)) return undefined;
  return Number(raw);
}
