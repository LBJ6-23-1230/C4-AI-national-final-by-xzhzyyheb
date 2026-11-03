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
  private async load(more: boolean = false): Promise<void> {
    const owner: string = appState.currentUser.userId;
    const version: number = ++this.version;
    this.busy = true;
    this.settingsReady = false;
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
    try { this.permission = await notificationManager.isNotificationEnabled(); } catch (_) { this.permission = false; }
    if (!this.active || owner !== appState.currentUser.userId || version !== this.version) return;
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
      }.width('100%').padding(12).backgroundColor('#EFF6FF').borderRadius(12)
    }
  }
  @Builder
  HourButton(hour: number) {
    Button(`${this.isSelectedHour(hour) ? '✓ ' : ''}${hour}:00`)
      .layoutWeight(1).height(40).fontSize(14).borderRadius(10)
      .fontColor(this.isSelectedHour(hour) ? '#FFFFFF' : '#475467')
      .backgroundColor(this.isSelectedHour(hour) ? '#2563EB' : '#F2F4F7')
      .enabled(!this.busy && this.settingsReady).onClick(() => this.chooseHour(hour))
  }
  build() {
    Column() {
      PageHeader({ title: '提醒设置', detail: '提醒时间与通知', onBack: () => router.back() })
      Scroll() {
        Column({ space: 14 }) {
          Column({ space: 8 }) {
            Text(!this.settingsReady ? '正在检查通知状态…' : !this.pushConfigured ? '通知服务暂未开通' : !this.permission ? '请允许系统通知' : !this.deviceReady ? '此设备尚未连接通知服务' : '学习通知')
              .fontSize(17).fontWeight(FontWeight.Bold).fontColor('#101828').width('100%')
            Text(this.permission ? '系统通知权限：已开启' : '系统通知权限未开启：需要你允许应用发送通知。')
              .fontSize(13).fontColor('#475467').lineHeight(20).width('100%')
            Text(!this.settingsReady ? '检查完成后会显示当前可用的提醒方式。' : !this.pushConfigured ? '需要由知学 Mate 的开发团队开通推送服务，你无需额外配置。开通前，离开应用后暂时收不到学习通知。' : !this.deviceReady ? '尚未完成设备连接，请确认网络正常后重试。' : '开启下方开关后，离开应用也能接收学习提醒。实际送达受网络和系统设置影响。')
              .fontSize(13).fontColor('#475467').lineHeight(20).width('100%')
            Text('首页待办可照常查看，提醒时间和偏好也可以先保存。')
              .fontSize(12).fontColor('#667085').lineHeight(19).width('100%')
            if (!this.permission) Button('开启系统通知').height(40).fontSize(14).backgroundColor('#2563EB')
              .enabled(!this.busy).onClick(() => this.requestPermission())
            if (this.permission && this.pushConfigured && !this.deviceReady) Button('重新连接').height(44).fontSize(14)
              .enabled(!this.busy).onClick(() => this.load())
          }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(12)
          Column({ space: 12 }) {
            Row() {
              Text('允许后台通知').fontSize(16).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.settings.enabled }).enabled(!this.busy && this.settingsReady && (this.settings.enabled || (this.pushConfigured && this.permission && this.deviceReady)))
                .onChange((value: boolean) => { if (value !== this.settings.enabled) void this.save(value); })
            }.width('100%')
            Text('每天提醒开始时间').fontSize(15).fontWeight(FontWeight.Medium).width('100%')
            Row({ space: 10 }) {
              this.HourButton(9)
              this.HourButton(12)
              this.HourButton(18)
            }.width('100%')
            Text(!this.settingsReady ? '正在读取已保存的提醒时间…' : (this.pendingHour >= 0 ? `正在保存 ${this.pendingHour}:00…` : `已设置：每天 ${this.selectedHour}:00 后开始安排常规提醒`))
              .fontSize(13).fontColor('#2563EB').width('100%')
            Text('这是最早提醒时间，不保证整点发送；没有需要提醒的事项时不会打扰你。')
              .fontSize(12).fontColor('#667085').lineHeight(19).width('100%')
            if (this.message.length > 0) {
              Text(this.message).fontSize(13).fontColor(this.saved ? '#067647' : '#B54708')
                .width('100%').padding(10).backgroundColor(this.saved ? '#ECFDF3' : '#FFFAEB').borderRadius(8)
            }
            Row() {
              Text('免打扰').fontSize(15).fontWeight(FontWeight.Medium).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.settings.quietEnabled ?? true }).enabled(!this.busy && this.settingsReady)
                .onChange((value: boolean) => { if (value !== (this.settings.quietEnabled ?? true)) this.chooseQuietEnabled(value); })
            }.width('100%')
            if (this.settings.quietEnabled ?? true) {
              Text(this.quietLabel()).fontSize(14).fontColor('#344054').width('100%')
              Row({ space: 10 }) {
                Button(`开始 ${this.timeLabel(this.settings.quietStart, this.settings.quietStartMinute ?? 0)}`)
                  .layoutWeight(1).height(44).fontSize(14).borderRadius(10).backgroundColor('#EFF6FF').fontColor('#2563EB')
                  .enabled(!this.busy && this.settingsReady).onClick(() => this.editQuiet(true))
                Button(`结束 ${this.timeLabel(this.settings.quietEnd, this.settings.quietEndMinute ?? 0)}`)
                  .layoutWeight(1).height(44).fontSize(14).borderRadius(10).backgroundColor('#EFF6FF').fontColor('#2563EB')
                  .enabled(!this.busy && this.settingsReady).onClick(() => this.editQuiet(false))
              }.width('100%')
              Text('点击时间可自由调整，免打扰期间不发送常规学习通知。').fontSize(13).fontColor('#475467').lineHeight(20).width('100%')
            }
            Row() {
              Text('紧急截止提醒可在免打扰时发送').fontSize(14).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.settings.urgentException }).enabled(!this.busy && this.settingsReady && (this.settings.quietEnabled ?? true))
                .onChange((value: boolean) => { if (value !== this.settings.urgentException) this.chooseUrgent(value); })
            }.width('100%')
            Text(`每天最多${this.settings.dailyLimit}次，常规提醒最多1次；两次提醒至少间隔${Math.round(this.settings.minimumGapMinutes / 60)}小时。`)
              .fontSize(12).fontColor('#667085').lineHeight(19).width('100%')
          }.padding(16).backgroundColor('#FFFFFF').borderRadius(12).width('100%')
          Column({ space: 12 }) {
            Text('哪些事项发送通知').fontSize(16).fontWeight(FontWeight.Medium).width('100%')
            Text('关闭某类通知后，首页待办仍会显示。').fontSize(12).fontColor('#667085').width('100%')
            ForEach(['task', 'exam', 'conflict'], (kind: string) => {
              Column({ space: 4 }) {
                Row() {
                  Text(this.categoryLabel(kind)).fontSize(14).layoutWeight(1)
                  Toggle({ type: ToggleType.Switch, isOn: (this.settings.categories ?? ['task', 'exam', 'gap', 'conflict']).includes(kind) })
                    .enabled(!this.busy && this.settingsReady).onChange((value: boolean) => {
                      if (value !== (this.settings.categories ?? ['task', 'exam', 'gap', 'conflict']).includes(kind)) this.chooseCategory(kind, value);
                    })
                }.width('100%')
                Text(this.categoryDescription(kind)).fontSize(12).fontColor('#667085').lineHeight(19).width('100%')
              }.width('100%')
            })
          }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(12)
          Column({ space: 8 }) {
            Row() {
              Text('首页学习提醒').fontSize(15).fontWeight(FontWeight.Medium).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.settings.studyGapEnabled ?? true }).enabled(!this.busy && this.settingsReady)
                .onChange((value: boolean) => { if (value !== (this.settings.studyGapEnabled ?? true)) this.chooseStudyGap(value); })
            }.width('100%')
            Text('已有专注记录，但连续两天没有新记录时，打开首页并展开“今日安排”，会看到继续学习的提示。有其他待办时优先显示待办。')
              .fontSize(13).fontColor('#475467').lineHeight(21).width('100%')
            Text('只在首页显示，不发送手机通知。关闭后不再显示这条提示。')
              .fontSize(13).fontColor('#475467').lineHeight(21).width('100%')
          }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(12)
        }.padding(16).width('100%').constraintSize({ maxWidth: 960 })
      }.layoutWeight(1).width('100%').align(Alignment.TopStart)
    }.height('100%').width('100%').backgroundColor('#F3F6FA')
  }
}
