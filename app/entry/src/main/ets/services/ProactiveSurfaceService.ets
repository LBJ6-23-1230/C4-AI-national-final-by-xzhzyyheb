import { ReminderDeviceService } from './ReminderDeviceService';
import { common, wantAgent } from '@kit.AbilityKit';
import notificationManager from '@ohos.notificationManager';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AgentApiClient } from '../api/AgentApiClient';
import { ProactiveResponse } from '../api/ApiModels';
import { ApiFailure } from '../api/ApiResult';
import { appState } from '../data/AppState';
import { ProactiveViewModel } from '../viewmodels/ProactiveViewModel';
import { ProactiveSettingsStore } from './ProactiveSettingsStore';
import { LearningCardService } from './LearningCardService';

const DOMAIN: number = 0x5A01;
const TAG: string = 'ProactiveSurface';

/** Refreshes every visible proactive surface after a learning-state event. */
export class ProactiveSurfaceService {
  static async refresh(context: common.UIAbilityContext, foreground: boolean): Promise<void> {
    if (!AppStorage.get<boolean>('identityReady')) return;
    const owner: string = appState.currentUser.userId;
    const result = await AgentApiClient.getToday();
    if (owner !== appState.currentUser.userId) return;
    if (result.ok) await LearningCardService.saveOverview(context, result.data);
    ReminderDeviceService.heartbeat(context, foreground);
  }

  static async requestPermission(context: common.UIAbilityContext): Promise<boolean> {
    try {
      if (await notificationManager.isNotificationEnabled()) return true;
      await notificationManager.requestEnableNotification(context);
      return await notificationManager.isNotificationEnabled();
    } catch (error) {
      hilog.error(DOMAIN, TAG, '%{public}s', `Notification permission failed: ${JSON.stringify(error)}`);
      return false;
    }
  }
}
