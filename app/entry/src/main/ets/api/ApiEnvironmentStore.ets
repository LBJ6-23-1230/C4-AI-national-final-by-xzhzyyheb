import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { AgentApiClient, ApiClientConfig } from './AgentApiClient';
import { ApiDefaults } from './ApiDefaults';

export class ApiEnvironmentStore {
  private static readonly STORE_NAME: string = 'api_environment';
  private static readonly KEY_BASE_URL: string = 'base_url';
  private static readonly KEY_USE_FIXTURE: string = 'use_fixture';
  private static readonly KEY_TIMEOUT_MS: string = 'timeout_ms';

  static restore(context: common.UIAbilityContext): boolean {
    if (!ApiDefaults.ALLOW_DEBUG) {
      AgentApiClient.configure({ baseUrl: ApiDefaults.DEFAULT_BASE_URL, useFixture: false,
        timeoutMs: ApiDefaults.DEFAULT_TIMEOUT_MS });
      return true;
    }
    try {
      const defaults: ApiClientConfig = AgentApiClient.getConfig();
      const store: preferences.Preferences = preferences.getPreferencesSync(context, {
        name: ApiEnvironmentStore.STORE_NAME
      });
      const savedUrl = store.getSync(ApiEnvironmentStore.KEY_BASE_URL, defaults.baseUrl) as string;
      const repairUsb = ApiDefaults.ALLOW_USB_HUAWEI_LOGIN &&
        AgentApiClient.parseBackendOrigin(savedUrl) === ApiDefaults.USB_MISTYPED_HTTPS_URL;
      AgentApiClient.configure({
        baseUrl: repairUsb ? ApiDefaults.LOCALHOST_BASE_URL : savedUrl,
        useFixture: store.getSync(ApiEnvironmentStore.KEY_USE_FIXTURE, defaults.useFixture) as boolean,
        timeoutMs: store.getSync(ApiEnvironmentStore.KEY_TIMEOUT_MS, defaults.timeoutMs) as number
      });
      if (repairUsb) ApiEnvironmentStore.save(context, AgentApiClient.getConfig());
      return true;
    } catch (error) {
      return false;
    }
  }

  static save(context: common.UIAbilityContext, config: ApiClientConfig): boolean {
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, {
        name: ApiEnvironmentStore.STORE_NAME
      });
      store.putSync(ApiEnvironmentStore.KEY_BASE_URL, config.baseUrl);
      store.putSync(ApiEnvironmentStore.KEY_USE_FIXTURE, config.useFixture);
      store.putSync(ApiEnvironmentStore.KEY_TIMEOUT_MS, config.timeoutMs);
      store.flushSync();
      return true;
    } catch (error) {
      return false;
    }
  }
}
