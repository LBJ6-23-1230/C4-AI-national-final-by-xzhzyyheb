import { DeviceSummary } from '../components/DeviceSummary';
import { AppBottomBar } from '../components/AppBottomBar';
import { LearningStatCard } from '../components/LearningStatCard';
import { UiTheme } from '../utils/UiTheme';
import { CourseReviewReminder } from '../components/CourseReviewReminder';
import router from '@ohos.router';
import { UserAvatar } from '../components/UserAvatar';
import { appState } from '../data/AppState';
import { FocusTask, LearningPlanTask, WeeklyLearningPlan } from '../models/AgentModels';
import { LocalAgentService } from '../services/LocalAgentService';
import { DateHelper } from '../utils/DateHelper';
import { ChatNavigation } from '../services/ChatNavigation';
import { AIFloatButton } from '../components/AIFloatButton';
import { FactorBreakdownCard } from '../components/FactorBreakdownCard';
import { AgentApiClient, ApiClientConfig } from '../api/AgentApiClient';
import { ApiDefaults } from '../api/ApiDefaults';
import { LearningPlan, PlanTask, ProactiveResponse, WorkflowResponse, WorkflowStatusResponse } from '../api/ApiModels';
import { ClientCache } from '../cache/ClientCache';
import { WorkflowViewModel } from '../viewmodels/WorkflowViewModel';
import { ApiDisplayFormatter } from '../utils/ApiDisplayFormatter';
import { PlanViewModel } from '../viewmodels/PlanViewModel';
import { ProactiveViewModel } from '../viewmodels/ProactiveViewModel';
import { common } from '@kit.AbilityKit';
import { LearningCardService } from '../services/LearningCardService';
import { WorkflowSessionStore } from '../cache/WorkflowSessionStore';
import { AuthClient } from '../api/AuthClient';
import { AuthStore } from '../api/AuthStore';
import { TodayOverview } from '../api/ReminderModels';
import { TodayStore } from '../services/TodayStore';
import { PendingTasks } from '../utils/PendingTasks';

@Entry
@Component
struct Index {
  @StorageLink('learningDataRevision') @Watch('onLearningDataChanged') learningDataRevision: number = 0;
  @StorageLink('focusDataRevision') @Watch('onFocusDataChanged') focusDataRevision: number = 0;
  @StorageLink('knowledgeSyncMessage') knowledgeSyncMessage: string = '';
  @State wrongBookCount: number = -1;
  @State courseCount: number = 0;
  @State urgentCount: number = 0;
  @State pendingCount: number = appState.getPendingDDLs().length;
  @State pendingTaskCount: number = -1;
  @State planProgress: number = appState.getPlanProgress();
  @State todayMinutes: number = appState.getFocusSummary().todayMinutes;
  @State focusCount: number = appState.focusSessions.length;
  @State streakDays: number = appState.getFocusSummary().streakDays;
  @State refreshKey: number = 0;
  @State profileNickname: string = appState.authNickname;
  @State studyWindowWidth: number = 0;
  @State profileAvatar: string = appState.authAvatar;

  private onLearningDataChanged(): void {
    if (this.isPageActive) this.ensurePlan();
    this.profileNickname = appState.authNickname;
    this.profileAvatar = appState.authAvatar;
    this.courseCount = appState.courses.length;
    this.pendingCount = appState.getPendingDDLs().length;
    this.onFocusDataChanged();
    if (this.activeTab === 2) void this.loadWrongBookCount();
    this.urgentCount = appState.getUrgentDDLs().length;
    this.refreshKey++;
  }

  private onFocusDataChanged(): void {
    const summary = appState.getFocusSummary();
    this.planProgress = appState.getPlanProgress();
    this.todayMinutes = summary.todayMinutes;
    this.focusCount = appState.focusSessions.length;
    this.streakDays = summary.streakDays;
    this.pendingCount = appState.getPendingDDLs().length;
    this.updatePendingTaskCount();
  }

  private pendingOverview: TodayOverview | null = null;
  private pendingOverviewKey: string = '';
  private pendingRequestVersion: number = 0;

  private updatePendingTaskCount(): void {
    const owner: string = appState.currentUser.userId;
    const key: string = TodayStore.key(owner);
    if (key !== this.pendingOverviewKey) {
      this.pendingOverviewKey = key;
      this.pendingOverview = TodayStore.read(getContext(this) as common.Context, owner);
    }
    this.pendingTaskCount = PendingTasks.count(this.pendingOverview, appState.getPendingDDLs().length,
      (id: string): boolean => appState.isTaskCompleted(id, 'pending'));
  }

  private async loadPendingTasks(): Promise<void> {
    const owner: string = appState.currentUser.userId;
    const key: string = TodayStore.key(owner);
    const version: number = ++this.pendingRequestVersion;
    const result = await AgentApiClient.getToday();
    if (!this.isPageActive || version !== this.pendingRequestVersion ||
      owner !== appState.currentUser.userId || key !== TodayStore.key(owner)) return;
    if (result.ok && result.data.userId === owner) {
      this.pendingOverviewKey = key;
      this.pendingOverview = result.data;
      TodayStore.save(getContext(this) as common.Context, result.data);
      this.updatePendingTaskCount();
    }
  }

  /** Show local facts immediately, then reconcile cloud data without clearing the cards. */
  private async refreshLearningStatistics(): Promise<void> {
    const owner: string = appState.currentUser.userId;
    const requestVersion: number = ++this.statisticsRequestVersion;
    try {
      await Promise.all([appState.syncLearningData(), appState.syncFocusSessions(), this.loadPendingTasks()]);
    } catch (error) {
      console.warn('学习统计同步失败，保留本机记录');
    } finally {
      if (this.isPageActive && requestVersion === this.statisticsRequestVersion &&
        owner === appState.currentUser.userId) this.onLearningDataChanged();
    }
  }

  onPageShow(): void {
    this.isPageActive = true;
    this.applyInitialTab();
    this.onLearningDataChanged();
    if (!this.hasShownOnce) {
      this.hasShownOnce = true;
      return;
    }
    // 从导入、计划或专注页返回时，首页的推荐与计划提示都要重新对账。
    void this.loadAgentPlan(true);
    void this.loadProactiveDecision();
    void this.refreshLearningStatistics();
  }
  @State isWorkflowRefreshing: boolean = false;
  @State isAgentPlanLoading: boolean = false;
  @State agentPlan: LearningPlan | null = null;
  @State agentPlanMessage: string = '';
  @State agentPlanKind: string = 'ok';
  @State proactiveDecision: ProactiveResponse | null = null;
  @State proactiveMessage: string = '';
  @State isProactiveLoading: boolean = false;
  /** 切换身份进行中（防连点重复吊销会话）。 */
  @State isSwitchingIdentity: boolean = false;
  /** 当前标签页：0 对话（回对话页）/ 1 我的智能体 / 2 学习 / 3 我的。 */
  @State activeTab: number = 1;
  /** 智能体页的分类筛选，默认「全部」。 */
  @State agentFilter: string = '全部';
  /** 多入口智能体的选择浮层。 */
  @State showRouteSheet: boolean = false;
  @State pendingAgent: AgentSpec | null = null;
  private workflowViewModel: WorkflowViewModel = new WorkflowViewModel();
  private planViewModel: PlanViewModel = new PlanViewModel();
  private proactiveViewModel: ProactiveViewModel = new ProactiveViewModel();
  private workflowRequestVersion: number = 0;
  private planRequestVersion: number = 0;
  private proactiveRequestVersion: number = 0;
  private statisticsRequestVersion: number = 0;
  private isPageActive: boolean = false;
  /** 首帧 onPageShow 与 aboutToAppear 属于同一次进入，避免重复请求。 */
  private hasShownOnce: boolean = false;
  private lastRequestedTab: number = -1;

  aboutToAppear(): void {
    this.isPageActive = true;
    this.applyInitialTab();
    this.onLearningDataChanged();
    void this.loadAgentPlan(true);
    void this.loadProactiveDecision();
    void this.refreshLearningStatistics();
  }

  /**
   * 读取路由参数 `initialTab`，支持从对话页底部标签直达指定标签。
   *
   * 为什么需要：智能体页与学习页都在本页的不同标签里，
   * 对话页点「智能体」时若只 `replaceUrl('pages/Index')`，
   * 会因为本页默认标签是 1 而永远只看到智能体页、看不到学习页。
   * 带参数跳转后，落地标签由调用方决定。
   */
  private applyInitialTab(): void {
    try {
      const params: Record<string, Object> = router.getParams() as Record<string, Object>;
      if (params === undefined || params === null) {
        return;
      }
      const value: Object | undefined = params['initialTab'] as Object | undefined;
      const requested: number = typeof value === 'number' ? value as number : typeof value === 'string' ? Number(value) : -1;
      if (Number.isInteger(requested) && requested >= 0 && requested <= 3 && requested !== this.lastRequestedTab) {
        this.activeTab = requested;
        this.lastRequestedTab = requested;
      }
    } catch (error) {
      // 无参数（正常启动）时保持默认标签，不抛错
    }
  }

  aboutToDisappear(): void {
    this.onPageHide();
  }

  onPageHide(): void {
    this.isPageActive = false;
    this.workflowRequestVersion++;
    this.planRequestVersion++;
    this.proactiveRequestVersion++;
    this.statisticsRequestVersion++;
    this.pendingRequestVersion++;
    this.isWorkflowRefreshing = false;
    this.isAgentPlanLoading = false;
    this.isProactiveLoading = false;
  }

  /**
   * 判断这份 proactive 决策是否真的"有可执行的动作"。
   *
   * 后端在静默情形（专注会话进行中、或未命中任何触发条件）会返回
   * `action.type='none'` + 空 title/hint。这种结果**不该覆盖桌面学习卡** ——
   * 否则用户桌面上的卡片会变成空任务或"不打扰"这类无意义文案。
   *
   * 首页仍然照常展示 `cardData` / `reason`（那是"推荐做什么"），
   * 只是不把它写进卡片。
   */
  private hasActionableDecision(decision: ProactiveResponse): boolean {
    if (decision.action === undefined || decision.action === null) {
      return false;
    }
    return decision.action.type !== 'none' && decision.title.trim().length > 0;
  }

  private async loadProactiveDecision(): Promise<void> {
    this.isProactiveLoading = true;
    this.proactiveMessage = '';
    const requestVersion: number = ++this.proactiveRequestVersion;
    //  不要用 `?? 30` 编一个倒计时：没有课程/考试日期时**如实传 undefined**，
    // 由 `ProactiveViewModel.buildRequest` 决定不下发该字段（后端会跳过考试类判断）。
    // 原来编的 30 会让卡片文案写成"考试剩 30 天（紧迫度贡献 0.000）"，
    // 与计划页的后端口径（5 天 → 0.83）互相矛盾。
    const highPriorityCourse = appState.getHighPriorityCourse();
    const daysLeft: number | undefined = highPriorityCourse !== null
      ? highPriorityCourse.exam.daysLeft : undefined;
    const recentSessions = appState.getFocusSummary().recentSessions;
    const lastStudyAt: string | undefined = recentSessions.length > 0 ? recentSessions[0].endedAt : undefined;
    // `foreground` 传 **false** —— 这一点是修过的缺陷。
    //
    // 原先传 `true`，后端 `agent/proactive.py` 会直接返回静默结果
    // （`action.type='none'`、`title=''`、`hint=''`）。后果有两个：
    //   ① `startProactiveTask()` 与 `isActionReady()` 的第一个分支**变成死代码**；
    //   ② 那个空结果会被 `LearningCardService.saveDecision()` 存成学习卡，
    //      用户在桌面上看到一句"用户当前前台使用应用，暂不打扰"。
    //
    // 语义上也本就不该传 true：`shouldNotify` 回答的是"**要不要发系统通知**"，
    // 而首页只关心"**推荐做什么**"。前台展示与通知投递是两件事 ——
    // 通知投递由 `ProactiveSurfaceService`（App 进后台时）负责。
    const state = await this.proactiveViewModel.load(
      appState.currentUser.userId, daysLeft, false,
      appState.focusRuntime !== null && appState.focusRuntime.ownerId === appState.currentUser.userId && appState.focusRuntime.finishedAt === undefined && appState.focusResultDraft === null,
      lastStudyAt);
    if (!this.isPageActive || requestVersion !== this.proactiveRequestVersion) return;
    this.proactiveDecision = state.decision;
    this.proactiveMessage = state.errorMessage;
    if (state.decision !== null && this.hasActionableDecision(state.decision)) {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      // TodayPanel writes the validated event snapshot used by all surfaces.
    }
    this.isProactiveLoading = false;
  }

  private async loadAgentPlan(forceRefresh: boolean = true): Promise<void> {
    this.isAgentPlanLoading = true;
    this.agentPlanMessage = '';
    const requestVersion: number = ++this.planRequestVersion;
    const state = await this.planViewModel.load(forceRefresh);
    if (!this.isPageActive || requestVersion !== this.planRequestVersion) return;
    this.agentPlan = state.plan;
    this.agentPlanKind = state.kind;
    this.agentPlanMessage = state.errorMessage;
    this.isAgentPlanLoading = false;
    this.onFocusDataChanged();
  }

  private isFixture(): boolean {
    return AgentApiClient.getConfig().useFixture;
  }

  private currentAgentTask(): PlanTask | null {
    if (this.agentPlan === null || this.agentPlan.tasks.length === 0) return null;
    for (let index: number = 0; index < this.agentPlan.tasks.length; index++) {
      const task: PlanTask = this.agentPlan.tasks[index];
      const now: Date = new Date();
      const today: string = `${now.getFullYear()}-${(now.getMonth() + 1).toString().padStart(2, '0')}-${now.getDate().toString().padStart(2, '0')}`;
      if (!appState.isTaskCompleted(task.taskId, task.status) && (!task.scheduledDate || task.scheduledDate <= today)) return task;
    }
    return null;
  }

  private startAgentTask(task: PlanTask): void {
    appState.setFocusTask({
      course: task.sourceCourse || '专项学习',
      task: task.knowledgePointName,
      plannedMinutes: task.durationMinutes,
      source: 'agent',
      mode: 'normal',
      timerType: 'countdown',
      planTaskId: task.taskId
    } as FocusTask);
    router.pushUrl({ url: 'pages/FocusSetup' });
  }

  private startProactiveTask(): void {
    const decision: ProactiveResponse | null = this.proactiveDecision;
    if (decision === null || decision.action.type !== 'focus') return;
    appState.setFocusTask({
      course: '数据结构',
      task: decision.cardData.taskName,
      plannedMinutes: decision.action.preset.durationMinutes ?? decision.cardData.durationMinutes ?? 45,
      source: 'agent',
      mode: 'normal',
      timerType: 'countdown',
      planTaskId: decision.action.preset.taskId
    } as FocusTask);
    router.pushUrl({ url: 'pages/FocusSetup' });
  }

  private async bootstrapWorkflow(): Promise<void> {
    if (this.isWorkflowRefreshing) {
      return;
    }
    this.isWorkflowRefreshing = true;
    const requestVersion: number = ++this.workflowRequestVersion;
    let workflow: WorkflowResponse | null = ClientCache.getWorkflow();
    let created: boolean = false;
    if (workflow === null) {
      workflow = await this.workflowViewModel.start(
        appState.currentUser.learningGoal.goal,
        appState.currentUser.userId
      );
      //  建完必须**持久化**这个会话。
      //
      // 原来只有 `StudyTags`（启动诊断那条路径）会 `WorkflowSessionStore.save`，
      // 而这里是首页每次冷启动都会走的路径：它建完就丢，
      // 于是**每次启动都新造一个 workflow + 一个空 trace，且永远不会被复用** ——
      // 运行库里 workflows/traces 单调增长（实测 45 个计划、19 条轨迹里
      // 相当一部分是这么攒出来的）。存下来之后冷启动就能恢复同一个会话。
      if (workflow !== null) {
        const context: common.UIAbilityContext =
          this.getUIContext().getHostContext() as common.UIAbilityContext;
        WorkflowSessionStore.save(context, workflow, appState.currentUser.userId);
      }
      created = workflow !== null;
    }
    if (workflow !== null) {
      if (created) {
        await this.workflowViewModel.runUntilComplete(1);
      } else {
        await this.workflowViewModel.refreshStatus(true);
      }
      //  自愈：本地缓存的会话在服务端已不存在（典型触发：刚跑过 `demo/reset`，
      //   它会把演示名下的 workflows 清掉）。
      //
      //   光清 `ClientCache` 不够 —— `WorkflowSessionStore` 里还存着同一个 id，
      //   下次冷启动又会把它读回来，用户就永远停在「workflow not found + 重试」
      //   （而重试**永远不会成功**）。这里连持久化一起清，并立刻新建一个会话，
      //   用户不必自己点重试。实测触发路径：重置演示数据 → 回首页。
      if (this.workflowViewModel.wasSessionStale()) {
        // 会话失效：`WorkflowViewModel` 内部**已经**清掉 `ClientCache` 并新建了一个，
        // 这里只负责把**持久化**那份也换掉 —— 否则下次冷启动又会把死 id 读回来。
        //  不要再调 `start()`：那会多建一个用不上的 workflow。
        const staleContext: common.UIAbilityContext =
          this.getUIContext().getHostContext() as common.UIAbilityContext;
        WorkflowSessionStore.clear(staleContext);
        const fresh: WorkflowResponse | null = ClientCache.getWorkflow();
        if (fresh !== null) {
          WorkflowSessionStore.save(staleContext, fresh, appState.currentUser.userId);
        }
      }
    }
    //  这里**不能**加 `if (!this.isFixture())` 的门槛。
    //
    // 原来只在联机模式加载计划，于是离线模式下 `ClientCache` 里没有"用户看得见的那份
    // 计划"，而首页主行动卡带下来的 taskId 是**契约 id**（`task-postorder`）、
    // `appState.weeklyPlan` 里却是本地 id（`agent-数据结构-0`）—— 专注完成后
    // 完成状态匹配不到任何任务，「任务完成度」恒 0%、复盘恒说"还没有完成任务"
    // （文档 P0-2，复现路径正是离线模式）。
    // 离线模式下 `AgentApiClient.getCurrentPlan()` 走 Fixture 传输层，不发网络请求。
    await this.loadAgentPlan(true);
    if (!this.isPageActive || requestVersion !== this.workflowRequestVersion) {
      return;
    }
    this.isWorkflowRefreshing = false;
    this.refreshKey++;
  }

  private ensurePlan(): void {
    if (!this.isFixture()) return;
    if (appState.weeklyPlan === null) {
      appState.setWeeklyPlan(LocalAgentService.generateWeeklyPlan(
        appState.courses, appState.homeworkDDLs, appState.currentUser
      ));
    }
  }

  /**
   * 取当前周计划，**保证非空**。
   *
   *  原实现是 `ensurePlan(); return appState.weeklyPlan!;` —— 这是运行时炸弹：
   * `ensurePlan()` 在**联机模式直接 return**（`weeklyPlan` 只由本地生成路径写入，
   * 服务端从不写它），所以联机模式下 `weeklyPlan` 一直是 `null`，
   * `!` 只是让类型检查闭嘴，运行时照样抛 `Cannot read property 'tasks'of null`。
   *
   * 触发路径：联机模式 + 后端不可达 → 首页主行动卡走「先做一组快速诊断」兜底
   * → `onPrimaryAction()` 求值 `primaryTask()` → 本方法 → 崩溃，
   * 用户点首页主按钮直接闪退（`openExercisePractice()` 永远执行不到）。
   *
   * 现在返回一份**结构合法的空计划**（tasks 为空数组、decisionTrace 字段齐全），
   * 让上层按"今天没有排定任务"走正常兜底，而不是崩溃。
   */
  private plan(): WeeklyLearningPlan {
    this.ensurePlan();
    const current: WeeklyLearningPlan | null = appState.weeklyPlan;
    if (current !== null) {
      return current;
    }
    return {
      weekLabel: '本周',
      tasks: [],
      decisionTrace: {
        inputSummary: '',
        urgencyReason: '',
        weaknessReason: '',
        timeReason: '',
        recommendation: '',
        updatedAt: ''
      },
      adjustmentMessage: ''
    } as WeeklyLearningPlan;
  }

  private todayTasks(): LearningPlanTask[] {
    const todayLabel: string = DateHelper.getTodayLabel();
    return this.plan().tasks.filter((task: LearningPlanTask) =>
      task.dateLabel.indexOf(todayLabel) !== -1 && task.status !== 'completed'
    );
  }

  private primaryTask(): LearningPlanTask | null {
    const today: LearningPlanTask[] = this.todayTasks();
    return today.length > 0 ? today[0] : null;
  }

  private startTask(task: LearningPlanTask): void {
    appState.setFocusTask({
      course: task.course,
      task: task.title,
      plannedMinutes: task.plannedMinutes,
      source: 'agent',
      mode: 'normal',
      timerType: 'countdown',
      planTaskId: task.id
    } as FocusTask);
    router.pushUrl({ url: 'pages/FocusSetup' });
  }

  private openHistory(): void {
    router.pushUrl({ url: 'pages/LearningHistory' });
  }

  // ==========================================================================
  // 首页信息架构（2026-09-18 重构）
  //
  // 设计初衷（docs/前端README.md 5 层工作流）：Agent 的第 3 层「判断层」要挑出
  // **最优**的一步，第 4/5 层把它变成可执行行动。所以首页的正确形态是
  // **「一个最优下一步」+「其他一切收纳」**，而不是把所有功能平铺成并列入口。
  //
  // 重构前的问题：10 个按钮 / 18 个可点区域 / 9 个跳转目标平铺在一起，
  // 用户点进来不知道该干嘛；底部"标签栏"其实是 4 个跳转快捷键（active 写死 true），
  // 「我的」居然跳到学习记录页，点击结果完全不可预期。
  //
  // 重构后：4 个区块 + 真实标签栏，且**身份标签与"我的"标签指向同一个页面**。
  // ==========================================================================

  /** 页头：身份标签可点进「我的」，与底部标签栏指向一致（原来一个进 Account、一个进 LearningHistory）。 */
  /** 页头标题：与底部标签一一对应（0 号「对话」已跳走到 ChatMain，不会在此出现）。 */
  private async loadWrongBookCount(): Promise<void> {
    const owner: string = appState.currentUser.userId;
    const result = await AgentApiClient.getWrongBook();
    if (this.isPageActive && owner === appState.currentUser.userId && result.ok) this.wrongBookCount = result.data.total;
  }

  private headerTitle(): string {
    if (this.activeTab === 1) return '智能体';
    if (this.activeTab === 2) return '学习';
    return '我的';
  }

  /**
   * 底部标签栏。
   *
   *  **必须写成无参 `@Builder`**，且高亮状态在 Builder 内部**直接读 `this.activeTab`**。
   *
   * 原因：ArkTS 的 `@Builder` 函数参数是**按值传递**的，参数变化不会触发该 Builder
   * 重新求值（只有组件所在范围整体重建时才会刷新）。所以
   * `BottomNavItem('⌂', '首页', this.activeTab === 0, ...)` 这种写法里，
   * `active` 是**初次渲染时算好的布尔值**，切换标签后高亮永远停在"首页"——
   * 页面内容已经切走了，标签却还加粗在首页。这正是本次修掉的 bug。
   *
   * 改成无参 Builder 后，`this.activeTab` 是 `@State`，其变化会驱动
   * `TabBar` 所在范围重建，从而正确刷新每一项的高亮。
   */
  /**
   * 能力卡片（对齐参考设计图3）。
   *
   * 每张卡：图标 + 分类标签 / 名称 / 一句话说明 / 可用状态 + 「使用」。
   * 卡片只接收**静态**的 AgentSpec（常量），不含状态，故不存在
   * 「@Builder 参数不触发重渲染」的问题。
   */
  @Builder
  AgentCard(item: AgentSpec) {
    Column({ space: 4 }) {
      Row() {
        Text(item.name).fontSize(17).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).layoutWeight(1)
        Text('›').fontSize(22).fontColor(UiTheme.secondary)
      }.width('100%').constraintSize({ minHeight: 28 }).onClick(() => this.invokeAgent(item))
      Text(item.role).fontSize(13).fontColor(UiTheme.secondary).lineHeight(19).width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(item.routes, (route: AgentRoute) => {
          Text(`${route.label} ›`).fontSize(14).fontColor(UiTheme.accent)
            .constraintSize({ minHeight: 32 }).padding({ right: 20, top: 4, bottom: 4 })
            .onClick(() => this.goRoute(route))
        }, (route: AgentRoute) => route.label)
      }.width('100%')
    }.width('100%').padding({ top: 10, bottom: 10 }).alignItems(HorizontalAlign.Start)
      .border({ width: { bottom: 1 }, color: UiTheme.line })
  }

  /** 「学习」标签里的一行入口。 */
  @Builder
  PanelRow(icon: Resource, title: string, desc: string, target: string) {
    Row({ space: 12 }) {
      Text(title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).layoutWeight(1)
      if (desc.length > 0) { Text(desc).fontSize(12).fontColor(UiTheme.secondary).constraintSize({ maxWidth: '42%' }) }
      Text('›').fontSize(22).fontColor(UiTheme.muted)
    }.width('100%').constraintSize({ minHeight: 56 }).padding({ top: 12, bottom: 12 })
      .border({ width: { bottom: 1 }, color: UiTheme.line })
      .onClick(() => router.pushUrl({ url: target }))
  }

  @Builder
  LearningShortcut(icon: Resource, title: string, detail: string, target: string) {
    Column({ space: 7 }) {
      Image(icon).width(28).height(28).objectFit(ImageFit.Contain)
      Text(title).fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink)
      Text(detail).fontSize(11).fontColor(UiTheme.secondary).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }.layoutWeight(1).padding(14).backgroundColor(UiTheme.surface).borderRadius(8)
      .onClick(() => router.pushUrl({ url: target }))
  }

  private hasLearningData(): boolean { return appState.courses.length > 0 || appState.homeworkDDLs.length > 0; }

  /** 首次导入引导；已有数据时使用紧凑的课程管理入口。 */
  @Builder
  PanelCard(title: string, desc: string, buttonText: string, target: string) {
    Column({ space: 12 }) {
      Text(title).fontSize(17).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).width('100%')
      Text(desc).fontSize(12.5).fontColor(UiTheme.secondary).lineHeight(19).width('100%')
      Button(buttonText)
        .width('100%').height(46).fontSize(14).fontWeight(FontWeight.Bold)
        .fontColor(UiTheme.surface).backgroundColor(UiTheme.accent).borderRadius(8)
        .onClick(() => router.pushUrl({ url: target }))
    }
    .width('100%').padding(18).backgroundColor(UiTheme.surface).borderRadius(8)
    .border({ width: 1, color: UiTheme.line })
  }

  /** 当前唯一推荐行动。首页前台展示不等同于系统通知，因此不依赖 shouldNotify。 */
  @Builder
  PrimaryActionCard() {
    Column({ space: 10 }) {
      Text(this.perceptionLine()).fontSize(11.5).fontColor(UiTheme.secondary).width('100%')
      if (this.hasProactiveTask()) {
        Text(this.proactiveDecision!.cardData.taskName ?? this.proactiveDecision!.title)
          .fontSize(20).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).width('100%')
        Text(this.proactiveDecision!.reason.length > 0
          ? this.proactiveDecision!.reason : this.proactiveDecision!.body)
          .fontSize(12.5).fontColor(UiTheme.secondary).lineHeight(19).width('100%')
      } else if (this.currentAgentTask() !== null) {
        Text(this.currentAgentTask()!.knowledgePointName)
          .fontSize(20).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).width('100%')
        Text('这是 Agent 当前计划中的下一项未完成任务。')
          .fontSize(12.5).fontColor(UiTheme.secondary).lineHeight(19).width('100%')
      } else {
        Text(appState.courses.length === 0 && appState.homeworkDDLs.length === 0 ? '先建立课程与学习目标' : '先做一组快速诊断').fontSize(20).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).width('100%')
        Text(this.proactiveMessage.length > 0 ? this.proactiveMessage : '用一组练习确定当前薄弱点，再生成下一步计划。')
          .fontSize(12.5).fontColor(UiTheme.secondary).lineHeight(19).width('100%')
      }
      Button(this.isActionReady() ? '开始当前任务' : (appState.courses.length === 0 && appState.homeworkDDLs.length === 0 ? '开始建立学习档案' : '开始诊断'))
        .width('100%').height(46).fontSize(14).fontWeight(FontWeight.Bold)
        .fontColor(UiTheme.surface).backgroundColor(UiTheme.accent).borderRadius(8)
        .onClick(() => this.onPrimaryAction())
    }
    .width('100%').padding(18).backgroundColor(UiTheme.surface).borderRadius(8)
    .border({ width: 1, color: '#BFDBFE' })
  }

  /** 计划不存在与计划读取失败是两种事实：首页必须给出不同的下一步。 */
  @Builder
  PlanLoadNotice() {
    Column({ space: 9 }) {
      Text(this.agentPlanKind === 'no_plan' ? '还没有学习计划' : '计划同步提示')
        .fontSize(14).fontWeight(FontWeight.Bold)
        .fontColor(this.agentPlanKind === 'error' ? UiTheme.danger : UiTheme.secondary).width('100%')
      Text(this.agentPlanMessage).fontSize(12).lineHeight(18).fontColor(UiTheme.secondary).width('100%')
      if (this.agentPlanKind === 'no_plan') {
        Button('导入课程，生成计划').width('100%').height(40).fontSize(13)
          .fontColor(UiTheme.surface).backgroundColor(UiTheme.accent).borderRadius(8)
          .onClick(() => router.pushUrl({ url: 'pages/CourseImport', params: { initialTab: 'import' } }))
      } else {
        Button(this.isAgentPlanLoading ? '读取中…' : '重新读取计划').width('100%').height(40).fontSize(13)
          .fontColor(UiTheme.accent).backgroundColor(UiTheme.tint).borderRadius(8)
          .enabled(!this.isAgentPlanLoading)
          .onClick(() => { void this.loadAgentPlan(true); })
      }
    }
    .width('100%').padding(14).backgroundColor(UiTheme.surface).borderRadius(8)
    .border({ width: 1, color: this.agentPlanKind === 'error' ? '#FECACA' : UiTheme.line })
  }

  /** 页头副标题：按标签切换，说明这一页能做什么。 */
  private headerSubtitle(): string {
    if (this.activeTab === 1) return '多智能体助学团：学情诊断 · 学习规划 · 专项练习 · 效果测评 · 阶段复盘。';
    // 学习标签只做"任务从哪来、时间怎么安排"，能力类入口一律去「智能体」页，避免重复。
    if (this.activeTab === 2) return '上传作业 DDL、安排专注任务。';
    return '账号与密码管理、学习数据、我的搭子。';
  }

  /** 按分类过滤能力卡；'全部'返回全部。 */
  private filteredAgents(): AgentSpec[] {
    if (this.agentFilter === '全部') {
      return AGENT_SPECS;
    }
    return AGENT_SPECS.filter((item: AgentSpec) => item.category === this.agentFilter);
  }

  /**
   * 调用某个智能体。
   *
   * **不改任何 Agent 行为**：一个智能体可能对应多个既有页面（`routes`），
   * 这里只负责把用户送到对应页面；所有分析、判分、重规划逻辑仍由后端原有代码完成。
   *
   * 交互取舍：单入口直接跳；多入口用一个轻量 ActionSheet 让用户选，
   * 避免"点一下不知道该去哪"。
   */
  private invokeAgent(item: AgentSpec): void {
    if (item.routes.length === 0) {
      return;
    }
    if (item.routes.length === 1) {
      this.goRoute(item.routes[0]);
      return;
    }
    this.pendingAgent = item;
    this.showRouteSheet = true;
  }

  /** 执行一个入口跳转：有 prompt 的走对话（预填问题），否则直达页面。 */
  private goRoute(route: AgentRoute): void {
    this.showRouteSheet = false;
    if (route.prompt.length > 0) {
      appState.setChatPrompt(route.prompt);
      router.pushUrl({ url: 'pages/ChatMain' });
      return;
    }
    router.pushUrl({ url: route.target });
  }

  /** 多入口选择浮层。 */
  @Builder
  RouteSheet() {
    Column() {
      Column({ space: 14 }) {
        if (this.pendingAgent !== null) {
          Column({ space: 4 }) {
            Text(this.pendingAgent!.name).fontSize(17).fontWeight(FontWeight.Bold)
              .fontColor(UiTheme.ink).width('100%')
            Text(this.pendingAgent!.role).fontSize(12.5).fontColor(UiTheme.secondary).width('100%')
          }.width('100%')

          ForEach(this.pendingAgent!.routes, (route: AgentRoute) => {
            Button(route.label)
              .width('100%').height(46).fontSize(15).fontColor(UiTheme.accent)
              .backgroundColor(UiTheme.tint).borderRadius(8)
              .onClick(() => this.goRoute(route))
          }, (route: AgentRoute) => route.label)

          Button('取消')
            .width('100%').height(42).fontSize(14).fontColor(UiTheme.secondary)
            .backgroundColor(UiTheme.subtle).borderRadius(8)
            .onClick(() => { this.showRouteSheet = false; })
        }
      }
      .width('86%').padding(20).backgroundColor(UiTheme.surface).borderRadius(8)
    }
    .width('100%').height('100%')
    .backgroundColor('rgba(15, 23, 42, 0.45)')
    .justifyContent(FlexAlign.Center)
  }


  @Builder
  TabBar() {
    AppBottomBar({ selected: this.activeTab, onSelect: (index: number) => this.switchTab(index) })
  }

  /**
   * 单个标签项：只接收**静态**参数（图标、文案、下标），
   * 高亮状态一律在内部由 `this.activeTab` 推导，不通过参数传入。
   */
  @Builder
  TabItem(icon: Resource, selectedIcon: Resource, label: string, index: number) {
    Column({ space: 6 }) {
      Image(this.activeTab === index ? selectedIcon : icon)
        .width(22).height(22).objectFit(ImageFit.Contain)
      Text(label).fontSize(12)
        .fontWeight(this.activeTab === index ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.activeTab === index ? UiTheme.accent : UiTheme.secondary)
    }
    .layoutWeight(1).height(62).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    .accessibilityText(label)
    .backgroundColor(this.activeTab === index ? UiTheme.tint : UiTheme.surface).borderRadius(8)
    .onClick(() => { this.switchTab(index); })
  }

  /**
   * 标签切换。
   *
   * 「对话」不是本页的一个标签，而是**另一个页面**（`pages/ChatMain`）。
   * 所以点它必须真的跳过去，不能只把 `activeTab` 置 0 —— 那样会停在本页
   * 一张"回到对话"的中间卡片上，用户还得再点一次才能说话。
   *
   * 用 `replaceUrl` 而不是 `pushUrl`：四个标签是**同级导航**，
   * 用 pushUrl 会让页面栈随每次切换不断增长（来回点几次就退不出去了）。
   * 这一点与 `ChatMain.switchTab` 保持同一套纪律。
   */
  private switchTab(index: number): void {
    if (index === 0) {
      // 对话页自己就是标签 0，直接回去，不产生任何中间页。
      router.replaceUrl({ url: 'pages/ChatMain' });
      return;
    }
    this.activeTab = index;
    this.onLearningDataChanged();
    if (index === 3) {
      void this.loadAgentPlan(true);
      void this.refreshLearningStatistics();
    }
  }

  /**
   * 把后端的**内部标签**翻译成用户看得懂的话。
   *
   *  原来直接把 `contextTags` 原样 `join(' · ')` 显示出来，界面上就出现了
   * `已掌握 0 门课程、0 项临近作业 · exam_within_7d · r…` —— 那是给日志与联调看的
   * 英文枚举，不是给用户看的文案（实测反馈：「有的东西不要写给用户直接看」）。
   *
   * 翻不出来的标签**一律不显示**，宁可少说，也不把内部标识泄给用户。
   */
  private tagLabel(tag: string): string {
    if (tag === 'exam_within_7d' || tag === 'exam_within_7d_low_mastery') {
      return '考试临近';
    }
    if (tag === 'no_study_for_2d' || tag === 'recent_gap_2d') {
      return '两天没学习了';
    }
    if (tag === 'pending_ddl_within_2d') {
      return '有作业快截止';
    }
    if (tag === 'focus_session_active') {
      return '正在专注';
    }
    return '';
  }

  /** Agent 一句话感知摘要：先说"我知道什么"，再说"所以做什么"。 */
  private perceptionLine(): string {
    const courses: number = this.courseCount;
    const ddls: number = this.urgentCount;
    const d: ProactiveResponse | null = this.proactiveDecision;
    if (this.knowledgeSyncMessage.length > 0) return `${courses} 门课程、${ddls} 项临近作业。${this.knowledgeSyncMessage}`;
    if (d !== null && d.contextTags.length > 0) {
      const labels: string[] = [];
      d.contextTags.forEach((tag: string) => {
        const label: string = this.tagLabel(tag);
        if (label.length > 0 && labels.indexOf(label) === -1) {
          labels.push(label);
        }
      });
      if (labels.length > 0) {
        return `已掌握 ${courses} 门课程、${ddls} 项临近作业 · ${labels.join(' · ')}`;
      }
    }
    return `已掌握 ${courses} 门课程、${ddls} 项临近作业`;
  }

  /**
   *  唯一主行动 CTA。
   *
   * 三个候选来源按可靠性排序，**永远只渲染一个按钮**：
   *   1. 后端 proactive 决策（最权威，带 Agent 的 reason 与 factors）
   *   2. 后端当前计划的下一个未完成任务
   *   3. Fixture 今日最优任务
   * 全部不可用时给一个兜底动作（诊断练习），而不是让用户面对空白。
   */
  /** 是否已有明确的 Agent 建议可执行。 */
  private isActionReady(): boolean {
    if (this.hasProactiveTask() && this.proactiveDecision!.action.type === 'focus') {
      return true;
    }
    if (this.currentAgentTask() !== null) {
      return true;
    }
    return this.isFixture() && this.primaryTask() !== null;
  }

  /** 主按钮分派：走的都是既有逻辑（写 focusTask 再跳专注设置页），只是收口到一处。 */
  private onPrimaryAction(): void {
    if (appState.courses.length === 0 && appState.homeworkDDLs.length === 0 && appState.latestWrongAnalysis === null && this.currentAgentTask() === null) {
      router.pushUrl({ url: 'pages/CourseImport' });
      return;
    }
    if (this.hasProactiveTask() && this.proactiveDecision!.action.type === 'focus') {
      this.startProactiveTask();
      return;
    }
    const agentTask: PlanTask | null = this.currentAgentTask();
    if (agentTask !== null) {
      this.startAgentTask(agentTask);
      return;
    }
    //  必须先判 `isFixture()` 再求值 `primaryTask()`。
    // 原写法是 `const fixtureTask = this.primaryTask(); if (this.isFixture() && ...)` ——
    // 参数在 `&&` 之前就已求值，联机模式下 `primaryTask()` 照样被调用，
    // 于是那条"先做一组快速诊断"的兜底路径一点就崩（见 plan() 的注释）。
    const fixtureTask: LearningPlanTask | null = this.isFixture() ? this.primaryTask() : null;
    if (fixtureTask !== null) {
      this.startTask(fixtureTask);
      return;
    }
    this.openExercisePractice();
  }

  /** 空画像返回的 proactive 响应只用于说明“暂无数据”，不能冒充当前任务。 */
  private hasProactiveTask(): boolean {
    return this.proactiveDecision !== null &&
      (this.proactiveDecision!.cardData.taskName ?? '').trim().length > 0;
  }

  private openAccount(): void {
    router.pushUrl({ url: 'pages/Account' });
  }

  /**
   * 回到登录 / 注册界面（切换身份）。
   *
   * **三种身份都要支持**，而不只是"已登录"：
   * * 已登录 → 先 `signOut()` 吊销服务端会话 + 清本地凭据 + 清缓存。
   *   否则 `EntryAbility` 下次启动会读本地凭据直接进主页，
   *   用户会觉得"我明明退出去了怎么又回来了"。
   * * 游客 / 离线 → 没有服务端凭据可吊销，直接跳；离线态还要切回联机数据源，
   *   否则登录成功后仍会走 Fixture 数据。
   *
   * 用 `replaceUrl` 而不是 `pushUrl`：登录页是身份入口，
   * 不该留在返回栈里，否则在登录页按返回又会回到「我的」。
   */
  private async goToLogin(): Promise<void> {
    if (this.isSwitchingIdentity) {
      return;
    }
    this.isSwitchingIdentity = true;
    if (AuthStore.isSignedIn()) {
      await AuthClient.signOut();
      appState.applyLogout();
    }
    // 离线态回到联机，否则登录后仍在读本地 Fixture 数据
    AgentApiClient.setUseFixture(false);
    this.isSwitchingIdentity = false;
    router.replaceUrl({ url: 'pages/Login' });
  }

  /** 诊断练习入口：也是 PrimaryActionCard 在无任何 Agent 建议时的兜底动作。 */
  private openExercisePractice(): void {
    router.pushUrl({ url: 'pages/ExercisePractice' });
  }

  private openAgentTrace(): void {
    router.pushUrl({ url: 'pages/AgentTrace' });
  }

  /** 身份标签：登录用户显示昵称，游客显示"体验身份"。 */
  private identityLabel(): string {
    if (appState.isSignedIn) {
      return this.profileNickname.length > 0 ? this.profileNickname : '我的';
    }
    return '体验身份';
  }

  private apiEnvironmentLabel(): string {
    const config: ApiClientConfig = AgentApiClient.getConfig();
    if (config.useFixture) return 'Fixture';
    return config.baseUrl === ApiDefaults.DEFAULT_BASE_URL ? '真 Agent 后端' : '自定义后端';
  }

  private agentStatusTitle(): string {
    const status: WorkflowStatusResponse | null = ClientCache.getWorkflowStatus();
    if (status !== null && status.currentAgent !== null) {
      return `${ApiDisplayFormatter.agent(status.currentAgent)} · ${ApiDisplayFormatter.workflowStatus(status.status)}`;
    }
    const workflow: WorkflowResponse | null = ClientCache.getWorkflow();
    return workflow === null ? '计划 Agent 已就绪' : `Agent 会话 · ${ApiDisplayFormatter.workflowStatus(workflow.status)}`;
  }

  private agentStatusDetail(): string {
    const status: WorkflowStatusResponse | null = ClientCache.getWorkflowStatus();
    if (status !== null && status.finalAction !== null) {
      return status.finalAction;
    }
    const workflow: WorkflowResponse | null = ClientCache.getWorkflow();
    if (workflow !== null) return `下一步：${ApiDisplayFormatter.nextAction(workflow.nextAction)}`;
    return this.isFixture() ? this.plan().decisionTrace.inputSummary : '等待真 Agent 后端返回会话状态。';
  }

  private returnToChat(): void {
    appState.leaveChatTask();
    ChatNavigation.returnToChat();
  }

  @Builder
  private StudyFocusSection() {
    Column() {
      DeviceSummary()
      Divider().color(UiTheme.line)
      if (appState.focusRuntime !== null && appState.focusRuntime.ownerId === appState.currentUser.userId && appState.focusRuntime.finishedAt === undefined) {
        Column({ space: 8 }) {
          Text('下一项任务').fontSize(12).fontColor(UiTheme.secondary)
          Row({ space: 12 }) {
            Column({ space: 5 }) {
              Text(appState.activeFocusTask?.task || '继续当前专注').fontSize(17).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink)
              Text(`${appState.activeFocusTask?.course || ''} · ${appState.activeFocusTask?.plannedMinutes || 0} 分钟`).fontSize(12).fontColor(UiTheme.secondary)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Button('继续专注', { type: ButtonType.Normal }).fontSize(14).height(44).fontColor(UiTheme.surface)
              .backgroundColor(UiTheme.accent).borderRadius(8).onClick(() => router.pushUrl({ url: 'pages/FocusTimer' }))
          }.width('100%')
        }.width('100%').padding({ top: 20, bottom: 20 }).alignItems(HorizontalAlign.Start)
      } else if (this.currentAgentTask() !== null) {
        Column({ space: 8 }) {
          Text('下一项任务').fontSize(12).fontColor(UiTheme.secondary)
          Row({ space: 12 }) {
            Column({ space: 5 }) {
              Text(this.currentAgentTask()!.knowledgePointName).fontSize(17).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink)
              Text(`${this.currentAgentTask()!.sourceCourse || '学习任务'} · ${this.currentAgentTask()!.durationMinutes} 分钟`).fontSize(12).fontColor(UiTheme.secondary)
              Text('依据：今日或逾期未完成任务，按计划顺序推荐。').fontSize(12).fontColor(UiTheme.secondary)
              Text('查看和调整计划 ›').fontSize(13).fontColor(UiTheme.accent).onClick(() => router.pushUrl({ url: 'pages/StudyPlan' }))
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Button('开始专注', { type: ButtonType.Normal }).fontSize(14).height(44).fontColor(UiTheme.surface)
              .backgroundColor(UiTheme.accent).borderRadius(8).onClick(() => this.startAgentTask(this.currentAgentTask()!))
          }.width('100%')
        }.width('100%').padding({ top: 20, bottom: 20 }).alignItems(HorizontalAlign.Start)
      } else {
        this.PanelRow($r('app.media.feature_focus'), '开始专注', '安排本次学习时间', 'pages/FocusSetup')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private StudyLinks() {
    Column() {
      this.PanelRow($r('app.media.feature_courses'), '课程与作业', `${this.courseCount}门 / ${this.pendingCount}项`, 'pages/CourseImport')
      this.PanelRow($r('app.media.feature_diagnosis'), '错题本', this.wrongBookCount >= 0 ? `${this.wrongBookCount}题` : '', 'pages/WrongBook')
      this.PanelRow($r('app.media.feature_courses'), '我的知识库', '', 'pages/KnowledgeBase')
      this.PanelRow($r('app.media.feature_planner'), '学习计划', '', 'pages/StudyPlan')
      this.PanelRow($r('app.media.feature_review'), '学习目标与考试', '', 'pages/UpcomingExams')
      if (!this.hasLearningData()) {
        this.PanelCard('建立课程与学习目标', '导入课程表与作业截止时间，安排自己的学习任务。', '去上传 / 导入数据', 'pages/CourseImport')
      }
      if (this.agentPlanMessage.length > 0) this.PlanLoadNotice()
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Blank().width(64)
          Text(this.headerTitle()).fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink)
            .layoutWeight(1).textAlign(TextAlign.Center)
          Blank().width(64)
        }.width('100%').height(56).backgroundColor(UiTheme.surface)
        Scroll() {
          Column({ space: 0 }) {
            if (this.activeTab === 1) {
              Row({ space: 6 }) {
                ForEach(AGENT_CATEGORIES, (category: string) => {
                  Button(category === '学情诊断' ? '诊断' : category === '路径规划' ? '规划' : category === '推送练习' ? '练习' : category === '效果评估' ? '测评' : category === '阶段复盘' ? '复盘' : '全部', { type: ButtonType.Normal })
                    .fontSize(12).fontColor(this.agentFilter === category ? UiTheme.surface : UiTheme.secondary)
                    .backgroundColor(this.agentFilter === category ? UiTheme.accent : UiTheme.surface)
                    .border({ width: 1, color: this.agentFilter === category ? UiTheme.accent : UiTheme.line })
                    .borderRadius(8).height(36).layoutWeight(1).padding({ left: 5, right: 5 })
                    .onClick(() => this.agentFilter = category)
                }, (category: string) => category)
              }.width('100%').padding({ top: 12, bottom: 10 })
              ForEach(this.filteredAgents(), (item: AgentSpec) => { this.AgentCard(item) }, (item: AgentSpec) => item.key)
            }
            if (this.activeTab === 2) {
              if (this.studyWindowWidth >= 820) {
                Row({ space: 28 }) {
                  Column() { this.StudyFocusSection() }.layoutWeight(1.2)
                  Column() { this.StudyLinks() }.layoutWeight(1)
                }.width('100%').alignItems(VerticalAlign.Top)
              } else {
                this.StudyFocusSection()
                this.StudyLinks()
              }
            }
            if (this.activeTab === 3) {
              Row({ space: 14 }) {
                UserAvatar({ source: this.profileAvatar, nickname: this.profileNickname, diameter: 52 })
                Column({ space: 6 }) {
                  Text(this.profileNickname || '我的').fontSize(19).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink)
                  Text(appState.isSignedIn ? '编辑资料 ›' : '登录 ›').fontSize(13).fontColor(UiTheme.secondary)
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              }.width('100%').padding({ top: 20, bottom: 24 })
                .onClick(() => router.pushUrl({ url: appState.isSignedIn ? 'pages/EditProfile' : 'pages/Login' }))
              Row() {
                LearningStatCard({ value: `${this.planProgress}%`, label: '任务\n完成度' })
                LearningStatCard({ value: `${this.todayMinutes}分钟`, label: '今日\n专注' })
                LearningStatCard({ value: `${this.focusCount}次`, label: '专注\n记录 ›', target: 'pages/LearningHistory' })
                LearningStatCard({ value: `${this.streakDays}天`, label: '连续\n学习' })
                LearningStatCard({ value: this.pendingTaskCount < 0 ? '—' : `${this.pendingTaskCount}项`, label: '待办\n任务 ›', target: 'pages/CourseImport' })
              }.width('100%').border({ width: 1, color: UiTheme.line }).borderRadius(8).margin({ bottom: 24 })
              this.PanelRow($r('app.media.feature_assessment'), '学习报告', '', 'pages/ReviewSummary')
              this.PanelRow($r('app.media.feature_focus'), '专注记录', '', 'pages/LearningHistory')
              this.PanelRow($r('app.media.feature_courses'), '学习目标记录', '', 'pages/LearningRecords')
              this.PanelRow($r('app.media.feature_partner'), '搭子与协同', '', 'pages/PartnerMatch')
              this.PanelRow($r('app.media.feature_review'), '提醒设置', '', 'pages/Reminders')
              this.PanelRow($r('app.media.feature_review'), '账号、安全与隐私', '', 'pages/Account')
            }
          }.width('100%').constraintSize({ maxWidth: this.activeTab === 2 && this.studyWindowWidth >= 820 ? 1120 : UiTheme.contentWidth })
            .padding({ left: 20, right: 20, bottom: 24 })
        }.width('100%').layoutWeight(1).align(this.activeTab === 2 ? Alignment.Top : Alignment.TopStart).scrollBar(BarState.Off)
          .onAreaChange((_old: Area, area: Area) => { this.studyWindowWidth = Number(area.width); })
        this.TabBar()
      }.width('100%').height('100%').backgroundColor(UiTheme.surface)
      AIFloatButton({ bottomGap: 100 })
      if (this.showRouteSheet) { this.RouteSheet() }
    }.width('100%').height('100%')
  }


}


/** 智能体能力的静态描述（常量，不含状态）。 */
interface AgentSpec {
  key: string;
  icon: Resource;
  name: string;
  category: string;
  /** 一句话职能（比 desc 更短，用于卡片上的粗体副标题）。 */
  role: string;
  desc: string;
  /** 该智能体可直达的页面（一个智能体可对应多个既有页面，不新增 Agent 行为）。 */
  routes: AgentRoute[];
  ready: boolean;
}

/** 智能体下的一个可直达入口。 */
interface AgentRoute {
  label: string;
  target: string;
  prompt: string;
}

/**
 * 本项目的 Agent 能力清单 —— 与后端 6 类意图 + 各功能页一一对应。
 *
 * 这张表就是「我的智能体」页的唯一数据源；增删能力只改这里。
 * `prompt` 非空表示该能力走对话链路（预填问题后进对话页）；
 * `target` 是直达页面；`target === 'pages/Index'` 表示回到首页主行动卡。
 */
/**
 * 本项目的多智能体助学团 —— 对齐指导老师建议的四智能体架构：
 *
 *   诊断智能体（学情诊断） → 规划智能体（路径规划）
 *                          → 练习智能体（推送练习）
 *                          → 测评智能体（效果评估）
 *   秘书智能体（总控编排）统筹上面四个，决定"下一步叫谁"。
 *
 *  **后端逻辑完全未改动**：这 5 张卡只是把既有页面/意图**归并展示**，
 * 每个 `routes` 仍指向原有页面，不新增也不删除任何 Agent 行为。
 *
 * 为什么从 12 张收到 5 张：原先把「学习记录 / 课程导入 / 专注模式 / 学习复盘」
 * 这类**功能页**也当成了智能体，导致"智能体"这个概念被稀释。
 * 按老师给的架构，智能体应当对应**认知职能**，功能页归到「学习」标签。
 */
const AGENT_SPECS: AgentSpec[] = [
  {
    key: 'diagnosis', icon: $r('app.media.feature_diagnosis'), name: '诊断智能体', category: '学情诊断',
    role: '找出你哪里薄弱',
    desc: '读取错题与练习记录，定位知识点短板与错误类型，形成可复核的学情证据。',
    routes: [
      { label: '错题诊断', target: 'pages/WrongQuestion', prompt: '' },
      { label: '学情画像', target: 'pages/StudyTags', prompt: '' }
    ],
    ready: true
  },
  {
    key: 'planner', icon: $r('app.media.feature_planner'), name: '规划智能体', category: '路径规划',
    role: '生成并调整学习计划',
    desc: '根据目标、课程与DDL、可用时间和掌握度生成学习计划；练习完成或时间改变后重新安排任务。',
    routes: [
      { label: '学习计划', target: 'pages/StudyPlan', prompt: '' }
    ],
    ready: true
  },
  {
    key: 'exercise', icon: $r('app.media.feature_exercise'), name: '练习智能体', category: '推送练习',
    role: '按薄弱点推题',
    desc: '按知识点抽取题目并计时专注，提交后由确定性代码判分，掌握度随之更新。',
    routes: [
      { label: '专项练习', target: 'pages/ExercisePractice', prompt: '' }
    ],
    ready: true
  },
  {
    key: 'assessment', icon: $r('app.media.feature_assessment'), name: '测评智能体', category: '效果评估',
    role: '评估练习表现',
    desc: '汇总练习记录，查看需巩固与待复测的知识点；做题和解析统一进入练习智能体。',
    routes: [
      { label: '学习报告', target: 'pages/ReviewSummary', prompt: '' }
    ],
    ready: true
  },
  {
    key: 'secretary', icon: $r('app.media.feature_secretary'), name: '秘书智能体', category: '阶段复盘',
    role: '复盘学习记录并安排下一步',
    desc: '读取阶段学习记录、错题和考试日期，生成有依据、有时长、有完成条件的复习行动。',
    routes: [
      { label: '阶段复盘与考前建议', target: 'pages/LearningReview', prompt: '' }
    ],
    ready: true
  }
];

/** 首页横滑区的常用智能体（全部 5 个）。 */
const QUICK_AGENTS: AgentSpec[] = AGENT_SPECS;

/** 能力分类筛选项。 */
const AGENT_CATEGORIES: string[] = ['全部', '学情诊断', '路径规划', '推送练习', '效果评估', '阶段复盘'];
