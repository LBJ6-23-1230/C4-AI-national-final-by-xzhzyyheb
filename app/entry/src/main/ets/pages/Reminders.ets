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
      this.busy = false;
    }
  }
  private snapshot(): ReminderPreferences {
    return { enabled: this.settings.enabled, timezone: this.settings.timezone,
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
  private chooseQuiet(start: number, end: number): void {
    const request: ReminderPreferences = this.snapshot();
    request.quietStart = start;
    request.quietEnd = end;
    void this.persist(request, `已保存：${start}:00 至次日 ${end}:00 免打扰。`);
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
            Text(this.pushConfigured && this.permission ? '后台通知设置' : '后台通知暂不可用')
              .fontSize(17).fontWeight(FontWeight.Bold).fontColor('#101828').width('100%')
            Text(this.permission ? '系统通知权限：已开启' : '系统通知权限未开启：需要你允许应用发送通知。')
              .fontSize(13).fontColor('#475467').lineHeight(20).width('100%')
            Text(this.pushConfigured ? '后台提醒服务：已配置，通知送达仍需设备验证。' : '后台提醒服务尚未接通：应用关闭后暂时收不到通知。')
              .fontSize(13).fontColor('#475467').lineHeight(20).width('100%')
            Text(this.pushConfigured && this.permission ? '打开下方开关后，可按你的设置发送提醒。' : '首页待办仍可正常查看。下方偏好可先保存，后台通知具备条件后生效。')
              .fontSize(12).fontColor('#667085').lineHeight(19).width('100%')
            if (!this.permission) Button('开启系统通知').height(40).fontSize(14).backgroundColor('#2563EB')
              .enabled(!this.busy).onClick(() => this.requestPermission())
          }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(12)
          Column({ space: 12 }) {
            Row() {
              Text('允许后台通知').fontSize(16).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.settings.enabled }).enabled(!this.busy && this.settingsReady && this.pushConfigured && this.permission)
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
            Text(`免打扰：${this.settings.quietStart}:00 至次日 ${this.settings.quietEnd}:00`)
              .fontSize(15).fontWeight(FontWeight.Medium).width('100%').margin({ top: 4 })
            Row({ space: 10 }) {
              Button(`${this.settings.quietStart === 22 && this.settings.quietEnd === 8 ? '✓ ' : ''}22:00—8:00`)
                .layoutWeight(1).height(38).fontSize(13).borderRadius(10)
                .backgroundColor(this.settings.quietStart === 22 && this.settings.quietEnd === 8 ? '#EFF6FF' : '#F2F4F7').fontColor('#2563EB')
                .enabled(!this.busy && this.settingsReady).onClick(() => this.chooseQuiet(22, 8))
              Button(`${this.settings.quietStart === 23 && this.settings.quietEnd === 9 ? '✓ ' : ''}23:00—9:00`)
                .layoutWeight(1).height(38).fontSize(13).borderRadius(10)
                .backgroundColor(this.settings.quietStart === 23 && this.settings.quietEnd === 9 ? '#EFF6FF' : '#F2F4F7').fontColor('#2563EB')
                .enabled(!this.busy && this.settingsReady).onClick(() => this.chooseQuiet(23, 9))
            }.width('100%')
            Row() {
              Text('紧急截止提醒可在免打扰时发送').fontSize(14).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.settings.urgentException }).enabled(!this.busy && this.settingsReady)
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
            Text('久未学习提醒 · 应用内提示').fontSize(15).fontWeight(FontWeight.Medium).width('100%')
            Text('两天没有新的专注记录，且没有更优先的待办时，在首页提示继续学习。无需开启系统通知。')
              .fontSize(12).fontColor('#667085').lineHeight(20).width('100%')
          }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(12)
        }.padding(16).width('100%').constraintSize({ maxWidth: 960 })
      }.layoutWeight(1).width('100%').align(Alignment.TopStart)
    }.height('100%').width('100%').backgroundColor('#F3F6FA')
  }
}
