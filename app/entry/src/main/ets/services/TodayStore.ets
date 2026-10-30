import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { TodayOverview } from '../api/ReminderModels';
import { ApiResponseValidator } from '../api/ApiResponseValidator';
import { AgentApiClient } from '../api/AgentApiClient';

/** Persistent cache is keyed by account and only used after identity recovery. */
export class TodayStore {
  private static key(owner: string): string { return `${AgentApiClient.getConfig().baseUrl}:${owner}`; }
  static firstDisplay(context: common.Context, owner: string): boolean {
    try {
      const store = preferences.getPreferencesSync(context, { name: 'today_panel_preferences' });
      if (store.getSync(TodayStore.key(owner), false) as boolean) return false;
      store.putSync(TodayStore.key(owner), true); store.flushSync(); return true;
    } catch (_) { return false; }
  }
  static read(context: common.Context, owner: string): TodayOverview | null {
    try {
      const store = preferences.getPreferencesSync(context, { name: 'today_overview' });
      const raw: string = store.getSync(TodayStore.key(owner), '') as string;
      if (!raw) return null;
      const data: TodayOverview = JSON.parse(raw) as TodayOverview;
      return data.userId === owner && ApiResponseValidator.isValid('GET', '/api/v1/today', data) ? data : null;
    } catch (_) { return null; }
  }
  static save(context: common.Context, data: TodayOverview): void {
    try {
      const store = preferences.getPreferencesSync(context, { name: 'today_overview' });
      store.putSync(TodayStore.key(data.userId), JSON.stringify(data)); store.flushSync();
    } catch (_) { /* A failed cache write never changes server state. */ }
  }
}
