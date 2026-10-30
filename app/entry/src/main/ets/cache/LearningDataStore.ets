import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { CourseInfo, HomeworkDDL, FocusSession, PlanTaskStatus, FocusRuntime } from '../models/AgentModels';
import { LearningChanges } from '../api/LearningSyncModels';
import { AgentApiClient } from '../api/AgentApiClient';

export interface StoredTaskStatus {
  taskId: string;
  status: PlanTaskStatus;
}

/**
 * 一份账号隔离的课程与 DDL 快照。
 *
 * 服务端保存课程和作业事实；这里按账号与接口环境保存缓存及离线操作队列。
 * 旧版设备数据只迁移一次，不能用本机的空列表替换服务端数据。
 */
export interface StoredLearningData {
  syncQueue?: LearningChanges[];
  cloudInitialized?: boolean;
  courses: CourseInfo[];
  homeworkDDLs: HomeworkDDL[];
  isDataImported: boolean;
  focusSessions?: FocusSession[];
  pendingFocusSessions?: FocusSession[];
  taskStatuses?: StoredTaskStatus[];
  focusRuntime?: FocusRuntime;
  focusResultDraft?: FocusSession;
}

export class LearningDataStore {
  private static readonly STORE_NAME: string = 'account_learning_data';
  private static readonly KEY_PREFIX: string = 'learning_data_';
  private static context: common.UIAbilityContext | null = null;

  static initialize(context: common.UIAbilityContext): void {
    LearningDataStore.context = context;
  }

  static load(userId: string): StoredLearningData {
    const empty: StoredLearningData = {
      courses: [],
      homeworkDDLs: [],
      isDataImported: false
    };
    if (LearningDataStore.context === null || userId.trim().length === 0) return empty;
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(LearningDataStore.context, {
        name: LearningDataStore.STORE_NAME
      });
      let raw: string = store.getSync(LearningDataStore.key(userId), '') as string;
      if (!raw) {
        const claim: string = `legacy_environment_${encodeURIComponent(userId)}`;
        const environment: string = LearningDataStore.environment();
        const claimed: string = store.getSync(claim, '') as string;
        if (!claimed || claimed === environment) {
          raw = store.getSync(LearningDataStore.KEY_PREFIX + encodeURIComponent(userId.trim()), '') as string;
          if (raw) { store.putSync(claim, environment); store.flushSync(); }
        }
      }
      if (raw.length === 0) return empty;
      const parsed: StoredLearningData = JSON.parse(raw) as StoredLearningData;
      const courses: CourseInfo[] = Array.isArray(parsed.courses) ? parsed.courses : [];
      const ddls: HomeworkDDL[] = Array.isArray(parsed.homeworkDDLs) ? parsed.homeworkDDLs : [];
      return {
        syncQueue: Array.isArray(parsed.syncQueue) ? parsed.syncQueue : [],
        cloudInitialized: parsed.cloudInitialized === true,
        courses: courses,
        homeworkDDLs: ddls,
        isDataImported: parsed.isDataImported === true,
        focusSessions: Array.isArray(parsed.focusSessions) ? parsed.focusSessions : [],
        pendingFocusSessions: Array.isArray(parsed.pendingFocusSessions) ? parsed.pendingFocusSessions : [],
        taskStatuses: Array.isArray(parsed.taskStatuses) ? parsed.taskStatuses : [],
        focusRuntime: parsed.focusRuntime,
        focusResultDraft: parsed.focusResultDraft
      };
    } catch (error) {
      return empty;
    }
  }

  static save(userId: string, data: StoredLearningData): boolean {
    if (LearningDataStore.context === null || userId.trim().length === 0) return false;
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(LearningDataStore.context, {
        name: LearningDataStore.STORE_NAME
      });
      store.putSync(LearningDataStore.key(userId), JSON.stringify(data));
      store.flushSync();
      return true;
    } catch (error) {
      return false;
    }
  }

  /** userId 来自服务端，编码后再作为 preferences key，避免特殊字符破坏键名。 */
  private static key(userId: string): string {
    return LearningDataStore.KEY_PREFIX + encodeURIComponent(LearningDataStore.environment()) + '_' + encodeURIComponent(userId.trim());
  }
  static environment(): string {
    const config = AgentApiClient.getConfig();
    return config.useFixture ? 'fixture' : config.baseUrl;
  }
}
