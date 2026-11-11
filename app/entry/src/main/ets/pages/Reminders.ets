import { UiTheme } from '../utils/UiTheme';
import { ReminderNavigation } from '../services/ReminderNavigation';
import router from '@ohos.router';
import { common } from '@kit.AbilityKit';
import notificationManager from '@ohos.notificationManager';
import { AgentApiClient } from '../api/AgentApiClient';
import { ApiFailure } from '../api/ApiResult';
import { ReminderEvent, ReminderPreferences } from '../api/ReminderModels';
import { appState } from '../data/AppState';
import { PageHeader } from '../components/PageHeader';
import { ProactiveSurfaceService } from '../services/ProactiveSurfaceService';
import { ReminderDeviceService } from '../services/ReminderDeviceService';

@Entry
@Component
struct Reminders {
  @State statusDetails: boolean = false;
  @State quietTimesExpanded: boolean = false;
  @State events: ReminderEvent[] = [];
  @State message: string = '';
  @State busy: boolean = false;
  @State permission: boolean = false;
  @State pushConfigured: boolean = false;
  @State deviceReady: boolean = false;
  @State cursor: string = '';
  @State hasMore: boolean = false;
  @State lastSync: string = '';
  @State selectedHour: number = 9;
  @State pendingHour: number = -1;
  @State settingsReady: boolean = false;
  @State saved: boolean = false;
  @State settings: ReminderPreferences = { enabled: false, timezone: 'Asia/Shanghai', quietStart: 22,
    quietEnd: 8, dailyLimit: 2, minimumGapMinutes: 240, urgentException: false, summaryHour: 9 };
  private active: boolean = true;
  private version: number = 0;
  private shown: boolean = false;
  onPageShow(): void { if (this.shown) void this.load(); this.shown = true; }
  aboutToAppear(): void { this.active = true; void this.load(); }
  aboutToDisappear(): void { this.active = false; this.version++; }
  onBackPress(): boolean {
    if (Number(router.getLength()) > 1) return false;
    router.replaceUrl({ url: 'pages/ChatMain' });
    return true;
  }
  private async load(more: boolean = false): Promise<void> {
    const owner: string = appState.currentUser.userId;
    const version: number = ++this.version;
    this.busy = true;
    this.settingsReady = false;
    let permission: boolean = false;
    try { permission = await notificationManager.isNotificationEnabled(); } catch (_) {}
    if (!this.active || owner !== appState.currentUser.userId || version !== this.version) return;
    this.permission = permission;
    const list = await AgentApiClient.getReminders(more ? this.cursor : '');
    if (!this.active || owner !== appState.currentUser.userId || version !== this.version) return;
    if (list.ok) {
      this.events = more ? this.events.concat(list.data.events) : list.data.events;
      this.cursor = list.data.cursor; this.hasMore = list.data.hasMore;
    } else this.message = (list as ApiFailure).error.message;
    const settings = await AgentApiClient.getReminderSettings();
    if (!this.active || owner !== appState.currentUser.userId || version !== this.version) return;
    if (settings.ok) {
      this.settings = settings.data.preferences;
      this.selectedHour = this.settings.summaryHour;
      this.pushConfigured = settings.data.pushConfigured;
      this.settingsReady = true;
    }
    else this.message = (settings as ApiFailure).error.message;
    await ReminderDeviceService.sync(getContext(this) as common.Context, true);
    if (this.active && owner === appState.currentUser.userId && version === this.version) {
      this.lastSync = ReminderDeviceService.lastSync;
      this.deviceReady = ReminderDeviceService.status === 'ready';
      this.busy = false;
    }
  }
  private snapshot(): ReminderPreferences {
    return { enabled: this.settings.enabled, timezone: this.settings.timezone,
      quietEnabled: this.settings.quietEnabled ?? true,
      quietStartMinute: this.settings.quietStartMinute ?? 0, quietEndMinute: this.settings.quietEndMinute ?? 0,
      studyGapEnabled: this.settings.studyGapEnabled ?? true,
      quietStart: this.settings.quietStart, quietEnd: this.settings.quietEnd, dailyLimit: this.settings.dailyLimit,
      minimumGapMinutes: this.settings.minimumGapMinutes, urgentException: this.settings.urgentException, summaryHour: this.settings.summaryHour,
      categories: (this.settings.categories ?? ['task', 'exam', 'gap', 'conflict']).slice() };
  }
  private async persist(request: ReminderPreferences, confirmation: string = '提醒设置已保存。'): Promise<void> {
    if (this.busy || !this.settingsReady) return;
    const owner: string = appState.currentUser.userId;
    const version: number = ++this.version;
    this.busy = true;
    this.saved = false;
    this.message = '正在保存设置…';
    try {
      const result = await AgentApiClient.saveReminderSettings(request);
      if (!this.active || owner !== appState.currentUser.userId || version !== this.version) return;
      if (result.ok) {
        this.settings = result.data.preferences;
        this.selectedHour = this.settings.summaryHour;
        this.saved = true;
        this.message = confirmation;
      } else {
        this.settings = this.snapshot();
        this.message = '保存失败，原设置已保留：' + (result as ApiFailure).error.message;
      }
    } catch (_) {
      if (this.active && owner === appState.currentUser.userId && version === this.version) {
        this.settings = this.snapshot();
        this.message = '保存失败，原设置已保留，请重试。';
      }
    } finally {
      if (this.active && owner === appState.currentUser.userId && version === this.version) {
        this.busy = false;
        this.pendingHour = -1;
      }
    }
  }
  private async chooseHour(hour: number): Promise<void> {
    if (this.busy || !this.settingsReady) return;
    const request: ReminderPreferences = this.snapshot();
    request.summaryHour = hour;
    this.pendingHour = hour;
    await this.persist(request, `已保存：每天 ${hour}:00 后开始安排常规提醒。`);
  }
  private save(enabled: boolean): void {
    const request: ReminderPreferences = this.snapshot();
    request.enabled = enabled;
    void this.persist(request);
  }
  private timeLabel(hour: number, minute: number = 0): string {
    return `${hour.toString().padStart(2, '0')}:${minute.toString().padStart(2, '0')}`;
  }
  private quietLabel(): string {
    const start: number = this.settings.quietStart * 60 + (this.settings.quietStartMinute ?? 0);
    const end: number = this.settings.quietEnd * 60 + (this.settings.quietEndMinute ?? 0);
    return `${this.timeLabel(this.settings.quietStart, this.settings.quietStartMinute ?? 0)} 至${end <= start ? '次日 ' : ' '}${this.timeLabel(this.settings.quietEnd, this.settings.quietEndMinute ?? 0)}`;
  }
  private chooseQuiet(start: number, end: number, startMinute: number = 0, endMinute: number = 0): void {
    if (start === end && startMinute === endMinute) {
      this.saved = false;
      this.message = '开始和结束时间不能相同。如无需免打扰，请关闭免打扰开关。';
      return;
    }
    const request: ReminderPreferences = this.snapshot();
    request.quietStart = start;
    request.quietEnd = end;
    request.quietStartMinute = startMinute;
    request.quietEndMinute = endMinute;
    void this.persist(request, '免打扰时间已保存。');
  }
  private editQuiet(isStart: boolean): void {
    if (this.busy || !this.settingsReady) return;
    const owner: string = appState.currentUser.userId;
    const version: number = this.version;
    const selected: Date = new Date();
    selected.setHours(isStart ? this.settings.quietStart : this.settings.quietEnd,
      isStart ? (this.settings.quietStartMinute ?? 0) : (this.settings.quietEndMinute ?? 0), 0, 0);
    TimePickerDialog.show({ selected: selected, useMilitaryTime: true,
      onAccept: (value: TimePickerResult) => {
        if (!this.active || owner !== appState.currentUser.userId || version !== this.version) return;
        const hour: number = value.hour ?? 0;
        const minute: number = value.minute ?? 0;
        this.chooseQuiet(isStart ? hour : this.settings.quietStart, isStart ? this.settings.quietEnd : hour,
          isStart ? minute : (this.settings.quietStartMinute ?? 0), isStart ? (this.settings.quietEndMinute ?? 0) : minute);
      }
    });
  }
  private chooseQuietEnabled(value: boolean): void {
    const request: ReminderPreferences = this.snapshot();
    request.quietEnabled = value;
    void this.persist(request, value ? '免打扰已开启。' : '免打扰已关闭。');
  }
  private chooseStudyGap(value: boolean): void {
    const request: ReminderPreferences = this.snapshot();
    request.studyGapEnabled = value;
    void this.persist(request, value ? '已开启首页学习提醒。' : '已关闭首页学习提醒。');
  }
  private chooseUrgent(value: boolean): void {
    const request: ReminderPreferences = this.snapshot();
    request.urgentException = value;
    void this.persist(request);
  }
  private chooseCategory(kind: string, value: boolean): void {
    const request: ReminderPreferences = this.snapshot();
    const categories: string[] = request.categories ?? [];
    request.categories = value ? categories.concat([kind]) : categories.filter((item: string) => item !== kind);
    void this.persist(request);
  }
  private async requestPermission(): Promise<void> {
    if (this.busy) return;
    const owner: string = appState.currentUser.userId;
    const version: number = ++this.version;
    this.busy = true;
    try {
      const permission: boolean = await ProactiveSurfaceService.requestPermission(getContext(this) as common.UIAbilityContext);
      if (!this.active || owner !== appState.currentUser.userId || version !== this.version) return;
      this.permission = permission;
      await ReminderDeviceService.sync(getContext(this) as common.Context, true);
      if (!this.active || owner !== appState.currentUser.userId || version !== this.version) return;
      this.deviceReady = ReminderDeviceService.status === 'ready';
      this.saved = permission;
      this.message = permission ? '系统通知权限已开启。' : '尚未开启通知权限，可在系统设置中允许通知。';
      void ProactiveSurfaceService.refresh(getContext(this) as common.UIAbilityContext, true);
    } catch (_) {
      if (this.active && owner === appState.currentUser.userId && version === this.version) {
        this.saved = false;
        this.message = '暂时无法申请通知权限，请稍后重试。';
      }
    } finally {
      if (this.active && owner === appState.currentUser.userId && version === this.version) this.busy = false;
    }
  }
  private async act(item: ReminderEvent, action: string, minutes: number = 30): Promise<void> {
    if (this.busy) return;
    const owner: string = appState.currentUser.userId;
    this.busy = true;
    const result = await AgentApiClient.reminderAction(item.eventId, { action: action, version: item.version,
      idempotencyKey: `${item.eventId}-${item.version}-${action}-${minutes}`, minutes: minutes });
    if (!this.active || owner !== appState.currentUser.userId) return;
    this.busy = false;
    if (!result.ok) this.message = (result as ApiFailure).error.code === 'RESULT_UNCONFIRMED' ? '暂未确认，请重试。' : '操作失败，请重试。';
    else if (action === 'open') ReminderNavigation.open(item);
    else this.message = action === 'snooze' ? '已延后至 ' + new Date(result.data.event.snoozedUntil ?? '').toLocaleString() : '今日已忽略。';
    void this.load();
  }
  private statusLabel(item: ReminderEvent): string {
    if (item.status === 'snoozed') return '已延后至 ' + new Date(item.snoozedUntil ?? '').toLocaleString();
    if (item.status === 'ignored') return '今天已忽略';
    if (item.status === 'started') return '已开始';
    if (item.status === 'completed') return '已完成';
    if (item.status === 'invalid') return '已失效';
    return item.level === 'urgent' ? '紧急' : item.level === 'important' ? '重要' : '待处理';
  }
  private categoryLabel(kind: string): string {
    if (kind === 'task') return '任务与截止日期';
    if (kind === 'exam') return '考前薄弱点提醒';
    if (kind === 'conflict') return '学习安排超时提醒';
    return '久未学习提醒';
  }
  private categoryDescription(kind: string): string {
    if (kind === 'task') return '提醒临近截止的作业和待完成任务。';
    if (kind === 'exam') return '根据已有测评记录，提醒巩固考前薄弱知识点。';
    return '任务预计用时超过已确认可用时间时，提醒你调整计划。';
  }
  private isSelectedHour(hour: number): boolean {
    return this.settingsReady && (this.pendingHour === hour || (this.pendingHour < 0 && this.selectedHour === hour));
  }
  @State snoozeItem: ReminderEvent | null = null;
  @State snoozeMinutes: string = '30';
  private chooseSnooze(item: ReminderEvent): void { this.snoozeItem = item; this.snoozeMinutes = '30'; }
  private confirmSnooze(): void {
    const minutes: number = Number(this.snoozeMinutes);
    if (!Number.isInteger(minutes) || minutes < 5 || minutes > 1440 || minutes % 5 !== 0) { this.message = '请输入5到1440分钟，且为5的倍数'; return; }
    const item: ReminderEvent | null = this.snoozeItem;
    this.snoozeItem = null;
    if (item !== null) void this.act(item, 'snooze', minutes);
  }
  @Builder
  SnoozeSelector() {
    if (this.snoozeItem !== null) {
      Column({ space: 10 }) {
        Text('选择稍后提醒时间').fontSize(16)
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach([15, 30, 60, 120, 240], (minutes: number) => {
            Button(`${minutes}分钟`).margin(4).onClick(() => { this.snoozeMinutes = minutes.toString(); this.confirmSnooze(); })
          })
          Button('今晚20点').margin(4).onClick(() => {
            const tonight: Date = new Date(); tonight.setHours(20, 0, 0, 0);
            const minutes: number = Math.ceil((tonight.getTime() - Date.now()) / 300000) * 5;
            if (minutes < 5) { this.message = '今天20点已过，请选择其他时间'; return; }
            this.snoozeMinutes = minutes.toString(); this.confirmSnooze();
          })
        }
        TextInput({ text: this.snoozeMinutes, placeholder: '自定义分钟，5的倍数' }).type(InputType.Number).onChange((value: string) => this.snoozeMinutes = value)
        Row({ space: 12 }) { Button('确认延后').onClick(() => this.confirmSnooze()); Button('取消').onClick(() => this.snoozeItem = null) }
      }.width('100%').padding(12).backgroundColor(UiTheme.tint).borderRadius(8)
    }
  }
  @Builder
  HourButton(hour: number) {
    Button(`${this.isSelectedHour(hour) ? ' ' : ''}${hour}:00`)
      .layoutWeight(1).height(40).fontSize(14).borderRadius(8)
      .fontColor(this.isSelectedHour(hour) ? UiTheme.surface : UiTheme.secondary)
      .backgroundColor(this.isSelectedHour(hour) ? UiTheme.accent : UiTheme.subtle)
      .enabled(!this.busy && this.settingsReady).onClick(() => this.chooseHour(hour))
  }
  build() {
    Column() {
      PageHeader({ title: '提醒设置', onBack: () => { if (!this.onBackPress()) router.back(); } })
      Scroll() {
        Column({ space: 16 }) {
          Column({ space: 6 }) {
            Text(!this.settingsReady ? '正在检查通知状态…' : !this.pushConfigured ? '通知服务暂未开通' : !this.permission ? '请允许系统通知' : !this.deviceReady ? '此设备尚未连接通知服务' : '学习通知已就绪')
              .fontSize(14).fontWeight(FontWeight.Medium).fontColor(!this.pushConfigured ? '#A34612' : UiTheme.ink).width('100%')
            Text('可先保存提醒偏好，通知送达需服务、系统权限与设备连接就绪。').fontSize(12).lineHeight(19).fontColor(UiTheme.secondary).width('100%')
            Text(this.statusDetails ? '收起说明 ⌃' : '查看状态与说明 ›').fontSize(12).fontColor(UiTheme.accent).padding({ top: 6, bottom: 6 }).onClick(() => this.statusDetails = !this.statusDetails)
            if (this.statusDetails) {
              Text(this.permission ? '系统通知权限：已开启' : '系统通知权限：未开启').fontSize(12).fontColor(UiTheme.secondary).width('100%')
              Text(!this.pushConfigured ? '推送服务需由开发团队开通；开通前，离开应用后暂时收不到通知。首页待办可照常查看。' : !this.deviceReady ? '设备尚未连接，请检查网络后重试。' : '通知服务与设备已连接，实际送达受网络和系统设置影响。')
                .fontSize(12).lineHeight(20).fontColor(UiTheme.secondary).width('100%')
            }
            if (!this.permission) {
              Button('开启系统通知', { type: ButtonType.Normal }).height(40).fontSize(13).backgroundColor(UiTheme.accent).fontColor('#FFFFFF').borderRadius(8)
                .enabled(!this.busy).onClick(() => this.requestPermission())
            }
            if (this.permission && this.pushConfigured && !this.deviceReady) {
              Button('重新连接', { type: ButtonType.Normal }).height(40).fontSize(13).backgroundColor(UiTheme.tint).fontColor(UiTheme.accent).borderRadius(8)
                .enabled(!this.busy).onClick(() => this.load())
            }
          }.width('100%').padding(12).backgroundColor(!this.pushConfigured ? '#FFF6EC' : UiTheme.subtle).borderRadius(8)
          Row() {
            Column({ space: 4 }) {
              Text('后台通知（学习提醒推送）').fontSize(14).fontColor(UiTheme.ink)
              Text(this.permission ? '系统通知权限已开启' : '系统通知权限未开启').fontSize(12).fontColor(UiTheme.secondary)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.settings.enabled }).enabled(!this.busy && this.settingsReady && (this.settings.enabled || (this.pushConfigured && this.permission && this.deviceReady)))
              .onChange((value: boolean) => { if (value !== this.settings.enabled) void this.save(value); })
          }.width('100%').constraintSize({ minHeight: 48 })
          Row() {
            Column({ space: 5 }) {
              Text('最早开始时间').fontSize(14).fontColor(UiTheme.ink)
              Text('在此时间后才安排常规提醒').fontSize(12).fontColor(UiTheme.secondary)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Text(!this.settingsReady ? '读取中' : this.pendingHour >= 0 ? '保存中…' : `${this.selectedHour}:00 ›`).fontSize(14).fontColor(UiTheme.ink).height(44).padding({ top: 12 })
              .bindMenu([{ value: '9:00', action: () => { this.chooseHour(9); } }, { value: '12:00', action: () => { this.chooseHour(12); } }, { value: '18:00', action: () => { this.chooseHour(18); } }])
              .enabled(!this.busy && this.settingsReady)
          }.width('100%')
          Row() {
            Text('免打扰').fontSize(14).fontColor(UiTheme.ink).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.settings.quietEnabled ?? true }).enabled(!this.busy && this.settingsReady)
              .onChange((value: boolean) => { if (value !== (this.settings.quietEnabled ?? true)) this.chooseQuietEnabled(value); })
          }.width('100%').height(40)
          if (this.settings.quietEnabled ?? true) {
            Row() {
              Text('免打扰时段').fontSize(14).fontColor(UiTheme.ink).layoutWeight(1)
              Text(this.quietLabel() + ' ›').fontSize(13).fontColor(UiTheme.secondary)
            }.width('100%').height(44).onClick(() => this.quietTimesExpanded = !this.quietTimesExpanded)
            if (this.quietTimesExpanded) {
              Row({ space: 12 }) {
                Button(`开始 ${this.timeLabel(this.settings.quietStart, this.settings.quietStartMinute ?? 0)}`, { type: ButtonType.Normal }).layoutWeight(1).height(44).fontSize(13).borderRadius(8).backgroundColor(UiTheme.tint).fontColor(UiTheme.accent)
                  .enabled(!this.busy && this.settingsReady).onClick(() => this.editQuiet(true))
                Button(`结束 ${this.timeLabel(this.settings.quietEnd, this.settings.quietEndMinute ?? 0)}`, { type: ButtonType.Normal }).layoutWeight(1).height(44).fontSize(13).borderRadius(8).backgroundColor(UiTheme.tint).fontColor(UiTheme.accent)
                  .enabled(!this.busy && this.settingsReady).onClick(() => this.editQuiet(false))
              }.width('100%')
            }
          }
          Row() {
            Column({ space: 4 }) {
              Text('紧急截止例外').fontSize(14).fontColor(UiTheme.ink)
              Text('任务临近截止时，仍可发送提醒').fontSize(12).fontColor(UiTheme.secondary)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.settings.urgentException }).enabled(!this.busy && this.settingsReady && (this.settings.quietEnabled ?? true))
              .onChange((value: boolean) => { if (value !== this.settings.urgentException) this.chooseUrgent(value); })
          }.width('100%').constraintSize({ minHeight: 48 })
          Divider().color(UiTheme.line)
          Text('提醒内容').fontSize(16).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
          ForEach(['task', 'exam', 'conflict'], (kind: string) => {
            Row() {
              Column({ space: 4 }) {
                Text(this.categoryLabel(kind)).fontSize(14).fontColor(UiTheme.ink)
                Text(this.categoryDescription(kind)).fontSize(12).fontColor(UiTheme.secondary).lineHeight(18)
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              Toggle({ type: ToggleType.Switch, isOn: (this.settings.categories ?? ['task', 'exam', 'gap', 'conflict']).includes(kind) })
                .enabled(!this.busy && this.settingsReady).onChange((value: boolean) => {
                  if (value !== (this.settings.categories ?? ['task', 'exam', 'gap', 'conflict']).includes(kind)) this.chooseCategory(kind, value);
                })
            }.width('100%').constraintSize({ minHeight: 48 })
          })
          Row() {
            Column({ space: 4 }) {
              Text('首页学习提醒').fontSize(14).fontColor(UiTheme.ink)
              Text('连续两天无新专注记录时，在首页提示继续学习；不发送推送。').fontSize(12).fontColor(UiTheme.secondary).lineHeight(18)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.settings.studyGapEnabled ?? true }).enabled(!this.busy && this.settingsReady)
              .onChange((value: boolean) => { if (value !== (this.settings.studyGapEnabled ?? true)) this.chooseStudyGap(value); })
          }.width('100%').constraintSize({ minHeight: 48 })
          Text(`每天最多${this.settings.dailyLimit}次，常规提醒最多1次；两次提醒至少间隔${Math.round(this.settings.minimumGapMinutes / 60)}小时。关闭某类通知后，首页待办仍显示。`)
            .fontSize(12).fontColor(UiTheme.secondary).lineHeight(20).width('100%')
          if (this.message) { Text(this.message).fontSize(13).fontColor(this.saved ? UiTheme.success : UiTheme.danger).width('100%').onClick(() => this.load()) }
        }.padding(20).width('100%').constraintSize({ maxWidth: UiTheme.contentWidth }).alignItems(HorizontalAlign.Start)
      }.layoutWeight(1).width('100%').align(Alignment.Top).scrollBar(BarState.Off)
    }.width('100%').height('100%').backgroundColor(UiTheme.surface)
  }
}
