import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { formBindingData, formProvider } from '@kit.FormKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ProactiveResponse } from '../api/ApiModels';
import { TodayOverview } from '../api/ReminderModels';
import { TodayRecommendations } from '../utils/TodayRecommendations';

const DOMAIN: number = 0x5A01;
const TAG: string = 'LearningCard';

export interface LearningCardData {
  eventId?: string;
  eventVersion?: number;
  userId: string;
  title: string;
  taskName: string;
  reason: string;
  durationText: string;
  durationMinutes: number;
  actionText: string;
}

interface RegisteredForm {
  id: string;
  compact: boolean;
}

export class LearningCardService {
  static async saveOverview(context: common.Context, overview: TodayOverview, recommendationId: string): Promise<void> {
    const event = TodayRecommendations.select(overview, recommendationId);
    const data: LearningCardData = { userId: overview.userId, eventId: event?.eventId ?? '',
      eventVersion: event?.version ?? 0, title: '今日重点', taskName: event?.title ?? '今日暂无推荐',
      reason: event?.reason ?? overview.guidance, durationText: event ? `${event.durationMinutes} 分钟` : '打开查看安排',
      durationMinutes: event?.durationMinutes ?? 0, actionText: '打开核对任务' };
    await LearningCardService.publish(context, data);
  }
  private static readonly STORE_NAME: string = 'learning_card';
  private static readonly KEY_DATA: string = 'data';
  private static readonly KEY_FORM_IDS: string = 'form_ids';
  private static formUpdates: Promise<void> = Promise.resolve();

  static defaultData(): LearningCardData {
    return {
      userId: '',
      title: '今日学习建议',
      taskName: '打开知学Mate，生成当前任务',
      reason: '根据考试、薄弱点和可用时间，给出下一步行动。',
      durationText: '待生成',
      durationMinutes: 30,
      actionText: '开始专注'
    };
  }

  static read(context: common.Context): LearningCardData {
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, {
        name: LearningCardService.STORE_NAME
      });
      const raw: string = store.getSync(LearningCardService.KEY_DATA, '') as string;
      if (raw.length === 0) return LearningCardService.defaultData();
      const parsed: LearningCardData = JSON.parse(raw) as LearningCardData;
      return parsed.taskName.length > 0 ? parsed : LearningCardService.defaultData();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '%{public}s', `Read card snapshot failed: ${JSON.stringify(error)}`);
      return LearningCardService.defaultData();
    }
  }

  static registerForm(context: common.Context, formId: string, compact: boolean): void {
    if (formId.length === 0) return;
    const registrations: RegisteredForm[] = LearningCardService.readForms(context)
      .filter((item: RegisteredForm) => item.id !== formId);
    registrations.push({ id: formId, compact: compact });
    LearningCardService.writeForms(context, registrations);
  }

  static unregisterForm(context: common.Context, formId: string): void {
    const registrations: RegisteredForm[] = LearningCardService.readForms(context)
      .filter((item: RegisteredForm) => item.id !== formId);
    LearningCardService.writeForms(context, registrations);
  }

  static async saveDecision(context: common.Context, decision: ProactiveResponse): Promise<void> {
    const data: LearningCardData = LearningCardService.fromDecision(decision);
    data.userId = typeof decision.userId === 'string' ? decision.userId : '';
    const existing: LearningCardData = LearningCardService.read(context);
    const identityChanged: boolean = existing.userId !== data.userId;
    const actionable: boolean = data.taskName.trim().length > 0 && data.title.trim().length > 0;
    if (!identityChanged && !actionable) {
      return;
    }
    await LearningCardService.publish(context, data);
  }

  private static async publish(context: common.Context, data: LearningCardData): Promise<void> {
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, {
        name: LearningCardService.STORE_NAME
      });
      store.putSync(LearningCardService.KEY_DATA, JSON.stringify(data));
      store.flushSync();
      LearningCardService.formUpdates = LearningCardService.formUpdates
        .then(() => LearningCardService.updateRegisteredForms(context, LearningCardService.read(context)))
        .catch((error: Error) => { hilog.warn(DOMAIN, TAG, '%{public}s', `Update forms failed: ${error.message}`); });
      await LearningCardService.formUpdates;
    } catch (error) {
      hilog.error(DOMAIN, TAG, '%{public}s', `Save card snapshot failed: ${JSON.stringify(error)}`);
    }
  }

  static fromDecision(decision: ProactiveResponse): LearningCardData {
    const minutes: number | undefined = decision.action.preset.durationMinutes ?? decision.cardData.durationMinutes;
    return {
      userId: '',
      title: decision.title.length > 0 ? decision.title : '今日学习建议',
      taskName: decision.cardData.taskName ?? decision.body,
      reason: decision.reason.length > 0 ? decision.reason : decision.body,
      durationText: minutes === undefined ? '按计划完成' : `${minutes} 分钟`,
      durationMinutes: minutes === undefined ? 30 : minutes,
      actionText: '开始专注'
    };
  }

  static bindingData(data: LearningCardData, compact: boolean = false): formBindingData.FormBindingData {
    return formBindingData.createFormBindingData({
      cardTitle: data.title,
      eventId: data.eventId ?? '',
      eventVersion: data.eventVersion ?? 0,
      taskName: data.taskName,
      reason: data.reason,
      durationText: data.durationText,
      durationMinutes: data.durationMinutes ?? 30,
      actionText: data.actionText,
      isCompact: compact
    });
  }

  static async updateForm(context: common.Context, formId: string): Promise<void> {
    if (formId.length === 0) return;
    try {
      const registration: RegisteredForm | undefined = LearningCardService.readForms(context)
        .find((item: RegisteredForm) => item.id === formId);
      await formProvider.updateForm(formId, LearningCardService.bindingData(
        LearningCardService.read(context), registration?.compact ?? false));
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '%{public}s', `Update form failed: ${JSON.stringify(error)}`);
    }
  }

  private static async updateRegisteredForms(context: common.Context, data: LearningCardData): Promise<void> {
    const registrations: RegisteredForm[] = LearningCardService.readForms(context);
    for (let index: number = 0; index < registrations.length; index++) {
      try {
        const registration: RegisteredForm = registrations[index];
        await formProvider.updateForm(registration.id,
          LearningCardService.bindingData(data, registration.compact));
      } catch (error) {
        hilog.warn(DOMAIN, TAG, '%{public}s',
          `Update ${registrations[index].id} failed: ${JSON.stringify(error)}`);
      }
    }
  }

  private static readForms(context: common.Context): RegisteredForm[] {
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, {
        name: LearningCardService.STORE_NAME
      });
      const raw: string = store.getSync(LearningCardService.KEY_FORM_IDS, '[]') as string;
      const parsed: Object[] = JSON.parse(raw) as Object[];
      const registrations: RegisteredForm[] = [];
      for (let index: number = 0; index < parsed.length; index++) {
        const item: Object = parsed[index];
        if (typeof item === 'string') {
          registrations.push({ id: item as string, compact: false });
        } else {
          registrations.push(item as RegisteredForm);
        }
      }
      return registrations;
    } catch (error) {
      return [];
    }
  }

  private static writeForms(context: common.Context, registrations: RegisteredForm[]): void {
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, {
        name: LearningCardService.STORE_NAME
      });
      store.putSync(LearningCardService.KEY_FORM_IDS, JSON.stringify(registrations));
      store.flushSync();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '%{public}s', `Persist form ids failed: ${JSON.stringify(error)}`);
    }
  }
}
