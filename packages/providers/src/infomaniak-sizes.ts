import type { VMSize } from '@simple-agent-manager/shared';

import { DEFAULT_INFOMANIAK_ROOT_DISK_GB } from './infomaniak-boot-volume';
import type { SizeConfig } from './types';

export const INFOMANIAK_FLAVORS: Readonly<Record<VMSize, string>> = {
  small: 'a2-ram4-disk20-perf1',
  medium: 'a4-ram8-disk20-perf1',
  large: 'a8-ram16-disk20-perf1',
};
// storageGb is the boot volume SAM creates (infomaniak-boot-volume.ts), not the flavor's 20 GB.
const ROOT_GB = DEFAULT_INFOMANIAK_ROOT_DISK_GB;
export const INFOMANIAK_SIZE_CONFIGS: Readonly<Record<VMSize, SizeConfig>> = {
  small: {
    type: INFOMANIAK_FLAVORS.small,
    price: 'usage-based',
    vcpu: 2,
    ramGb: 4,
    storageGb: ROOT_GB,
  },
  medium: {
    type: INFOMANIAK_FLAVORS.medium,
    price: 'usage-based',
    vcpu: 4,
    ramGb: 8,
    storageGb: ROOT_GB,
  },
  large: {
    type: INFOMANIAK_FLAVORS.large,
    price: 'usage-based',
    vcpu: 8,
    ramGb: 16,
    storageGb: ROOT_GB,
  },
};

export function mergeInfomaniakLegacySizes(
  flavors: Partial<Record<VMSize, string>> | undefined
): Readonly<Record<VMSize, SizeConfig>> {
  if (!flavors) return INFOMANIAK_SIZE_CONFIGS;
  return {
    small: { ...INFOMANIAK_SIZE_CONFIGS.small, ...(flavors.small ? { type: flavors.small } : {}) },
    medium: {
      ...INFOMANIAK_SIZE_CONFIGS.medium,
      ...(flavors.medium ? { type: flavors.medium } : {}),
    },
    large: { ...INFOMANIAK_SIZE_CONFIGS.large, ...(flavors.large ? { type: flavors.large } : {}) },
  };
}
