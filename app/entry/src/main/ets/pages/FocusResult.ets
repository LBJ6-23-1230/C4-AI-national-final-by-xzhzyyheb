import { UiTheme } from '../utils/UiTheme';
import { PageHeader } from '../components/PageHeader';
import router from '@ohos.router';
import { appState } from '../data/AppState';
import { AgentFeedback, FocusSelfAssessment, FocusSession, FocusTask, PlanTaskStatus } from '../models/AgentModels';
import { LocalAgentService } from '../services/LocalAgentService';
import { AIFloatButton } from '../components/AIFloatButton';
import { ChatNavigation } from '../services/ChatNavigation';
import { AgentApiClient } from '../api/AgentApiClient';
import { DistributedStateService } from '../services/DistributedStateService';
import { FocusSessionSyncService } from '../services/FocusSessionSyncService';

@Entry
@Component
struct FocusResult {
  @State assessment: FocusSelfAssessment = 'completed';
  @State actualMinutes: number = 30;
  @State pauseCount: number = 0;
  @State interruptionCount: number = 0;
  @State showRecordDetails: boolean = false;
  @State saved: boolean = false;
  @State resultSession: FocusSession | null = null;
  @State saveError: string = '';
  @State saving: boolean = false;
  @StorageLink('focusSyncMessage') focusSyncMessage: string = '';
  private ownerId: string = '';
  private fallbackTaskId: string = `focus-${Date.now()}`;

  aboutToAppear(): void {
    if (this.ownerId.length > 0 && this.ownerId !== appState.currentUser.userId) {
      this.resultSession = null;
      this.saveError = '账号已切换，请返回原账号继续。';
      router.back();
      return;
    }
    this.ownerId = appState.currentUser.userId;
    if (appState.focusResultDraft !== null) {
      this.resultSession = appState.focusResultDraft;
      this.assessment = appState.focusResultDraft.selfAssessment;
      this.actualMinutes = appState.focusResultDraft.actualMinutes;
      this.pauseCount = appState.focusResultDraft.pauseCount;
      this.interruptionCount = appState.focusResultDraft.interruptionCount;
      const shared = FocusSessionSyncService.getInstance().getSnapshot().session;
      if (shared?.sessionId === this.resultSession.taskId && shared.record !== undefined && shared.record !== null) {
        this.resultSession = shared.record;
        this.assessment = shared.record.selfAssessment;
        this.saved = true;
        const active = appState.activeFocusTask;
        if (active !== null && active.course === shared.record.course && active.task === shared.record.task &&
          active.planTaskId === shared.record.planTaskId) appState.clearFocusTask();
        appState.clearFocusResultDraft();
      }
    }
  }

  private currentSession(): FocusSession {
    const draft: FocusSession | null = this.resultSession ?? appState.focusResultDraft;
    const focusTask: FocusTask | null = appState.activeFocusTask;
    const planned: number = draft?.plannedMinutes ?? focusTask?.plannedMinutes ?? 30;
    const actual: number = draft?.actualMinutes ?? this.actualMinutes;
    const timedRate: number = planned <= 0 ? (actual > 0 ? 100 : 0) : Math.min(100, Math.round(actual / planned * 100));
    const completionRate: number = timedRate;
    const status = this.assessment === 'completed' ? 'completed' :
      ((draft?.status === 'interrupted' || this.interruptionCount > 0) ? 'interrupted' : 'not_completed');
    return {
      shared: draft?.shared,
      taskId: draft?.taskId ?? this.fallbackTaskId,
      planTaskId: draft?.planTaskId ?? focusTask?.planTaskId,
      course: draft?.course ?? focusTask?.course ?? '数据结构',
      task: draft?.task ?? focusTask?.task ?? '理清二叉树中序遍历',
      plannedMinutes: planned, actualMinutes: actual,
      pauseCount: draft?.pauseCount ?? this.pauseCount,
      interruptionCount: draft?.interruptionCount ?? this.interruptionCount,
      completionRate: completionRate, selfAssessment: this.assessment,
      timerType: draft?.timerType ?? focusTask?.timerType ?? 'countdown',
      status: status,
      // 同 FocusTimer：必须是 ISO 8601，否则后端解析 `lastStudyAt` 失败，
      // `no_study_for_2d` 触发路径不可达。
      endedAt: draft?.endedAt ?? new Date().toISOString()
    };
  }

  private async save(): Promise<void> {
    if (this.saved || this.saving) {
      return;
    }
    if (appState.currentUser.userId !== this.ownerId) {
      this.saveError = '账号已切换，请返回原账号保存这条记录。';
      return;
    }
    if (this.resultSession === null && appState.focusResultDraft === null) {
      this.saveError = '没有可保存的结算记录，请先开始一次专注。';
      return;
    }
    const proposed: FocusSession = this.currentSession();
    let sharedSaved: boolean = false;
    const sharedService = FocusSessionSyncService.getInstance();
    const shared = sharedService.getSnapshot().session;
    if (proposed.shared === true || shared?.sessionId === proposed.taskId) {
      this.saving = true;
      if (shared === null) await DistributedStateService.getInstance().refresh();
      const current = sharedService.getSnapshot().session;
      if (current?.sessionId !== proposed.taskId) {
        this.saveError = '暂时无法读取这次共享专注，请联网后重试。'; this.saving = false; return;
      }
      if (!['completed', 'abandoned'].includes(current.state) && !(await sharedService.finish(this.assessment))) {
        this.saveError = sharedService.getSnapshot().lastError; this.saving = false; return;
      }
      if (appState.currentUser.userId !== this.ownerId) { this.saving = false; return; }
      sharedSaved = true;
      this.saving = false;
    }
    const existing: FocusSession | undefined = appState.focusSessions.find(
      (item: FocusSession) => item.taskId === proposed.taskId);
    const canonical = sharedService.getSnapshot().session?.record;
    const session: FocusSession = sharedSaved && canonical !== undefined && canonical !== null ? canonical : (existing ?? proposed);
    this.assessment = session.selfAssessment;
    // 重复 taskId（同一条专注被结算两次，例如快速连点"保存这次记录"）。
    //
    //  这里**不能提前 return** —— 那样会留下两个尾巴：
    //   ① `focusResultDraft` 不被清掉，下次进结算页还会看到上一条的旧数据；
    //   ② 计划不回写，可页面照样显示"已保存"，用户以为进度更新了（假成功）。
    // 正确做法：照常走完"清理 + 回写"，只在文案上如实说明这是重复提交。
    const saveStatus: string = appState.saveFocusSession(session, sharedSaved);
    if (saveStatus === 'failed') {
      this.saveError = '本机保存失败，请重试；当前结果仍保留在本页。';
      return;
    }
    this.saveError = '';
    const duplicate: boolean = saveStatus === 'duplicate';
    const fixtureMode: boolean = this.isFixture();
    // ① 把完成状态记到**用户看得见的那份计划**的 taskId 上（联机=后端契约计划、
    //    离线=Fixture 契约计划，两者 id 同源）。这一步与"有没有本地计划"无关 ——
    //    否则"先专注、后打开计划页"的顺序会把完成状态丢掉。
    //    此前的缺陷：只按本地计划的 `agent-*` id 匹配，而入口带下来的是契约 id
    //    `task-postorder`，两边永不相等 → 完成度恒 0%、复盘恒说"还没有完成任务"。
    const planTaskStatus: PlanTaskStatus =
      session.selfAssessment === 'completed' ? 'completed' :
        (session.selfAssessment === 'partial' ? 'partial' : 'deferred');
    const matchedPlan: boolean = appState.markPlanTaskStatus(
      session.planTaskId ?? session.taskId, planTaskStatus);

    // ② 本地生成的那份计划（离线兜底）仍按自己的 id 更新一次，两条路互不影响。
    const currentPlan = appState.weeklyPlan ?? (fixtureMode ? LocalAgentService.generateWeeklyPlan(
      appState.courses, appState.homeworkDDLs, appState.currentUser
    ) : null);
    if (currentPlan !== null) {
      appState.setWeeklyPlan(LocalAgentService.adjustPlanAfterFocus(currentPlan, session));
    }
    if (fixtureMode) {
      appState.latestReview = LocalAgentService.generateReviewSummary(
        appState.latestSuggestion,
        appState.latestPartner,
        appState.latestWrongAnalysis
      );
    }
    // 文案必须与**实际结果**一致：没关联到计划任务时不能报"进度已更新"
    // （原来只要 `currentPlan !== null` 就说"已更新"，即使一个任务都没匹配上 ——
    //  这正是文档里记的"假成功"）。
    const head: string = duplicate ? '（这条专注记录此前已保存过，本次未重复计入。）' : '';
    appState.completeChatTask(
      head + (matchedPlan ?
        (fixtureMode
          ? (this.assessment === 'completed' ? '本次专注已完成，离线计划已同步更新。' : '本次专注结果已保存，离线计划已调整。')
          : '本次专注已保存到本机，当前计划进度已更新，云端同步状态请查看专注结果页。') :
        '本次专注结果已保存；本次任务未关联到当前计划，计划进度不变。'),
      matchedPlan ? (fixtureMode ? '查看离线模式更新后的安排。' : '查看更新后的当前计划。') : '查看当前计划。',
      '查看更新计划',
      'pages/StudyPlan'
    );
    this.resultSession = session;
    appState.clearFocusResultDraft();
    appState.clearFocusTask();
    //  同步清除分布式共享状态。
    //   漏掉这一步会造成跨设备"僵尸任务"：本机已经结算完，另一台设备上
    //   却一直显示「手机正在专注：xxx」并提供"接着做"按钮，点了会进入一个
    //   早已结束的任务。必须与本地状态一起清理。
    if (!sharedSaved) DistributedStateService.getInstance().clearFocusTask();
    this.saved = true;
    void appState.syncFocusSessions();
  }

  private returnToChat(): void {
    ChatNavigation.returnToChat();
  }

  private changeAssessment(value: FocusSelfAssessment): void {
    const previous: FocusSelfAssessment = this.assessment;
    this.assessment = value;
    if (!appState.setFocusResultDraft(this.currentSession())) {
      this.assessment = previous;
      this.saveError = '自评草稿保存失败，请重试。';
    } else {
      this.saveError = '';
    }
  }

  private isFixture(): boolean {
    return AgentApiClient.getConfig().useFixture;
  }

  private timerLabel(): string {
    return this.currentSession().timerType === 'stopwatch' ? '正计时' : '倒计时';
  }

  private statusLabel(): string {
    switch (this.currentSession().status) {
      case 'completed': return '已完成';
      case 'interrupted': return '已中断';
      default: return '未完成';
    }
  }

  build() {
    Stack() {
      Column() {
        PageHeader({ title: '专注已结束', assistant: true, onBack: () => { if (this.saved) this.returnToChat(); } })
        Scroll() {
          Column({ space: 18 }) {
            Text(this.saved ? '记录已保存在本机' : '保存后保留本机记录并同步').fontSize(13).fontColor(UiTheme.secondary).width('100%')
            if (this.focusSyncMessage) { Text(this.focusSyncMessage).fontSize(13).fontColor(UiTheme.secondary).lineHeight(20).width('100%') }
            Text('本次专注完成').fontSize(22).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
            Row() {
              this.StatCard(`${this.currentSession().actualMinutes}分钟`, '实际时长')
              this.StatCard(this.currentSession().plannedMinutes > 0 ? `${this.currentSession().plannedMinutes}分钟` : '正计时', '计划时长')
            }.width('100%')
            Divider().color(UiTheme.line)
            Row({ space: 12 }) {
              Text('任务').fontSize(14).fontColor(UiTheme.secondary).width(44)
              Text(this.currentSession().task).fontSize(15).fontColor(UiTheme.ink).layoutWeight(1)
            }.width('100%')
            Text('自我评价').fontSize(17).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
            Text('自评不等于掌握，用于后续复盘。').fontSize(12).fontColor(UiTheme.secondary).width('100%')
            ForEach(['completed', 'partial', 'not_completed'], (value: string) => {
              Button({ type: ButtonType.Normal }) {
                Row({ space: 12 }) {
                  Radio({ value: value, group: 'focus-assessment' }).checked(this.assessment === value).width(18).height(18).hitTestBehavior(HitTestMode.None)
                  Column({ space: 4 }) {
                    Text(this.assessmentLabel(value)).fontSize(15).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink)
                    Text(value === 'completed' ? '按计划完成任务，达成本次目标。' : value === 'partial' ? '完成了主要内容，仍有未完成部分。' : '本次基本未完成，需要重新安排。')
                      .fontSize(12).fontColor(UiTheme.secondary)
                  }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                }.width('100%').padding(12)
              }.width('100%').constraintSize({ minHeight: 58 }).backgroundColor(this.assessment === value ? UiTheme.tint : UiTheme.surface)
                .border({ width: 1, color: UiTheme.line }).borderRadius(8).enabled(!this.saved)
                .onClick(() => this.changeAssessment(value as FocusSelfAssessment))
            }, (value: string) => value)
            if (this.saveError) { Text(this.saveError).fontSize(13).fontColor(UiTheme.danger).width('100%') }
            if (!this.saved) {
              Button(this.saving ? '正在同步…' : '保存这次记录', { type: ButtonType.Normal }).width('100%').height(46).fontSize(15).fontColor('#FFFFFF')
                .backgroundColor(UiTheme.accent).borderRadius(8).enabled(!this.saving).onClick(() => { void this.save(); })
            } else {
              if (!this.isFixture()) { Button('重试同步', { type: ButtonType.Normal }).height(44).fontSize(14).fontColor(UiTheme.accent).backgroundColor(UiTheme.surface).onClick(() => { void appState.syncFocusSessions(); }) }
              Button('查看更新计划', { type: ButtonType.Normal }).width('100%').height(46).fontSize(15).fontColor('#FFFFFF')
                .backgroundColor(UiTheme.accent).borderRadius(8).onClick(() => router.pushUrl({ url: 'pages/StudyPlan' }))
              Button('返回聊天', { type: ButtonType.Normal }).width('100%').height(44).fontSize(14).fontColor(UiTheme.accent)
                .backgroundColor(UiTheme.surface).onClick(() => this.returnToChat())
            }
            Text(this.showRecordDetails ? '收起记录信息' : '更多记录信息 ›').fontSize(13).fontColor(UiTheme.secondary).padding({ top: 12, bottom: 12 })
              .onClick(() => this.showRecordDetails = !this.showRecordDetails)
            if (this.showRecordDetails) {
              Text(`${this.currentSession().course} · ${this.timerLabel()} · ${this.statusLabel()}`).fontSize(13).fontColor(UiTheme.secondary).width('100%')
              Text(`暂停${this.currentSession().pauseCount}次 · 中断${this.currentSession().interruptionCount}次`).fontSize(13).fontColor(UiTheme.secondary).width('100%')
              if (this.isFixture()) {
                Text('离线模式的下一步建议').fontSize(14).fontColor(UiTheme.ink).width('100%')
                Text(this.currentFeedback().feedback + '\n' + this.currentFeedback().nextSuggestion).fontSize(13).fontColor(UiTheme.secondary).lineHeight(21).width('100%')
              }
            }
          }.width('100%').constraintSize({ maxWidth: UiTheme.contentWidth }).padding(20).alignItems(HorizontalAlign.Start)
        }.width('100%').layoutWeight(1).scrollBar(BarState.Off).align(Alignment.TopStart)
      }.width('100%').height('100%').backgroundColor(UiTheme.surface)
      AIFloatButton()
    }.width('100%').height('100%')
  }

  private assessmentLabel(value: string): string {
    return value === 'completed' ? '完成' : value === 'partial' ? '部分完成' : '未完成';
  }

  private currentFeedback(): AgentFeedback {
    return LocalAgentService.createFocusFeedback(this.currentSession());
  }

  @Builder
  StatCard(value: string, label: string) {
    Column({ space: 8 }) {
      Text(label).fontSize(13).fontColor(UiTheme.secondary)
      Text(value).fontSize(25).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink)
    }.layoutWeight(1).padding({ top: 12, bottom: 12 }).alignItems(HorizontalAlign.Start)
  }
}
