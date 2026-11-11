import { AppBottomBar } from '../components/AppBottomBar';
import { UiTheme } from '../utils/UiTheme';
import { PageHeader } from '../components/PageHeader';
import router from '@ohos.router';
import { appState } from '../data/AppState';
import { CourseInfo, FocusMode, FocusSource, FocusTask, FocusTimerType, HomeworkDDL } from '../models/AgentModels';
import { AIFloatButton } from '../components/AIFloatButton';
import { DistributedSnapshot, DistributedStateService } from '../services/DistributedStateService';
import { FocusSessionSyncService } from '../services/FocusSessionSyncService';
import { AgentApiClient } from '../api/AgentApiClient';
import { KnowledgeMastery, PlanTask } from '../api/ApiModels';
import { ApiFailure } from '../api/ApiResult';
import { ClientCache } from '../cache/ClientCache';

interface FocusTaskChoice {
  title: string;
  planTaskId?: string;
  minutes: number;
  source: FocusSource;
}

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
  @State task: string = '';
  @State minutes: number = 30;
  @State customMinutesText: string = '45';
  @State selectedDuration: string = '30';
  @State mode: FocusMode = 'normal';
  @State allowBackgroundTiming: boolean = false;
  @State shareFocus: boolean = false;
  @State source: FocusSource = 'manual';
  @State timerType: FocusTimerType = 'countdown';
  @State planTasks: PlanTask[] = [];
  @State knowledgePoints: KnowledgeMastery[] = [];
  @State newPointOpen: boolean = false;
  @State newPointName: string = '';
  @State newPointCourse: string = '';
  @State newPointError: string = '';
  @State savingPoint: boolean = false;
  private pointRequestVersion: number = 0;
  private planTaskId: string | undefined = undefined;
  private active: boolean = false;

  @State private syncReady: boolean = false;
  @State private syncPermissionGranted: boolean = false;
  @State private syncPeerCount: number = 0;
  @State private syncLocalDevice: string = '';
  @State private syncError: string = '';
  @State private syncDelivery: string = '';
  @State private syncRemoteTask: string = '';
  @State private syncRemoteDevice: string = '';
  @State private syncRemoteActive: boolean = false;

  private distributed: DistributedStateService = DistributedStateService.getInstance();

  aboutToAppear(): void {
    this.active = true;
    this.refreshRecovery();
    const imported: FocusTask | null = appState.activeFocusTask;
    if (imported !== null) {
      this.course = imported.course;
      this.task = imported.task;
      this.minutes = imported.plannedMinutes > 0 ? imported.plannedMinutes : 30;
      this.mode = imported.mode;
      this.allowBackgroundTiming = appState.focusRuntime !== null && imported.allowBackgroundTiming === true;
      this.source = imported.source;
      this.planTaskId = imported.planTaskId;
      this.timerType = imported.timerType ?? 'countdown';
      this.selectedDuration = imported.timerType === 'stopwatch' ? 'stopwatch' : this.durationKey(this.minutes);
      this.customMinutesText = this.selectedDuration === 'custom' ? this.minutes.toString() : this.customMinutesText;
    } else if (appState.courses.length > 0) {
      this.course = appState.getHighPriorityCourse()?.courseName ?? this.course;
    }

    this.distributed.setListener((snapshot: DistributedSnapshot) => this.applySnapshot(snapshot));
    this.applySnapshot(this.distributed.getSnapshot());
    this.refreshShared();
    this.knowledgePoints = ClientCache.getProfile()?.mastery ?? [];
    void this.loadKnowledgePoints();
    void this.loadPlanTasks();
  }

  aboutToDisappear(): void {
    this.active = false;
    this.pointRequestVersion++;
    this.distributed.setListener(null);
  }

  private async loadPlanTasks(): Promise<void> {
    const owner: string = appState.currentUser.userId;
    const result = await AgentApiClient.getCurrentPlan();
    if (this.active && owner === appState.currentUser.userId && result.ok) {
      this.planTasks = result.data.tasks.filter((task: PlanTask) => task.status !== 'completed');
    }
  }

  private courseOptions(): string[] {
    const names: string[] = [this.course];
    appState.courses.forEach((course: CourseInfo) => {
      if (!names.includes(course.courseName)) names.push(course.courseName);
    });
    this.planTasks.forEach((task: PlanTask) => {
      if (task.sourceCourse && !names.includes(task.sourceCourse)) names.push(task.sourceCourse);
    });
    return names;
  }

  private courseAssignments(): HomeworkDDL[] {
    return appState.homeworkDDLs.filter((ddl: HomeworkDDL) =>
      ddl.courseName === this.course && !appState.isTaskCompleted(ddl.id, 'pending') &&
      !this.planTasks.some((task: PlanTask) => task.taskId === ddl.id || task.parentTaskId === ddl.id));
  }

  private coursePlanTasks(): PlanTask[] {
    return this.planTasks.filter((task: PlanTask) => task.sourceCourse === this.course);
  }

  private async loadKnowledgePoints(): Promise<void> {
    const owner: string = appState.currentUser.userId;
    const version: number = ++this.pointRequestVersion;
    const result = await AgentApiClient.getProfile(owner);
    if (!this.active || owner !== appState.currentUser.userId || version !== this.pointRequestVersion) return;
    if (result.ok) {
      this.knowledgePoints = result.data.mastery;
      ClientCache.cacheProfile(result.data);
    }
  }

  private taskChoices(): FocusTaskChoice[] {
    const choices: FocusTaskChoice[] = this.coursePlanTasks().map((task: PlanTask): FocusTaskChoice => ({
      title: task.knowledgePointName, planTaskId: task.taskId, minutes: task.durationMinutes,
      source: task.source === 'partner' ? 'collaborative' : task.source === 'manual' ? 'manual' :
        task.source === 'ddl' || task.source === 'ddl_step' ? 'course' : 'agent'
    }));
    this.courseAssignments().forEach((ddl: HomeworkDDL) => choices.push({
      title: ddl.title, planTaskId: ddl.id, minutes: ddl.estimatedMinutes, source: 'course'
    }));
    this.knowledgePoints.filter((point: KnowledgeMastery) => point.sourceCourse === this.course && !point.classificationRequired)
      .forEach((point: KnowledgeMastery) => {
        if (!choices.some((choice: FocusTaskChoice) => choice.title === point.knowledgePointName)) {
          choices.push({ title: point.knowledgePointName, minutes: 0, source: 'manual' });
        }
      });
    if (this.task && !choices.some((choice: FocusTaskChoice) => this.planTaskId ?
      choice.planTaskId === this.planTaskId : choice.title === this.task)) {
      choices.unshift({ title: this.task, planTaskId: this.planTaskId, minutes: this.minutes, source: this.source });
    }
    return choices;
  }

  private selectedTaskIndex(): number {
    return this.taskChoices().findIndex((choice: FocusTaskChoice) => this.planTaskId ?
      choice.planTaskId === this.planTaskId : choice.title === this.task);
  }

  private selectTaskChoice(index: number): void {
    const choices: FocusTaskChoice[] = this.taskChoices();
    if (index === choices.length) {
      this.newPointName = '';
      this.newPointCourse = this.course;
      this.newPointError = '';
      this.newPointOpen = true;
      return;
    }
    const choice: FocusTaskChoice | undefined = choices[index];
    if (choice) this.selectTask(choice.title, choice.planTaskId, choice.minutes, choice.source);
  }

  private async saveKnowledgePoint(): Promise<void> {
    if (this.savingPoint) return;
    const name: string = this.newPointName.trim();
    if (!name || name.length > 80) { this.newPointError = '请填写1至80字的知识点名称。'; return; }
    const owner: string = appState.currentUser.userId;
    const course: string = this.newPointCourse;
    const version: number = ++this.pointRequestVersion;
    this.savingPoint = true;
    this.newPointError = '';
    const result = await AgentApiClient.createKnowledgePoint(owner, { courseName: course, knowledgePointName: name });
    if (!this.active || owner !== appState.currentUser.userId || version !== this.pointRequestVersion) return;
    this.savingPoint = false;
    if (!result.ok) { this.newPointError = (result as ApiFailure).error.message; return; }
    const point: KnowledgeMastery = result.data;
    this.knowledgePoints = this.knowledgePoints.filter((item: KnowledgeMastery) => item.knowledgePointId !== point.knowledgePointId).concat([point]);
    ClientCache.invalidateProfile();
    appState.notifyLearningDataChanged();
    if (course === this.course && this.newPointOpen) {
      this.selectTask(point.knowledgePointName, undefined, 0, 'manual');
      this.newPointOpen = false;
    }
  }

  private selectCourse(course: string): void {
    if (this.course === course) return;
    this.course = course;
    this.editTask('');
  }

  private editTask(value: string): void {
    if (value === this.task) return;
    this.task = value;
    this.planTaskId = undefined;
    this.source = 'manual';
  }

  private selectTask(title: string, id: string | undefined, minutes: number, source: FocusSource): void {
    this.task = title;
    this.planTaskId = id;
    this.source = source;
    if (this.timerType === 'countdown' && minutes > 0) {
      this.minutes = Math.min(minutes, 180);
      this.selectedDuration = this.durationKey(this.minutes);
      if (this.selectedDuration === 'custom') this.customMinutesText = this.minutes.toString();
    }
  }

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
    this.planTaskId = remote.planTaskId;
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
    const planTaskId: string | undefined = this.planTaskId;
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

  @Builder
  DistributedCard() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {

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

  onBackPress(): boolean {
    if (Number(router.getLength()) > 1) return false;
    router.replaceUrl({ url: 'pages/Index', params: { initialTab: 2 } });
    return true;
  }

  @Builder
  NewKnowledgePoint() {
    Column({ space: 12 }) {
      Text(`所属课程：${this.newPointCourse}`).fontSize(14).fontColor(UiTheme.secondary).width('100%')
      Text('知识点名称').fontSize(14).fontColor(UiTheme.ink).width('100%')
      TextInput({ text: this.newPointName, placeholder: '例如：二叉树的层序遍历' }).height(44).fontSize(14)
        .maxLength(80).enabled(!this.savingPoint).accessibilityText('新增知识点名称')
        .onChange((value: string) => { this.newPointName = value; this.newPointError = ''; })
      if (this.newPointError) { Text(this.newPointError).fontSize(13).fontColor(UiTheme.danger).width('100%') }
      Row({ space: 12 }) {
        Button('取消', { type: ButtonType.Normal }).layoutWeight(1).height(44).fontSize(14)
          .fontColor(UiTheme.secondary).backgroundColor(UiTheme.subtle).enabled(!this.savingPoint)
          .onClick(() => this.newPointOpen = false)
        Button(this.savingPoint ? '正在保存…' : '保存并选中', { type: ButtonType.Normal }).layoutWeight(1).height(44).fontSize(14)
          .fontColor(UiTheme.surface).backgroundColor(UiTheme.accent).enabled(!this.savingPoint && this.newPointName.trim().length > 0)
          .onClick(() => { void this.saveKnowledgePoint(); })
      }.width('100%')
    }.width('100%').padding(20)
  }

  build() {
    Stack() {
      Column() {
        PageHeader({ title: '专注设置', assistant: true, onBack: () => { if (!this.onBackPress()) router.back(); } })
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
              Select(this.courseOptions().map((name: string): SelectOption => ({ value: name })))
                .value(this.course).layoutWeight(1).height(44)
                .onSelect((_index: number, value: string) => this.selectCourse(value))
            }.width('100%').constraintSize({ minHeight: 44 }).border({ width: { bottom: 1 }, color: UiTheme.line })
            Row({ space: 12 }) {
              Text('知识点').fontSize(14).fontColor(UiTheme.ink).width(48)
              Select(this.taskChoices().map((choice: FocusTaskChoice): SelectOption => ({ value: choice.title })).concat([{ value: '＋新增知识点' }]))
                .selected(this.newPointOpen ? this.taskChoices().length : this.selectedTaskIndex())
                .value(this.newPointOpen ? '新增知识点' : this.task || '选择知识点').height(44).layoutWeight(1)
                .font({ size: 14 }).fontColor(UiTheme.ink).backgroundColor(UiTheme.subtle).borderRadius(8)
                .accessibilityText('选择知识点').onSelect((index: number) => this.selectTaskChoice(index))
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
        }.width('100%').layoutWeight(1).scrollBar(BarState.Off).align(Alignment.Top)
        AppBottomBar({ selected: 2 })
      }.width('100%').height('100%').backgroundColor(UiTheme.surface)
      AIFloatButton()
    }.width('100%').height('100%')
      .bindSheet($$this.newPointOpen, this.NewKnowledgePoint(), { height: SheetSize.FIT_CONTENT, title: { title: '新增知识点' },
        showClose: !this.savingPoint, backgroundColor: UiTheme.surface,
        shouldDismiss: (dismiss: SheetDismiss) => { if (!this.savingPoint) { this.newPointOpen = false; dismiss.dismiss(); } } })
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
