import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { TodayOverview } from '../api/ReminderModels';
import { ApiResponseValidator } from '../api/ApiResponseValidator';
import { AgentApiClient } from '../api/AgentApiClient';

export class TodayStore {
  private static readonly STORE_NAME: string = 'today_overview';

  static key(owner: string): string {
    const config = AgentApiClient.getConfig();
    return `${config.useFixture ? 'fixture' : config.baseUrl}:${owner}`;
  }
  static firstDisplay(context: common.Context, owner: string): boolean {
    try {
      const store = preferences.getPreferencesSync(context, { name: 'today_panel_preferences' });
      if (store.getSync(TodayStore.key(owner), false) as boolean) return false;
      store.putSync(TodayStore.key(owner), true); store.flushSync(); return true;
    } catch (_) { return false; }
  }
  static read(context: common.Context, owner: string): TodayOverview | null {
    try {
      const store = preferences.getPreferencesSync(context, { name: TodayStore.STORE_NAME });
      const raw: string = store.getSync(TodayStore.key(owner), '') as string;
      if (!raw) return null;
      const data: TodayOverview = JSON.parse(raw) as TodayOverview;
      return data.userId === owner && ApiResponseValidator.isValid('GET', '/api/v1/today', data) ? data : null;
    } catch (_) { return null; }
  }
  static save(context: common.Context, data: TodayOverview): void {
    try {
      const store = preferences.getPreferencesSync(context, { name: TodayStore.STORE_NAME });
      store.putSync(TodayStore.key(data.userId), JSON.stringify(data)); store.flushSync();
    } catch (_) {                                                        }
  }

  static readRecommendationId(context: common.Context, owner: string): string {
    try {
      const store = preferences.getPreferencesSync(context, { name: TodayStore.STORE_NAME });
      return store.getSync(`selection:${TodayStore.key(owner)}`, '') as string;
    } catch (_) { return ''; }
  }

  static saveRecommendationId(context: common.Context, owner: string, eventId: string): void {
    try {
      const store = preferences.getPreferencesSync(context, { name: TodayStore.STORE_NAME });
      store.putSync(`selection:${TodayStore.key(owner)}`, eventId);
      store.flushSync();
    } catch (_) {                                                                   }
  }
}
