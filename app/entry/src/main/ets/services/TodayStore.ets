import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { TodayOverview } from '../api/ReminderModels';
import { ApiResponseValidator } from '../api/ApiResponseValidator';

/** Persistent cache is keyed by account and only used after identity recovery. */
export class TodayStore {
  static read(context: common.Context, owner: string): TodayOverview | null {
    try {
      const store = preferences.getPreferencesSync(context, { name: 'today_overview' });
      const raw: string = store.getSync(owner, '') as string;
      if (!raw) return null;
      const data: TodayOverview = JSON.parse(raw) as TodayOverview;
      return data.userId === owner && ApiResponseValidator.isValid('GET', '/api/v1/today', data) ? data : null;
    } catch (_) { return null; }
  }
  static save(context: common.Context, data: TodayOverview): void {
    try {
      const store = preferences.getPreferencesSync(context, { name: 'today_overview' });
      store.putSync(data.userId, JSON.stringify(data)); store.flushSync();
    } catch (_) { /* A failed cache write never changes server state. */ }
  }
}
