import {
  CourseInfo,
  HomeworkDDL,
  LearningReview,
  PartnerMatch,
  StudySuggestion,
  UserProfile,
  WrongAnalysisResult,
  WrongQuestionImage,
  WorkflowContext,
  WorkflowStage,
  NavigationIntent,
  TaskPriority,
  WeaknessJudgment,
  MatchFeasibility,
  FocusTask,
  FocusSession,
  FocusRuntime,
  FocusSummary,
  LearningPlanTask,
  WeeklyLearningPlan,
  PlanTaskStatus
} from '../models/AgentModels';
import { ChatCourseUpdate, ChatHandoff, ChatProfileUpdates, ChatTaskUpdate } from '../models/ChatModels';
import { AgentApiClient } from '../api/AgentApiClient';
import { ApiDefaults } from '../api/ApiDefaults';
import { AuthSource, AuthUser } from '../api/AuthModels';
import {
  LearningPlan as VisiblePlan,
  PlanTask as VisiblePlanTask,
  PlanTaskStatus as VisiblePlanTaskStatus
} from '../api/ApiModels';
import {
  mockCurrentUser,
  mockCoursesList,
  mockHomeworkDDLs,
  mockCandidates
} from './MockData';
import { DateHelper } from '../utils/DateHelper';
import { FocusClock } from '../utils/FocusClock';
import { ClientCache } from '../cache/ClientCache';
import { LearningDataStore, StoredLearningData, StoredTaskStatus } from '../cache/LearningDataStore';
import { LearningSync } from '../services/LearningSync';
import { LearningSnapshot } from '../api/LearningSyncModels';

export class AppState {
  private static instance: AppState;
  private knowledgeSyncVersion: number = 0;
  private learningSync: LearningSync = new LearningSync();
  private learningEnvironment: string = '';

  public async syncLearningData(): Promise<boolean> {
    if (this.learningEnvironment !== LearningDataStore.environment()) this.restoreLearningData(this.currentUser.userId);
    if (!this.isSignedIn || AgentApiClient.getConfig().useFixture) return true;
    const owner: string = this.currentUser.userId;
    const engine: LearningSync = this.learningSync;
    const environment: string = AgentApiClient.getConfig().baseUrl;
    const current = (): boolean => this.isSignedIn && this.currentUser.userId === owner &&
      this.learningSync === engine && AgentApiClient.getConfig().baseUrl === environment;
    const snapshot: LearningSnapshot | null = await engine.sync(owner, current);
    if (!current()) return false;
    if (snapshot !== null && engine.queue.length === 0) {
      engine.accept(snapshot);
      this.courses = snapshot.courses;
      this.homeworkDDLs = snapshot.homeworkDDLs;
      this.importedCourseCount = this.courses.length;
      this.importedDDLCount = this.homeworkDDLs.length;
      this.isDataImported = this.courses.length + this.homeworkDDLs.length > 0;
      this.homeworkDDLs.forEach((item: HomeworkDDL) => {
        if (item.completed) this.taskStatusOverrides.set(item.id, 'completed');
      });
      this.notifyLearningDataChanged();
    }
    AppStorage.setOrCreate('learningSyncMessage', engine.message);
    AppStorage.setOrCreate('learningSyncConflict', engine.conflict);
    this.saveLearningSnapshot();
    if (snapshot !== null && engine.queue.length > 0) return this.syncLearningData();
    return snapshot !== null;
  }

  public async useServerLearningData(): Promise<void> {
    if (this.learningSync.running) return;
    const owner: string = this.currentUser.userId;
    const cloud = await AgentApiClient.getLearningData();
    if (owner !== this.currentUser.userId) return;
    if (!cloud.ok || cloud.data.userId !== owner) { AppStorage.setOrCreate('learningSyncMessage', '同步失败，请重试。'); return; }
    const saved: boolean = LearningDataStore.save(`conflict-backup-${this.currentUser.userId}-${Date.now()}`, {
      courses: this.courses, homeworkDDLs: this.homeworkDDLs, isDataImported: this.isDataImported,
      syncQueue: this.learningSync.queue, cloudInitialized: this.learningSync.initialized });
    if (!saved) { AppStorage.setOrCreate('learningSyncMessage', '本机备份失败，请重试。'); return; }
    this.learningSync = new LearningSync();
    this.learningSync.restore(cloud.data.courses, cloud.data.homeworkDDLs, [], true);
    this.courses = cloud.data.courses; this.homeworkDDLs = cloud.data.homeworkDDLs;
    this.isDataImported = this.courses.length + this.homeworkDDLs.length > 0;
    this.importedCourseCount = this.courses.length; this.importedDDLCount = this.homeworkDDLs.length;
    this.saveLearningSnapshot(); this.notifyLearningDataChanged();
    AppStorage.setOrCreate('learningSyncConflict', false);
    AppStorage.setOrCreate('learningSyncMessage', '已恢复云端数据，本机修改已备份。');
  }

  public async keepLocalLearningChanges(): Promise<void> {
    if (this.learningSync.running) return;
    const owner: string = this.currentUser.userId;
    const engine: LearningSync = this.learningSync;
    const cloud = await AgentApiClient.getLearningData();
    if (owner !== this.currentUser.userId || engine !== this.learningSync) return;
    if (!cloud.ok || cloud.data.userId !== owner) { AppStorage.setOrCreate('learningSyncMessage', '同步失败，请重试。'); return; }
    engine.keepLocal(cloud.data);
    this.saveLearningSnapshot();
    await this.syncLearningData();
  }

  public notifyLearningDataChanged(): void {
    AppStorage.setOrCreate('learningDataRevision', (AppStorage.get<number>('learningDataRevision') ?? 0) + 1);
  }

  private notifyFocusDataChanged(): void {
    AppStorage.setOrCreate('focusDataRevision', (AppStorage.get<number>('focusDataRevision') ?? 0) + 1);
  }

  public markIdentityPending(): void {
    AppStorage.setOrCreate('identityReady', false);
  }

  public markIdentityReady(): void {
    AppStorage.setOrCreate('identityReady', true);
  }

  private persistLearningData(): boolean {
    if (this.learningEnvironment !== LearningDataStore.environment()) {
      this.restoreLearningData(this.currentUser.userId);
      AppStorage.setOrCreate('learningSyncMessage', '接口环境已变化，请重新打开页面。');
      return false;
    }
    this.homeworkDDLs.forEach((item: HomeworkDDL) => item.completed = this.isTaskCompleted(item.id, 'pending'));
    this.learningSync.capture(this.courses, this.homeworkDDLs);
    const saved: boolean = this.saveLearningSnapshot();
    if (saved && this.learningSync.queue.length > 0) void this.syncLearningData();
    return saved;
  }

  private saveLearningSnapshot(): boolean {
    const statuses: StoredTaskStatus[] = [];
    this.taskStatusOverrides.forEach((status: PlanTaskStatus, taskId: string) => {
      statuses.push({ taskId: taskId, status: status });
    });
    const snapshot: StoredLearningData = {
      syncQueue: this.learningSync.queue,
      cloudInitialized: this.learningSync.initialized,
      courses: this.courses,
      homeworkDDLs: this.homeworkDDLs,
      isDataImported: this.isDataImported,
      focusSessions: this.focusSessions,
      pendingFocusSessions: this.pendingFocusSessions,
      taskStatuses: statuses,
      focusRuntime: this.focusRuntime ?? undefined,
      focusResultDraft: this.focusResultDraft ?? undefined
    };
    if (!LearningDataStore.save(this.currentUser.userId, snapshot)) {
      console.warn('学习记录本地持久化失败');
      return false;
    }
    return true;
  }

  private restoreLearningData(userId: string): void {
    this.learningEnvironment = LearningDataStore.environment();
    const saved: StoredLearningData = LearningDataStore.load(userId);
    this.courses = saved.courses;
    this.homeworkDDLs = saved.homeworkDDLs;
    this.learningSync = new LearningSync();
    this.learningSync.restore(this.courses, this.homeworkDDLs, saved.syncQueue ?? [], saved.cloudInitialized ?? false);
    this.isDataImported = saved.isDataImported;
    this.importedCourseCount = saved.courses.length;
    this.importedDDLCount = saved.homeworkDDLs.length;
    this.focusSessions = saved.focusSessions ?? [];
    this.pendingFocusSessions = saved.pendingFocusSessions ?? [];
    this.focusRuntime = FocusClock.valid(saved.focusRuntime, userId) ? (saved.focusRuntime ?? null) : null;
    this.focusResultDraft = saved.focusResultDraft ?? null;
    if (this.focusResultDraft !== null && this.focusSessions.some(
      (item: FocusSession) => item.taskId === this.focusResultDraft?.taskId)) this.focusResultDraft = null;
    if (this.focusResultDraft !== null) this.focusRuntime = null;
    if (this.focusRuntime !== null && this.focusRuntime.shared !== true && this.focusRuntime.task.mode !== 'strict' &&
      this.focusRuntime.task.allowBackgroundTiming !== true && this.focusRuntime.backgroundReason !== 'screenOff') {
      this.focusRuntime = FocusClock.pauseOnDeparture(this.focusRuntime, this.focusRuntime.lastUpdatedAt);
    }
    if (this.focusRuntime !== null) this.activeFocusTask = this.focusRuntime.task;
    this.taskStatusOverrides.clear();
    (saved.taskStatuses ?? []).forEach((entry: StoredTaskStatus) => {
      this.taskStatusOverrides.set(entry.taskId, entry.status);
    });
    this.restoreFocusStatuses();
    this.notifyFocusDataChanged();
    this.notifyLearningDataChanged();
  }

  private async syncImportedKnowledge(): Promise<void> {
    this.notifyLearningDataChanged();
    const version: number = ++this.knowledgeSyncVersion;
    const userId: string = this.currentUser.userId;
    const courses: string[] = [];
    this.courses.forEach((item: CourseInfo) => {
      if (item.courseName.trim().length > 0 && courses.indexOf(item.courseName) < 0) courses.push(item.courseName);
    });
    this.homeworkDDLs.forEach((item: HomeworkDDL) => {
      if (item.courseName.trim().length > 0 && courses.indexOf(item.courseName) < 0) courses.push(item.courseName);
    });
    if (courses.length === 0) return;
    AppStorage.setOrCreate('knowledgeSyncMessage', '本地导入已完成，正在同步知识点…');
    try {
      const result = await AgentApiClient.importKnowledgePoints(userId, courses);
      if (userId !== this.currentUser.userId || version !== this.knowledgeSyncVersion) return;
      if (result.ok) {
        ClientCache.cacheProfile(result.data);
        ClientCache.invalidateCurrentPlan();
        AppStorage.setOrCreate('knowledgeSyncMessage', `已为你的 ${courses.length} 门课准备 ${result.data.mastery.length} 个知识点，点“开始诊断”即可练习。`);
        this.notifyLearningDataChanged();
      } else {
        console.warn('课程知识点同步失败，本地导入数据已保留');
        AppStorage.setOrCreate('knowledgeSyncMessage', '本地导入成功，知识点同步失败，请检查连接后重新导入。');
      }
    } catch (error) {
      if (userId === this.currentUser.userId && version === this.knowledgeSyncVersion) {
        AppStorage.setOrCreate('knowledgeSyncMessage', '本地导入成功，知识点同步失败，请稍后重新导入。');
      }
    }
  }

  public currentUser: UserProfile = mockCurrentUser;
  public courses: CourseInfo[] = [];
  public homeworkDDLs: HomeworkDDL[] = [];
  public candidates: UserProfile[] = mockCandidates;

  public isDataImported: boolean = false;
  public importedCourseCount: number = 0;
  public importedDDLCount: number = 0;

  public isSignedIn: boolean = false;
  public authSource: AuthSource = 'guest';
  public authNickname: string = ApiDefaults.DEMO_USER_NAME;
  public authAvatar: string = '';
  public loginNotice: string = '';

  public chatMessages: string = '';
  public hasActiveChat: boolean = false;
  public chatSessionId: string = '';
  public pendingChatPrompt: string = '';

  public wrongQuestionImages: WrongQuestionImage[] = [];

  public latestSuggestion: StudySuggestion | null = null;
  public latestWrongAnalyses: WrongAnalysisResult[] = [];
  public latestWrongAnalysis: WrongAnalysisResult | null = null;
  public latestPartner: PartnerMatch | null = null;
  public latestReview: LearningReview | null = null;

  public activeFocusTask: FocusTask | null = null;
  public focusResultDraft: FocusSession | null = null;
  public focusSessions: FocusSession[] = [];
  public focusRuntime: FocusRuntime | null = null;
  private pendingFocusSessions: FocusSession[] = [];
  private focusSyncUsers: Set<string> = new Set<string>();

  public weeklyPlan: WeeklyLearningPlan | null = null;

  public optimalTask: TaskPriority | null = null;
  public weaknessJudgments: WeaknessJudgment[] = [];
  public matchFeasibility: MatchFeasibility | null = null;

  public workflowContext: WorkflowContext = {
    currentStage: 'idle',
    lastAction: '',
    lastActionTime: '',
    completedStages: [],
    pendingActions: []
  };

  public selectedImageUri: string = '';

  public activeChatTask: string = '';
  private chatHandoff: ChatHandoff | null = null;

  public static getInstance(): AppState {
    if (AppState.instance === undefined) {
      AppState.instance = new AppState();
    }
    return AppState.instance;
  }


  public applyLogin(user: AuthUser | null, source: AuthSource, notice: string = ''): void {
    if (user === null) {
      this.applyLogout();
      return;
    }
    const identityChanged: boolean = this.currentUser.userId !== user.userId;
    this.currentUser = {
      userId: user.userId,
      basicInfo: {
        name: user.nickname,
        grade: user.grade.length > 0 ? user.grade : '',
        major: this.currentUser.basicInfo.major
      },
      learningGoal: this.currentUser.learningGoal,
      time: this.currentUser.time,
      knowledge: this.currentUser.knowledge
    };
    this.authSource = source;
    this.authNickname = user.nickname;
    this.authAvatar = user.avatar ?? '';
    this.isSignedIn = source === 'local' || source === 'restored';

    ClientCache.bindIdentity(user.userId);
    if (identityChanged) {
      this.resetAccountScopedState();
      this.restoreLearningData(user.userId);
    }
    this.loginNotice = notice;
    void this.syncLearningData();
    void this.syncFocusSessions();
  }

  public applyLogout(): void {
    this.currentUser = {
      userId: ApiDefaults.DEMO_USER_ID,
      basicInfo: {
        name: ApiDefaults.DEMO_USER_NAME,
        grade: mockCurrentUser.basicInfo.grade,
        major: mockCurrentUser.basicInfo.major
      },
      learningGoal: mockCurrentUser.learningGoal,
      time: mockCurrentUser.time,
      knowledge: mockCurrentUser.knowledge
    };
    this.authSource = 'guest';
    this.authNickname = ApiDefaults.DEMO_USER_NAME;
    this.authAvatar = '';
    this.isSignedIn = false;
    ClientCache.bindIdentity(ApiDefaults.DEMO_USER_ID);
    this.resetAccountScopedState();
    this.restoreLearningData(ApiDefaults.DEMO_USER_ID);
  }

  public startChatTask(taskName: string): void {
    this.activeChatTask = taskName;
  }

  public getChatTaskContext(): string {
    if (this.activeChatTask.length === 0) {
      return '由知学Mate为你准备';
    }
    return `正在完成：${this.activeChatTask}`;
  }

  public leaveChatTask(): void {
    this.activeChatTask = '';
  }

  public completeChatTask(summary: string, nextPrompt: string, actionLabel: string, targetPage: string): void {
    const handoff: ChatHandoff = {
      summary: summary,
      nextPrompt: nextPrompt,
      actionLabel: actionLabel,
      targetPage: targetPage
    };
    this.chatHandoff = handoff;
    this.activeChatTask = '';
  }

  public consumeChatHandoff(): ChatHandoff | null {
    const handoff: ChatHandoff | null = this.chatHandoff;
    this.chatHandoff = null;
    return handoff;
  }


  public importCourses(newCourses: CourseInfo[]): void {
    if (newCourses.length === 0) {
      throw new Error('导入数据为空，请检查文件内容');
    }
    this.courses = newCourses;
    this.importedCourseCount = newCourses.length;
    this.isDataImported = true;
    this.persistLearningData();
    this.advanceStage('input', '导入课程表数据');
    this.syncImportedKnowledge();
  }

  public importDDLs(newDDLs: HomeworkDDL[]): void {
    this.homeworkDDLs = newDDLs;
    this.importedDDLCount = newDDLs.length;
    this.isDataImported = true;
    this.persistLearningData();
    this.advanceStage('input', '导入作业DDL数据');
    this.syncImportedKnowledge();
  }

  public removeCourse(courseId: string): void {
    const filtered: CourseInfo[] = [];
    for (let i = 0; i < this.courses.length; i++) {
      if (this.courses[i].courseId !== courseId) {
        filtered.push(this.courses[i]);
      }
    }
    this.courses = filtered;
    this.importedCourseCount = filtered.length;
    this.isDataImported = this.courses.length > 0 || this.homeworkDDLs.length > 0;
    this.persistLearningData();
    this.notifyLearningDataChanged();
  }

  public updateCourse(courseId: string, updatedCourse: CourseInfo): boolean {
    const next: CourseInfo[] = [];
    let found: boolean = false;
    let courseNameChanged: boolean = false;
    for (let i = 0; i < this.courses.length; i++) {
      const current: CourseInfo = this.courses[i];
      if (current.courseId === courseId) {
        found = true;
        courseNameChanged = current.courseName !== updatedCourse.courseName;
        next.push({
          courseId: current.courseId,
          courseName: updatedCourse.courseName,
          exam: {
            date: updatedCourse.exam.date,
            daysLeft: updatedCourse.exam.daysLeft
          },
          priority: updatedCourse.priority,
          recentStatus: {
            studyHours: current.recentStatus.studyHours,
            status: current.recentStatus.status
          }
        });
      } else {
        next.push(current);
      }
    }
    if (!found) return false;
    this.courses = next;
    this.persistLearningData();
    this.notifyLearningDataChanged();
    if (courseNameChanged) this.syncImportedKnowledge();
    return true;
  }

  public applyChatProfileUpdates(updates: ChatProfileUpdates): string[] {
    const changed: string[] = [];
    if (updates.user !== undefined) {
      if (updates.user.basicInfo !== undefined) {
        this.currentUser.basicInfo = {
          name: updates.user.basicInfo.name ?? this.currentUser.basicInfo.name,
          grade: updates.user.basicInfo.grade ?? this.currentUser.basicInfo.grade,
          major: updates.user.basicInfo.major ?? this.currentUser.basicInfo.major
        };
        changed.push('个人信息');
      }
      if (updates.user.learningGoal !== undefined) {
        this.currentUser.learningGoal = {
          course: updates.user.learningGoal.course ?? this.currentUser.learningGoal.course,
          goal: updates.user.learningGoal.goal ?? this.currentUser.learningGoal.goal
        };
        changed.push('学习目标');
      }
      if (updates.user.time?.freeTime !== undefined) {
        this.currentUser.time = { freeTime: updates.user.time.freeTime };
        changed.push('空闲时间');
      }
      if (updates.user.knowledge !== undefined) {
        this.currentUser.knowledge = {
          weakness: updates.user.knowledge.weakness ?? this.currentUser.knowledge.weakness,
          strength: updates.user.knowledge.strength ?? this.currentUser.knowledge.strength
        };
        changed.push('知识情况');
      }
    }

    const courseUpdates: ChatCourseUpdate[] = updates.course ?? [];
    if (courseUpdates.length === 0) return changed;
    let nextCourses: CourseInfo[] = this.courses.slice();
    let nextDDLs: HomeworkDDL[] = this.homeworkDDLs.slice();
    let changedCourseCount: number = 0;
    let changedTaskCount: number = 0;
    const stamp: number = Date.now();

    for (let index: number = 0; index < courseUpdates.length; index++) {
      const update: ChatCourseUpdate = courseUpdates[index];
      const requestedId: string = (update.courseId ?? '').trim();
      const requestedName: string = (update.courseName ?? '').trim();
      let foundIndex: number = -1;
      for (let courseIndex: number = 0; courseIndex < nextCourses.length; courseIndex++) {
        const current: CourseInfo = nextCourses[courseIndex];
        if ((requestedId.length > 0 && current.courseId === requestedId) ||
          (requestedName.length > 0 && current.courseName === requestedName)) {
          foundIndex = courseIndex;
          break;
        }
      }

      const existing: CourseInfo | undefined = foundIndex >= 0 ? nextCourses[foundIndex] : undefined;
      const oldName: string = existing?.courseName ?? requestedName;
      const finalName: string = requestedName.length > 0 ? requestedName : oldName;
      if (finalName.length === 0) continue;
      const examDate: string = update.exam?.date ?? existing?.exam.date ?? '未设置';
      const computedDays: number = examDate === '未设置' ? 30 : DateHelper.calculateDaysLeft(examDate);
      const finalCourse: CourseInfo = {
        courseId: existing?.courseId ?? (requestedId.length > 0 ? requestedId : `chat-course-${stamp}-${index}`),
        courseName: finalName,
        exam: {
          date: examDate,
          daysLeft: isNaN(computedDays) ? (existing?.exam.daysLeft ?? 30) : computedDays
        },
        priority: update.priority ?? existing?.priority ?? '中',
        recentStatus: {
          studyHours: update.recentStatus?.studyHours ?? existing?.recentStatus.studyHours ?? 0,
          status: update.recentStatus?.status ?? existing?.recentStatus.status ?? '尚未评估'
        }
      };
      if (foundIndex >= 0) nextCourses[foundIndex] = finalCourse;
      else nextCourses.push(finalCourse);
      changedCourseCount++;

      if (oldName.length > 0 && oldName !== finalName) {
        nextDDLs = nextDDLs.map((item: HomeworkDDL): HomeworkDDL => item.courseName === oldName
          ? {
            id: item.id,
            courseName: finalName,
            title: item.title,
            dueDate: item.dueDate,
            daysLeft: item.daysLeft,
            priority: item.priority,
            estimatedMinutes: item.estimatedMinutes,
            origin: item.origin
          } : item);
      }

      if (update.tasks !== undefined) {
        const previousForCourse: HomeworkDDL[] = nextDDLs.filter(
          (item: HomeworkDDL): boolean => item.courseName === finalName);
        nextDDLs = nextDDLs.filter((item: HomeworkDDL): boolean => item.courseName !== finalName);
        for (let taskIndex: number = 0; taskIndex < update.tasks.length; taskIndex++) {
          const task: ChatTaskUpdate = update.tasks[taskIndex];
          const title: string = (task.taskname ?? '').trim();
          if (title.length === 0) continue;
          const previous: HomeworkDDL | undefined = previousForCourse.find(
            (item: HomeworkDDL): boolean => item.title === title);
          const dueDate: string = (task.deadline ?? previous?.dueDate ?? '').trim();
          const daysLeft: number = dueDate.length > 0 ? DateHelper.calculateDaysLeft(dueDate) : 30;
          nextDDLs.push({
            id: previous?.id ?? `chat-ddl-${stamp}-${index}-${taskIndex}`,
            courseName: finalName,
            title: title,
            dueDate: dueDate,
            daysLeft: isNaN(daysLeft) ? 30 : daysLeft,
            priority: finalCourse.priority,
            estimatedMinutes: task.estimatedMinutes ?? previous?.estimatedMinutes ?? 60,
            origin: previous !== undefined
              ? (previous.id.startsWith('chat-ddl-') ? 'chat' : 'import')
              : 'chat'
          });
          changedTaskCount++;
        }
      }
    }

    this.courses = nextCourses;
    this.homeworkDDLs = nextDDLs;
    this.importedCourseCount = nextCourses.length;
    this.importedDDLCount = nextDDLs.length;
    this.isDataImported = nextCourses.length > 0 || nextDDLs.length > 0;
    this.persistLearningData();
    this.clearWeeklyPlan();
    this.notifyLearningDataChanged();
    this.syncImportedKnowledge();
    if (changedCourseCount > 0) changed.push(`${changedCourseCount} 门课程`);
    if (changedTaskCount > 0 || courseUpdates.some((item: ChatCourseUpdate): boolean => item.tasks !== undefined)) {
      changed.push(`${changedTaskCount} 项任务`);
    }
    return changed;
  }

  public updateDDL(ddlId: string, title: string, dueDate: string, minutes: number, priority: string): boolean {
    if (!title.trim() || !Number.isInteger(minutes) || minutes < 1 || minutes > 1440) return false;
    const previous: HomeworkDDL[] = this.homeworkDDLs;
    const original: HomeworkDDL | undefined = previous.find((item: HomeworkDDL) => item.id === ddlId);
    if (original === undefined) return false;
    const due: number = Date.parse(dueDate.replace(' ', 'T'));
    if (!Number.isFinite(due)) return false;
    const updated: HomeworkDDL = {
      id: original.id, courseId: original.courseId, syncVersion: original.syncVersion,
      courseName: original.courseName, origin: original.origin, completed: original.completed,
      title: title.trim(), dueDate: dueDate.trim(), estimatedMinutes: minutes, priority: priority,
      daysLeft: DateHelper.calculateDaysLeft(dueDate)
    };
    this.homeworkDDLs = previous.map((item: HomeworkDDL) => item.id === ddlId ? updated : item);
    if (!this.persistLearningData()) { this.homeworkDDLs = previous; return false; }
    this.notifyLearningDataChanged();
    return true;
  }

  public removeDDL(ddlId: string): void {
    const filtered: HomeworkDDL[] = [];
    for (let i = 0; i < this.homeworkDDLs.length; i++) {
      if (this.homeworkDDLs[i].id !== ddlId) {
        filtered.push(this.homeworkDDLs[i]);
      }
    }
    this.homeworkDDLs = filtered;
    this.importedDDLCount = filtered.length;
    this.isDataImported = this.courses.length > 0 || this.homeworkDDLs.length > 0;
    this.persistLearningData();
    this.notifyLearningDataChanged();
  }

  public appendCourses(newCourses: CourseInfo[]): void {
    for (let i = 0; i < newCourses.length; i++) {
      this.courses.push(newCourses[i]);
    }
    this.importedCourseCount += newCourses.length;
    this.isDataImported = true;
    this.persistLearningData();
    this.syncImportedKnowledge();
  }

  public appendDDLs(newDDLs: HomeworkDDL[]): void {
    for (let i = 0; i < newDDLs.length; i++) {
      this.homeworkDDLs.push(newDDLs[i]);
    }
    this.importedDDLCount += newDDLs.length;
    this.isDataImported = true;
    this.persistLearningData();
    this.syncImportedKnowledge();
  }

  public resetToMockData(): void {
    this.courses = [...mockCoursesList];
    this.homeworkDDLs = [...mockHomeworkDDLs];
    this.isDataImported = false;
    this.importedCourseCount = 0;
    this.importedDDLCount = 0;
    this.persistLearningData();
    this.resetSession();
  }

  public getDataSourceDescription(): string {
    if (!this.isDataImported && this.courses.length === 0 && this.homeworkDDLs.length === 0) {
      return '尚未导入课程与作业';
    }
    if (!this.isDataImported) {
      return `演示数据 · ${this.courses.length}门课程 · ${this.homeworkDDLs.length}项作业`;
    }
    const parts: string[] = [];
    if (this.importedCourseCount > 0) {
      parts.push(`${this.importedCourseCount}门课程`);
    }
    if (this.importedDDLCount > 0) {
      parts.push(`${this.importedDDLCount}项作业`);
    }
    return '已导入 · ' + (parts.length > 0 ? parts.join(' · ') : '数据已加载');
  }


  public getHighPriorityCourse(): CourseInfo | null {
    if (this.courses.length === 0) {
      return null;
    }
    let highestCourse: CourseInfo = this.courses[0];
    for (let index: number = 1; index < this.courses.length; index++) {
      const course: CourseInfo = this.courses[index];
      if (course.exam.daysLeft < highestCourse.exam.daysLeft) {
        highestCourse = course;
      }
    }
    return highestCourse;
  }

  public getUrgentDDLs(): HomeworkDDL[] {
    return this.homeworkDDLs.filter((ddl: HomeworkDDL) => ddl.daysLeft <= 7 && !this.isTaskCompleted(ddl.id, 'pending'));
  }

  public getPendingDDLs(): HomeworkDDL[] {
    return this.homeworkDDLs.filter((ddl: HomeworkDDL): boolean => !this.isTaskCompleted(ddl.id, 'pending'));
  }

  public getDDLsByCourse(courseName: string): HomeworkDDL[] {
    return this.homeworkDDLs.filter((ddl: HomeworkDDL) => ddl.courseName === courseName);
  }

  public getWeaknessTags(): string[] {
    return this.currentUser.knowledge.weakness;
  }

  public getStrengthTags(): string[] {
    return this.currentUser.knowledge.strength;
  }

  public setChatPrompt(prompt: string): void {
    this.pendingChatPrompt = prompt;
  }

  public setFocusTask(task: FocusTask): void {
    this.activeFocusTask = task;
  }

  public clearFocusTask(): void {
    this.activeFocusTask = null;
  }

  public setWeeklyPlan(plan: WeeklyLearningPlan): void {
    this.weeklyPlan = plan;
    this.advanceStage('output', 'Agent 已生成并更新本周学习计划');
  }

  public clearWeeklyPlan(): void {
    this.weeklyPlan = null;
  }

  public getTodayPlanTasks(): LearningPlanTask[] {
    if (this.weeklyPlan === null) {
      return [];
    }
    const todayLabel: string = DateHelper.getTodayLabel();
    return this.weeklyPlan.tasks.filter((task: LearningPlanTask) =>
      task.dateLabel.split(' ')[0] === todayLabel
    );
  }

  private taskStatusOverrides: Map<string, PlanTaskStatus> = new Map<string, PlanTaskStatus>();

  public isTaskCompleted(taskId: string, status: string): boolean {
    return this.isPlanTaskDone(taskId, status);
  }

  private isPlanTaskDone(taskId: string, status: string): boolean {
    if (status === 'completed') {
      return true;
    }
    return this.taskStatusOverrides.get(taskId) === 'completed';
  }

  private knownPlanTaskIds(): string[] {
    const ids: string[] = [];
    const visible: VisiblePlan | null = ClientCache.getCurrentPlan();
    if (visible !== null) {
      visible.tasks.forEach((task: VisiblePlanTask) => ids.push(task.taskId));
    }
    if (this.weeklyPlan !== null) {
      this.weeklyPlan.tasks.forEach((task: LearningPlanTask) => ids.push(task.id));
    }
    return ids;
  }

  public markPlanTaskStatus(taskId: string | undefined, status: PlanTaskStatus): boolean {
    const key: string = (taskId ?? '').trim();
    if (key.length === 0) {
      return false;
    }
    if (this.taskStatusOverrides.get(key) === 'completed' && status !== 'completed') {
      return this.knownPlanTaskIds().indexOf(key) !== -1;
    }
    this.taskStatusOverrides.set(key, status);
    this.persistLearningData();
    this.notifyFocusDataChanged();
    return this.knownPlanTaskIds().indexOf(key) !== -1;
  }

  public getPlanProgress(): number {
    const visible: VisiblePlan | null = ClientCache.getCurrentPlan();
    if (visible !== null && visible.tasks.length > 0) {
      const done: number = visible.tasks.filter(
        (task: VisiblePlanTask) => this.isPlanTaskDone(task.taskId, task.status)).length;
      return Math.round(done / visible.tasks.length * 100);
    }
    if (this.weeklyPlan === null || this.weeklyPlan.tasks.length === 0) {
      return 0;
    }
    const done: number = this.weeklyPlan.tasks.filter(
      (task: LearningPlanTask) => this.isPlanTaskDone(task.id, task.status)).length;
    return Math.round(done / this.weeklyPlan.tasks.length * 100);
  }

  public getCompletedPlanTasks(): LearningPlanTask[] {
    const visible: VisiblePlan | null = ClientCache.getCurrentPlan();
    if (visible !== null && visible.tasks.length > 0) {
      const done: VisiblePlanTask[] = visible.tasks.filter(
        (task: VisiblePlanTask) => this.isPlanTaskDone(task.taskId, task.status));
      const mapped: LearningPlanTask[] = [];
      done.forEach((task: VisiblePlanTask) => mapped.push(AppState.toDisplayTask(task)));
      return mapped;
    }
    if (this.weeklyPlan === null) {
      return [];
    }
    return this.weeklyPlan.tasks.filter(
      (task: LearningPlanTask) => this.isPlanTaskDone(task.id, task.status));
  }

  private static toDisplayTask(task: VisiblePlanTask): LearningPlanTask {
    return {
      id: task.taskId,
      course: '专项学习',
      title: task.knowledgePointName,
      knowledgePoint: task.knowledgePointName,
      type: 'practice',
      dateLabel: '',
      plannedMinutes: task.durationMinutes,
      priorityScore: 0,
      priorityLabel: '',
      reason: '',
      completionCriteria: '',
      steps: [],
      status: 'completed',
      source: 'agent',
      canCollaborate: false
    };
  }

  public updatePlanTaskStatus(taskId: string, status: PlanTaskStatus): void {
    const key: string = (taskId ?? '').trim();
    if (key.length === 0) {
      return;
    }
    this.taskStatusOverrides.set(key, status);
    if (this.weeklyPlan === null) {
      return;
    }
    const task: LearningPlanTask | undefined = this.weeklyPlan.tasks.find((item: LearningPlanTask) => item.id === key);
    if (task !== undefined) {
      task.status = status;
    }
  }

  public hasPendingWrongQuestionReview(course: string, knowledgePoint: string): boolean {
    if (this.weeklyPlan === null) {
      return false;
    }
    return this.weeklyPlan.tasks.some((task: LearningPlanTask) =>
      task.source === 'wrong_question' &&
      task.course === course &&
      task.knowledgePoint === knowledgePoint &&
      task.status !== 'completed'
    );
  }

  public addReviewTask(task: LearningPlanTask, message: string): boolean {
    if (this.weeklyPlan === null) {
      return false;
    }
    if (this.hasPendingWrongQuestionReview(task.course, task.knowledgePoint)) {
      this.weeklyPlan.adjustmentMessage = `“${task.knowledgePoint}”已在复习计划中，无需重复添加。`;
      return false;
    }
    this.weeklyPlan.tasks.unshift(task);
    this.weeklyPlan.adjustmentMessage = message;
    return true;
  }

  public hasActiveCollaborativeTask(taskId: string): boolean {
    if (this.weeklyPlan === null) {
      return false;
    }
    return this.weeklyPlan.tasks.some((task: LearningPlanTask) =>
      (task.id === taskId || task.id.startsWith(taskId + '-round-')) &&
      task.source === 'partner_match' && task.status !== 'completed'
    );
  }

  public hasCompletedCollaborativeTask(taskId: string): boolean {
    if (this.weeklyPlan === null) {
      return false;
    }
    return this.weeklyPlan.tasks.some((task: LearningPlanTask) =>
      (task.id === taskId || task.id.startsWith(taskId + '-round-')) &&
      task.source === 'partner_match' && task.status === 'completed'
    );
  }

  public nextCollaborativeTaskId(taskId: string): string {
    if (this.weeklyPlan === null) {
      return taskId;
    }
    const count: number = this.weeklyPlan.tasks.filter((task: LearningPlanTask) =>
      task.source === 'partner_match' &&
      (task.id === taskId || task.id.startsWith(taskId + '-round-'))
    ).length;
    return count === 0 ? taskId : `${taskId}-round-${count + 1}`;
  }

  public addCollaborativeTask(task: LearningPlanTask, message: string): boolean {
    if (this.weeklyPlan === null || this.hasActiveCollaborativeTask(task.id)) {
      if (this.weeklyPlan !== null) {
        this.weeklyPlan.adjustmentMessage = '该搭子的协同学习任务已在计划中，无需重复添加。';
      }
      return false;
    }
    this.weeklyPlan.tasks.unshift(task);
    this.weeklyPlan.adjustmentMessage = message;
    return true;
  }

  public clearCurrentWrongQuestionDraft(): void {
    this.selectedImageUri = '';
    this.latestWrongAnalysis = null;
    this.latestWrongAnalyses = [];
  }

  public beginFocusRuntime(task: FocusTask): boolean {
    if (this.focusRuntime !== null || this.focusResultDraft !== null) return false;
    const previousTask: FocusTask | null = this.activeFocusTask;
    this.focusRuntime = FocusClock.create(this.currentUser.userId, task);
    this.activeFocusTask = task;
    if (!this.persistLearningData()) {
      this.focusRuntime = null;
      this.activeFocusTask = previousTask;
      return false;
    }
    this.notifyFocusDataChanged();
    return true;
  }

  public checkpointFocusRuntime(runtime: FocusRuntime): boolean {
    if (runtime.ownerId !== this.currentUser.userId || this.focusRuntime?.sessionId !== runtime.sessionId) return false;
    const previous: FocusRuntime | null = this.focusRuntime;
    this.focusRuntime = runtime;
    if (!this.persistLearningData()) {
      this.focusRuntime = previous;
      return false;
    }
    return true;
  }

  public applySharedFocusRuntime(runtime: FocusRuntime | null, sessionId: string): boolean {
    if (runtime !== null && runtime.ownerId !== this.currentUser.userId) return false;
    if (this.focusRuntime !== null && this.focusRuntime.sessionId !== sessionId) return false;
    if (this.focusResultDraft !== null && this.focusResultDraft.taskId !== sessionId) return false;
    const previous = this.focusRuntime;
    const previousTask = this.activeFocusTask;
    this.focusRuntime = runtime;
    if (runtime !== null) this.activeFocusTask = runtime.task;
    else if (previous !== null && this.activeFocusTask === previous.task) this.activeFocusTask = null;
    if (!this.persistLearningData()) {
      this.focusRuntime = previous;
      this.activeFocusTask = previousTask;
      return false;
    }
    this.notifyFocusDataChanged();
    return true;
  }

  public pauseFocusOnDeparture(): boolean {
    return this.handleFocusDeparture('navigation');
  }

  public handleFocusDeparture(reason: 'navigation' | 'background' | 'screenOff', now: number = Date.now()): boolean {
    const runtime: FocusRuntime | null = this.focusRuntime;
    if (runtime === null || runtime.ownerId !== this.currentUser.userId) return true;
    const environment: string = this.learningEnvironment;
    const next: FocusRuntime = FocusClock.depart(runtime, reason, now);
    const saved: boolean = this.checkpointFocusRuntime(next);
    if (!saved && this.learningEnvironment === environment && this.focusRuntime?.sessionId === runtime.sessionId) this.focusRuntime = next;
    this.notifyFocusDataChanged();
    return saved;
  }

  public setFocusResultDraft(session: FocusSession): boolean {
    const previousRuntime: FocusRuntime | null = this.focusRuntime;
    const previousDraft: FocusSession | null = this.focusResultDraft;
    this.focusRuntime = null;
    this.focusResultDraft = session;
    if (!this.persistLearningData()) {
      this.focusRuntime = previousRuntime;
      this.focusResultDraft = previousDraft;
      return false;
    }
    this.notifyFocusDataChanged();
    return true;
  }

  public clearFocusResultDraft(): void {
    this.focusResultDraft = null;
    this.persistLearningData();
    this.notifyFocusDataChanged();
  }

  public discardFocusRecovery(): boolean {
    const runtime: FocusRuntime | null = this.focusRuntime;
    const draft: FocusSession | null = this.focusResultDraft;
    this.focusRuntime = null;
    this.focusResultDraft = null;
    if (!this.persistLearningData()) {
      this.focusRuntime = runtime;
      this.focusResultDraft = draft;
      return false;
    }
    this.notifyFocusDataChanged();
    return true;
  }

  public saveFocusSession(session: FocusSession, alreadySynced: boolean = false): string {
    if (this.focusSessions.some((saved: FocusSession) => saved.taskId === session.taskId)) {
      return 'duplicate';
    }
    this.focusSessions.push(session);
    if (!alreadySynced && !AgentApiClient.getConfig().useFixture && this.isSignedIn) this.pendingFocusSessions.push(session);
    if (!this.persistLearningData()) {
      this.focusSessions = this.focusSessions.filter((item: FocusSession) => item.taskId !== session.taskId);
      this.pendingFocusSessions = this.pendingFocusSessions.filter((item: FocusSession) => item.taskId !== session.taskId);
      return 'failed';
    }
    this.notifyFocusDataChanged();
    return 'saved';
  }

  public acceptSharedFocusRecord(session: FocusSession): void {
    const index: number = this.focusSessions.findIndex((item: FocusSession) => item.taskId === session.taskId);
    if (index >= 0) this.focusSessions[index] = session;
    else this.focusSessions.push(session);
    this.pendingFocusSessions = this.pendingFocusSessions.filter((item: FocusSession) => item.taskId !== session.taskId);
    this.restoreFocusStatuses();
    this.persistLearningData();
    this.notifyFocusDataChanged();
  }

  private restoreFocusStatuses(): void {
    const ordered: FocusSession[] = this.focusSessions.slice().sort(
      (left: FocusSession, right: FocusSession): number => Date.parse(left.endedAt) - Date.parse(right.endedAt));
    ordered.forEach((item: FocusSession) => {
      const taskId: string = item.planTaskId ?? '';
      if (taskId.length === 0 || this.taskStatusOverrides.get(taskId) === 'completed') return;
      this.taskStatusOverrides.set(taskId, item.selfAssessment === 'completed' ? 'completed' :
        (item.selfAssessment === 'partial' ? 'partial' : 'deferred'));
    });
  }

  public async syncFocusSessions(): Promise<void> {
    const owner: string = this.currentUser.userId;
    if (AgentApiClient.getConfig().useFixture || this.focusSyncUsers.has(owner)) return;
    if (!this.isSignedIn) {
      AppStorage.setOrCreate('focusSyncMessage', '演示身份的专注记录仅保存在本机。');
      return;
    }
    this.focusSyncUsers.add(owner);
    AppStorage.setOrCreate('focusSyncMessage', '正在同步专注记录…');
    try {
      while (this.pendingFocusSessions.length > 0) {
        if (this.currentUser.userId !== owner || !this.isSignedIn || AgentApiClient.getConfig().useFixture) return;
        const session: FocusSession = this.pendingFocusSessions[0];
        const result = await AgentApiClient.saveFocusSession(session);
        if (this.currentUser.userId !== owner || !this.isSignedIn) return;
        if (!result.ok || result.data.userId !== owner) {
          AppStorage.setOrCreate('focusSyncMessage', '记录已保存在本机，云端同步未完成；回到应用或点击重试后继续。');
          return;
        }
        const remaining: FocusSession[] = this.pendingFocusSessions;
        this.pendingFocusSessions = remaining.filter((item: FocusSession) => item.taskId !== session.taskId);
        if (!this.persistLearningData()) {
          this.pendingFocusSessions = remaining;
          AppStorage.setOrCreate('focusSyncMessage', '本机同步状态保存失败，稍后将安全重试。');
          return;
        }
      }
      const history = await AgentApiClient.getFocusHistory();
      if (this.currentUser.userId !== owner || !this.isSignedIn) return;
      if (!history.ok || history.data.userId !== owner) {
        AppStorage.setOrCreate('focusSyncMessage', '本机记录已保留，暂时无法读取云端历史。');
        return;
      }
      history.data.sessions.forEach((session: FocusSession) => {
        if (!this.focusSessions.some((local: FocusSession) => local.taskId === session.taskId)) {
          this.focusSessions.push(session);
        }
      });
      this.focusSessions.sort((left: FocusSession, right: FocusSession): number =>
        Date.parse(left.endedAt) - Date.parse(right.endedAt));
      this.restoreFocusStatuses();
      this.notifyFocusDataChanged();
      AppStorage.setOrCreate('focusSyncMessage', this.persistLearningData()
        ? '专注记录已同步。' : '云端已同步，本机历史保存失败，请重试。');
    } finally {
      this.focusSyncUsers.delete(owner);
    }
  }

  public getFocusSummary(): FocusSummary {
    const courseMinutes: Map<string, number> = new Map();
    let todayMinutes: number = 0;
    const todayKey: string = DateHelper.todayKey();
    const studyDays: Set<string> = new Set<string>();
    for (let index: number = 0; index < this.focusSessions.length; index++) {
      const session: FocusSession = this.focusSessions[index];
      const accumulated: number = courseMinutes.get(session.course) ?? 0;
      courseMinutes.set(session.course, accumulated + session.actualMinutes);
      const dayKey: string = DateHelper.localDateKey(session.endedAt);
      if (dayKey.length === 0) {
        continue;
      }
      studyDays.add(dayKey);
      if (dayKey === todayKey) {
        todayMinutes += session.actualMinutes;
      }
    }
    return {
      todayMinutes: todayMinutes,
      streakDays: AppState.countStreakDays(studyDays, todayKey),
      courseMinutes: courseMinutes,
      recentSessions: this.focusSessions.slice(-7).reverse()
    };
  }

  private static countStreakDays(studyDays: Set<string>, todayKey: string): number {
    if (studyDays.size === 0) {
      return 0;
    }
    let cursor: string = todayKey;
    if (!studyDays.has(cursor)) {
      const yesterdayKey: string = AppState.shiftDayKey(cursor, -1);
      if (!studyDays.has(yesterdayKey)) {
        return 0;
      }
      cursor = yesterdayKey;
    }
    let streak: number = 0;
    while (studyDays.has(cursor)) {
      streak++;
      cursor = AppState.shiftDayKey(cursor, -1);
    }
    return streak;
  }

  private static shiftDayKey(key: string, deltaDays: number): string {
    const base: Date = new Date(`${key}T00:00:00`);
    if (isNaN(base.getTime())) {
      return '';
    }
    base.setDate(base.getDate() + deltaDays);
    return `${base.getFullYear()}-${DateHelper.pad(base.getMonth() + 1)}-${DateHelper.pad(base.getDate())}`;
  }


  public addWrongQuestionImage(uri: string, fileName: string): void {
    const image: WrongQuestionImage = {
      imageUri: uri,
      fileName: fileName,
      uploadTime: new Date().toLocaleString()
    };
    this.wrongQuestionImages.push(image);
    this.selectedImageUri = uri;
  }

  public getLatestImage(): WrongQuestionImage | null {
    if (this.wrongQuestionImages.length === 0) {
      return null;
    }
    return this.wrongQuestionImages[this.wrongQuestionImages.length - 1];
  }


  public advanceStage(stage: WorkflowStage, action: string): void {
    this.workflowContext.currentStage = stage;
    this.workflowContext.lastAction = action;
    this.workflowContext.lastActionTime = new Date().toLocaleString();
    if (this.workflowContext.completedStages.indexOf(stage) === -1) {
      this.workflowContext.completedStages.push(stage);
    }
  }

  public hasCompleted(stage: WorkflowStage): boolean {
    return this.workflowContext.completedStages.indexOf(stage) !== -1;
  }

  public getAvailableActions(): NavigationIntent[] {
    const actions: NavigationIntent[] = ['back_to_hub'];

    if (this.wrongQuestionImages.length > 0 && this.latestWrongAnalysis !== null) {
      actions.push('view_tags');
    }
    if (this.latestPartner === null) {
      actions.push('find_partner');
    }
    if (this.latestSuggestion !== null) {
      actions.push('view_study_plan');
    }
    if (this.latestReview !== null) {
      actions.push('view_review');
    }
    if (this.courses.length > 0) {
      actions.push('view_courses');
    }
    if (this.wrongQuestionImages.length === 0 || this.latestWrongAnalysis === null) {
      actions.push('analyze_wrong_question');
    }

    return actions;
  }

  public resetSession(): void {
    this.latestSuggestion = null;
    this.latestWrongAnalysis = null;
    this.latestWrongAnalyses = [];
    this.latestPartner = null;
    this.latestReview = null;
    this.optimalTask = null;
    this.weaknessJudgments = [];
    this.matchFeasibility = null;
    this.wrongQuestionImages = [];
    this.selectedImageUri = '';
    this.weeklyPlan = null;
    this.activeChatTask = '';
    this.chatHandoff = null;
    this.workflowContext = {
      currentStage: 'idle',
      lastAction: '',
      lastActionTime: '',
      completedStages: [],
      pendingActions: []
    };
  }

  public resetAccountScopedState(): void {
    this.knowledgeSyncVersion++;
    AppStorage.setOrCreate('knowledgeSyncMessage', '');
    this.chatMessages = '';
    this.hasActiveChat = false;
    this.chatSessionId = '';
    this.pendingChatPrompt = '';
    this.loginNotice = '';
    this.focusSessions = [];
    this.pendingFocusSessions = [];
    AppStorage.setOrCreate('focusSyncMessage', '');
    this.activeFocusTask = null;
    this.focusResultDraft = null;
    this.focusRuntime = null;
    this.taskStatusOverrides.clear();
    this.courses = [];
    this.homeworkDDLs = [];
    this.notifyLearningDataChanged();
    this.isDataImported = false;
    this.importedCourseCount = 0;
    this.importedDDLCount = 0;
    this.resetSession();
    this.notifyFocusDataChanged();
  }
}

export const appState: AppState = AppState.getInstance();
