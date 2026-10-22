import router from '@ohos.router';
import { appState } from '../data/AppState';
import { FocusTask, HomeworkDDL } from '../models/AgentModels';
import { AIFloatButton } from '../components/AIFloatButton';
import { LearningPlan, PlanTask, PlanBudgetRequest, PlanDiff } from '../api/ApiModels';
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
  @State budgetText: string = '60';
  @State budgetMessage: string = '';
  @State budgetSaving: boolean = false;
  @State budgetDiff: PlanDiff | null = null;
  private pendingBudget: PlanBudgetRequest | null = null;
  private pendingBudgetOwner: string = '';
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
    this.planKind = state.kind;
    if (this.pendingBudget === null && state.plan?.budgetSummary !== undefined) {
      this.budgetText = state.plan.budgetSummary.availableMinutes.toString();
    }
    this.apiPlanMessage = state.errorMessage;
    this.isApiPlanLoading = false;
  }

  private startTask(task: PlanTask): void {
    appState.setFocusTask({
      course: '专项学习', task: task.knowledgePointName, plannedMinutes: task.durationMinutes,
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
    if (this.pendingBudget === null || this.pendingBudget.availableMinutes !== minutes || this.pendingBudgetOwner !== owner) {
      this.pendingBudget = { availableMinutes: minutes, expectedPlanVersion: this.apiPlan.version,
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
      this.budgetMessage = result.data.changed ? '已按可用时间调整，未安排任务保留在下方。' : '当前安排已满足此时间预算。';
      this.pendingBudget = null;
    } else {
      const failure: ApiFailure = result as ApiFailure;
      this.budgetMessage = failure.error.message;
      if (failure.error.statusCode === 409 || failure.error.code === 'STALE_PLAN') {
        this.pendingBudget = null;
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
          Text(`${task.durationMinutes} 分钟专项练习`).fontSize(12).fontColor('#667085')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Text(this.taskStatusLabel(task)).fontSize(11).fontWeight(FontWeight.Medium)
          .fontColor('#2563EB').backgroundColor('#EFF6FF').borderRadius(10).padding({ left: 8, right: 8, top: 4, bottom: 4 })
      }.width('100%')
      if (task.priority !== undefined) {
        Text(task.priority === 'high' ? 'Agent 优先处理' : `优先级：${task.priority}`)
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
        Text(task.priority).fontSize(11).fontColor('#2563EB').backgroundColor('#EFF6FF')
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
              Text('Agent 学习计划').fontSize(25).fontWeight(FontWeight.Bold).fontColor('#1F2937')
              Blank()
              if (this.apiPlan !== null) {
                Text(`Plan V${this.apiPlan.version}`).fontSize(12).fontWeight(FontWeight.Bold).fontColor('#2563EB')
                  .backgroundColor('#EFF6FF').borderRadius(9).padding({ left: 8, right: 8, top: 4, bottom: 4 })
              }
            }.width('100%')
            Text('Agent 专项计划与课程截止任务分开管理；对话中确认的任务会显示在下方课程任务区。')
              .fontSize(13).fontColor('#667085').lineHeight(20).width('100%')
            Text(appState.getChatTaskContext()).fontSize(12).fontColor('#2563EB')
              .width('100%').padding(10).backgroundColor('#EFF6FF').borderRadius(10)
            // 这里只展示对话中明确确认的任务。课程表导入的普通 DDL 仍由
            // “课程与作业”管理，不能因为共用 HomeworkDDL 存储就混到计划首屏。
            if (this.conversationTasks.length > 0) {
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
              Column({ space: 8 }) {
                Text('本次专项计划可用时间').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#1F2937').width('100%')
                Text('仅约束下方专项任务；课程DDL仍需另外预留时间。系统保留完整任务，安排不下时列为暂未安排。')
                  .fontSize(12).fontColor('#667085').width('100%')
                Row({ space: 8 }) {
                  TextInput({ text: this.budgetText, placeholder: '可用分钟' }).type(InputType.Number)
                    .onChange((value: string) => this.budgetText = value).layoutWeight(1).enabled(!this.budgetSaving)
                  Button(this.budgetSaving ? '调整中' : '应用').enabled(!this.budgetSaving)
                    .onClick(() => {
                      if (this.budgetText.trim().length === 0) this.budgetMessage = '请输入可用分钟数。';
                      else void this.applyBudget(Number(this.budgetText));
                    })
                  Button('30分钟').enabled(!this.budgetSaving).onClick(() => { void this.applyBudget(30); })
                }.width('100%')
                if (this.apiPlan.budgetSummary !== undefined) {
                  Text(`可用${this.apiPlan.budgetSummary.availableMinutes}分钟，已安排${this.apiPlan.budgetSummary.scheduledMinutes}分钟，未安排${this.apiPlan.budgetSummary.unscheduledMinutes}分钟`)
                    .fontSize(13).fontColor('#0F766E').width('100%')
                }
                if (this.budgetMessage.length > 0) Text(this.budgetMessage).fontSize(12).fontColor('#475467').width('100%')
              }.width('100%').padding(14).backgroundColor('#EFF6FF').borderRadius(14)
              if (this.budgetDiff !== null) PlanDiffCard({ value: this.budgetDiff })
              if (this.apiPlan.reason !== undefined) {
                Column({ space: 6 }) {
                  Text('本次计划依据').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#1F2937')
                  Text(this.apiPlan.reason).fontSize(13).fontColor('#475467').lineHeight(20)
                  Text(`基于画像版本 ${this.apiPlan.generatedFromProfileVersion} 生成`).fontSize(12).fontColor('#667085')
                }.width('100%').padding(16).backgroundColor('#EFF6FF').borderRadius(16)
              }
              Text(`${this.apiPlan.tasks.length} 项当前任务`).fontSize(17).fontWeight(FontWeight.Bold).fontColor('#1F2937').width('100%')
              if (this.apiPlan.tasks.length === 0) {
                Text('当前没有可执行的专项任务；如有暂未安排任务，可调整可用时间后重试。').fontSize(14).fontColor('#667085')
                  .width('100%').padding(22).backgroundColor('#FFFFFF').borderRadius(14)
              } else {
                ForEach(this.apiPlan.tasks, (task: PlanTask) => {
                  this.PlanTaskCard(task)
                }, (task: PlanTask) => `${task.taskId}-${task.status}`)
              }
              if (this.apiPlan.unscheduledTasks !== undefined && this.apiPlan.unscheduledTasks.length > 0) {
                Text('暂未安排，仍保留').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#92400E').width('100%')
                ForEach(this.apiPlan.unscheduledTasks, (task: PlanTask) => {
                  Column({ space: 4 }) {
                    Text(`${task.knowledgePointName} · ${task.durationMinutes}分钟`).fontSize(14).fontColor('#344054')
                    Text(task.deferredReason ?? '等待后续安排').fontSize(12).fontColor('#667085')
                  }.width('100%').padding(12).backgroundColor('#FFFBEB').borderRadius(12)
                }, (task: PlanTask) => task.taskId)
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
                  Button('导入课程，生成计划').width('100%').height(44).fontSize(14).fontWeight(FontWeight.Bold)
                    .fontColor('#FFFFFF').backgroundColor('#2563EB').borderRadius(12)
                    .onClick(() => this.openCourseImport())
                  Button('去对话建立学习目标').width('100%').height(44).fontSize(14)
                    .fontColor('#2563EB').backgroundColor('#FFFFFF')
                    .border({ width: 1, color: '#BFDBFE' }).borderRadius(12)
                    .onClick(() => this.openChatGoal())
                }
              }.width('100%').padding(18).backgroundColor('#FFFBEB').borderRadius(14)
            }
            Button(this.isApiPlanLoading ? '正在刷新…' : '刷新当前计划').width('100%').height(46).fontSize(15).fontWeight(FontWeight.Bold)
              .fontColor('#2563EB').backgroundColor('#FFFFFF').border({ width: 1, color: '#BFDBFE' }).borderRadius(12)
              .enabled(!this.isApiPlanLoading).onClick(() => this.loadCurrentPlan(true))
            if (this.apiPlan !== null) {
              Button('确认计划').width('100%').height(48).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
                .backgroundColor('#2563EB').borderRadius(14).margin({ bottom: 20 }).onClick(() => this.completePlan())
            }
          }.width('100%').padding({ left: 20, right: 20, top: 20, bottom: 96 })
        }.layoutWeight(1).backgroundColor('#F7F8FA')
      }.width('100%').height('100%')
      AIFloatButton()
    }.width('100%').height('100%')
  }
}
