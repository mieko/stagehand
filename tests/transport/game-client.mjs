import { connect as connectStagehand, forwardMethods } from './addons/stagehand/client.mjs';
export * from './addons/stagehand/client.mjs';

export function connect(address, options = {}) {
  return connectStagehand(address, {
    ...options,
    wrappers: {
      Fixture: forwardMethods(['echo']),
      ...options.wrappers,
    },
  });
}
