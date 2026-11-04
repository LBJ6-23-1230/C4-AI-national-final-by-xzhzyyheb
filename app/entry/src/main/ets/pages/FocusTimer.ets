import { DeviceSummary } from '../components/DeviceSummary';
import { PageHeader } from '../components/PageHeader';
import { UiTheme } from '../utils/UiTheme';
import router from '@ohos.router';
import { appState } from '../data/AppState';
import { FocusSession, FocusSessionStatus, FocusTask, FocusRuntime } from '../models/AgentModels';
import { FocusClock } from '../utils/FocusClock';
import { AIFloatButton } from '../components/AIFloatButton';
import { FocusLifecycleService } from '../services/FocusLifecycleService';

@Entry
@Component
struct FocusTimer {
  @State remainingSeconds: number = 1800;
  @State elapsedSeconds: number = 0;
  @State paused: boolean = false;
  @State pauseCount: number = 0;
  @State interruptionCount: number = 0;
  @State showExitConfirm: boolean = false;
  @State showCompleteConfirm: boolean = false;
  @State saveError: string = '';
  private timerId: number = -1;
  private runtime: FocusRuntime | null = null;
  private ownerId: string = '';
  private lastCheckpointAt: number = 0;
  private pageHidden: boolean = false;

  aboutToAppear(): void {
    this.ownerId = appState.currentUser.userId;
    FocusLifecycleService.enterPage();
    this.resetFromTask();
    if (this.runtime === null) return;
    this.startTimer();
    if (!this.isStopwatch() && this.remainingSeconds <= 0) this.completeSession();
  }

  aboutToDisappear(): void {
    this.onPageHide();
    this.stopTimer();
  }

  /** Classify screen-off separately from navigation/background lifecycle callbacks. */
  onPageHide(): void {
    if (this.timerId < 0 || this.pageHidden || this.runtime === null || this.ownerId !== appState.currentUser.userId) return;
    this.pageHidden = true;
    FocusLifecycleService.pageHidden();
    this.stopTimer();
  }

  onPageShow(): void {
    if (this.runtime === null || this.ownerId !== appState.currentUser.userId) return;
    FocusLifecycleService.enterPage();
    this.pageHidden = false;
    if (appState.focusRuntime?.sessionId !== this.runtime.sessionId) return;
    this.runtime = appState.focusRuntime;
    if (this.runtime === null) return;
    this.paused = this.runtime.paused;
    this.pauseCount = this.runtime.pauseCount;
    this.interruptionCount = this.runtime.interruptionCount;
    this.updateClock();
    this.startTimer();
    if (!this.isStopwatch() && this.remainingSeconds <= 0) this.completeSession();
  }

  private resetFromTask(): void {
    const focusTask: FocusTask | null = appState.activeFocusTask;
    if (appState.focusRuntime === null && focusTask !== null && appState.focusResultDraft === null) {
      appState.beginFocusRuntime(focusTask);
    }
    this.runtime = appState.focusRuntime;
    if (this.runtime === null || this.runtime.ownerId !== this.ownerId) {
      this.saveError = '没有可恢复的计时记录，请返回专注设置。';
      this.runtime = null;
      return;
    }
    appState.setFocusTask(this.runtime.task);
    this.paused = this.runtime.paused;
    this.pauseCount = this.runtime.pauseCount;
    this.interruptionCount = this.runtime.interruptionCount;
    this.updateClock();
  }

  /** Elapsed time advances only while the runtime is running. */
  private updateClock(): void {
    if (this.runtime === null || this.ownerId !== appState.currentUser.userId) return;
    this.runtime = FocusClock.advance(this.runtime);
    const seconds: number = Math.floor(this.runtime.elapsedMs / 1000);
    const plannedSeconds: number = (appState.activeFocusTask?.plannedMinutes ?? 30) * 60;
    this.elapsedSeconds = this.isStopwatch() ? seconds : Math.min(seconds, plannedSeconds);
    this.remainingSeconds = this.isStopwatch() ? 0 : Math.max(0, plannedSeconds - this.elapsedSeconds);
  }

  private startTimer(): void {
    this.stopTimer();
    this.lastCheckpointAt = Date.now();
    this.timerId = setInterval(() => {
      this.updateClock();
      if (this.paused) {
        return;
      }
      if (this.runtime !== null && Date.now() - this.lastCheckpointAt >= 5000) {
        if (!appState.checkpointFocusRuntime(this.runtime)) this.saveError = '计时记录暂未保存成功，请稍后重试。';
        this.lastCheckpointAt = Date.now();
      }
      if (this.isStopwatch()) {
        return;
      }
      if (this.remainingSeconds <= 0) {
        this.completeSession();
      }
    }, 1000);
  }

  private stopTimer(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private isStrict(): boolean {
    return appState.activeFocusTask?.mode === 'strict';
  }

  private isStopwatch(): boolean {
    return appState.activeFocusTask?.timerType === 'stopwatch';
  }

  private displayedSeconds(): number {
    return this.isStopwatch() ? this.elapsedSeconds : this.remainingSeconds;
  }

  private displayTime(): string {
    const seconds: number = this.displayedSeconds();
    return `${Math.floor(seconds / 60).toString().padStart(2, '0')}:${(seconds % 60).toString().padStart(2, '0')}`;
  }

  private elapsedMinutes(): number {
    if (this.elapsedSeconds <= 0) {
      return 0;
    }
    return Math.max(1, Math.ceil(this.elapsedSeconds / 60));
  }

  private progressPercent(): number {
    const focusTask: FocusTask | null = appState.activeFocusTask;
    if (focusTask === null || this.isStopwatch() || focusTask.plannedMinutes <= 0) {
      return 0;
    }
    return Math.min(100, Math.round(this.elapsedSeconds / (focusTask.plannedMinutes * 60) * 100));
  }

  private completionRate(status: FocusSessionStatus): number {
    const focusTask: FocusTask | null = appState.activeFocusTask;
    if (status === 'interrupted') {
      return this.isStopwatch() ? 0 : this.progressPercent();
    }
    if (this.isStopwatch()) {
      return status === 'completed' ? 100 : 0;
    }
    if (focusTask === null || focusTask.plannedMinutes <= 0) {
      return status === 'completed' ? 100 : 0;
    }
    return Math.min(100, Math.round(this.elapsedMinutes() / focusTask.plannedMinutes * 100));
  }

  private buildSession(status: FocusSessionStatus): FocusSession {
    const focusTask: FocusTask | null = appState.activeFocusTask;
    return {
      taskId: this.runtime?.sessionId ?? `focus-${Date.now()}`,
      planTaskId: focusTask?.planTaskId,
      course: focusTask?.course ?? '数据结构',
      task: focusTask?.task ?? '理清二叉树中序遍历',
      plannedMinutes: this.isStopwatch() ? 0 : (focusTask?.plannedMinutes ?? 30),
      actualMinutes: this.elapsedMinutes(),
      pauseCount: this.pauseCount,
      interruptionCount: status === 'interrupted' ? this.interruptionCount + 1 : this.interruptionCount,
      completionRate: this.completionRate(status),
      selfAssessment: status === 'completed' ? 'completed' : 'not_completed',
      timerType: focusTask?.timerType ?? 'countdown',
      status: status,
      // 必须是 **ISO 8601**：这个值会作为 `lastStudyAt` 传给后端
      // `/api/v1/agent/proactive`，而后端用 `datetime.fromisoformat()` 解析。
      // 原先用 `toLocaleString()`（形如 "2026/9/20 17:30:00"）解析失败返回 None，
      // 导致 `gap_days=0`、`no_study_for_2d` 这条触发路径**永远不可达**。
      endedAt: new Date(!this.isStopwatch() && status === 'completed' && this.runtime?.finishedAt !== undefined
        ? this.runtime.finishedAt : Date.now()).toISOString()
    };
  }

  private openResult(status: FocusSessionStatus): void {
    this.updateClock();
    if (appState.currentUser.userId !== this.ownerId) {
      this.stopTimer();
      router.back();
      return;
    }
    if (!appState.setFocusResultDraft(this.buildSession(status))) {
      this.saveError = '结算草稿保存失败，请重试；计时记录仍然保留。';
      return;
    }
    this.stopTimer();
    router.pushUrl({ url: 'pages/FocusResult' });
  }

  private completeSession(): void {
    this.openResult('completed');
  }

  private togglePause(): void {
    if (this.isStrict()) {
      return;
    }
    this.updateClock();
    if (this.runtime === null) return;
    const next: FocusRuntime = FocusClock.advance(this.runtime);
    next.paused = !this.paused;
    next.autoPaused = false;
    next.backgroundReason = undefined;
    if (next.paused) next.pauseCount++;
    if (!appState.checkpointFocusRuntime(next)) {
      this.saveError = '暂停状态保存失败，请重试。';
      return;
    }
    this.runtime = next;
    this.paused = next.paused;
    this.pauseCount = next.pauseCount;
    this.saveError = '';
  }

  private goBackToSetup(): void {
    if (this.isStrict()) {
      this.showExitConfirm = true;
      return;
    }
    FocusLifecycleService.leavePage();
    this.onPageHide();
    router.back();
  }

  onBackPress(): boolean {
    if (!this.isStrict()) {
      FocusLifecycleService.leavePage();
      return false;
    }
    this.showExitConfirm = true;
    return true;
  }

  private showCompleteConfirmDialog(): void {
    this.showCompleteConfirm = true;
  }

  private dismissCompleteConfirm(): void {
    this.showCompleteConfirm = false;
  }

  private confirmComplete(): void {
    this.showCompleteConfirm = false;
    this.completeSession();
  }

  private showExitConfirmDialog(): void {
    this.showExitConfirm = true;
  }

  private dismissExitConfirm(): void {
    this.showExitConfirm = false;
  }

  private saveIncompleteAndLeave(): void {
    this.showExitConfirm = false;
    this.openResult('not_completed');
  }

  private leaveWithoutRecord(): void {
    if (!appState.discardFocusRecovery()) {
      this.saveError = '未能保存放弃操作，请重试。';
      return;
    }
    this.stopTimer();
    this.showExitConfirm = false;
    const planTaskId: string | undefined = appState.activeFocusTask?.planTaskId;
    if (planTaskId !== undefined) {
      appState.updatePlanTaskStatus(planTaskId, 'todo');
    }
    router.back();
  }

  private interruptStrictFocus(): void {
    this.showExitConfirm = false;
    this.openResult('interrupted');
  }

  private statusText(): string {
    if (this.isStrict()) {
      return '严格专注进行中';
    }
    if (this.paused) {
      return this.runtime?.autoPaused ? '离开后已自动暂停，点击继续' : '已暂停，准备好后继续';
    }
    return this.isStopwatch() ? '从现在开始，往前多走一点' : '只专注这一件事';
  }

  private modeHint(): string {
    if (this.isStrict()) {
      return '严格模式：没有暂停，提前退出会记录为中断。';
    }
    return appState.activeFocusTask?.allowBackgroundTiming === true
      ? '后台计时已开启：返回、切换应用和息屏后继续计时。'
      : '后台计时已关闭：返回或切换应用会暂停；息屏继续计时。';
  }

  build() {
    Stack() {
      Column() {
        PageHeader({ title: '专注计时', assistant: true, onBack: () => this.goBackToSetup() })
        Scroll() {
          Column({ space: 18 }) {
            DeviceSummary({ compact: true })
            Divider().color(UiTheme.line)
            if (this.saveError.length > 0) { Text(this.saveError).fontSize(13).fontColor(UiTheme.danger).width('100%') }
            Column({ space: 14 }) {
              Text(this.isStopwatch() ? '已专注时间' : '剩余时间').fontSize(14).fontColor(UiTheme.secondary)
              Text(this.displayTime()).fontSize(64).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink)
              Text(this.isStrict() ? '严格模式' : '普通模式').fontSize(13).fontColor(UiTheme.accent)
                .padding({ left: 10, right: 10, top: 5, bottom: 5 }).backgroundColor(UiTheme.tint).borderRadius(8)
              Text(this.paused ? this.statusText() : this.isStrict() ? '严格 · 不可暂停' : appState.activeFocusTask?.allowBackgroundTiming === true ? '普通 · 后台计时开启' : '普通 · 后台计时关闭')
                .fontSize(13).fontColor(UiTheme.secondary).lineHeight(20).textAlign(TextAlign.Center)
            }.width('100%').padding({ top: 44, bottom: 32 })
            if (!this.isStrict()) {
              Button(this.paused ? '继续专注' : '暂停', { type: ButtonType.Normal }).width('100%').height(48)
                .fontSize(16).fontWeight(FontWeight.Medium).fontColor(UiTheme.surface).backgroundColor(UiTheme.accent)
                .borderRadius(8).onClick(() => this.togglePause())
            }
            Button('完成本次专注', { type: ButtonType.Normal }).width('100%').height(46).fontSize(15)
              .fontColor('#FFFFFF').backgroundColor(UiTheme.accent).borderRadius(8)
              .onClick(() => this.showCompleteConfirmDialog())
            Button(this.isStrict() ? '中断并结算' : '提前退出', { type: ButtonType.Normal }).width('100%').height(44)
              .fontSize(14).fontColor(this.isStrict() ? UiTheme.danger : UiTheme.secondary).backgroundColor(this.isStrict() ? '#FFF0F0' : UiTheme.surface).borderRadius(8)
              .onClick(() => this.showExitConfirmDialog())
            if (!this.isStrict()) {
              Text(this.modeHint()).fontSize(12).fontColor(UiTheme.secondary).lineHeight(19).width('100%').margin({ top: 12 })
            }
          }.width('100%').constraintSize({ maxWidth: UiTheme.contentWidth }).padding({ left: 20, right: 20, bottom: 24 })
        }.width('100%').layoutWeight(1).scrollBar(BarState.Off).align(Alignment.TopStart)
      }.width('100%').height('100%').backgroundColor(UiTheme.surface)

      if (this.showCompleteConfirm) {
        Column() {
          Column({ space: 16 }) {
            Text('确认完成本次专注？')
              .fontSize(20).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink)
            Text(`已专注 ${this.elapsedMinutes()} 分钟，确认后会进入结算页。`)
              .fontSize(14).fontColor(UiTheme.secondary).lineHeight(20).textAlign(TextAlign.Center)
            Row({ space: 12 }) {
              Button('继续专注').layoutWeight(1).height(44).fontSize(14).fontWeight(FontWeight.Medium)
                .fontColor(UiTheme.accent).backgroundColor(UiTheme.surface)
                .border({ width: 1, color: UiTheme.accent }).borderRadius(8)
                .onClick(() => this.dismissCompleteConfirm())
              Button('去结算').layoutWeight(1).height(44).fontSize(14).fontWeight(FontWeight.Medium)
                .fontColor(UiTheme.surface).backgroundColor(this.isStrict() ? '#1E3A5F' : UiTheme.accent).borderRadius(8)
                .onClick(() => this.confirmComplete())
            }.width('100%')
          }
          .width('82%').padding(24).backgroundColor(UiTheme.surface).borderRadius(8)

        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
        .backgroundColor('#40000000')
      }

      if (this.showExitConfirm) {
        Column() {
          Column({ space: 16 }) {
            Text(this.isStrict() ? '确认中断严格专注？' : '提前退出吗？')
              .fontSize(20).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink)
            Text(this.isStrict() ? '这次会记录为中断，并进入结算页。' : '你可以继续，也可以保存为未完成记录。')
              .fontSize(14).fontColor(UiTheme.secondary).lineHeight(20).textAlign(TextAlign.Center)
            if (this.isStrict()) {
              Row({ space: 12 }) {
                Button('继续坚持').layoutWeight(1).height(44).fontSize(14).fontWeight(FontWeight.Medium)
                  .fontColor(UiTheme.surface).backgroundColor('#1E3A5F').borderRadius(8)
                  .onClick(() => this.dismissExitConfirm())
                Button('确认中断').layoutWeight(1).height(44).fontSize(14).fontWeight(FontWeight.Medium)
                  .fontColor('#8A3A2B').backgroundColor(UiTheme.surface)
                  .border({ width: 1, color: '#8A3A2B' }).borderRadius(8)
                  .onClick(() => this.interruptStrictFocus())
              }.width('100%')
            } else {
              Button('继续专注').width('100%').height(42).fontSize(14).fontColor(UiTheme.surface).backgroundColor(UiTheme.accent).borderRadius(8)
                .onClick(() => this.dismissExitConfirm())
              Button('保存为未完成').width('100%').height(42).fontSize(14).fontColor(UiTheme.accent).backgroundColor(UiTheme.surface)
                .border({ width: 1, color: UiTheme.accent }).borderRadius(8)
                .onClick(() => this.saveIncompleteAndLeave())
              Button('不保存，返回设置').width('100%').height(42).fontSize(14).fontColor('#8A3A2B').backgroundColor(UiTheme.surface)
                .border({ width: 1, color: '#D6B3A7' }).borderRadius(8)
                .onClick(() => this.leaveWithoutRecord())
            }
          }
          .width('82%').padding(24).backgroundColor(UiTheme.surface).borderRadius(8)

        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
        .backgroundColor('#40000000')
      }
    AIFloatButton()
    }
    .width('100%').height('100%').backgroundColor(this.isStrict() ? UiTheme.canvas : UiTheme.surface)
  }
}
