import { AppBottomBar } from '../components/AppBottomBar';
import { UiTheme } from '../utils/UiTheme';
import { PageHeader } from '../components/PageHeader';
import router from '@ohos.router';
import { appState } from '../data/AppState';
import { FocusMode, FocusSource, FocusTask, FocusTimerType } from '../models/AgentModels';
import { AIFloatButton } from '../components/AIFloatButton';
import { DistributedSnapshot, DistributedStateService } from '../services/DistributedStateService';
import { FocusSessionSyncService } from '../services/FocusSessionSyncService';
import { AgentApiClient } from '../api/AgentApiClient';

@Entry
@Component
struct FocusSetup {
  @State recoveryDescription: string = '';
  @State startError: string = '';
  @State starting: boolean = false;
  @State sharedDescription: string = '';
  @StorageLink('sharedFocusRevision') @Watch('refreshShared') sharedFocusRevision: number = 0;
  @StorageLink('focusDataRevision') @Watch('refreshRecovery') focusDataRevision: number = 0;
  @State course: string = '数据结构';
  @State task: string = '理清二叉树中序遍历';
  @State minutes: number = 30;
  @State customMinutesText: string = '45';
  @State selectedDuration: string = '30';
  @State mode: FocusMode = 'normal';
  @State allowBackgroundTiming: boolean = false;
  @State shareFocus: boolean = false;
  @State source: FocusSource = 'manual';
  @State timerType: FocusTimerType = 'countdown';

  /* ---- 全场景分布式同步状态 ----
   *
   *  拆成多个**顶层 @State 基本类型**，而不是存一个 `DistributedSnapshot` 对象：
   * ArkUI 只对 @State 变量本身做变更观测，对对象内部字段的赋值不触发重渲染。
   * 存整个对象会出现"数据更新了但界面不动"的假象。
   */
  @State private syncReady: boolean = false;
  @State private syncPermissionGranted: boolean = false;
  @State private syncPeerCount: number = 0;
  @State private syncLocalDevice: string = '';
  @State private syncError: string = '';
  @State private syncDelivery: string = '';
  /** 对端同步过来的任务描述；空串表示当前没有对端任务。 */
  @State private syncRemoteTask: string = '';
  @State private syncRemoteDevice: string = '';
  /** 对端任务是否为"正在专注中"（用于文案区分"正在专注"与"刚结束"）。 */
  @State private syncRemoteActive: boolean = false;

  private distributed: DistributedStateService = DistributedStateService.getInstance();

  aboutToAppear(): void {
    this.refreshRecovery();
    const imported: FocusTask | null = appState.activeFocusTask;
    if (imported !== null) {
      this.course = imported.course;
      this.task = imported.task;
      this.minutes = imported.plannedMinutes > 0 ? imported.plannedMinutes : 30;
      this.mode = imported.mode;
      this.allowBackgroundTiming = appState.focusRuntime !== null && imported.allowBackgroundTiming === true;
      this.source = imported.source;
      this.timerType = imported.timerType ?? 'countdown';
      this.selectedDuration = imported.timerType === 'stopwatch' ? 'stopwatch' : this.durationKey(this.minutes);
      this.customMinutesText = this.selectedDuration === 'custom' ? this.minutes.toString() : this.customMinutesText;
    } else if (appState.courses.length > 0) {
      this.course = appState.getHighPriorityCourse()?.courseName ?? this.course;
    }

    // 订阅跨设备同步状态，并立刻拉一次当前快照（服务可能在进入本页之前就已就绪）。
    this.distributed.setListener((snapshot: DistributedSnapshot) => this.applySnapshot(snapshot));
    this.applySnapshot(this.distributed.getSnapshot());
    this.refreshShared();
  }

  aboutToDisappear(): void {
    // 只解除 UI 订阅，**不退出分布式会话** —— 会话要在整个应用生命周期内保持，
    // 否则切换页面就会掉线，另一台设备看到的状态会闪断。
    this.distributed.setListener(null);
  }

  /** 把服务快照摊平成 @State 变量（见上文关于"不存对象"的说明）。 */
  private applySnapshot(snapshot: DistributedSnapshot): void {
    this.syncReady = snapshot.sessionReady && snapshot.localJoined;
    this.syncPermissionGranted = snapshot.permissionGranted;
    this.syncPeerCount = snapshot.onlinePeerCount;
    this.syncLocalDevice = snapshot.localDeviceLabel;
    this.syncError = snapshot.lastError;
    this.syncDelivery = snapshot.deliveryText;
    this.syncRemoteDevice = snapshot.remoteDeviceLabel;
    if (snapshot.remoteTask !== null) {
      const remote: FocusTask = snapshot.remoteTask;
      this.syncRemoteTask = remote.task.length > 0 ? remote.task : remote.course;
      this.syncRemoteActive = true;
    } else {
      this.syncRemoteTask = '';
      this.syncRemoteActive = false;
    }
  }

  private refreshShared(): void {
    const snapshot = FocusSessionSyncService.getInstance().getSnapshot();
    const session = snapshot.session;
    if (session === null || !['running', 'paused'].includes(session.state)) { this.sharedDescription = ''; return; }
    const seconds = Math.ceil(session.remainingMs / 1000);
    const clock = session.task.timerType === 'stopwatch' ? `已专注 ${Math.floor(session.elapsedMs / 60000)} 分钟` :
      `剩余 ${Math.floor(seconds / 60)}:${(seconds % 60).toString().padStart(2, '0')}`;
    this.sharedDescription = `${session.leaderLabel} · ${session.task.task} · ${session.state === 'paused' ? '已暂停' : clock}`;
  }

  private async continueShared(): Promise<void> {
    this.starting = true;
    const service = FocusSessionSyncService.getInstance();
    if (await service.handoff()) router.pushUrl({ url: 'pages/FocusTimer' });
    else this.startError = service.getSnapshot().lastError;
    this.starting = false;
  }

  /**
   * 采用对端设备上正在进行的任务。
   *
   * 这是"全场景接续"的核心动作：手机上选的任务，平板上一点就能接着做，
   * 不需要用户在第二台设备上重新挑课程、重新输任务名。
   */
  private adoptRemoteTask(): void {
    const remote: FocusTask | null = this.distributed.getSnapshot().remoteTask;
    if (remote === null) {
      return;
    }
    if (appState.focusRuntime !== null || appState.focusResultDraft !== null) {
      this.startError = '请先完成或放弃本机上次专注，再使用其他设备的任务。';
      return;
    }
    appState.setFocusTask(remote);
    this.distributed.consumeRemoteTask();
    this.course = remote.course;
    this.task = remote.task;
    if (remote.plannedMinutes > 0) {
      this.minutes = remote.plannedMinutes;
      this.selectedDuration = this.durationKey(remote.plannedMinutes);
      if (this.selectedDuration === 'custom') {
        this.customMinutesText = remote.plannedMinutes.toString();
      }
    }
    this.mode = remote.mode;
    this.allowBackgroundTiming = remote.allowBackgroundTiming === true;
    this.timerType = remote.timerType ?? 'countdown';
    this.source = remote.source;
  }

  private durationKey(value: number): string {
    if (value === 30) {
      return '30';
    }
    if (value === 60) {
      return '60';
    }
    return 'custom';
  }

  private selectCountdown(value: number): void {
    this.timerType = 'countdown';
    this.minutes = value;
    this.selectedDuration = value.toString();
  }

  private selectCustom(): void {
    this.timerType = 'countdown';
    this.selectedDuration = 'custom';
    this.minutes = this.normalizedCustomMinutes();
  }

  private selectStopwatch(): void {
    this.timerType = 'stopwatch';
    this.selectedDuration = 'stopwatch';
  }

  private normalizedCustomMinutes(): number {
    const raw: number = Number(this.customMinutesText.replace(/[^0-9]/g, ''));
    if (raw < 1) {
      return 1;
    }
    if (raw > 180) {
      return 180;
    }
    return raw;
  }

  private onCustomMinutesChange(value: string): void {
    this.customMinutesText = value;
    if (this.selectedDuration === 'custom') {
      this.minutes = this.normalizedCustomMinutes();
    }
  }

  private plannedMinutesForStart(): number {
    if (this.timerType === 'stopwatch') {
      return 0;
    }
    if (this.selectedDuration === 'custom') {
      return this.normalizedCustomMinutes();
    }
    return this.minutes;
  }

  private async startFocus(): Promise<void> {
    if (this.starting) return;
    this.starting = true;
    this.startError = '';
    const planTaskId: string | undefined = appState.activeFocusTask?.planTaskId;
    const focusTask: FocusTask = {
      course: this.course,
      task: this.task.trim(),
      plannedMinutes: this.plannedMinutesForStart(),
      source: this.source,
      mode: this.mode,
      timerType: this.timerType,
      allowBackgroundTiming: this.mode === 'normal' && this.allowBackgroundTiming,
      planTaskId: planTaskId
    };
    if (this.shareFocus && !AgentApiClient.getConfig().useFixture && appState.isSignedIn) {
      if (appState.focusRuntime !== null || appState.focusResultDraft !== null) {
        this.startError = '请先恢复或放弃上次专注，再开始新任务。'; this.starting = false; return;
      }
      await this.distributed.refresh();
      const service = FocusSessionSyncService.getInstance();
      if (!(await service.start(focusTask))) {
        this.startError = service.getSnapshot().lastError || '暂时无法开始共享专注，请检查连接后重试。';
        this.starting = false; this.refreshShared(); return;
      }
    } else if (this.sharedDescription.length > 0) {
      this.startError = '已有共享专注正在进行，请先接续或结束该场专注。';
      this.starting = false; return;
    } else if (!appState.beginFocusRuntime(focusTask)) {
      this.startError = this.recoveryDescription.length > 0
        ? '请先恢复或放弃上次专注，再开始新任务。' : '计时记录保存失败，请重试。';
      this.starting = false; return;
    }
    if (planTaskId !== undefined) {
      appState.updatePlanTaskStatus(planTaskId, 'in_progress');
    }
    // Send only to explicitly confirmed devices. Delivery is shown after recipient ACK.
    this.starting = false;
    router.pushUrl({ url: 'pages/FocusTimer' });
  }

  private refreshRecovery(): void {
    this.recoveryDescription = appState.focusResultDraft !== null
      ? `上次专注“${appState.focusResultDraft.task}”还没有保存结算。`
      : (appState.focusRuntime !== null ? `可恢复专注“${appState.focusRuntime.task.task}”。${appState.focusRuntime.paused ? '已暂停，恢复后点击继续才重新计时。' : '计时仍在进行，返回后可查看进度。'}` : '');
  }

  private resumeRecovery(): void {
    if (appState.focusResultDraft !== null) {
      router.pushUrl({ url: 'pages/FocusResult' });
    } else if (appState.focusRuntime !== null) {
      appState.setFocusTask(appState.focusRuntime.task);
      router.pushUrl({ url: 'pages/FocusTimer' });
    }
  }

  private async discardRecovery(): Promise<void> {
    const recoveryId = appState.focusRuntime?.sessionId ?? appState.focusResultDraft?.taskId;
    const service = FocusSessionSyncService.getInstance();
    const session = service.getSnapshot().session;
    if (session !== null && session.sessionId === recoveryId && ['running', 'paused'].includes(session.state)) {
      if (!(await service.abandon())) { this.startError = service.getSnapshot().lastError; return; }
    }
    if (!appState.discardFocusRecovery()) this.startError = '放弃操作保存失败，请重试。';
  }

  private getSourceLabel(): string {
    switch (this.source) {
      case 'agent': return '来自 Agent 学习计划';
      case 'course': return '来自课程任务';
      case 'collaborative': return '来自协同学习';
      default: return '自己安排';
    }
  }

  private modeHint(): string {
    if (this.mode === 'strict') {
      return '严格专注会隐藏暂停；提前退出需要确认，并留下中断记录。';
    }
    return '应用内换页和息屏时继续计时。';
  }

  private timerHint(): string {
    if (this.timerType === 'stopwatch') {
      return '正计时不设目标，从 00:00 开始，结束时按实际投入结算。';
    }
    return `本次目标 ${this.plannedMinutesForStart()} 分钟。`;
  }

  /** Show confirmed connections and task receipt separately. */
  @Builder
  DistributedCard() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {

        // 原标题是「全场景接续」—— 内部术语，实测反馈明确问"这个全场接续是什么意思"。
        // 换成用户一眼能懂的说法（卡片下方的说明进一步解释）。
        Text('换设备接着做')
          .fontSize(15).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink)
        Blank()
        Text(this.syncReady
          ? (this.syncPeerCount > 0 ? `已连接 ${this.syncPeerCount} 台设备` : '尚未连接设备')
          : (this.syncPermissionGranted ? '服务未连接' : '登录后连接'))
          .fontSize(12)
          .fontColor(this.syncPeerCount > 0 ? UiTheme.success : UiTheme.secondary)
          .backgroundColor(UiTheme.subtle)
          .borderRadius(8).padding({ left: 8, right: 8, top: 3, bottom: 3 })
      }.width('100%')

      if (!this.syncPermissionGranted) {
        Text('两台设备登录同一知学账号并联网，然后选择设备并确认连接。离线演示模式无法连接设备。')
          .fontSize(12).fontColor('#92400E').width('100%')
      } else if (this.syncError.length > 0) {
        Text(this.syncError).fontSize(12).fontColor('#B91C1C').width('100%')
      } else if (this.sharedDescription.length > 0) {
        Text(this.sharedDescription).fontSize(13).fontColor(UiTheme.ink).width('100%')
        Button('在这台设备继续').width('100%').height(44).fontSize(14).enabled(!this.starting)
          .onClick(() => { void this.continueShared(); })
      } else if (this.syncRemoteTask.length > 0) {
        Text(`收到${this.syncRemoteDevice}的任务：${this.syncRemoteTask}`)
          .fontSize(13).fontColor(UiTheme.ink).width('100%')
        Button('使用此任务')
          .width('100%').height(38).fontSize(13).fontColor(UiTheme.surface)
          .backgroundColor('#0F766E').borderRadius(8)
          .onClick(() => this.adoptRemoteTask())
      } else {
        Text(this.syncPeerCount > 0 ? '开始专注后，已连接设备可以接着计时，暂停与完成会同步。' : '打开连接设备，选择同账号在线设备，并在对方设备上同意连接。')
          .fontSize(12).fontColor(UiTheme.secondary).width('100%')
      }
      if (this.syncDelivery) { Text(this.syncDelivery).fontSize(12).fontColor(UiTheme.secondary).width('100%') }
      Button('管理连接设备').height(44).fontSize(14).fontColor(UiTheme.accent).backgroundColor(UiTheme.subtle)
        .onClick(() => router.pushUrl({ url: 'pages/DeviceConnect' }))
    }
    .width('100%').padding(12)
    .backgroundColor(UiTheme.subtle)
    .borderRadius(8)

  }

  build() {
    Stack() {
      Column() {
        PageHeader({ title: '专注设置', assistant: true, onBack: () => router.replaceUrl({ url: 'pages/Index', params: { initialTab: 2 } }) })
        Scroll() {
          Column({ space: 14 }) {
            this.DistributedCard()
            if (this.recoveryDescription) {
              Column({ space: 10 }) {
                Text(this.recoveryDescription).fontSize(14).fontColor(UiTheme.ink).width('100%')
                Row({ space: 10 }) {
                  Button('恢复上次专注').layoutWeight(1).fontSize(13).height(44).onClick(() => this.resumeRecovery())
                  Button('放弃上次记录').layoutWeight(1).fontSize(13).height(44).backgroundColor(UiTheme.subtle).fontColor(UiTheme.secondary).onClick(() => {
                    AlertDialog.show({ title: '放弃上次未保存的专注？', message: '已保存的专注历史不受影响。',
                      primaryButton: { value: '保留', action: () => {} },
                      secondaryButton: { value: '确认放弃', action: () => {
                        void this.discardRecovery();
                      } } });
                  })
                }.width('100%')
              }.padding(12).width('100%').backgroundColor(UiTheme.tint).borderRadius(8)
            }
            Text('专注设置').fontSize(20).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
            Text('设置本次专注的课程、任务与时长。').fontSize(13).fontColor(UiTheme.secondary).width('100%')
            Row({ space: 12 }) {
              Text('课程').fontSize(14).fontColor(UiTheme.ink).width(48)
              Text(this.course).fontSize(14).fontColor(UiTheme.ink).layoutWeight(1)
              if (appState.courses.length > 1) {
                Text('切换 ›').fontSize(13).fontColor(UiTheme.accent).height(44).padding({ top: 13 }).onClick(() => {
                  const currentIdx: number = appState.courses.findIndex(c => c.courseName === this.course);
                  this.course = appState.courses[(currentIdx + 1) % appState.courses.length].courseName;
                })
              }
            }.width('100%').constraintSize({ minHeight: 44 }).border({ width: { bottom: 1 }, color: UiTheme.line })
            Row({ space: 12 }) {
              Text('任务').fontSize(14).fontColor(UiTheme.ink).width(48)
              TextInput({ text: this.task, placeholder: '填写本次任务' }).fontSize(14).height(44).layoutWeight(1)
                .backgroundColor(UiTheme.subtle).borderRadius(8).onChange((value: string) => this.task = value)
            }.width('100%')
            Text(this.getSourceLabel()).fontSize(11).fontColor(UiTheme.secondary).width('100%')
            Text('专注时长').fontSize(15).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
            Row({ space: 6 }) {
              this.DurationButton('30分钟', '30')
              this.DurationButton('60分钟', '60')
              this.DurationButton('自定义', 'custom')
              this.DurationButton('正计时', 'stopwatch')
            }.width('100%')
            if (this.selectedDuration === 'custom') {
              Row({ space: 12 }) {
                Text('自定义时长').fontSize(13).fontColor(UiTheme.secondary).layoutWeight(1)
                TextInput({ text: this.customMinutesText, placeholder: '1–180' }).type(InputType.Number).fontSize(14)
                  .width(96).height(40).backgroundColor(UiTheme.subtle).borderRadius(8).onChange((value: string) => this.onCustomMinutesChange(value))
                Text('分钟').fontSize(13).fontColor(UiTheme.secondary)
              }.width('100%')
            }
            Text(this.timerHint()).fontSize(12).fontColor(UiTheme.secondary).width('100%')
            Divider().color(UiTheme.line)
            Text('专注方式').fontSize(15).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
            Row({ space: 10 }) {
              Radio({ value: 'normal', group: 'focusMode' }).checked(this.mode === 'normal').onChange((value: boolean) => { if (value) this.mode = 'normal'; })
              Text('普通（可暂停，可切换应用）').fontSize(13).fontColor(UiTheme.ink).layoutWeight(1).onClick(() => this.mode = 'normal')
            }.width('100%').height(36)
            Row({ space: 10 }) {
              Radio({ value: 'strict', group: 'focusMode' }).checked(this.mode === 'strict').onChange((value: boolean) => { if (value) this.mode = 'strict'; })
              Text('严格（不可暂停，退出记为中断）').fontSize(13).fontColor(UiTheme.ink).layoutWeight(1).onClick(() => this.mode = 'strict')
            }.width('100%').height(36)
            Text(this.modeHint()).fontSize(12).fontColor(UiTheme.secondary).width('100%')
            if (this.mode === 'normal' && !this.shareFocus) {
              Row() {
                Text('后台仍计时').fontSize(14).fontColor(UiTheme.ink).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.allowBackgroundTiming })
                  .accessibilityText('后台仍计时').onChange((value: boolean) => this.allowBackgroundTiming = value)
              }.width('100%').height(44)
              Text(this.allowBackgroundTiming ? '切换到其他应用后继续计时。' : '切换到其他应用时暂停计时。')
                .fontSize(12).fontColor(UiTheme.secondary).width('100%')
            }
            if (!AgentApiClient.getConfig().useFixture && appState.isSignedIn) {
              Row() {
                Text('与已连接设备共享专注').fontSize(14).fontColor(UiTheme.ink).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.shareFocus })
                  .accessibilityText('与已连接设备共享专注').onChange((value: boolean) => this.shareFocus = value)
              }.width('100%').height(44)
              if (this.shareFocus) {
                Text('共享专注在锁屏、切后台时继续计时，状态同步到已连接设备。')
                  .fontSize(12).fontColor(UiTheme.secondary).lineHeight(20).width('100%')
              }
            }
            if (this.startError) { Text(this.startError).fontSize(13).fontColor(UiTheme.danger).width('100%') }
            if (!appState.isDataImported && appState.courses.length <= 3) {
              Text('导入课程后，建议会更贴近你的时间和作业。').fontSize(12).fontColor(UiTheme.secondary).width('100%')
                .onClick(() => router.pushUrl({ url: 'pages/CourseImport' }))
            }
            Button(this.starting ? '正在连接…' : '开始专注', { type: ButtonType.Normal }).width('100%').height(46).fontSize(15)
              .fontColor('#FFFFFF').backgroundColor(UiTheme.accent).borderRadius(8).enabled(!this.starting && this.task.trim().length > 0).onClick(() => { void this.startFocus(); })
          }.width('100%').constraintSize({ maxWidth: UiTheme.contentWidth }).padding(20).alignItems(HorizontalAlign.Start)
        }.width('100%').layoutWeight(1).scrollBar(BarState.Off).align(Alignment.TopStart)
        AppBottomBar({ selected: 2 })
      }.width('100%').height('100%').backgroundColor(UiTheme.surface)
      AIFloatButton()
    }.width('100%').height('100%')
  }

  @Builder
  DurationButton(label: string, key: string) {
    Button(label, { type: ButtonType.Normal }).layoutWeight(1).height(36).fontSize(13)
      .fontColor(this.selectedDuration === key ? UiTheme.surface : UiTheme.accent)
      .backgroundColor(this.selectedDuration === key ? UiTheme.accent : UiTheme.surface)
      .borderRadius(8).border({ width: 1, color: '#BFDBFE' })
      .onClick(() => {
        if (key === '30') {
          this.selectCountdown(30);
        } else if (key === '60') {
          this.selectCountdown(60);
        } else if (key === 'custom') {
          this.selectCustom();
        } else {
          this.selectStopwatch();
        }
      })
  }
}
