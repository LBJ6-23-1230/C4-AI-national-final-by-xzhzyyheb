import router from '@ohos.router';
import { appState } from '../data/AppState';
import { DecisionFactor, LearningPlan, PlanTask } from '../api/ApiModels';
import { FocusTask } from '../models/AgentModels';
import { PlanViewModel } from '../viewmodels/PlanViewModel';
import { FactorBreakdownCard } from '../components/FactorBreakdownCard';
import { AIFloatButton } from '../components/AIFloatButton';

/**
 * 「今日学习建议」页。
 *
 * ⚠️ 本页最容易犯的错是**把三种"没有任务"说成同一句话**。用户实测截图就是
 * 「暂时无法读取学习建议 / 你还没有学习计划 / 只有『重新加载』」——
 * 一个**空账号**（正常状态）被说成"读不出来"（故障状态），
 * 而"重新加载"永远不可能让它变好：后端确实还没有计划。
 *
 * 现在按事实分四种状态，每种只给**真的能推进**的动作：
 *   1. 正在读取
 *   2. `no_plan`    —— 还没有计划：去建立学习目标 / 导入课程 / 上传讲义
 *   3. `error`      —— 真实故障：重试（并说明为什么可能失败）
 *   4. 有计划         —— 有可执行任务就推荐；全部完成或全部暂未安排则说明原因
 */
@Entry
@Component
struct StudySuggestion {
  @State isLoading: boolean = true;
  @State plan: LearningPlan | null = null;
  @State planKind: string = 'ok';
  @State errorMessage: string = '';
  @State isCached: boolean = false;
  private planViewModel: PlanViewModel = new PlanViewModel();
  private requestVersion: number = 0;
  private isPageActive: boolean = false;
  /** 首帧的 `onPageShow` 与 `aboutToAppear` 是同一次进入，不重复请求。 */
  private hasShownOnce: boolean = false;

  aboutToAppear(): void {
    this.isPageActive = true;
    // 首次进入强制读服务端：缓存可能来自上一次会话，甚至上一个账号。
    void this.loadSuggestion(true);
  }

  aboutToDisappear(): void {
    this.isPageActive = false;
    this.requestVersion++;
  }

  /**
   * 从导入页 / 计划页返回时**必须重新读**。
   *
   * 原实现只在 `aboutToAppear` 请求一次，而 `router.pushUrl` 打开的页返回时
   * 不会重新触发 `aboutToAppear` —— 用户导入完课程回来，页面还停在
   * "你没有计划"，于是只能再点一次重试，看起来像导入没生效。
   */
  onPageShow(): void {
    this.isPageActive = true;
    if (!this.hasShownOnce) {
      this.hasShownOnce = true;
      return;
    }
    void this.loadSuggestion(true);
  }

  onPageHide(): void {
    this.isPageActive = false;
    this.requestVersion++;
    // 被丢弃的请求不会再复位加载态；不复位的话返回本页会永远停在"正在读取"。
    this.isLoading = false;
  }

  private async loadSuggestion(forceRefresh: boolean = false): Promise<void> {
    if (this.isLoading && forceRefresh && this.hasShownOnce) return;
    this.isLoading = true;
    const requestVersion: number = ++this.requestVersion;
    const state = await this.planViewModel.load(forceRefresh);
    if (!this.isPageActive || requestVersion !== this.requestVersion) return;
    this.plan = state.plan;
    this.planKind = state.kind;
    this.errorMessage = state.errorMessage;
    this.isCached = state.isCached;
    this.isLoading = false;
  }

  /** 任务是否已完成：接口回写的状态 + 本地专注结算记录，二者任一成立即完成。 */
  private isTaskDone(task: PlanTask): boolean {
    return appState.isTaskCompleted(task.taskId, task.status);
  }

  /**
   * 当前可执行任务。
   *
   * ⚠️ 原实现遍历不到未完成任务时 `return this.plan.tasks[0]`，
   * 于是一个**全部做完**的计划会继续把第 1 项（已完成）当作"立即专注"的对象 ——
   * 用户点下去就是重复做一遍已经完成的任务。已完成/暂未安排都不该被推荐。
   */
  private currentTask(): PlanTask | null {
    if (this.plan === null) return null;
    for (let index: number = 0; index < this.plan.tasks.length; index++) {
      if (!this.isTaskDone(this.plan.tasks[index])) return this.plan.tasks[index];
    }
    return null;
  }

  /** 计划里确实有任务，但全部完成。 */
  private allTasksDone(): boolean {
    return this.plan !== null && this.plan.tasks.length > 0 && this.currentTask() === null;
  }

  /** 任务状态文案：接口状态 + 本地专注结算，二者取较新的结论。 */
  private taskStatusText(task: PlanTask): string {
    if (this.isTaskDone(task)) return '已完成';
    if (task.status === 'in_progress') return '进行中';
    return '待执行';
  }

  private unscheduledCount(): number {
    if (this.plan === null || this.plan.unscheduledTasks === undefined) return 0;
    return this.plan.unscheduledTasks.length;
  }

  private pendingAssignments(): PlanTask[] {
    return (this.plan?.unscheduledTasks ?? []).filter((task: PlanTask): boolean =>
      task.source === 'ddl' && !this.isTaskDone(task));
  }

  private async arrangeAssignment(task: PlanTask): Promise<void> {
    if (this.isLoading) return;
    this.isLoading = true;
    const result = await this.planViewModel.syncAssignments(task.taskId);
    this.isLoading = false;
    if (!this.isPageActive) return;
    if (result.ok) {
      await this.loadSuggestion(true);
    } else {
      this.errorMessage = '作业加入计划失败，请检查连接后重试。';
    }
  }

  private factors(): DecisionFactor[] { return this.plan?.factors ?? []; }
  private goBack(): void { appState.leaveChatTask(); router.back(); }

  /** 去对话重新提目标：把开局那句话预填好，但仍由用户自己发送。 */
  private openChatGoal(): void {
    appState.setChatPrompt('帮我安排今天的学习：先看看我哪些知识点最薄弱，再给一个今天能做完的计划。');
    appState.leaveChatTask();
    router.pushUrl({ url: 'pages/ChatMain' });
  }

  /** 导入课程会经服务端写入知识点并生成计划，是本页"没有计划"时最短的正路。 */
  private openCourseImport(): void {
    router.pushUrl({ url: 'pages/CourseImport', params: { initialTab: 'import' } });
  }

  private openKnowledgeBase(): void {
    router.pushUrl({ url: 'pages/KnowledgeBase' });
  }

  private openFullPlan(): void {
    router.pushUrl({ url: 'pages/StudyPlan' });
  }

  private startSuggestedFocus(): void {
    const task: PlanTask | null = this.currentTask();
    if (task === null) return;
    appState.setFocusTask({ course: '专项学习', task: task.knowledgePointName,
      plannedMinutes: task.durationMinutes, source: 'agent', mode: 'normal', timerType: 'countdown',
      planTaskId: task.taskId } as FocusTask);
    router.pushUrl({ url: 'pages/FocusSetup' });
  }

  @Builder
  SuggestionCard(task: PlanTask) {
    Column({ space: 12 }) {
      Row() {
        Text('Agent 建议').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#172033').layoutWeight(1)
        Text(task.priority === 'high' ? '高优先级' : '当前任务').fontSize(12).fontColor('#FFFFFF')
          .backgroundColor(task.priority === 'high' ? '#DC2626' : '#2563EB')
          .borderRadius(14).padding({ left: 10, right: 10, top: 5, bottom: 5 })
      }.width('100%')
      Text(this.plan?.reason ?? 'Agent 已根据当前画像生成学习任务。')
        .fontSize(15).fontColor('#4B5565').lineHeight(22).width('100%')
      Column({ space: 8 }) {
        Text(`知识点：${task.knowledgePointName}`).fontSize(14).fontColor('#344054').width('100%')
        Text(`建议时长：${task.durationMinutes} 分钟`).fontSize(14).fontColor('#344054').width('100%')
        Text(`计划版本：V${this.plan?.version ?? 0}`).fontSize(14).fontColor('#344054').width('100%')
        Text(`基于画像版本：${this.plan?.generatedFromProfileVersion ?? 0}`).fontSize(14).fontColor('#344054').width('100%')
      }.width('100%').padding(12).backgroundColor('#F8FAFC').borderRadius(10)
      Button('立即专注').width('100%').height(46).fontSize(15).fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF').backgroundColor('#2563EB').borderRadius(14).onClick(() => this.startSuggestedFocus())
    }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(18)
      .shadow({ radius: 14, color: '#14000000', offsetX: 0, offsetY: 6 })
  }

  /** 空状态：**还没有计划**（不是故障）。给三条真正能建立计划的路。 */
  @Builder
  NoPlanBlock() {
    Column({ space: 12 }) {
      Text('还没有学习计划').fontSize(19).fontWeight(FontWeight.Bold).fontColor('#1F2937').width('100%')
      Text(this.errorMessage.length > 0 ? this.errorMessage
        : '这个账号还没有学习计划，计划由 Agent 按你的真实课程与练习记录生成。')
        .fontSize(13).fontColor('#475467').lineHeight(21).width('100%')
      Text('第 1 步：导入课程并确认目标与 DDL；第 2 步：补充讲义或错题；第 3 步：诊断后开始学习。')
        .fontSize(12).fontColor('#667085').lineHeight(19).width('100%')
      Button('开始建立学习档案 →').width('100%').height(46).fontSize(15).fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF').backgroundColor('#2563EB').borderRadius(14)
        .onClick(() => this.openCourseImport())
      Text('完成基础信息后，在课程导入页面继续补充知识库资料。')
        .fontSize(11).fontColor('#98A2B3').lineHeight(17).width('100%')
    }.width('100%').padding(20).backgroundColor('#FFFFFF').borderRadius(16)
  }

  /** 空状态：**读取失败**（连不上/契约不符）。这里的重试才有意义。 */
  @Builder
  FailureBlock() {
    Column({ space: 12 }) {
      Text('暂时无法读取学习建议').fontSize(19).fontWeight(FontWeight.Bold).fontColor('#B45309').width('100%')
      Text(this.errorMessage.length > 0 ? this.errorMessage : '请求当前计划失败。')
        .fontSize(13).fontColor('#667085').lineHeight(21).width('100%')
      Text('重试前可先确认「接口环境」里的服务地址可访问；若服务未启动，本页不会改用演示计划代替。')
        .fontSize(12).fontColor('#667085').lineHeight(19).width('100%')
      Button(this.isLoading ? '正在重新加载…' : '重新加载').width('100%').height(44)
        .fontSize(15).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
        .backgroundColor('#2563EB').borderRadius(12).enabled(!this.isLoading)
        .onClick(() => { void this.loadSuggestion(true); })
      Button('去核对接口环境').width('100%').height(44).fontSize(14)
        .fontColor('#2563EB').backgroundColor('#FFFFFF')
        .border({ width: 1, color: '#BFDBFE' }).borderRadius(12)
        .onClick(() => router.pushUrl({ url: 'pages/ApiEnvironment' }))
    }.width('100%').padding(20).backgroundColor('#FFFFFF').borderRadius(16)
  }

  /** 有计划但没有可执行任务：说明是"做完了"还是"没排上"，并给出下一步。 */
  @Builder
  NoTaskBlock() {
    Column({ space: 12 }) {
      Text(this.pendingAssignments().length > 0 ? `有 ${this.pendingAssignments().length} 项作业待安排`
        : (this.allTasksDone() ? '本次计划已全部完成' : '当前计划没有可执行任务'))
        .fontSize(19).fontWeight(FontWeight.Bold).fontColor('#1F2937').width('100%')
      Text(this.pendingAssignments().length > 0
        ? '你的作业 DDL 已同步。选择一项加入本次计划，按该作业预计时长安排；也可以到完整计划里调整可用时间。'
        : this.allTasksDone()
        ? `计划 V${this.plan?.version ?? 0} 里的 ${this.plan?.tasks.length ?? 0} 项任务都已完成。已完成的任务不会被重新推荐。`
        : '计划里暂时没有待执行任务；若有暂未安排任务，说明当前可用时间装不下它们。')
        .fontSize(13).fontColor('#475467').lineHeight(21).width('100%')
      if (this.unscheduledCount() > 0) {
        Text(`另有 ${this.unscheduledCount()} 项待安排，可能尚未设置学习时间，或当前时间不足。`)
          .fontSize(12).fontColor('#92400E').lineHeight(19).width('100%')
          .padding(10).backgroundColor('#FFFBEB').borderRadius(8)
      }
      ForEach(this.pendingAssignments(), (task: PlanTask) => {
        Column({ space: 6 }) {
          Text(task.knowledgePointName).fontSize(15).fontWeight(FontWeight.Bold).width('100%')
          Text(`${task.sourceCourse ?? ''} · 截止 ${task.dueDate ?? ''} · 预计 ${task.durationMinutes} 分钟`)
            .fontSize(12).fontColor('#667085').width('100%')
          Button('加入本次计划').onClick(() => { void this.arrangeAssignment(task); })
        }.width('100%').padding(12).backgroundColor('#F8FAFC').borderRadius(10)
      }, (task: PlanTask) => task.taskId)
      if (this.errorMessage.length > 0) {
        Text(this.errorMessage).fontSize(12).fontColor('#B45309').width('100%')
      }
      Button('查看完整计划').width('100%').height(46).fontSize(15).fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF').backgroundColor('#2563EB').borderRadius(14)
        .onClick(() => this.openFullPlan())
      Button('去对话安排下一轮').width('100%').height(44).fontSize(14)
        .fontColor('#2563EB').backgroundColor('#FFFFFF')
        .border({ width: 1, color: '#BFDBFE' }).borderRadius(12)
        .onClick(() => this.openChatGoal())
    }.width('100%').padding(20).backgroundColor('#FFFFFF').borderRadius(16)
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Text('← 返回').fontSize(14).fontColor('#64748B').fontWeight(FontWeight.Medium).onClick(() => this.goBack())
          Blank()
          Text('学习建议').fontSize(13).fontColor('#2563EB').fontWeight(FontWeight.Bold)
        }.width('100%').padding({ left: 20, right: 20, top: 14, bottom: 14 }).backgroundColor('#FFFFFF')
      Scroll() {
          Column({ space: 16 }) {
            Text('今日学习建议').fontSize(26).fontWeight(FontWeight.Bold).fontColor('#172033').width('100%')
            Text('任务、时长和判断依据均来自当前 Agent 计划，前端不重新计算优先级。')
              .fontSize(13).fontColor('#667085').lineHeight(20).width('100%')
            if (this.isCached && !this.isLoading) {
              Text('当前显示的是最近一次成功读取的计划，可能已过期。')
                .fontSize(12).fontColor('#92400E').lineHeight(18).width('100%')
                .padding(10).backgroundColor('#FFFBEB').borderRadius(8)
            }
            if (this.isLoading) {
              Column({ space: 10 }) {
                LoadingProgress().width(34).height(34).color('#2563EB')
                Text('正在读取 Agent 计划…').fontSize(14).fontColor('#667085')
              }.width('100%').padding(32).alignItems(HorizontalAlign.Center)
            } else if (this.currentTask() !== null) {
              this.SuggestionCard(this.currentTask()!)
              if (this.factors().length > 0) {
                FactorBreakdownCard({ factors: this.factors(), reason: this.plan?.reason ?? '' })
              }
              Text(`${this.plan!.tasks.length} 项任务已按 Agent 计划排序`).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#1F2937').width('100%')
              ForEach(this.plan!.tasks, (task: PlanTask, index: number) => {
                Row({ space: 10 }) {
                  Text(`${index + 1}`).fontSize(13).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
                    .width(24).height(24).textAlign(TextAlign.Center)
                    .backgroundColor(this.isTaskDone(task) ? '#94A3B8' : '#2563EB').borderRadius(12)
                  Column({ space: 3 }) {
                    Text(task.knowledgePointName).fontSize(14).fontWeight(FontWeight.Bold).fontColor('#1F2937')
                    Text(`${task.durationMinutes} 分钟 · ${this.taskStatusText(task)}`)
                      .fontSize(12).fontColor('#667085')
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                }.width('100%').padding(13).backgroundColor('#FFFFFF').borderRadius(12)
              }, (task: PlanTask) => task.taskId)
              if (this.unscheduledCount() > 0) {
                Text(`另有 ${this.unscheduledCount()} 项暂未安排，已在计划里保留，可在计划页调整可用时间。`)
                  .fontSize(12).fontColor('#92400E').lineHeight(18).width('100%')
                  .padding(10).backgroundColor('#FFFBEB').borderRadius(8)
              }
            } else if (this.planKind === 'no_plan') {
              this.NoPlanBlock()
            } else if (this.plan !== null) {
              this.NoTaskBlock()
            } else {
              this.FailureBlock()
            }
          }.width('100%').padding({ left: 20, right: 20, top: 16, bottom: 96 })
        }.layoutWeight(1).backgroundColor('#F5F7FA')
      }.width('100%').height('100%')
      AIFloatButton()
    }.width('100%').height('100%')
  }
}
