import { ActionButton } from '../components/ActionButton';
import { LearningEvidence } from '../utils/LearningEvidence';
import router from '@ohos.router';
import { common } from '@kit.AbilityKit';
import { appState } from '../data/AppState';
import { AIFloatButton } from '../components/AIFloatButton';
import { RadarChart } from '../components/RadarChart';
import { Evidence, KnowledgeMastery, MasteryHistory } from '../api/ApiModels';
import { DemoSnapshot } from '../cache/DemoSnapshot';
import { ProfileViewModel } from '../viewmodels/ProfileViewModel';
import { WorkflowViewModel } from '../viewmodels/WorkflowViewModel';
import { WorkflowSessionStore } from '../cache/WorkflowSessionStore';
import { ApiDisplayFormatter } from '../utils/ApiDisplayFormatter';

@Entry
@Component
struct StudyTags {
  @State isLoading: boolean = true;
  @State errorMessage: string = '';
  @State workflowErrorMessage: string = '';
  @State isStartingWorkflow: boolean = false;
  @State userId: string = '';
  @State goal: string = '';
  @State profileVersion: number = 0;
  @State mastery: KnowledgeMastery[] = [];
  private allMastery: KnowledgeMastery[] = [];
  @State courseNames: string[] = [];
  @State selectedCourse: string = '';
  private selectCourse(course: string): void {
    this.selectedCourse = course;
    this.mastery = this.allMastery.filter((p: KnowledgeMastery) => (p.sourceCourse || '待分类') === course);
    this.buildChartData();
  }

  @State history: MasteryHistory[] = [];
  @State evidence: Evidence[] = [];
  @State expandedHistoryTimestamp: string = '';
  @State showAllMastery: boolean = false;
  @State showHistory: boolean = false;
  @State showAllHistory: boolean = false;
  @State showMoreActions: boolean = false;
  @State chartDims: string[] = [];
  @State chartCurrent: number[] = [];
  @State chartTarget: number[] = [];
  @State chartWeak: number[] = [];
  @State chartStrong: number[] = [];

  /**
   * 把"最弱的那个知识点"翻译成一句人话，作为「接下来」卡片的理由。
   * 取掌握度最低的一项；没有数据时给保守兜底文案，不留空白。
   */
  private assessed(item: KnowledgeMastery): boolean {
    return LearningEvidence.assessed(item, this.evidence, this.history);
  }
  private weaknessSummary(): string {
    if (this.mastery.filter((p: KnowledgeMastery) => this.assessed(p)).length === 0) {
      return '还没有足够的学情数据。先做一轮诊断练习，Agent 才能算出你的薄弱点。';
    }
    let weakest: KnowledgeMastery = this.mastery.filter((p: KnowledgeMastery) => this.assessed(p))[0];
    for (let index: number = 1; index < this.mastery.length; index++) {
      if (this.assessed(this.mastery[index]) && this.mastery[index].masteryScore < weakest.masteryScore) {
        weakest = this.mastery[index];
      }
    }
    return `当前最薄弱的是「${weakest.knowledgePointName}」，掌握度 ${weakest.masteryScore}。`
      + '先围绕这个知识点练习，再根据结果调整计划。';
  }

  private hasAssessment(): boolean {
    return this.mastery.some((point: KnowledgeMastery) => this.assessed(point));
  }

  private openRecommendedPractice(): void {
    const points: KnowledgeMastery[] = this.mastery.filter((point: KnowledgeMastery) => this.assessed(point))
      .sort((left: KnowledgeMastery, right: KnowledgeMastery): number =>
        left.masteryScore - right.masteryScore);
    if (points.length > 0) {
      router.pushUrl({ url: 'pages/ExercisePractice', params: { knowledgePointId: points[0].knowledgePointId } });
    } else {
      router.pushUrl({ url: 'pages/ExercisePractice' });
    }
  }
  private viewModel: ProfileViewModel = new ProfileViewModel();
  private workflowViewModel: WorkflowViewModel = new WorkflowViewModel();
  private profileRequestVersion: number = 0;
  private workflowRequestVersion: number = 0;
  private isPageActive: boolean = false;
  /** 首帧的 `onPageShow` 与 `aboutToAppear` 是同一次进入，不重复请求。 */
  private hasShownOnce: boolean = false;

  aboutToAppear(): void {
    this.isPageActive = true;
    this.loadProfile();
  }

  aboutToDisappear(): void {
    this.isPageActive = false;
    this.profileRequestVersion++;
    this.workflowRequestVersion++;
    this.isStartingWorkflow = false;
  }

  onPageShow(): void {
    this.isPageActive = true;
    // 从导入页 / 练习页返回时重新读画像：`router.pushUrl` 打开的页返回不会重入
    // `aboutToAppear`，否则导入完课程回到本页仍是"尚未建立知识画像"。
    if (!this.hasShownOnce) {
      this.hasShownOnce = true;
      return;
    }
    void this.loadProfile(true);
  }

  onPageHide(): void {
    this.isPageActive = false;
    this.profileRequestVersion++;
    this.workflowRequestVersion++;
    this.isStartingWorkflow = false;
    // 被版本校验丢弃的请求不会复位加载态，留在加载中会一直转圈。
    this.isLoading = false;
  }

  /**
   * 当前身份对应的 userId。
   *
   * 已登录 → 真实 userId；游客/离线 → `demo-user`（它本来就是体验身份）。
   * 页面里**不允许再写死 `demo-user`** —— 那是"登录后仍看到演示数据"的根因。
   */
  private effectiveUserId(): string {
    const id: string = appState.currentUser.userId;
    return id.length > 0 ? id : DemoSnapshot.USER_ID;
  }

  private async loadProfile(forceRefresh: boolean = false): Promise<void> {
    if (this.isLoading && forceRefresh) {
      return;
    }
    const requestVersion: number = ++this.profileRequestVersion;
    this.isLoading = true;
    // 读**当前身份**的画像，而不是写死的演示账号。
    //
    // 修复的缺陷：这里原先硬编码 `DemoSnapshot.USER_ID`（= demo-user），
    // 于是用户注册登录后，画像页展示的仍是演示账号的掌握度（42），
    // 而不是自己的（新账号是 0）。后端侧同步修了身份解析，
    // 两边都改才生效。
    //
    // 注意游客/离线态下 `appState.currentUser.userId` 本来就是 demo-user，
    // 所以演示基线不受影响。
    const state = await this.viewModel.load(this.effectiveUserId(), forceRefresh);
    if (!this.isPageActive || requestVersion !== this.profileRequestVersion) {
      return;
    }
    this.userId = state.userId;
    this.goal = state.goal;
    this.profileVersion = state.profileVersion;
    this.allMastery = state.mastery;
    const names: string[] = [];
    state.mastery.forEach((p: KnowledgeMastery) => {
      const name: string = p.sourceCourse || '待分类';
      if (names.indexOf(name) < 0) names.push(name);
    });
    this.courseNames = names;
    this.selectCourse(names.indexOf(this.selectedCourse) >= 0 ? this.selectedCourse : (names[0] || ''));
    this.history = state.history;
    this.evidence = state.evidence;
    this.errorMessage = state.errorMessage;
    this.buildChartData();
    this.isLoading = false;
  }

  private async startDiagnosis(): Promise<void> {
    if (this.isStartingWorkflow) {
      return;
    }
    this.isStartingWorkflow = true;
    this.workflowErrorMessage = '';
    const requestVersion: number = ++this.workflowRequestVersion;
    try {
    const workflow = await this.workflowViewModel.start(this.goal, this.userId);
    if (!this.isPageActive || requestVersion !== this.workflowRequestVersion) {
      return;
    }
    if (workflow === null) {
      this.workflowErrorMessage = this.workflowViewModel.getErrorMessage() || 'Agent 会话启动失败，请稍后重试。';
      return;
    }
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    // 带上归属身份：冷启动恢复时靠它判断这个会话是不是当前用户的。
    WorkflowSessionStore.save(context, workflow, appState.currentUser.userId);
    const progress = await this.workflowViewModel.runUntilComplete(1);
    if (progress === null || progress.status === 'failed' || progress.status === 'error') {
      this.workflowErrorMessage = this.workflowViewModel.getErrorMessage() || 'Agent 会话推进失败，请重试。';
      return;
    }
    if (!this.isPageActive || requestVersion !== this.workflowRequestVersion) {
      return;
    }
    router.pushUrl({ url: 'pages/ExercisePractice' });
    } catch (error) {
      this.workflowErrorMessage = 'Agent 会话启动失败，请检查连接后重试。';
    } finally {
      if (requestVersion === this.workflowRequestVersion) this.isStartingWorkflow = false;
    }
  }

  private buildChartData(): void {
    // 最多 6 个维度：雷达图再密就看不清标签了；优先展示最薄弱的维度，
    // 避免接口返回顺序把真正需要关注的知识点挤出图表。
    const items: KnowledgeMastery[] = this.mastery.filter((p: KnowledgeMastery) => this.assessed(p)).sort((a: KnowledgeMastery, b: KnowledgeMastery): number => a.knowledgePointId.localeCompare(b.knowledgePointId)).slice(0, 6);
    this.chartDims = [];
    this.chartCurrent = [];
    this.chartTarget = [];
    this.chartWeak = [];
    this.chartStrong = [];

    for (let index: number = 0; index < items.length; index++) {
      this.chartDims.push(items[index].knowledgePointName);
      this.chartCurrent.push(items[index].masteryScore);
    }

    // ⚠️ 下面三段是补上的。原先这里只填了 dims/current，
    // 而 `target` / `weakIndices` / `strengthIndices` 三个数组
    // **声明了、传给组件了、却从未赋值**，永远是空数组 ——
    // 于是雷达图里三条与之相关的绘制分支全是死代码：
    //   · 「目标水平(灰虚线)」：组件判 `target.length === n`，空数组长度为 0 必不成立
    //   · 最薄弱点标红（半径 7 的红点）
    //   · 最强点标深蓝
    // 图还是画得出来（网格/轴线/当前水平/标签都正常），
    // 所以只看截图看不出问题 —— 属于"画了但少画了三样"。

    // 目标线：从学习目标文案里取"80+"这类分数，取不到就用 80
    // （示例目标为「数据结构期末80+」）。
    const targetValue: number = StudyTags.parseTargetScore(this.goal);
    for (let index: number = 0; index < items.length; index++) {
      // Exam marks and mastery scores have different scales.
    }

    // 最薄弱 / 最强：按本次展示的维度里取极值。
    // 只在维度数 >= 2 时才标 —— 单点时"最弱"和"最强"是同一个，标红没有信息量。
    if (items.length >= 2) {
      let weakest: number = 0;
      let strongest: number = 0;
      for (let index: number = 1; index < items.length; index++) {
        if (items[index].masteryScore < items[weakest].masteryScore) {
          weakest = index;
        }
        if (items[index].masteryScore > items[strongest].masteryScore) {
          strongest = index;
        }
      }
      // 掌握度全相同（并列）时不标任何点，避免随便挑一个标红造成误导
      if (items[weakest].masteryScore !== items[strongest].masteryScore) {
        this.chartWeak = [weakest];
        this.chartStrong = [strongest];
      }
    }
  }

  /**
   * 从学习目标文案里取目标分数。
   *
   * 支持「数据结构期末80+」「目标 85 分」「冲刺90」这几种写法。
   * 取不到就返回 80 —— 与后端演示基线（`data/repository.json` 的
   * 示例目标「数据结构期末80+」）一致，而不是随手写一个值。
   */
  private static parseTargetScore(goal: string): number {
    const matched: RegExpMatchArray | null = goal.match(/(\d{2,3})/);
    if (matched === null) {
      return 80;
    }
    const value: number = Number(matched[1]);
    if (!Number.isFinite(value) || value < 1 || value > 100) {
      return 80;
    }
    return value;
  }

  private evidenceCount(knowledgePointId: string): number {
    let count: number = 0;
    for (let index: number = 0; index < this.evidence.length; index++) {
      if (this.evidence[index].knowledgePointId === knowledgePointId) {
        count++;
      }
    }
    return count;
  }

  private evidenceValue(evidence: Evidence): string {
    if (typeof evidence.value === 'number') {
      const value: number = evidence.value as number;
      // 正确率等指标通常是 0–1，小数原样展示会出现
      // `0.6667000000000001` 这类浮点噪声；面向用户统一显示为百分比。
      if (evidence.metric === 'accuracy' && value >= 0 && value <= 1) {
        return `${Math.round(value * 100)}%`;
      }
      return `${Math.round(value * 100) / 100}`;
    }
    return JSON.stringify(evidence.value);
  }

  /** 掌握度由低到高排列；同分时，证据更多的项目优先，减少“全是 0”时的随机感。 */
  private sortedMastery(): KnowledgeMastery[] {
    const items: KnowledgeMastery[] = this.mastery.slice();
    items.sort((left: KnowledgeMastery, right: KnowledgeMastery): number => {
      if (this.assessed(left) !== this.assessed(right)) return this.assessed(left) ? -1 : 1;
      const scoreDiff: number = left.masteryScore - right.masteryScore;
      if (scoreDiff !== 0) return scoreDiff;
      return this.evidenceCount(right.knowledgePointId) - this.evidenceCount(left.knowledgePointId);
    });
    return items;
  }

  private visibleMastery(): KnowledgeMastery[] {
    const items: KnowledgeMastery[] = this.sortedMastery();
    return this.showAllMastery ? items : items.slice(0, MASTERY_PREVIEW_COUNT);
  }

  private weakMasteryCount(): number {
    return this.mastery.filter((item: KnowledgeMastery): boolean => this.assessed(item) && item.masteryScore < 60).length;
  }

  private masteredCount(): number {
    return this.mastery.filter((item: KnowledgeMastery): boolean => this.assessed(item) && item.masteryScore >= 80).length;
  }

  private masteryLevel(score: number): string {
    if (score >= 80) return '掌握良好';
    if (score >= 60) return '继续巩固';
    return '优先提升';
  }

  /** 0→0 不是变化，不应占满用户视线；这里只保留真正发生涨跌的记录并按时间倒序。 */
  private meaningfulHistory(): MasteryHistory[] {
    const items: MasteryHistory[] = this.history.filter((item: MasteryHistory): boolean =>
      item.oldScore !== item.newScore);
    items.sort((left: MasteryHistory, right: MasteryHistory): number =>
      right.timestamp.localeCompare(left.timestamp));
    return items;
  }

  private visibleHistory(): MasteryHistory[] {
    const items: MasteryHistory[] = this.meaningfulHistory();
    return this.showAllHistory ? items : items.slice(0, HISTORY_PREVIEW_COUNT);
  }

  /** 历史本身没带知识点 id，从关联证据反查名称；没有证据时如实显示“综合掌握度”。 */
  private historyKnowledgePoint(item: MasteryHistory): string {
    const linked: Evidence[] = this.evidenceForHistory(item);
    if (linked.length === 0) return '综合掌握度';
    const pointId: string = linked[0].knowledgePointId;
    const mastery: KnowledgeMastery | undefined = this.mastery.find((value: KnowledgeMastery): boolean =>
      value.knowledgePointId === pointId);
    return mastery !== undefined && mastery.knowledgePointName.trim().length > 0
      ? mastery.knowledgePointName : pointId;
  }

  private historyDelta(item: MasteryHistory): string {
    const delta: number = item.newScore - item.oldScore;
    return delta > 0 ? `+${delta}` : `${delta}`;
  }

  private isHistoryExpanded(item: MasteryHistory): boolean {
    return this.expandedHistoryTimestamp === item.timestamp;
  }

  private toggleHistoryEvidence(item: MasteryHistory): void {
    this.expandedHistoryTimestamp = this.isHistoryExpanded(item) ? '' : item.timestamp;
  }

  private evidenceForHistory(item: MasteryHistory): Evidence[] {
    return this.evidence.filter((evidence: Evidence) => item.evidenceIds.indexOf(evidence.id) !== -1);
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Text('← 返回')
            .fontSize(14).fontColor('#64748B').fontWeight(FontWeight.Medium)
            .onClick(() => { router.back(); })
          Blank()
          Button(this.isLoading ? '刷新中…' : '刷新', { type: ButtonType.Normal })
            .height(40).padding({ left: 12, right: 12 }).fontSize(13).fontColor('#64748B')
            .backgroundColor(Color.Transparent).borderRadius(8)
            .enabled(!this.isLoading && !this.isStartingWorkflow)
            .onClick(() => { void this.loadProfile(true); })
          Text(`知识画像 V${this.profileVersion}`)
            .fontSize(13).fontColor('#2563EB').fontWeight(FontWeight.Bold)
            .backgroundColor('#EFF6FF').borderRadius(16)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        }
        .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .backgroundColor('#FFFFFF')

        Text('阶段复盘与考前建议 ›').fontSize(13).fontColor('#667085').width('100%').padding(16).onClick(() => router.pushUrl({ url: 'pages/LearningReview' }))
      Scroll() {
          Column({ space: 16 }) {
            if (this.isLoading) {
              Column({ space: 10 }) {
                LoadingProgress().width(32).height(32)
                Text('正在读取学习画像…').fontSize(14).fontColor('#64748B')
              }
              .width('100%').padding(32).alignItems(HorizontalAlign.Center)
            } else {
              if (this.errorMessage.length > 0) {
                Text(this.errorMessage).fontSize(13).fontColor('#B45309').lineHeight(19)
                  .width('100%').padding(12).backgroundColor('#FFFBEB')
                  .border({ width: 1, color: '#FDE68A' }).borderRadius(12)
              }

              // 实测反馈：「学习画像和学情画像有什么区别？点开之后跳转的界面是一样的」。
              // 它们确实是**同一页** —— 数据只有一份，差别只在"看"还是"改"。
              // 与其让用户猜，不如在页面上直接讲清楚。
              Text('本页同时是「学情画像」与「学习画像」：前者在对话里用来查看掌握度；'
                + '后者在你更新学习档案（目标 / 掌握情况）之后回到这里核对结果。两者读的是同一份数据。')
                .fontSize(11).fontColor('#98A2B3').lineHeight(17).width('100%')

              Column({ space: 8 }) {
                Text('当前学习目标').fontSize(13).fontColor('#64748B')
                Text(this.goal.length > 0 ? this.goal : '尚未建立学习目标')
                  .fontSize(18).fontWeight(FontWeight.Bold).fontColor('#111827')
              }
              .width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(16)
              .shadow({ radius: 8, color: '#10000000', offsetX: 0, offsetY: 4 })

              if (this.mastery.length > 0) {
                if (this.chartDims.length >= 3) {
                  Column({ space: 8 }) {
                    Text(this.selectedCourse + ' · 知识掌握度').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#111827')
                    Text('蓝线表示后端返回的当前掌握度；分数不在前端重新计算。')
                      .fontSize(13).fontColor('#6B7280')
                    RadarChart({
                      dimensions: this.chartDims,
                      current: this.chartCurrent,
                      target: this.chartTarget,
                      weakIndices: this.chartWeak,
                      strengthIndices: this.chartStrong
                    })
                  }
                  .width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(16)
                  .shadow({ radius: 8, color: '#10000000', offsetX: 0, offsetY: 4 })
                } else {
                  Column({ space: 10 }) {
                    Text('当前掌握度').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#111827')
                    // 雷达图**不是没触发，而是维度不够**：至少要三个轴才成形，
                    // 两个点连起来只是一条线。实测反馈「之前初赛版本在学情画像内有
                    // 雷达图的，现在始终没有触发」—— 根因在这里（以及演示画像里
                    // 原先只预置了 1 个知识点，见 server 的 `app/api/demo.py`）。
                    // 与其让用户以为坏了，不如说清触发条件与达成路径。
                    Text(`雷达图需要至少 3 个知识点才成形（当前 ${this.mastery.length} 个），`
                      + '所以先用进度卡展示。做几轮其他知识点的专项练习、掌握度积累到 3 个以上后，'
                      + '这里会自动切换成雷达图。')
                      .fontSize(13).fontColor('#6B7280')
                    ForEach(this.mastery, (item: KnowledgeMastery) => {
                      Column({ space: 8 }) {
                        Row() {
                          Text(item.knowledgePointName).fontSize(15).fontWeight(FontWeight.Medium).fontColor('#1F2937').layoutWeight(1)
                          Text(this.assessed(item) ? `${item.masteryScore} / 100` : '尚无练习记录').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#2563EB')
                        }.width('100%')
                        if (this.assessed(item)) { Progress({ value: item.masteryScore, total: 100, type: ProgressType.Linear })
                          .color('#7C9FA0').backgroundColor('#ECEFF3').height(8).borderRadius(8) }
                      }.width('100%').padding(12).backgroundColor('#F8FAFC').borderRadius(12)
                    }, (item: KnowledgeMastery) => item.knowledgePointId)
                  }
                  .width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(16)
                  .shadow({ radius: 8, color: '#10000000', offsetX: 0, offsetY: 4 })
                }

                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.courseNames, (course: string) => {
                    Button(course).fontSize(13).margin(4)
                      .backgroundColor(course === this.selectedCourse ? '#E4E7EC' : '#F9FAFB')
                      .fontColor(course === this.selectedCourse ? '#344054' : '#667085')
                      .onClick(() => this.selectCourse(course))
                  }, (course: string) => course)
                }.width('100%')

                Column({ space: 10 }) {
                  Row() {
                    Text('优先关注').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#111827')
                    Blank()
                    Text(`共 ${this.mastery.length} 个知识点`).fontSize(12).fontColor('#667085')
                  }.width('100%')
                  Text(`按掌握度从低到高排列，默认只展示最需要提升的 ${Math.min(MASTERY_PREVIEW_COUNT, this.mastery.length)} 项。`)
                    .fontSize(12).fontColor('#667085').lineHeight(18).width('100%')
                  Row({ space: 8 }) {
                    Text(`待提升 ${this.weakMasteryCount()}`)
                      .fontSize(12).fontColor('#B42318').backgroundColor('#FEF3F2')
                      .padding({ left: 10, right: 10, top: 6, bottom: 6 }).borderRadius(12)
                    Text(`掌握良好 ${this.masteredCount()}`)
                      .fontSize(12).fontColor('#0F766E').backgroundColor('#ECFDF5')
                      .padding({ left: 10, right: 10, top: 6, bottom: 6 }).borderRadius(12)
                  }.width('100%')
                  ForEach(this.visibleMastery(), (item: KnowledgeMastery) => {
                    Column({ space: 7 }) {
                      Row() {
                        Text(item.knowledgePointName).fontSize(15).fontWeight(FontWeight.Medium)
                          .fontColor('#1F2937').layoutWeight(1).maxLines(1)
                        Text(this.assessed(item) ? this.masteryLevel(item.masteryScore) : '尚无练习记录').fontSize(11)
                          .fontColor(item.masteryScore < 60 ? '#B42318' : (item.masteryScore >= 80 ? '#0F766E' : '#B45309'))
                          .margin({ right: 8 })
                        Text(this.assessed(item) ? `${item.masteryScore}` : '—').fontSize(22).fontWeight(FontWeight.Bold).fontColor('#2563EB')
                        Text(this.assessed(item) ? '分' : '').fontSize(11).fontColor('#64748B').margin({ top: 7 })
                      }.width('100%').alignItems(VerticalAlign.Center)
                      if (this.assessed(item)) { Progress({ value: item.masteryScore, total: 100, type: ProgressType.Linear })
                        .color(item.masteryScore < 60 ? '#F97316' : '#2563EB')
                        .backgroundColor('#ECEFF3').height(6).borderRadius(8) }
                      Text(`练习证据 ${this.evidenceCount(item.knowledgePointId)} 条 · 更新于 ${ApiDisplayFormatter.timestamp(item.lastUpdated)}`)
                        .fontSize(11).fontColor('#98A2B3').maxLines(1)
                    }
                    .width('100%').padding(12).backgroundColor('#F8FAFC')
                    .border({ width: 1, color: '#E2E8F0' }).borderRadius(12)
                  }, (item: KnowledgeMastery) => item.knowledgePointId)
                  if (this.mastery.length > MASTERY_PREVIEW_COUNT) {
                    Button(this.showAllMastery ? '收起，只看优先项 ↑' : `查看全部 ${this.mastery.length} 项 ↓`)
                      .width('100%').height(40).fontSize(13).fontColor('#2563EB')
                      .backgroundColor('#EFF6FF').borderRadius(10)
                      .onClick(() => { this.showAllMastery = !this.showAllMastery; })
                  }
                }
                .width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(16)
                .shadow({ radius: 8, color: '#10000000', offsetX: 0, offsetY: 4 })
              } else {
                Column({ space: 10 }) {
                  Text('尚未建立知识画像').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#1F2937')
                    .width('100%')
                  Text('完成一次诊断或练习后，系统会在这里展示掌握度和证据。'
                    + '导入课程或讲义后，服务端会写入你的知识点加入候选池；选定课程和本次时长后再安排任务。')
                    .fontSize(14).fontColor('#64748B').lineHeight(22).width('100%')
                  Button('导入课程 / 资料').width('100%').height(44).fontSize(14).fontWeight(FontWeight.Bold)
                    .fontColor('#FFFFFF').backgroundColor('#2563EB').borderRadius(12)
                    .onClick(() => router.pushUrl({ url: 'pages/CourseImport', params: { initialTab: 'import' } }))
                  Button('去对话建立学习目标').width('100%').height(44).fontSize(14)
                    .fontColor('#2563EB').backgroundColor('#FFFFFF')
                    .border({ width: 1, color: '#BFDBFE' }).borderRadius(12)
                    .onClick(() => {
                      appState.setChatPrompt('帮我安排今天的学习：先看看我哪些知识点最薄弱，再给一个今天能做完的计划。');
                      router.pushUrl({ url: 'pages/ChatMain' });
                    })
                }.width('100%').padding(20).backgroundColor('#FFFFFF').borderRadius(16)
              }

              if (this.history.length > 0) {
                Column({ space: 10 }) {
                  Row() {
                    Text(`掌握度变化 ${this.meaningfulHistory().length} 次 ${this.showHistory ? '↑' : '↓'}`).onClick(() => this.showHistory = !this.showHistory).fontSize(17).fontWeight(FontWeight.Bold).fontColor('#111827')
                    Blank()
                  }.width('100%')
                  if (this.showHistory) {
                  Text('只展示分数真实发生变化的记录。')
                    .fontSize(12).fontColor('#667085').lineHeight(18).width('100%')
                  if (this.meaningfulHistory().length === 0) {
                    Column({ space: 5 }) {
                      Text('暂无有效变化').fontSize(15).fontWeight(FontWeight.Medium).fontColor('#475467')
                      Text('完成并提交一次专项练习后，这里会显示具体知识点、前后分数和增减幅度。')
                        .fontSize(12).fontColor('#98A2B3').lineHeight(18).textAlign(TextAlign.Center)
                    }.width('100%').padding(18).alignItems(HorizontalAlign.Center)
                      .backgroundColor('#F8FAFC').borderRadius(10)
                  }
                  ForEach(this.visibleHistory(), (item: MasteryHistory) => {
                    Column({ space: 8 }) {
                      Row() {
                        Column({ space: 3 }) {
                          Text(this.historyKnowledgePoint(item)).fontSize(14).fontWeight(FontWeight.Medium)
                            .fontColor('#1F2937')
                          Text(`${ApiDisplayFormatter.timestamp(item.timestamp)} · ${ApiDisplayFormatter.evidenceSource(item.source)}`)
                            .fontSize(11).fontColor('#98A2B3').maxLines(1)
                        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                        Text(this.historyDelta(item)).fontSize(18).fontWeight(FontWeight.Bold)
                          .fontColor(item.newScore > item.oldScore ? '#0F766E' : '#B42318')
                          .padding({ left: 9, right: 9, top: 4, bottom: 4 })
                          .backgroundColor(item.newScore > item.oldScore ? '#ECFDF5' : '#FEF3F2').borderRadius(10)
                      }.width('100%').onClick(() => this.toggleHistoryEvidence(item))
                      Row({ space: 8 }) {
                        Text(`${item.oldScore}`).fontSize(13).fontColor('#64748B')
                        Text('→').fontSize(13).fontColor('#98A2B3')
                        Text(`${item.newScore} 分`).fontSize(16).fontWeight(FontWeight.Bold).fontColor('#2563EB')
                        Blank()
                        Text(this.isHistoryExpanded(item) ? '收起 ↑' : '练习详情 ↓')
                          .fontSize(12).fontWeight(FontWeight.Medium).fontColor('#2563EB')
                      }.width('100%').onClick(() => this.toggleHistoryEvidence(item))
                      if (this.isHistoryExpanded(item)) {
                        if (this.evidenceForHistory(item).length === 0) {
                          Text('该次变化暂未返回可展示的证据详情。').fontSize(12).fontColor('#667085')
                        } else {
                          ForEach(this.evidenceForHistory(item), (evidence: Evidence) => {
                            Text(`${ApiDisplayFormatter.evidenceSource(evidence.sourceType)} · ${ApiDisplayFormatter.metric(evidence.metric)} · ${this.evidenceValue(evidence)}`)
                              .fontSize(12).fontColor('#475467').lineHeight(18).width('100%')
                          }, (evidence: Evidence) => evidence.id)
                        }
                      }
                    }.width('100%').padding(12).backgroundColor('#EFF6FF').borderRadius(10)
                  }, (item: MasteryHistory) => item.timestamp)
                  if (this.meaningfulHistory().length > HISTORY_PREVIEW_COUNT) {
                    Button(this.showAllHistory ? '收起变化记录 ↑' : `查看全部 ${this.meaningfulHistory().length} 次变化 ↓`)
                      .width('100%').height(40).fontSize(13).fontColor('#2563EB')
                      .backgroundColor('#EFF6FF').borderRadius(10)
                      .onClick(() => { this.showAllHistory = !this.showAllHistory; })
                  }
                  }
                }
                .width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(16)
              }

              if (this.mastery.length > 0) {
                Column({ space: 12 }) {
                  Text('建议下一步').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#1F2937').width('100%')
                  Text(this.weaknessSummary()).fontSize(13).fontColor('#475467').lineHeight(20).width('100%')
                  Button(this.hasAssessment() ? '开始专项练习' : '开始诊断练习', { type: ButtonType.Normal })
                    .width('100%').height(48).fontSize(15).fontWeight(FontWeight.Bold)
                    .fontColor('#FFFFFF').backgroundColor('#2563EB').borderRadius(12)
                    .enabled(!this.isStartingWorkflow)
                    .onClick(() => this.openRecommendedPractice())
                  Button('查看学习计划 →', { type: ButtonType.Normal })
                    .width('100%').height(40).fontSize(14).fontColor('#2563EB')
                    .backgroundColor(Color.Transparent).borderRadius(8)
                    .enabled(!this.isStartingWorkflow)
                    .onClick(() => router.pushUrl({ url: 'pages/StudyPlan' }))
                }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(18)
                  .border({ width: 1, color: '#BFDBFE' })
              }

              Column({ space: 10 }) {
                Button(this.showMoreActions ? '收起更多操作 ↑' : '更多操作 ↓', { type: ButtonType.Normal })
                  .width('100%').height(44).fontSize(13).fontColor('#64748B')
                  .backgroundColor(Color.Transparent).borderRadius(8)
                  .onClick(() => { this.showMoreActions = !this.showMoreActions; })
                if (this.showMoreActions) {
                  Text('需要重新评估整体学情时，可重新诊断并更新计划。')
                    .fontSize(12).fontColor('#667085').lineHeight(18).width('100%')
                  ActionButton({ label: this.isStartingWorkflow ? '正在启动诊断…' : '重新诊断并更新计划', available: !this.isStartingWorkflow, onAction: () => { void this.startDiagnosis(); } })
                }
              }.width('100%')

              if (this.workflowErrorMessage.length > 0) {
                Text(this.workflowErrorMessage).fontSize(13).fontColor('#B45309').lineHeight(19)
                  .width('100%').padding(12).backgroundColor('#FFFBEB').borderRadius(10)
              }

            }
          }
          .width('100%').padding({ left: 16, right: 16, top: 16, bottom: 96 })
        }
        .layoutWeight(1).backgroundColor('#F3F6FA')
      }
      .width('100%').height('100%')
      AIFloatButton()
    }.width('100%').height('100%')
  }
}

const MASTERY_PREVIEW_COUNT: number = 4;
const HISTORY_PREVIEW_COUNT: number = 3;
