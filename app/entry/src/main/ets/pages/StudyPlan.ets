import { KnowledgePointPanel } from '../components/KnowledgePointPanel';
import { AppBottomBar } from '../components/AppBottomBar';
import { UiTheme } from '../utils/UiTheme';
import { PlanScope } from '../utils/PlanScope';
import { PageHeader } from '../components/PageHeader';
import { CourseLabels } from '../utils/CourseLabels';
import { PlanStep, CalendarDay } from '../api/ApiModels';
import router from '@ohos.router';
import { appState } from '../data/AppState';
import { CourseInfo, FocusTask, HomeworkDDL } from '../models/AgentModels';
import { KnowledgeMastery, LearningPlan, PlanTask, PlanTaskScheduleRequest } from '../api/ApiModels';
import { PlanViewModel } from '../viewmodels/PlanViewModel';
import { ClientCache } from '../cache/ClientCache';
import { AgentApiClient } from '../api/AgentApiClient';
import { ApiFailure } from '../api/ApiResult';
@Entry
@Component
struct StudyPlan {
  @StorageLink('focusDataRevision') @Watch('onFocusDataChanged') focusDataRevision: number = 0;
  @State showManual: boolean = false;
  @State manualId: string = '';
  @State manualTitle: string = '';
  @State manualCourse: string = '';
  @State manualDate: string = '';
  @State manualMinutes: string = '30';
  @State manualNotice: string = '';
  @State manualBusy: boolean = false;
  @State isApiPlanLoading: boolean = true;
  @State apiPlan: LearningPlan | null = null;
  @State apiPlanMessage: string = '';
  @State scopedCourse: string = '';
  @State showDeferred: boolean = true;
  @State showCandidates: boolean = false;
  @State taskCourse: string = '';
  @State activeView: string = 'full';
  @State splitTaskId: string = '';
  @State splitText: string = '';
  @State calendarDays: CalendarDay[] = [];
  @State calendarInput: string[] = [];
  @State budgetMessage: string = '';
  @State budgetSaving: boolean = false;
  @State schedulingTaskId: string = '';
  @State deferredMessage: string = '';
  private pendingSchedule: PlanTaskScheduleRequest | null = null;
  private pendingScheduleOwner: string = '';
  @State conversationTasks: HomeworkDDL[] = [];
  private planViewModel: PlanViewModel = new PlanViewModel();
  private planRequestVersion: number = 0;
  private pendingPlanRead: number = 0;
  private isPageActive: boolean = false;
  private hasShownOnce: boolean = false;
  @State planKind: string = 'ok';

  aboutToAppear(): void {
    this.isPageActive = true;
    this.conversationTasks = appState.homeworkDDLs.filter((task: HomeworkDDL): boolean =>
      task.id.startsWith('chat-ddl-') ||
      (task.origin === 'chat' && !task.id.startsWith('ddl-csv-') && !task.id.startsWith('ddl-json-')));
    const params = router.getParams() as Record<string, string>;
    if (params?.['courseName'] && CourseLabels.valid(params['courseName'])) {
      this.scopedCourse = params['courseName'];
    }
    this.loadCurrentPlan();
  }

  aboutToDisappear(): void {
    this.isPageActive = false;
    this.planRequestVersion++;
  }

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
    this.pendingPlanRead = 0;
    this.isApiPlanLoading = false;
  }

  private editManual(task?: PlanTask): void {
    this.manualId = task?.taskId || `manual-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
    this.manualTitle = task?.knowledgePointName || '';
    this.manualCourse = task?.sourceCourse || this.scopedCourse || '';
    this.manualDate = task?.scheduledDate || this.todayDate();
    this.manualMinutes = (task?.durationMinutes || 30).toString();
    this.manualNotice = ''; this.showManual = true;
  }
  private async saveManual(action: string = 'save'): Promise<void> {
    if (this.manualBusy) return;
    const minutes: number = Number(this.manualMinutes);
    if (action === 'save' && (!this.manualTitle.trim() || !this.manualCourse.trim() || !/^\d{4}-\d{2}-\d{2}$/.test(this.manualDate) || !Number.isInteger(minutes) || minutes < 1 || minutes > 1440)) {
      this.manualNotice = '请填写任务、课程、日期（YYYY-MM-DD）和1至1440的整数分钟。'; return;
    }
    const owner: string = appState.currentUser.userId;
    this.planRequestVersion++;
    this.manualBusy = true;
    const result = await AgentApiClient.saveManualTask({ action: action, taskId: this.manualId,
      title: this.manualTitle.trim(), courseName: this.manualCourse.trim(), scheduledDate: this.manualDate,
      durationMinutes: minutes, expectedPlanVersion: this.apiPlan?.version ?? 0 });
    this.manualBusy = false;
    if (!this.isPageActive || owner !== appState.currentUser.userId) return;
    if (result.ok) { this.apiPlan = result.data; ClientCache.cacheCurrentPlan(result.data); this.showManual = false; this.prepareCalendar(); this.apiPlanMessage = ''; }
    else { this.manualNotice = (result as ApiFailure).error.message; if ((result as ApiFailure).error.statusCode === 409) void this.loadCurrentPlan(true); }
  }
  @Builder
  ManualEditor() {
    Column({ space: 12 }) {
      TextInput({ text: this.manualTitle, placeholder: '任务名称' }).maxLength(200).onChange((v: string) => this.manualTitle = v)
      TextInput({ text: this.manualCourse, placeholder: '所属课程' }).maxLength(80).onChange((v: string) => this.manualCourse = v)
      TextInput({ text: this.manualDate, placeholder: '安排日期 YYYY-MM-DD' }).onChange((v: string) => this.manualDate = v)
      TextInput({ text: this.manualMinutes, placeholder: '预计分钟数' }).type(InputType.Number).onChange((v: string) => this.manualMinutes = v)
      Text('保存后仍可通过任务旁的“编辑”调整；已开始或完成的任务保留原记录。').fontSize(13).fontColor(UiTheme.secondary).width('100%')
      if (this.manualNotice) { Text(this.manualNotice).fontSize(13).fontColor(UiTheme.danger).width('100%') }
      Button(this.manualBusy ? '保存中…' : '保存任务', { type: ButtonType.Normal }).width('100%').height(44).backgroundColor(UiTheme.accent).fontColor('#FFFFFF').enabled(!this.manualBusy).onClick(() => this.saveManual())
      if ((this.apiPlan?.tasks ?? []).some((t: PlanTask) => t.taskId === this.manualId)) {
        Button('删除任务', { type: ButtonType.Normal }).width('100%').height(44).fontColor(UiTheme.danger).backgroundColor(UiTheme.surface).enabled(!this.manualBusy)
          .onClick(() => AlertDialog.show({ title: '删除这项任务？', message: this.manualTitle, primaryButton: { value: '取消', action: () => {} }, secondaryButton: { value: '删除', action: () => { void this.saveManual('delete'); } } }))
      }
    }.width('100%').padding(20)
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
    if (this.isPageActive) void this.loadCurrentPlan(true, true);
  }

  private async loadCurrentPlan(forceRefresh: boolean = false, background: boolean = false): Promise<void> {
    if ((this.pendingPlanRead !== 0 && this.pendingPlanRead === this.planRequestVersion) ||
      this.budgetSaving || this.manualBusy) return;
    const requestVersion: number = ++this.planRequestVersion;
    this.pendingPlanRead = requestVersion;
    this.isApiPlanLoading = !background || this.apiPlan === null;
    try {
      const state = await this.planViewModel.load(forceRefresh);
      if (!this.isPageActive || requestVersion !== this.planRequestVersion) return;
      const samePlan: boolean = this.apiPlan !== null && this.apiPlan.planId === state.plan?.planId;
      this.apiPlan = state.plan;
      if (this.taskCourse && !this.courseChoices().includes(this.taskCourse)) this.taskCourse = '';
      this.prepareCalendar(samePlan);
      this.planKind = state.kind;
      this.apiPlanMessage = state.errorMessage;
    } finally {
      if (this.pendingPlanRead === requestVersion) {
        this.pendingPlanRead = 0;
        this.isApiPlanLoading = false;
      }
    }
  }

  private prepareCalendar(keepEdits: boolean = false): void {
    const days: CalendarDay[] = [];
    for (let i: number = 0; i < 7; i++) {
      const date: Date = new Date(); date.setDate(date.getDate() + i);
      const key: string = `${date.getFullYear()}-${(date.getMonth() + 1).toString().padStart(2, '0')}-${date.getDate().toString().padStart(2, '0')}`;
      const saved: CalendarDay | undefined = this.apiPlan?.calendarDays?.find((day: CalendarDay) => day.date === key);
      days.push({ date: key, minutes: saved?.minutes ?? 0 });
    }
    const values: string[] = days.map((day: CalendarDay): string => {
      if (keepEdits) {
        const index: number = this.calendarDays.findIndex((previous: CalendarDay) => previous.date === day.date);
        if (index >= 0 && this.calendarInput[index] !== this.calendarDays[index].minutes.toString()) {
          return this.calendarInput[index];
        }
      }
      return day.minutes.toString();
    });
    this.calendarDays = days;
    this.calendarInput = values;
  }
  private updateDay(index: number, value: string): void {
    if (index < 0 || index >= this.calendarDays.length) return;
    const input: string[] = this.calendarInput.slice();
    input[index] = value;
    this.calendarInput = input;
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
    this.budgetMessage = '';
    const days: CalendarDay[] = this.calendarDays.map((day: CalendarDay, index: number): CalendarDay => {
      return { date: day.date, minutes: Number(this.calendarInput[index] ?? '') };
    });
    if (days.some((day: CalendarDay): boolean => !Number.isInteger(day.minutes) || day.minutes < 0 || day.minutes > 1440)) {
      this.budgetSaving = false;
      this.budgetMessage = '每日可用时长请输入 0 到 1440 的整数分钟。';
      return;
    }
    try {
      const result = await AgentApiClient.scheduleCalendar({ days: days, expectedPlanVersion: this.apiPlan.version,
        targetCourse: this.taskCourse });
      if (!this.isPageActive || owner !== appState.currentUser.userId || version !== this.planRequestVersion) return;
      if (result.ok) {
        this.apiPlan = result.data;
        ClientCache.cacheCurrentPlan(result.data);
        this.prepareCalendar();
        this.budgetMessage = '已保存排期。下方按日期显示任务。';
      } else {
        this.budgetMessage = (result as ApiFailure).error.message;
      }
    } catch (error) {
      if (this.isPageActive && owner === appState.currentUser.userId && version === this.planRequestVersion) {
        this.budgetMessage = '暂时无法确认排期，请刷新计划后重试。';
      }
    } finally {
      this.budgetSaving = false;
    }
  }

  private taskCourseName(task: PlanTask): string {
    return task.sourceCourse?.trim() || appState.homeworkDDLs.find((ddl: HomeworkDDL) => ddl.id === task.taskId)?.courseName || '待确认课程';
  }
  private calendarScheduledMinutes(date: string): number {
    return this.apiPlan?.calendarDays?.find((day: CalendarDay): boolean => day.date === date)?.scheduledMinutes ?? 0;
  }

  private calendarTasks(date: string): PlanTask[] {
    return (this.apiPlan?.tasks ?? []).filter((task: PlanTask): boolean =>
      task.scheduledDate === date && task.status !== 'completed');
  }

  private visibleTasks(): PlanTask[] {
    const today: string = this.todayDate();
    return (this.apiPlan?.tasks ?? []).filter((task: PlanTask) =>
      !appState.isTaskCompleted(task.taskId, task.status) && (!task.scheduledDate || task.scheduledDate <= today));
  }
  private visibleCourseGroups(): string[] {
    const names: string[] = [];
    this.visibleTasks().forEach((task: PlanTask) => { const course: string = this.taskCourseName(task); if (!names.includes(course)) names.push(course); });
    return names;
  }
  private visibleCourseTasks(course: string): PlanTask[] { return this.visibleTasks().filter((task: PlanTask) => this.taskCourseName(task) === course); }
  private deferredTasks(): PlanTask[] { return (this.apiPlan?.unscheduledTasks ?? []); }
  private listedConversationTasks(): HomeworkDDL[] { return this.conversationTasks; }
  private addTodayTask(): void { router.pushUrl({ url: 'pages/CourseImport', params: { initialTab: 'ddls', ddlFilter: 'pending', addToToday: 'true' } }); }

  private scopedTasks(): PlanTask[] {
    return PlanScope.courseTasks(this.apiPlan?.tasks ?? [], this.scopedCourse, appState.homeworkDDLs);
  }

  private scopedDeferredTasks(): PlanTask[] {
    return PlanScope.courseTasks(this.apiPlan?.unscheduledTasks ?? [], this.scopedCourse, appState.homeworkDDLs);
  }

  private scopedAssignments(): HomeworkDDL[] {
    const planned: string[] = this.scopedTasks().concat(this.scopedDeferredTasks()).map((task: PlanTask) => task.taskId);
    return appState.homeworkDDLs.filter((task: HomeworkDDL) => task.courseName === this.scopedCourse && !task.completed && !planned.includes(task.id));
  }

  @Builder
  ScopedCoursePlan() {
    Scroll() {
      Column({ space: 16 }) {
        Text(this.scopedCourse).fontSize(23).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
        Text('仅显示这门课程的学习任务与作业安排。').fontSize(13).fontColor(UiTheme.secondary).width('100%')
        if (this.isApiPlanLoading && this.apiPlan === null) { LoadingProgress().width(28).height(28) }
        if (this.apiPlanMessage) { Text(this.apiPlanMessage).fontSize(13).fontColor(UiTheme.danger).width('100%') }
        Text(`已安排 ${this.scopedTasks().length} 项`).fontSize(17).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
        ForEach(this.scopedTasks(), (task: PlanTask) => { this.PlanTaskCard(task) }, (task: PlanTask) => task.taskId)
        if (this.apiPlan !== null && this.scopedTasks().length === 0) {
          Text('这门课程暂时没有已安排的学习任务。').fontSize(14).fontColor(UiTheme.secondary).width('100%')
        }
        if (this.scopedDeferredTasks().length > 0) {
          Text('待安排任务').fontSize(17).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
          ForEach(this.scopedDeferredTasks(), (task: PlanTask) => {
            Column({ space: 8 }) {
              Text(task.knowledgePointName).fontSize(16).fontColor(UiTheme.ink).width('100%')
              Text(`${task.durationMinutes}分钟 · ${task.deferredReason || '尚未排入计划'}`).fontSize(13).fontColor(UiTheme.secondary).width('100%')
              Button('加入本次计划', { type: ButtonType.Normal }).fontSize(13).height(44).fontColor(UiTheme.accent).backgroundColor(UiTheme.tint)
                .enabled(!this.budgetSaving && this.canScheduleTask(task)).onClick(() => this.confirmSchedule(task))
            }.width('100%').padding(12).border({ width: { bottom: 1 }, color: UiTheme.line })
          }, (task: PlanTask) => task.taskId)
        }
        if (this.scopedAssignments().length > 0) {
          Text('本课程待处理作业').fontSize(17).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
          ForEach(this.scopedAssignments(), (task: HomeworkDDL) => { this.CourseTaskCard(task) }, (task: HomeworkDDL) => task.id)
        }
        if (this.deferredMessage) { Text(this.deferredMessage).fontSize(13).fontColor(UiTheme.secondary).width('100%') }
        Button('刷新课程计划', { type: ButtonType.Normal }).width('100%').height(44).fontColor(UiTheme.accent).backgroundColor(UiTheme.tint)
          .enabled(!this.isApiPlanLoading).onClick(() => this.loadCurrentPlan(true))
      }.width('100%').constraintSize({ maxWidth: UiTheme.contentWidth }).padding(20).alignItems(HorizontalAlign.Start)
    }.width('100%').layoutWeight(1).align(Alignment.Top).scrollBar(BarState.Off)
  }
  private todayDate(): string {
    const now: Date = new Date();
    return `${now.getFullYear()}-${(now.getMonth() + 1).toString().padStart(2, '0')}-${now.getDate().toString().padStart(2, '0')}`;
  }
  private pendingTodayDDLs(): HomeworkDDL[] {
    const today: string = this.todayDate();
    const scheduled: PlanTask[] = (this.apiPlan?.tasks ?? []).filter((task: PlanTask) =>
      task.status !== 'completed' && (!task.scheduledDate || task.scheduledDate <= today));
    return appState.homeworkDDLs.filter((task: HomeworkDDL) => !appState.isTaskCompleted(task.id, 'pending') && task.dueDate <= today &&
      !scheduled.some((entry: PlanTask) => entry.taskId === task.id || entry.parentTaskId === task.id));
  }
  private courseChoices(): string[] {
    const choices: string[] = appState.courses.map((c: CourseInfo): string => c.courseName);
    appState.homeworkDDLs.forEach((ddl: HomeworkDDL) => {
      if (choices.indexOf(ddl.courseName) < 0) choices.push(ddl.courseName);
    });
    (this.apiPlan?.tasks ?? []).concat(this.apiPlan?.unscheduledTasks ?? []).forEach((task: PlanTask) => {
      choices.push(this.taskCourseName(task));
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
      this.budgetMessage = '';
      this.deferredMessage = `已将「${task.knowledgePointName}」加入今日计划。今日可用时间为${result.data.plan.budgetSummary?.availableMinutes ?? 0}分钟。`;
      this.pendingSchedule = null;
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

  private taskStatusLabel(task: PlanTask): string {
    if (appState.isTaskCompleted(task.taskId, task.status)) return '已完成';
    if (task.status === 'in_progress') return '进行中';
    return '待执行';
  }

  @Builder
  PlanTaskCard(task: PlanTask) {
    Row({ space: 12 }) {
      Column({ space: 6 }) {
        Text(task.knowledgePointName).fontSize(16).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
        Text(`${task.sourceCourse || (task.source === 'ddl' ? '课程作业' : '专项学习')} · ${task.durationMinutes}分钟${task.scheduledDate ? ' · ' + task.scheduledDate : ''}`)
          .fontSize(12).fontColor(UiTheme.secondary).lineHeight(19).width('100%')
        Text(this.taskStatusLabel(task)).fontSize(12).fontColor(UiTheme.secondary).width('100%')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        .onClick(() => router.pushUrl({ url: 'pages/TaskDetail', params: { taskId: task.taskId, scheduled: 'true' } }))
      if (task.source === 'manual' && !appState.isTaskCompleted(task.taskId, task.status)) {
        Text('编辑').fontSize(13).fontColor(UiTheme.accent).height(44).padding({ top: 12, right: 6 }).onClick(() => this.editManual(task))
      }
      if (!appState.isTaskCompleted(task.taskId, task.status)) {
        Button('开始', { type: ButtonType.Normal }).height(40).fontSize(13).fontColor('#FFFFFF').backgroundColor(UiTheme.accent)
          .borderRadius(8).onClick(() => this.startTask(task))
      }
      Text('›').fontSize(22).fontColor(UiTheme.secondary).width(24).height(44).textAlign(TextAlign.Center)
        .onClick(() => router.pushUrl({ url: 'pages/TaskDetail', params: { taskId: task.taskId, scheduled: 'true' } }))
    }.width('100%').padding({ top: 16, bottom: 16 }).border({ width: { bottom: 1 }, color: UiTheme.line })
  }

  @Builder
  CourseTaskCard(task: HomeworkDDL) {
    Column({ space: 10 }) {
      Row() {
        Column({ space: 4 }) {
          Text(task.title).fontSize(16).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).maxLines(2)
          Text(`${task.courseName} · ${task.estimatedMinutes} 分钟`).fontSize(12).fontColor(UiTheme.secondary)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Text(task.priority).fontSize(11).fontColor(UiTheme.accent).backgroundColor(UiTheme.surface)
          .borderRadius(8).padding({ left: 8, right: 8, top: 4, bottom: 4 })
      }.width('100%')
      Text(task.dueDate.length > 0 ? `截止：${task.dueDate}` : '暂未设置截止时间')
        .fontSize(12).fontColor(UiTheme.secondary).width('100%')
      Button('开始任务').width('100%').height(42).fontSize(13).fontWeight(FontWeight.Bold)
        .fontColor(UiTheme.surface).backgroundColor(UiTheme.accent).borderRadius(8)
        .onClick(() => this.startCourseTask(task))
    }.width('100%').padding(18).backgroundColor(UiTheme.surface).borderRadius(8)
      .border({ width: 1, color: UiTheme.line })
  }

  build() {
    Stack() {
      Column() {
        PageHeader({ title: this.scopedCourse ? '课程计划' : '学习计划', assistant: true, onBack: () => { this.goBack(); } })
        if (this.scopedCourse) { this.ScopedCoursePlan() } else {
        Scroll() {
          Column({ space: 16 }) {
            Row({ space: 12 }) {
              Button('今日', { type: ButtonType.Normal }).layoutWeight(1).height(40).fontSize(14).fontColor(this.activeView === 'today' ? UiTheme.accent : UiTheme.secondary).backgroundColor(this.activeView === 'today' ? UiTheme.tint : UiTheme.surface).borderRadius(8).onClick(() => this.activeView = 'today')
              Button('未来 7 天', { type: ButtonType.Normal }).layoutWeight(1).height(40).fontSize(14).fontColor(this.activeView === 'full' ? UiTheme.accent : UiTheme.secondary).backgroundColor(this.activeView === 'full' ? UiTheme.tint : UiTheme.surface).borderRadius(8).onClick(() => this.activeView = 'full')
            }.width('100%')
            if (this.activeView === 'today' && (!this.isApiPlanLoading || this.apiPlan !== null)) {
              if (this.pendingTodayDDLs().length > 0) {
                Column({ space: 10 }) {
                  Text(`需安排的到期作业 · ${this.pendingTodayDDLs().length} 项`).fontSize(16).fontWeight(FontWeight.Bold).width('100%')
                  Text('查看作业详情后，可把需要优先完成的作业加入今日计划。')
                    .fontSize(13).fontColor(UiTheme.secondary).width('100%')
                  ForEach(this.pendingTodayDDLs(), (ddl: HomeworkDDL) => {
                    Row({ space: 10 }) {
                      Column({ space: 4 }) {
                        Text(ddl.title).fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink)
                        Text(`${ddl.courseName} · 截止 ${ddl.dueDate} · ${ddl.estimatedMinutes}分钟`).fontSize(12).fontColor(UiTheme.secondary)
                      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                      Text('详情 ›').fontSize(13).fontColor(UiTheme.accent)
                    }.width('100%').constraintSize({ minHeight: 44 })
                      .onClick(() => router.pushUrl({ url: 'pages/CourseImport', params: { initialTab: 'ddls', focusDdlId: ddl.id } }))
                  }, (ddl: HomeworkDDL) => ddl.id)
                }.padding(14).width('100%').backgroundColor(UiTheme.surface).borderRadius(8)
              }
            }
            if (this.activeView === 'full' && this.apiPlan !== null) {
              Column({ space: 10 }) {
                Text('未来 7 天可用时间（含今天）').fontSize(17).fontWeight(FontWeight.Bold).width('100%')
                Text('填入每天能学习的分钟数，休息日填 0。生成后会按截止日期安排任务，并用剩余时间安排知识点练习。')
                  .fontSize(13).fontColor(UiTheme.secondary).lineHeight(20).width('100%')
                Text('优先课程（选填）').fontSize(14).fontWeight(FontWeight.Medium).width('100%')
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(['全部课程'].concat(this.courseChoices()), (course: string, index: number) => {
                    Button(course, { type: ButtonType.Normal }).fontSize(13).constraintSize({ minHeight: 44 })
                      .fontColor((index === 0 ? !this.taskCourse : this.taskCourse === course) ? UiTheme.surface : UiTheme.accent)
                      .backgroundColor((index === 0 ? !this.taskCourse : this.taskCourse === course) ? UiTheme.accent : UiTheme.tint)
                      .borderRadius(8).margin({ right: 8, bottom: 8 }).enabled(!this.budgetSaving)
                      .onClick(() => this.taskCourse = index === 0 ? '' : course)
                  }, (course: string) => course)
                }.width('100%')
                ForEach(this.calendarDays, (day: CalendarDay, index: number) => {
                  Row({ space: 12 }) {
                    Text(day.date).fontSize(13).layoutWeight(1)
                    TextInput({ text: this.calendarInput[index] ?? '', placeholder: '0' }).width(100).type(InputType.Number).enabled(!this.budgetSaving).onChange((value: string) => this.updateDay(index, value))
                    Text('分钟').fontSize(12)
                  }.width('100%')
                }, (day: CalendarDay) => day.date)
                Button(this.budgetSaving ? '处理中…' : '生成并保存 7 天计划').width('100%')
                  .enabled(!this.budgetSaving && !this.isApiPlanLoading).onClick(() => this.saveCalendar())
                if (this.budgetMessage.length > 0) {
                  Text(this.budgetMessage).fontSize(13).fontColor(UiTheme.secondary).width('100%')
                }
              }.padding(16).backgroundColor(UiTheme.surface).borderRadius(8).width('100%')
            }
            if (this.activeView === 'full' && this.listedConversationTasks().length > 0) {
              Column({ space: 6 }) {
                Row() {
                  Text('对话新增任务').fontSize(18).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink)
                  Blank()
                  Text(`${this.listedConversationTasks().length} 项 · 已同步`).fontSize(11).fontWeight(FontWeight.Medium)
                    .fontColor('#047857').backgroundColor('#ECFDF3').borderRadius(8)
                    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                }.width('100%')
                Text('仅显示你在对话中确认创建的任务，不包含课程表 DDL。')
                  .fontSize(12).fontColor(UiTheme.secondary).width('100%')
              }.width('100%').padding({ top: 4 })
              ForEach(this.listedConversationTasks(), (task: HomeworkDDL) => {
                this.CourseTaskCard(task)
              }, (task: HomeworkDDL) => task.id)
              Text('Agent 专项任务').fontSize(18).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink)
                .width('100%').margin({ top: 8 })
            }
            if (this.isApiPlanLoading && this.apiPlan === null) {
              Column({ space: 10 }) {
                LoadingProgress().width(30).height(30).color(UiTheme.accent)
                Text('正在读取当前计划…').fontSize(14).fontColor(UiTheme.secondary)
              }.width('100%').padding(32).alignItems(HorizontalAlign.Center).backgroundColor(UiTheme.surface).borderRadius(8)
            } else if (this.apiPlan !== null) {
              if (this.activeView === 'full') {
                Text('每日安排').fontSize(17).fontWeight(FontWeight.Bold).width('100%')
                if (!this.apiPlan.calendarDays?.length) {
                  Text('填好每日可用时间后，生成计划即可查看每天的任务。')
                    .fontSize(14).fontColor(UiTheme.secondary).width('100%')
                }
                ForEach(this.calendarDays, (day: CalendarDay) => {
                  if (this.apiPlan?.calendarDays?.some((saved: CalendarDay): boolean => saved.date === day.date)) {
                    Column({ space: 6 }) {
                      Text(`${day.date} · 已安排 ${this.calendarScheduledMinutes(day.date)} 分钟`)
                        .fontSize(15).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).width('100%')
                      if (this.calendarTasks(day.date).length === 0) {
                        Text('暂无待做任务').fontSize(13).fontColor(UiTheme.secondary).width('100%')
                      }
                      ForEach(this.calendarTasks(day.date), (task: PlanTask) => {
                        this.PlanTaskCard(task)
                      }, (task: PlanTask) => task.taskId)
                    }.width('100%').padding(12).backgroundColor(UiTheme.surface).borderRadius(8)
                  }
                }, (day: CalendarDay) => day.date)
              } else {
              Text(`${this.visibleTasks().length} 项${this.activeView === 'today' ? '今日安排' : '计划任务'}`).fontSize(17).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).width('100%')
              if (this.visibleTasks().length === 0) {
                Text(this.activeView === 'today' ? '今天没有待执行的计划任务，可查看本周计划或到期作业。' : '先选择主攻课程，再确认本次学习时长，即可从候选池安排任务。').fontSize(14).fontColor(UiTheme.secondary)
                  .width('100%').padding(22).backgroundColor(UiTheme.surface).borderRadius(8)
              } else {
                ForEach(this.visibleCourseGroups(), (course: string) => {
                  Column({ space: 0 }) {
                    Text(`${course} · ${this.visibleCourseTasks(course).length}项`).fontSize(15).fontWeight(FontWeight.Medium).fontColor(UiTheme.secondary).width('100%').padding({ top: 12, bottom: 8 })
                    ForEach(this.visibleCourseTasks(course), (task: PlanTask) => { this.PlanTaskCard(task) }, (task: PlanTask) => `${task.taskId}-${task.status}`)
                  }.width('100%')
                }, (course: string) => course)
              }
              }
              if (this.deferredMessage.length > 0) {
                Text(this.deferredMessage).fontSize(13).fontColor(UiTheme.secondary).lineHeight(20)
                  .width('100%').padding(12).backgroundColor(UiTheme.surface).borderRadius(8)
              }
              if (this.activeView === 'full' && this.apiPlan.unscheduledTasks !== undefined && this.deferredTasks().length > 0) {
                Text(`暂未安排 ${this.deferredTasks().length} 项 ${this.showDeferred ? '↑' : '↓'}`).onClick(() => this.showDeferred = !this.showDeferred).fontSize(17).fontWeight(FontWeight.Bold).fontColor('#92400E').width('100%')
                if (this.showDeferred) {
                Text('这些任务暂未排入未来 7 天。可以增加对应日期的可用时间，或将耗时较长的任务拆成小步骤后重新生成。')
                  .fontSize(13).fontColor(UiTheme.secondary).lineHeight(20).width('100%')
                ForEach(this.deferredTasks(), (task: PlanTask) => {
                  Column({ space: 8 }) {
                    Text(task.knowledgePointName).fontSize(16).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
                    Text(`${task.sourceCourse ? task.sourceCourse + ' · ' : ''}预计${task.durationMinutes}分钟${task.dueDate ? ' · 截止' + task.dueDate : ''}`)
                      .fontSize(12).fontColor(UiTheme.secondary).width('100%')
                    Text(task.deferredReason ?? '等待后续安排').fontSize(12).fontColor(UiTheme.secondary).width('100%')
                    if (task.source !== 'ddl_step' && task.source !== 'study_step') {
                      Text('拆分为明确步骤 ›').fontSize(13).fontColor(UiTheme.accent).width('100%').onClick(() => { this.splitTaskId = task.taskId; this.splitText = ''; })
                      if (this.splitTaskId === task.taskId) {
                        Text(`每行填写 步骤名称|分钟，合计${task.durationMinutes}分钟；完成全部步骤后才完成原任务。`).fontSize(12).fontColor(UiTheme.secondary).width('100%')
                        TextArea({ text: this.splitText, placeholder: '阅读要求|15\n完成实现|45\n检查与提交|30' }).height(140).onChange((value: string) => this.splitText = value)
                        Button('确认步骤并保存').enabled(!this.budgetSaving).onClick(() => this.splitTask(task))
                        Text('取消拆分').fontSize(13).fontColor(UiTheme.secondary).onClick(() => this.splitTaskId = '')
                      }
                    }

                  }.width('100%').padding(14).backgroundColor(UiTheme.surface).borderRadius(8)
                }, (task: PlanTask) => task.taskId)
                }
              }
              if (this.activeView === 'full' && this.apiPlan.candidatePool !== undefined) {
                Column({ space: 10 }) {
                  Text(`候选知识点 ${this.apiPlan.candidatePool.length} 项 ${this.showCandidates ? '↑' : '↓'}`)
                    .width('100%').padding({ top: 8, bottom: 8 })
                    .fontSize(14).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink)
                    .onClick(() => this.showCandidates = !this.showCandidates)
                  if (this.showCandidates) {
                    if (this.apiPlan.candidatePool.length === 0) {
                      Text('暂无候选知识点，导入课程资料后可在这里查看。').fontSize(13).fontColor(UiTheme.secondary)
                    }
                    KnowledgePointPanel({ restrictPoints: true, pointIds: this.apiPlan.candidatePool.map((p: KnowledgeMastery) => p.knowledgePointId) })
                  }
                }.width('100%').alignItems(HorizontalAlign.Start).padding(16).backgroundColor(UiTheme.surface).borderRadius(8)
              }
            } else {
              Column({ space: 10 }) {
                Text(this.planKind === 'no_plan' ? '这个账号还没有学习计划' : '暂时无法读取当前计划')
                  .fontSize(17).fontWeight(FontWeight.Bold)
                  .fontColor(this.planKind === 'no_plan' ? UiTheme.ink : '#B45309')
                Text(this.planKind === 'no_plan' ? '导入课程或建立学习目标后，计划会根据你的课程、资料和练习记录生成。' :
                  (this.apiPlanMessage || '请检查网络后刷新。'))
                  .fontSize(14).fontColor(UiTheme.secondary).lineHeight(20)
                if (this.planKind === 'no_plan') {
                  Button('导入课程，准备候选知识点').width('100%').height(44).fontSize(14).fontWeight(FontWeight.Bold)
                    .fontColor(UiTheme.surface).backgroundColor(UiTheme.accent).borderRadius(8)
                    .onClick(() => this.openCourseImport())
                  Button('去对话建立学习目标').width('100%').height(44).fontSize(14)
                    .fontColor(UiTheme.accent).backgroundColor(UiTheme.surface)
                    .border({ width: 1, color: '#BFDBFE' }).borderRadius(8)
                    .onClick(() => this.openChatGoal())
                }
              }.width('100%').padding(18).backgroundColor(UiTheme.surface).borderRadius(8)
            }
            Button(this.isApiPlanLoading ? '正在刷新…' : '刷新当前计划').width('100%').height(46).fontSize(15).fontWeight(FontWeight.Bold)
              .fontColor(UiTheme.accent).backgroundColor(UiTheme.surface).border({ width: 1, color: '#BFDBFE' }).borderRadius(8)
              .enabled(!this.isApiPlanLoading && !this.budgetSaving).onClick(() => this.loadCurrentPlan(true))
            Button('添加任务', { type: ButtonType.Normal }).width('100%').height(48).fontSize(15).fontWeight(FontWeight.Medium).fontColor(UiTheme.surface)
              .backgroundColor(UiTheme.accent).borderRadius(8).margin({ bottom: 20 }).onClick(() => this.addTodayTask())
          }.width('100%').constraintSize({ maxWidth: UiTheme.contentWidth }).padding({ left: 20, right: 20, top: 20, bottom: 96 })
        }.layoutWeight(1).backgroundColor(UiTheme.canvas).align(Alignment.Top)
        }
      }.width('100%').height('100%')
      }.width('100%').height('100%')
        .bindSheet($$this.showManual, this.ManualEditor(), { height: SheetSize.FIT_CONTENT, title: { title: '学习任务' }, showClose: true, dragBar: true })
  }
}
