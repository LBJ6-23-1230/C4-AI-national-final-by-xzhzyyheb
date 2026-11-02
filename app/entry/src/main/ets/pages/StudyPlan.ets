import { CourseLabels } from '../utils/CourseLabels';
import { PlanStep, CalendarDay } from '../api/ApiModels';
import router from '@ohos.router';
import { appState } from '../data/AppState';
import { CourseInfo, FocusTask, HomeworkDDL } from '../models/AgentModels';
import { KnowledgeMastery, LearningPlan, PlanTask, PlanBudgetRequest, PlanTaskScheduleRequest, PlanDiff } from '../api/ApiModels';
import { PlanViewModel } from '../viewmodels/PlanViewModel';
import { PlanDiffCard } from '../components/PlanDiffCard';
import { ClientCache } from '../cache/ClientCache';
import { AgentApiClient } from '../api/AgentApiClient';
import { ApiFailure } from '../api/ApiResult';

/** Displays the authoritative plan returned by the workflow API. */
@Entry
@Component
struct StudyPlan {
  @StorageLink('focusDataRevision') @Watch('onFocusDataChanged') focusDataRevision: number = 0;
  @State isApiPlanLoading: boolean = true;
  @State apiPlan: LearningPlan | null = null;
  @State apiPlanMessage: string = '';
  @State selectedCourse: string = '';
  @State showReason: boolean = false;
  @State showDeferred: boolean = true;
  @State showCandidates: boolean = false;
  @State activeView: string = 'today';
  @State splitTaskId: string = '';
  @State splitText: string = '';
  @State calendarDays: CalendarDay[] = [];
  @State budgetText: string = '60';
  @State budgetMessage: string = '';
  @State budgetSaving: boolean = false;
  @State budgetDiff: PlanDiff | null = null;
  private pendingBudget: PlanBudgetRequest | null = null;
  private pendingBudgetOwner: string = '';
  @State schedulingTaskId: string = '';
  @State deferredMessage: string = '';
  private pendingSchedule: PlanTaskScheduleRequest | null = null;
  private pendingScheduleOwner: string = '';
  @State conversationTasks: HomeworkDDL[] = [];
  private planViewModel: PlanViewModel = new PlanViewModel();
  private planRequestVersion: number = 0;
  private isPageActive: boolean = false;
  /** 首帧的 `onPageShow` 与 `aboutToAppear` 是同一次进入，不重复请求。 */
  private hasShownOnce: boolean = false;
  @State planKind: string = 'ok';

  aboutToAppear(): void {
    this.isPageActive = true;
    this.conversationTasks = appState.homeworkDDLs.filter((task: HomeworkDDL): boolean =>
      task.id.startsWith('chat-ddl-') ||
      (task.origin === 'chat' && !task.id.startsWith('ddl-csv-') && !task.id.startsWith('ddl-json-')));
    const params = router.getParams() as Record<string, string>;
    if (params?.['courseName'] && CourseLabels.valid(params['courseName'])) this.selectedCourse = params['courseName'];
    this.loadCurrentPlan();
  }

  aboutToDisappear(): void {
    this.isPageActive = false;
    this.planRequestVersion++;
  }

  /**
   * 从课程/资料导入页、专注页返回时刷新。
   *
   * 原实现只在 `aboutToAppear` 读一次；`router.pushUrl` 打开的页返回不会重入
   * `aboutToAppear`，于是导入完课程再回到计划页，看到的还是"本账号暂无计划"。
   */
  onPageShow(): void {
    this.isPageActive = true;
    if (!this.hasShownOnce) {
      this.hasShownOnce = true;
      return;
    }
    void this.loadCurrentPlan(true);
  }

  onPageHide(): void {
    this.isPageActive = false;
    this.planRequestVersion++;
    // 同上：被版本校验丢弃的请求不会复位加载态。
    this.isApiPlanLoading = false;
  }

  private openCourseImport(): void {
    router.pushUrl({ url: 'pages/CourseImport', params: { initialTab: 'import' } });
  }

  private openChatGoal(): void {
    appState.setChatPrompt('帮我安排今天的学习：先看看我哪些知识点最薄弱，再给一个今天能做完的计划。');
    appState.leaveChatTask();
    router.pushUrl({ url: 'pages/ChatMain' });
  }

  private onFocusDataChanged(): void {
    if (this.isPageActive) void this.loadCurrentPlan(true);
  }

  private async loadCurrentPlan(forceRefresh: boolean = false): Promise<void> {
    if (this.isApiPlanLoading && forceRefresh) return;
    const requestVersion: number = ++this.planRequestVersion;
    this.isApiPlanLoading = true;
    const state = await this.planViewModel.load(forceRefresh);
    if (!this.isPageActive || requestVersion !== this.planRequestVersion) return;
    this.apiPlan = state.plan;
    this.prepareCalendar();
    if (!CourseLabels.valid(this.selectedCourse)) this.selectedCourse = CourseLabels.valid(state.plan?.targetCourse ?? '') ? state.plan!.targetCourse! : '';
    this.planKind = state.kind;
    if (this.pendingBudget === null && state.plan?.budgetSummary !== undefined) {
      this.budgetText = state.plan.budgetSummary.availableMinutes.toString();
    }
    this.apiPlanMessage = state.errorMessage;
    this.isApiPlanLoading = false;
  }

  private prepareCalendar(): void {
    const days: CalendarDay[] = [];
    for (let i: number = 0; i < 7; i++) {
      const date: Date = new Date(); date.setDate(date.getDate() + i);
      const key: string = `${date.getFullYear()}-${(date.getMonth() + 1).toString().padStart(2, '0')}-${date.getDate().toString().padStart(2, '0')}`;
      const saved: CalendarDay | undefined = this.apiPlan?.calendarDays?.find((day: CalendarDay) => day.date === key);
      days.push({ date: key, minutes: saved?.minutes ?? (this.apiPlan?.calendarDays?.length ? 0 : i === 0 ? this.apiPlan?.budgetSummary?.availableMinutes ?? 0 : 0) });
    }
    this.calendarDays = days;
  }
  private updateDay(index: number, value: string): void {
    const minutes: number = Number(value);
    if (!Number.isInteger(minutes) || minutes < 0 || minutes > 1440) { this.budgetMessage = '每日时长须为0到1440的整数'; return; }
    const days: CalendarDay[] = this.calendarDays.slice();
    days[index] = { date: days[index].date, minutes: minutes }; this.calendarDays = days;
  }
  private async splitTask(task: PlanTask): Promise<void> {
    if (this.apiPlan === null || this.budgetSaving) return;
    const steps: PlanStep[] = this.splitText.split('\n').filter((line: string) => line.trim().length > 0).map((line: string): PlanStep => {
      const parts: string[] = line.split('|'); return { title: parts[0].trim(), minutes: parts.length === 2 ? Number(parts[1]) : 0 };
    });
    if (steps.length < 2 || steps.some((step: PlanStep) => !step.title || !Number.isInteger(step.minutes) || step.minutes <= 0) || steps.reduce((sum: number, step: PlanStep) => sum + step.minutes, 0) !== task.durationMinutes) {
      this.deferredMessage = `请填写至少两个步骤，时长合计须为${task.durationMinutes}分钟。`; return;
    }
    const owner: string = appState.currentUser.userId;
    const version: number = ++this.planRequestVersion;
    this.budgetSaving = true;
    const result = await AgentApiClient.splitPlanTask({ taskId: task.taskId, expectedPlanVersion: this.apiPlan.version, steps: steps });
    this.budgetSaving = false;
    if (!this.isPageActive || owner !== appState.currentUser.userId || version !== this.planRequestVersion) return;
    if (result.ok) { this.apiPlan = result.data; this.splitTaskId = ''; this.deferredMessage = '步骤已保存，请确认上方每日时长后生成排期。'; }
    else this.deferredMessage = (result as ApiFailure).error.message;
  }

  private async saveCalendar(): Promise<void> {
    if (this.apiPlan === null || this.budgetSaving) return;
    const owner: string = appState.currentUser.userId;
    const version: number = ++this.planRequestVersion;
    this.budgetSaving = true;
    const result = await AgentApiClient.scheduleCalendar({ days: this.calendarDays, expectedPlanVersion: this.apiPlan.version });
    if (!this.isPageActive || owner !== appState.currentUser.userId || version !== this.planRequestVersion) return;
    this.budgetSaving = false;
    if (result.ok) { this.apiPlan = result.data; this.budgetMessage = '已按每日时长排期，未安排内容与原因保留在下方。'; }
    else this.budgetMessage = (result as ApiFailure).error.message;
  }

  private visibleTasks(): PlanTask[] {
    const today: string = this.todayDate();
    return (this.apiPlan?.tasks ?? []).filter((task: PlanTask) => this.activeView === 'full' ||
      (!appState.isTaskCompleted(task.taskId, task.status) && (!task.scheduledDate || task.scheduledDate <= today)));
  }
  private todayDate(): string {
    const now: Date = new Date();
    return `${now.getFullYear()}-${(now.getMonth() + 1).toString().padStart(2, '0')}-${now.getDate().toString().padStart(2, '0')}`;
  }
  private pendingTodayDDLs(): HomeworkDDL[] {
    const scheduled: string[] = (this.apiPlan?.tasks ?? []).map((task: PlanTask) => task.taskId);
    return appState.homeworkDDLs.filter((task: HomeworkDDL) => !task.completed && task.dueDate <= this.todayDate() && scheduled.indexOf(task.id) < 0);
  }
  private budgetExplanation(): string {
    const summary = this.apiPlan?.budgetSummary;
    if (summary === undefined) return '';
    const mode: string = summary.allocationMode ?? '';
    return (mode === 'under_budget' ? '时间不足，已优先安排紧迫任务；其余保留在完整计划。' : mode === 'exact_budget' ? '时间刚好覆盖当前任务，已全部加入本次安排。' : '时间充足，已为现有任务安排额外巩固。') + (summary.allocationReason ?? '');
  }
  private courseChoices(): string[] {
    const choices: string[] = appState.courses.map((c: CourseInfo): string => c.courseName);
    appState.homeworkDDLs.forEach((ddl: HomeworkDDL) => {
      if (choices.indexOf(ddl.courseName) < 0) choices.push(ddl.courseName);
    });
    (this.apiPlan?.candidatePool ?? []).forEach((point: KnowledgeMastery) => {
      const name: string = point.sourceCourse ?? '';
      if (name.length > 0 && choices.indexOf(name) < 0) choices.push(name);
    });
    return choices.filter((name: string, index: number) => CourseLabels.valid(name) && choices.indexOf(name) === index);
  }

  private startTask(task: PlanTask): void {
    appState.setFocusTask({
      course: task.sourceCourse ?? '专项学习', task: task.knowledgePointName, plannedMinutes: task.durationMinutes,
      source: 'agent', mode: 'normal', timerType: 'countdown', planTaskId: task.taskId
    } as FocusTask);
    router.pushUrl({ url: 'pages/FocusSetup' });
  }

  private async applyBudget(minutes: number): Promise<void> {
    if (this.budgetSaving || this.apiPlan === null) return;
    if (!Number.isInteger(minutes) || minutes < 0 || minutes > 1440) {
      this.budgetMessage = '请输入0到1440之间的整数分钟。';
      return;
    }
    if (AgentApiClient.getConfig().useFixture) {
      this.budgetMessage = '时间预算调整需要连接服务，离线演示计划保持原样。';
      return;
    }
    const owner: string = ClientCache.currentOwnerUserId();
    if (this.pendingBudget === null || this.pendingBudget.availableMinutes !== minutes || this.pendingBudget.targetCourse !== this.selectedCourse || this.pendingBudgetOwner !== owner) {
      this.pendingBudget = { availableMinutes: minutes, targetCourse: this.selectedCourse, expectedPlanVersion: this.apiPlan.version,
        idempotencyKey: `availability-${Date.now()}-${Math.random().toString(36).substring(2, 8)}` };
      this.pendingBudgetOwner = owner;
    }
    this.budgetSaving = true;
    const requestVersion: number = ++this.planRequestVersion;
    const result = await this.planViewModel.updateBudget(this.pendingBudget);
    this.budgetSaving = false;
    if (!this.isPageActive || owner !== ClientCache.currentOwnerUserId() || requestVersion !== this.planRequestVersion) return;
    if (result.ok) {
      this.apiPlan = result.data.plan;
      this.budgetText = minutes.toString();
      this.budgetDiff = result.data.changed ? result.data.planDiff : null;
      this.budgetMessage = this.budgetExplanation();
      this.pendingBudget = null;
      this.pendingSchedule = null;
      this.deferredMessage = '';
    } else {
      const failure: ApiFailure = result as ApiFailure;
      this.budgetMessage = failure.error.message;
      if (failure.error.statusCode === 409 || failure.error.code === 'STALE_PLAN') {
        this.pendingBudget = null;
        await this.loadCurrentPlan(true);
      }
    }
  }

  private scheduledMinutes(): number {
    return (this.apiPlan?.tasks ?? []).filter((task: PlanTask): boolean => task.status !== 'completed' && (!task.scheduledDate || task.scheduledDate <= this.todayDate()))
      .reduce((total: number, task: PlanTask): number => total + task.durationMinutes, 0);
  }

  private budgetAfterAdding(task: PlanTask): number {
    return Math.max(this.apiPlan?.budgetSummary?.availableMinutes ?? 0, this.scheduledMinutes() + task.durationMinutes);
  }

  private canScheduleTask(task: PlanTask): boolean {
    return Number.isInteger(task.durationMinutes) && task.durationMinutes > 0 && this.budgetAfterAdding(task) <= 1440;
  }

  private scheduleHint(task: PlanTask): string {
    if (!Number.isInteger(task.durationMinutes) || task.durationMinutes <= 0) return '请先在任务来源处补充预计时长';
    const total: number = this.budgetAfterAdding(task);
    if (total > 1440) return '加入后超过一天，请先调整当前计划';
    const extra: number = total - (this.apiPlan?.budgetSummary?.availableMinutes ?? 0);
    return extra > 0 ? `加入后本次可用时间为${total}分钟（增加${extra}分钟）` : '本次剩余时间足够，无需增加时间预算';
  }

  private confirmSchedule(task: PlanTask): void {
    const extra: number = this.budgetAfterAdding(task) - (this.apiPlan?.budgetSummary?.availableMinutes ?? 0);
    if (extra <= 0) { void this.scheduleDeferredTask(task); return; }
    AlertDialog.show({ title: '确认增加可用学习时间', message: `当前预算不足。加入「${task.knowledgePointName}」需要增加${extra}分钟，调整为${this.budgetAfterAdding(task)}分钟。`,
      primaryButton: { value: '暂不加入', action: () => {} }, secondaryButton: { value: '确认增加并加入', action: () => { void this.scheduleDeferredTask(task); } } });
  }

  private async scheduleDeferredTask(task: PlanTask): Promise<void> {
    if (this.budgetSaving || this.isApiPlanLoading || this.apiPlan === null || !this.canScheduleTask(task)) return;
    if (AgentApiClient.getConfig().useFixture) {
      this.deferredMessage = '加入任务需要连接服务，请先切换到在线服务。';
      return;
    }
    const owner: string = ClientCache.currentOwnerUserId();
    if (this.pendingSchedule === null || this.pendingSchedule.taskId !== task.taskId || this.pendingScheduleOwner !== owner) {
      this.pendingSchedule = { taskId: task.taskId, expectedPlanVersion: this.apiPlan.version,
        idempotencyKey: `schedule-${Date.now()}-${Math.random().toString(36).substring(2, 8)}` };
      this.pendingScheduleOwner = owner;
    }
    this.budgetSaving = true;
    this.schedulingTaskId = task.taskId;
    this.deferredMessage = '';
    const requestVersion: number = ++this.planRequestVersion;
    const result = await this.planViewModel.scheduleTask(this.pendingSchedule);
    this.budgetSaving = false;
    this.schedulingTaskId = '';
    if (!this.isPageActive || owner !== ClientCache.currentOwnerUserId() || requestVersion !== this.planRequestVersion) return;
    if (result.ok) {
      this.apiPlan = result.data.plan;
      this.budgetText = (result.data.plan.budgetSummary?.availableMinutes ?? 0).toString();
      this.budgetDiff = result.data.planDiff;
      this.budgetMessage = '';
      this.deferredMessage = `已将「${task.knowledgePointName}」加入上方当前任务，可点击“开始任务”。本次可用时间为${this.budgetText}分钟。`;
      this.pendingSchedule = null;
      this.pendingBudget = null;
    } else {
      const failure: ApiFailure = result as ApiFailure;
      this.deferredMessage = failure.error.message;
      if (failure.error.statusCode === 409 || failure.error.statusCode === 404 || failure.error.code === 'STALE_PLAN') {
        this.pendingSchedule = null;
        await this.loadCurrentPlan(true);
      }
    }
  }

  private startCourseTask(task: HomeworkDDL): void {
    appState.setFocusTask({
      course: task.courseName, task: task.title, plannedMinutes: task.estimatedMinutes,
      source: 'course', mode: 'normal', timerType: 'countdown', planTaskId: task.id
    } as FocusTask);
    router.pushUrl({ url: 'pages/FocusSetup' });
  }

  private goBack(): void {
    appState.leaveChatTask();
    router.back();
  }

  private completePlan(): void {
    appState.completeChatTask(
      '当前学习计划已确认。',
      '从第一项专项任务开始，完成后 Agent 会基于新的学习证据更新计划。',
      '查看当前计划',
      'pages/StudyPlan'
    );
    router.back();
  }

  /**
   * 任务状态文案。
   *
   * ⚠️ 必须问 `appState`：接口**不会**回写 `task.status`（后端没有这个接口），
   * 完成状态只存在本地（专注结算时写入）。只按 `task.status` 渲染的话，
   * 用户做完专注回到计划页，任务卡仍然写着「待执行」—— 与「我的」里的
   * 任务完成度互相打架（实测反馈：「为什么无法读取更新后的学习计划」）。
   */
  private taskStatusLabel(task: PlanTask): string {
    if (appState.isTaskCompleted(task.taskId, task.status)) return '已完成';
    if (task.status === 'in_progress') return '进行中';
    return '待执行';
  }

  @Builder
  PlanTaskCard(task: PlanTask) {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 4 }) {
          Text(task.knowledgePointName).fontSize(17).fontWeight(FontWeight.Bold).fontColor('#1F2937').maxLines(2)
          Text(`${task.source === 'ddl' ? '作业' : '专项学习'} · ${task.durationMinutes} 分钟${task.scheduledDate ? ' · ' + task.scheduledDate : ''}`).fontSize(12).fontColor('#667085')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Text(this.taskStatusLabel(task)).fontSize(11).fontWeight(FontWeight.Medium)
          .fontColor('#2563EB').backgroundColor('#FFFFFF').borderRadius(10).padding({ left: 8, right: 8, top: 4, bottom: 4 })
      }.width('100%')
      if (task.allocationReason) Text(task.allocationReason).fontSize(12).fontColor('#475467').width('100%')
      if (task.steps) ForEach(task.steps, (step: string) => { Text('· ' + step).fontSize(13).fontColor('#475467').width('100%') })
      if (task.priority !== undefined) {
        Text(task.priority === 'high' ? '优先处理' : task.priority === 'medium' ? '优先级：中' : task.priority === 'low' ? '优先级：低' : `优先级：${task.priority}`)
          .fontSize(12).fontColor('#475467').width('100%')
      }
      // 已完成的任务不再给「开始任务」—— 判据与上面那行文案**同源**（都走 appState）。
      if (!appState.isTaskCompleted(task.taskId, task.status)) {
        Button('开始任务').width('100%').height(42).fontSize(13).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
          .backgroundColor('#2563EB').borderRadius(12).onClick(() => this.startTask(task))
      }
    }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(18).border({ width: 1, color: '#EAECF0' })
  }

  @Builder
  CourseTaskCard(task: HomeworkDDL) {
    Column({ space: 10 }) {
      Row() {
        Column({ space: 4 }) {
          Text(task.title).fontSize(16).fontWeight(FontWeight.Bold).fontColor('#1F2937').maxLines(2)
          Text(`${task.courseName} · ${task.estimatedMinutes} 分钟`).fontSize(12).fontColor('#667085')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Text(task.priority).fontSize(11).fontColor('#2563EB').backgroundColor('#FFFFFF')
          .borderRadius(10).padding({ left: 8, right: 8, top: 4, bottom: 4 })
      }.width('100%')
      Text(task.dueDate.length > 0 ? `截止：${task.dueDate}` : '暂未设置截止时间')
        .fontSize(12).fontColor('#475467').width('100%')
      Button('开始任务').width('100%').height(42).fontSize(13).fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF').backgroundColor('#2563EB').borderRadius(12)
        .onClick(() => this.startCourseTask(task))
    }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(18)
      .border({ width: 1, color: '#EAECF0' })
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Text('← 返回').fontSize(14).fontColor('#64748B').fontWeight(FontWeight.Medium).onClick(() => this.goBack())
          Blank()
          Text('当前学习计划').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#2563EB')
        }.width('100%').padding({ left: 20, right: 20, top: 18, bottom: 14 }).backgroundColor('#FFFFFF')
        Scroll() {
          Column({ space: 16 }) {
            Row() {
              Text('学习计划').fontSize(25).fontWeight(FontWeight.Bold).fontColor('#1F2937')
              Blank()
              if (this.apiPlan !== null) {
                Text(`计划版本 ${this.apiPlan.version}`).fontSize(12).fontWeight(FontWeight.Bold).fontColor('#2563EB')
                  .backgroundColor('#FFFFFF').borderRadius(9).padding({ left: 8, right: 8, top: 4, bottom: 4 })
              }
            }.width('100%')
            Text('今日安排只显示当天执行任务；本周计划按你确认的每日时长安排，并保留冲突与未安排内容。')
              .fontSize(13).fontColor('#667085').lineHeight(20).width('100%')
            Row({ space: 12 }) {
              Button('今日安排').backgroundColor(this.activeView === 'today' ? '#2563EB' : '#94A3B8').onClick(() => this.activeView = 'today')
              Button('本周计划').backgroundColor(this.activeView === 'full' ? '#2563EB' : '#94A3B8').onClick(() => this.activeView = 'full')
            }.width('100%')
            Text(appState.getChatTaskContext()).fontSize(12).fontColor('#2563EB')
              .width('100%').padding(10).backgroundColor('#FFFFFF').borderRadius(10)
            if (this.activeView === 'today') {
              Text('查看全部待办 ›').fontSize(14).fontColor('#2563EB').onClick(() => router.pushUrl({ url: 'pages/CourseImport', params: { initialTab: 'ddls', ddlFilter: 'pending' } }))
              if (this.pendingTodayDDLs().length > 0) {
                Column({ space: 10 }) {
                  Text(`需安排的到期作业 · ${this.pendingTodayDDLs().length} 项`).fontSize(16).fontWeight(FontWeight.Bold).width('100%')
                  ForEach(this.pendingTodayDDLs().slice(0, 3), (ddl: HomeworkDDL) => {
                    Text(`${ddl.title} · ${ddl.courseName} · 截止 ${ddl.dueDate} · ${ddl.estimatedMinutes}分钟`).fontSize(13).fontColor('#475467').width('100%')
                      .onClick(() => router.pushUrl({ url: 'pages/CourseImport', params: { initialTab: 'ddls', focusDdlId: ddl.id } }))
                  }, (ddl: HomeworkDDL) => ddl.id)
                }.padding(14).width('100%').backgroundColor('#FFFFFF').borderRadius(12)
              }
            }
            if (this.activeView === 'full' && this.apiPlan !== null) {
              Column({ space: 10 }) {
                Text('确认未来7天可用时间').fontSize(17).fontWeight(FontWeight.Bold).width('100%')
                Text('未填写的日期为0分钟；不虚构每日空档。任务按截止日期排期，无法容纳的长作业请先拆成明确步骤或调整时长。').fontSize(13).fontColor('#667085').width('100%')
                ForEach(this.calendarDays, (day: CalendarDay, index: number) => {
                  Row({ space: 12 }) {
                    Text(day.date).fontSize(13).layoutWeight(1)
                    TextInput({ text: day.minutes.toString(), placeholder: '可用分钟' }).width(100).type(InputType.Number).onChange((value: string) => this.updateDay(index, value))
                    Text('分钟').fontSize(12)
                  }.width('100%')
                }, (day: CalendarDay) => day.date)
                Button('按每日时间生成本周计划').width('100%').enabled(!this.budgetSaving).onClick(() => this.saveCalendar())
                if (this.apiPlan.calendarDays) ForEach(this.apiPlan.calendarDays, (day: CalendarDay) => {
                  Text(`${day.date} · 已安排${day.scheduledMinutes ?? 0}/${day.minutes}分钟`).fontSize(13).fontColor('#475467').width('100%')
                }, (day: CalendarDay) => day.date)
              }.padding(16).backgroundColor('#FFFFFF').borderRadius(12).width('100%')
            }
            if (this.activeView === 'full' && this.conversationTasks.length > 0) {
              Column({ space: 6 }) {
                Row() {
                  Text('对话新增任务').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#1F2937')
                  Blank()
                  Text(`${this.conversationTasks.length} 项 · 已同步`).fontSize(11).fontWeight(FontWeight.Medium)
                    .fontColor('#047857').backgroundColor('#ECFDF3').borderRadius(10)
                    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                }.width('100%')
                Text('仅显示你在对话中确认创建的任务，不包含课程表 DDL。')
                  .fontSize(12).fontColor('#667085').width('100%')
              }.width('100%').padding({ top: 4 })
              ForEach(this.conversationTasks, (task: HomeworkDDL) => {
                this.CourseTaskCard(task)
              }, (task: HomeworkDDL) => task.id)
              Text('Agent 专项任务').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#1F2937')
                .width('100%').margin({ top: 8 })
            }
            if (this.isApiPlanLoading) {
              Column({ space: 10 }) {
                LoadingProgress().width(30).height(30).color('#2563EB')
                Text('正在读取当前计划…').fontSize(14).fontColor('#667085')
              }.width('100%').padding(32).alignItems(HorizontalAlign.Center).backgroundColor('#FFFFFF').borderRadius(16)
            } else if (this.apiPlan !== null) {
              if (this.activeView === 'full') {
              Column({ space: 8 }) {
                Text('本次可用学习时间').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#1F2937').width('100%')
                Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
                  ForEach(this.courseChoices(), (course: string) => {
                    Button(course === this.selectedCourse ? `✓ ${course}` : course, { type: ButtonType.Normal })
                      .fontSize(14).constraintSize({ minHeight: 44, maxWidth: '100%' })
                      .padding({ left: 16, right: 16, top: 12, bottom: 12 }).margin({ right: 8, bottom: 8 })
                      .fontColor(course === this.selectedCourse ? '#FFFFFF' : '#2563EB')
                      .backgroundColor(course === this.selectedCourse ? '#2563EB' : '#FFFFFF')
                      .border({ width: 1, color: '#BFDBFE' }).borderRadius(12).enabled(!this.budgetSaving)
                      .onClick(() => { this.selectedCourse = course; this.pendingBudget = null; })
                  }, (course: string) => course)
                }.width('100%')
                if (this.courseChoices().length === 0) Text('先导入课程或资料，再选择本次学习内容。').fontSize(13).fontColor('#667085')
                Text('按课程和时长安排最多3项任务，其余知识点保留在候选池。课程作业另行安排。')
                  .fontSize(12).fontColor('#667085').width('100%')
                Row({ space: 8 }) {
                  TextInput({ text: this.budgetText, placeholder: '可用分钟' }).type(InputType.Number)
                    .onChange((value: string) => this.budgetText = value).layoutWeight(1).enabled(!this.budgetSaving)
                  Button(this.budgetSaving ? '调整中' : '应用').enabled(!this.budgetSaving)
                    .onClick(() => {
                      if (this.budgetText.trim().length === 0) this.budgetMessage = '请输入可用分钟数。';
                      else void this.applyBudget(Number(this.budgetText));
                    })
                }.width('100%')
                if (this.apiPlan.budgetSummary !== undefined) {
                  Text(this.budgetExplanation()).fontSize(13).fontColor('#475467').width('100%')
                  Text(`任务预计${this.apiPlan.budgetSummary.baseTotalMinutes ?? this.apiPlan.budgetSummary.scheduledMinutes}分钟 · 可用${this.apiPlan.budgetSummary.availableMinutes}分钟，已安排${this.apiPlan.budgetSummary.scheduledMinutes}分钟，未安排${this.apiPlan.budgetSummary.unscheduledMinutes}分钟`)
                    .fontSize(13).fontColor('#0F766E').width('100%')
                }
                if (this.budgetMessage.length > 0) Text(this.budgetMessage).fontSize(12).fontColor('#475467').width('100%')
              }.width('100%').padding(14).backgroundColor('#FFFFFF').borderRadius(14)
              if (this.budgetDiff !== null) PlanDiffCard({ value: this.budgetDiff })
              if (this.apiPlan.reason !== undefined) {
                Column({ space: 6 }) {
                  Text(this.showReason ? '本次计划依据 ↑' : '本次计划依据 ↓').width('100%').padding({ top: 8, bottom: 8 }).onClick(() => this.showReason = !this.showReason).fontSize(14).fontWeight(FontWeight.Bold).fontColor('#1F2937')
                  if (this.showReason) {
                  Text(this.apiPlan.reason).fontSize(13).fontColor('#475467').lineHeight(20)
                  Text(`基于画像版本 ${this.apiPlan.generatedFromProfileVersion} 生成`).fontSize(12).fontColor('#667085')
                  }
                }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(16)
              }
              }
              Text(`${this.visibleTasks().length} 项${this.activeView === 'today' ? '今日安排' : '计划任务'}`).fontSize(17).fontWeight(FontWeight.Bold).fontColor('#1F2937').width('100%')
              if (this.visibleTasks().length === 0) {
                Text(this.activeView === 'today' ? '今天没有待执行的计划任务，可查看本周计划或到期作业。' : '先选择主攻课程，再确认本次学习时长，即可从候选池安排任务。').fontSize(14).fontColor('#667085')
                  .width('100%').padding(22).backgroundColor('#FFFFFF').borderRadius(14)
              } else {
                ForEach(this.visibleTasks(), (task: PlanTask) => {
                  this.PlanTaskCard(task)
                }, (task: PlanTask) => `${task.taskId}-${task.status}`)
              }
              if (this.deferredMessage.length > 0) {
                Text(this.deferredMessage).fontSize(13).fontColor('#475467').lineHeight(20)
                  .width('100%').padding(12).backgroundColor('#FFFFFF').borderRadius(12)
              }
              if (this.activeView === 'full' && this.apiPlan.unscheduledTasks !== undefined && this.apiPlan.unscheduledTasks.length > 0) {
                Text(`暂未安排 ${this.apiPlan.unscheduledTasks.length} 项 ${this.showDeferred ? '↑' : '↓'}`).onClick(() => this.showDeferred = !this.showDeferred).fontSize(17).fontWeight(FontWeight.Bold).fontColor('#92400E').width('100%')
                if (this.showDeferred) {
                Text('这些任务尚未计入本次学习安排，会保留供后续选择。点击“加入本次计划”仅加入所选任务，时间不足时会先征求你的确认，不会自动增加可用时间。')
                  .fontSize(13).fontColor('#667085').lineHeight(20).width('100%')
                ForEach(this.apiPlan.unscheduledTasks, (task: PlanTask) => {
                  Column({ space: 8 }) {
                    Text(task.knowledgePointName).fontSize(16).fontWeight(FontWeight.Medium).fontColor('#344054').width('100%')
                    Text(`${task.sourceCourse ? task.sourceCourse + ' · ' : ''}预计${task.durationMinutes}分钟${task.dueDate ? ' · 截止' + task.dueDate : ''}`)
                      .fontSize(12).fontColor('#667085').width('100%')
                    Text(task.deferredReason ?? '等待后续安排').fontSize(12).fontColor('#667085').width('100%')
                    Text(this.scheduleHint(task)).fontSize(12).fontColor('#92400E').width('100%')
                    if (task.source !== 'ddl_step' && task.source !== 'study_step') {
                      Text('拆分为明确步骤 ›').fontSize(13).fontColor('#2563EB').width('100%').onClick(() => { this.splitTaskId = task.taskId; this.splitText = ''; })
                      if (this.splitTaskId === task.taskId) {
                        Text(`每行填写 步骤名称|分钟，合计${task.durationMinutes}分钟；完成全部步骤后才完成原任务。`).fontSize(12).fontColor('#667085').width('100%')
                        TextArea({ text: this.splitText, placeholder: '阅读要求|15\n完成实现|45\n检查与提交|30' }).height(140).onChange((value: string) => this.splitText = value)
                        Button('确认步骤并保存').enabled(!this.budgetSaving).onClick(() => this.splitTask(task))
                        Text('取消拆分').fontSize(13).fontColor('#667085').onClick(() => this.splitTaskId = '')
                      }
                    }

                    Button(this.schedulingTaskId === task.taskId ? '正在加入…' : '加入本次计划')
                      .width('100%').height(40).fontSize(13).fontWeight(FontWeight.Bold)
                      .fontColor('#FFFFFF').backgroundColor('#2563EB').borderRadius(10)
                      .enabled(!this.budgetSaving && !this.isApiPlanLoading && this.canScheduleTask(task))
                      .onClick(() => this.confirmSchedule(task))
                  }.width('100%').padding(14).backgroundColor('#FFFFFF').borderRadius(12)
                }, (task: PlanTask) => task.taskId)
                }
              }
              if (this.activeView === 'full' && this.apiPlan.candidatePool !== undefined) {
                Column({ space: 10 }) {
                  Text(`候选知识点 ${this.apiPlan.candidatePool.length} 项 ${this.showCandidates ? '↑' : '↓'}`)
                    .width('100%').padding({ top: 8, bottom: 8 })
                    .fontSize(14).fontWeight(FontWeight.Bold).fontColor('#1F2937')
                    .onClick(() => this.showCandidates = !this.showCandidates)
                  if (this.showCandidates) {
                    if (this.apiPlan.candidatePool.length === 0) {
                      Text('暂无候选知识点，导入课程资料后可在这里查看。').fontSize(13).fontColor('#667085')
                    }
                    Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
                      ForEach(this.apiPlan.candidatePool, (point: KnowledgeMastery) => {
                        Text(point.knowledgePointName).fontSize(13).fontColor('#344054')
                          .constraintSize({ maxWidth: '100%' }).padding(10).margin({ right: 8, bottom: 8 })
                          .backgroundColor('#FFFFFF').border({ width: 1, color: '#BFDBFE' }).borderRadius(10)
                      }, (point: KnowledgeMastery) => point.knowledgePointId)
                    }.width('100%')
                  }
                }.width('100%').alignItems(HorizontalAlign.Start).padding(16).backgroundColor('#FFFFFF').borderRadius(16)
              }
            } else {
              Column({ space: 10 }) {
                Text(this.planKind === 'no_plan' ? '这个账号还没有学习计划' : '暂时无法读取当前计划')
                  .fontSize(17).fontWeight(FontWeight.Bold)
                  .fontColor(this.planKind === 'no_plan' ? '#1F2937' : '#B45309')
                Text(this.apiPlanMessage.length > 0 ? this.apiPlanMessage : '暂时无法读取当前计划。')
                  .fontSize(14).fontColor('#475467').lineHeight(20)
                // 原来这句写死"请确认服务地址"，但失败原因未必是地址 ——
                // 也可能是"这个账号还没有计划"（后端 NOT_FOUND）。一律甩给地址会带偏排查方向。
                Text(this.planKind === 'no_plan'
                  ? '计划由 Agent 依据真实课程、资料与练习记录生成；导入或建立目标后，本页会自动出现计划。'
                  : '若刚切换过后端地址，请确认地址可访问。页面不会改用本地计划替代接口结果。')
                  .fontSize(12).fontColor('#667085').lineHeight(18)
                if (this.planKind === 'no_plan') {
                  Button('导入课程，准备候选知识点').width('100%').height(44).fontSize(14).fontWeight(FontWeight.Bold)
                    .fontColor('#FFFFFF').backgroundColor('#2563EB').borderRadius(12)
                    .onClick(() => this.openCourseImport())
                  Button('去对话建立学习目标').width('100%').height(44).fontSize(14)
                    .fontColor('#2563EB').backgroundColor('#FFFFFF')
                    .border({ width: 1, color: '#BFDBFE' }).borderRadius(12)
                    .onClick(() => this.openChatGoal())
                }
              }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(14)
            }
            Button(this.isApiPlanLoading ? '正在刷新…' : '刷新当前计划').width('100%').height(46).fontSize(15).fontWeight(FontWeight.Bold)
              .fontColor('#2563EB').backgroundColor('#FFFFFF').border({ width: 1, color: '#BFDBFE' }).borderRadius(12)
              .enabled(!this.isApiPlanLoading && !this.budgetSaving).onClick(() => this.loadCurrentPlan(true))
            if (this.apiPlan !== null) {
              Button('确认计划').width('100%').height(48).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
                .backgroundColor('#2563EB').borderRadius(14).margin({ bottom: 20 }).onClick(() => this.completePlan())
            }
          }.width('100%').padding({ left: 20, right: 20, top: 20, bottom: 96 })
        }.layoutWeight(1).backgroundColor('#F7F8FA')
      }.width('100%').height('100%')
      }.width('100%').height('100%')
  }
}
