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
  @State contentViewportWidth: number = 0;
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
  @State isSwitchingIdentity: boolean = false;
  @State activeTab: number = 1;
  @State agentFilter: string = '全部';
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
    const highPriorityCourse = appState.getHighPriorityCourse();
    const daysLeft: number | undefined = highPriorityCourse !== null
      ? highPriorityCourse.exam.daysLeft : undefined;
    const recentSessions = appState.getFocusSummary().recentSessions;
    const lastStudyAt: string | undefined = recentSessions.length > 0 ? recentSessions[0].endedAt : undefined;
    const state = await this.proactiveViewModel.load(
      appState.currentUser.userId, daysLeft, false,
      appState.focusRuntime !== null && appState.focusRuntime.ownerId === appState.currentUser.userId && appState.focusRuntime.finishedAt === undefined && appState.focusResultDraft === null,
      lastStudyAt);
    if (!this.isPageActive || requestVersion !== this.proactiveRequestVersion) return;
    this.proactiveDecision = state.decision;
    this.proactiveMessage = state.errorMessage;
    if (state.decision !== null && this.hasActionableDecision(state.decision)) {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
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
      if (this.workflowViewModel.wasSessionStale()) {
        const staleContext: common.UIAbilityContext =
          this.getUIContext().getHostContext() as common.UIAbilityContext;
        WorkflowSessionStore.clear(staleContext);
        const fresh: WorkflowResponse | null = ClientCache.getWorkflow();
        if (fresh !== null) {
          WorkflowSessionStore.save(staleContext, fresh, appState.currentUser.userId);
        }
      }
    }
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

  private headerSubtitle(): string {
    if (this.activeTab === 1) return '多智能体助学团：学情诊断 · 学习规划 · 专项练习 · 效果测评 · 阶段复盘。';
    if (this.activeTab === 2) return '上传作业 DDL、安排专注任务。';
    return '账号与密码管理、学习数据、我的搭子。';
  }

  private filteredAgents(): AgentSpec[] {
    if (this.agentFilter === '全部') {
      return AGENT_SPECS;
    }
    return AGENT_SPECS.filter((item: AgentSpec) => item.category === this.agentFilter);
  }

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

  private goRoute(route: AgentRoute): void {
    this.showRouteSheet = false;
    if (route.prompt.length > 0) {
      appState.setChatPrompt(route.prompt);
      router.pushUrl({ url: 'pages/ChatMain' });
      return;
    }
    router.pushUrl({ url: route.target });
  }

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
      .width('86%').constraintSize({ maxWidth: UiTheme.dialogWidth }).padding(20).backgroundColor(UiTheme.surface).borderRadius(8)
    }
    .width('100%').height('100%')
    .backgroundColor('rgba(15, 23, 42, 0.45)')
    .justifyContent(FlexAlign.Center)
  }


  @Builder
  TabBar() {
    AppBottomBar({ selected: this.activeTab, onSelect: (index: number) => this.switchTab(index) })
  }

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

  private switchTab(index: number): void {
    if (index === 0) {
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

  private isActionReady(): boolean {
    if (this.hasProactiveTask() && this.proactiveDecision!.action.type === 'focus') {
      return true;
    }
    if (this.currentAgentTask() !== null) {
      return true;
    }
    return this.isFixture() && this.primaryTask() !== null;
  }

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
    const fixtureTask: LearningPlanTask | null = this.isFixture() ? this.primaryTask() : null;
    if (fixtureTask !== null) {
      this.startTask(fixtureTask);
      return;
    }
    this.openExercisePractice();
  }

  private hasProactiveTask(): boolean {
    return this.proactiveDecision !== null &&
      (this.proactiveDecision!.cardData.taskName ?? '').trim().length > 0;
  }

  private openAccount(): void {
    router.pushUrl({ url: 'pages/Account' });
  }

  private async goToLogin(): Promise<void> {
    if (this.isSwitchingIdentity) {
      return;
    }
    this.isSwitchingIdentity = true;
    if (AuthStore.isSignedIn()) {
      await AuthClient.signOut();
      appState.applyLogout();
    }
    AgentApiClient.setUseFixture(false);
    this.isSwitchingIdentity = false;
    router.replaceUrl({ url: 'pages/Login' });
  }

  private openExercisePractice(): void {
    router.pushUrl({ url: 'pages/ExercisePractice' });
  }

  private openAgentTrace(): void {
    router.pushUrl({ url: 'pages/AgentTrace' });
  }

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
              if (this.contentViewportWidth >= UiTheme.wideBreakpoint) {
                GridRow({ columns: 2, gutter: { x: 28 } }) {
                  ForEach(this.filteredAgents(), (item: AgentSpec) => {
                    GridCol() { this.AgentCard(item) }
                  }, (item: AgentSpec) => item.key)
                }.width('100%').alignItems(ItemAlign.Start)
              } else {
                ForEach(this.filteredAgents(), (item: AgentSpec) => { this.AgentCard(item) }, (item: AgentSpec) => item.key)
              }
            }
            if (this.activeTab === 2) {
              if (this.contentViewportWidth >= UiTheme.wideBreakpoint) {
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
                LearningStatCard({ value: ApiDisplayFormatter.focusDuration(this.todayMinutes), label: '今日\n专注' })
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
          }.width('100%').constraintSize({
            maxWidth: (this.activeTab === 1 || this.activeTab === 2) && this.contentViewportWidth >= UiTheme.wideBreakpoint
              ? UiTheme.workspaceWidth : UiTheme.contentWidth
          })
            .padding({ left: 20, right: 20, bottom: 24 })
        }.width('100%').layoutWeight(1)
          .align(Alignment.Top)
          .scrollBar(BarState.Off)
          .onAreaChange((_old: Area, area: Area) => { this.contentViewportWidth = Number(area.width); })
        this.TabBar()
      }.width('100%').height('100%').backgroundColor(UiTheme.surface)
      AIFloatButton({ bottomGap: 100 })
      if (this.showRouteSheet) { this.RouteSheet() }
    }.width('100%').height('100%')
  }


}


interface AgentSpec {
  key: string;
  icon: Resource;
  name: string;
  category: string;
  role: string;
  desc: string;
  routes: AgentRoute[];
  ready: boolean;
}

interface AgentRoute {
  label: string;
  target: string;
  prompt: string;
}

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

const QUICK_AGENTS: AgentSpec[] = AGENT_SPECS;

const AGENT_CATEGORIES: string[] = ['全部', '学情诊断', '路径规划', '推送练习', '效果评估', '阶段复盘'];
