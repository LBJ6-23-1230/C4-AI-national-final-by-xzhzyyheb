import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { pushService } from '@kit.PushKit';
import notificationManager from '@ohos.notificationManager';
import { AgentApiClient } from '../api/AgentApiClient';
import { appState } from '../data/AppState';

export class ReminderDeviceService {
  static lastSync: string = '';
  static status: string = 'unknown';
  private static timer: number = -1;
  static heartbeat(context: common.Context, foreground: boolean): void {
    if (ReminderDeviceService.timer !== -1) clearInterval(ReminderDeviceService.timer);
    ReminderDeviceService.timer = -1;
    if (foreground) ReminderDeviceService.timer = setInterval(() => { void ReminderDeviceService.sync(context, true); }, 60000);
    void ReminderDeviceService.sync(context, foreground);
  }
  static async sync(context: common.Context, foreground: boolean): Promise<void> {
    const owner: string = appState.currentUser.userId;
    ReminderDeviceService.status = 'unknown';
    if (owner === 'demo-user' || AgentApiClient.getConfig().useFixture) return;
    try {
      const store = preferences.getPreferencesSync(context, { name: 'reminder_installation' });
      let id: string = store.getSync('id', '') as string;
      if (!id) {
        id = `device-${Date.now()}-${Math.random().toString(36).slice(2)}-${Math.random().toString(36).slice(2)}`;
        store.putSync('id', id); store.flushSync();
      }
      const permission: boolean = await notificationManager.isNotificationEnabled();
      let token: string = '';
      if (permission) { try { token = await pushService.getToken(); } catch (_) { token = ''; } }
      if (owner !== appState.currentUser.userId) return;
      const result = await AgentApiClient.bindReminderDevice({ deviceId: id, pushToken: token, permission: permission,
        foreground: foreground, focusing: appState.focusRuntime !== null && !appState.focusRuntime.paused });
      if (owner !== appState.currentUser.userId) return;
      if (result.ok) {
        ReminderDeviceService.lastSync = result.data.lastActive;
        ReminderDeviceService.status = result.data.active && result.data.hasToken && permission ? 'ready' : 'unavailable';
      } else ReminderDeviceService.status = 'failed';
    } catch (_) { if (owner === appState.currentUser.userId) ReminderDeviceService.status = 'failed'; }
  }
}
