import { ReminderNavigation } from '../services/ReminderNavigation';
import router from '@ohos.router';
import { common } from '@kit.AbilityKit';
import notificationManager from '@ohos.notificationManager';
import { AgentApiClient } from '../api/AgentApiClient';
import { ApiFailure } from '../api/ApiResult';
import { ReminderEvent, ReminderPreferences } from '../api/ReminderModels';
import { appState } from '../data/AppState';
import { FocusTask } from '../models/AgentModels';
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
    const list = await AgentApiClient.getReminders(more ? this.cursor : '');
    if (!this.active || owner !== appState.currentUser.userId || version !== this.version) return;
    this.busy = false;
    if (list.ok) {
      this.events = more ? this.events.concat(list.data.events) : list.data.events;
      this.cursor = list.data.cursor; this.hasMore = list.data.hasMore;
    } else this.message = (list as ApiFailure).error.message;
    const settings = await AgentApiClient.getReminderSettings();
    if (!this.active || owner !== appState.currentUser.userId || version !== this.version) return;
    if (settings.ok) { this.settings = settings.data.preferences; this.pushConfigured = settings.data.pushConfigured; }
    else this.message = (settings as ApiFailure).error.message;
    try { this.permission = await notificationManager.isNotificationEnabled(); } catch (_) { this.permission = false; }
    await ReminderDeviceService.sync(getContext(this) as common.Context, true);
    if (this.active && owner === appState.currentUser.userId && version === this.version) this.lastSync = ReminderDeviceService.lastSync;
  }
  private async save(enabled: boolean): Promise<void> {
    if (this.busy) return;
    const owner: string = appState.currentUser.userId;
    const request: ReminderPreferences = { enabled: enabled, timezone: this.settings.timezone,
      quietStart: this.settings.quietStart, quietEnd: this.settings.quietEnd, dailyLimit: this.settings.dailyLimit,
      minimumGapMinutes: this.settings.minimumGapMinutes, urgentException: this.settings.urgentException, summaryHour: this.settings.summaryHour,
      categories: this.settings.categories ?? ['task', 'exam', 'gap', 'conflict'] };
    this.busy = true;
    const result = await AgentApiClient.saveReminderSettings(request);
    if (!this.active || owner !== appState.currentUser.userId) return;
    this.busy = false;
    if (result.ok) { this.settings = result.data.preferences; this.message = '提醒设置已保存。'; }
    else this.message = (result as ApiFailure).error.message;
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
    if (kind === 'exam') return '已评估知识点考前巩固';
    if (kind === 'conflict') return '时间预算冲突';
    return '学习间隔';
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
  build() {
    Column() {
      PageHeader({ title: '提醒与设置', detail: '今日事项', onBack: () => router.back() })
      Scroll() {
        Column({ space: 14 }) {
          Column({ space: 12 }) {
            Row() {
              Text('允许主动提醒').fontSize(16).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.settings.enabled }).enabled(!this.busy)
                .onChange((value: boolean) => { if (value !== this.settings.enabled) void this.save(value); })
            }.width('100%')
            Text(`通知权限：${this.permission ? '已授权' : '未授权'} · 云推送：${this.pushConfigured ? '已配置，待设备验证' : '尚未配置'}`)
              .fontSize(12).fontColor('#667085').width('100%')
            Text(this.lastSync ? `本机最后同步：${this.lastSync.slice(0, 19).replace('T', ' ')} UTC` : '本机尚无成功的设备同步记录')
              .fontSize(12).fontColor('#667085').width('100%')
            Text(`免打扰 ${this.settings.quietStart}:00—${this.settings.quietEnd}:00 · ${this.settings.timezone}`)
              .fontSize(12).fontColor('#475467').width('100%')
            Row({ space: 12 }) {
              Text('22—8点').fontSize(13).fontColor('#2563EB').onClick(() => { this.settings.quietStart = 22; this.settings.quietEnd = 8; void this.save(this.settings.enabled); })
              Text('23—9点').fontSize(13).fontColor('#2563EB').onClick(() => { this.settings.quietStart = 23; this.settings.quietEnd = 9; void this.save(this.settings.enabled); })
              Text('申请通知权限').fontSize(13).fontColor('#2563EB').onClick(async () => {
                this.permission = await ProactiveSurfaceService.requestPermission(getContext(this) as common.UIAbilityContext);
                void ProactiveSurfaceService.refresh(getContext(this) as common.UIAbilityContext, true);
              })
            }.width('100%')
            Row() {
              Text('允许紧急事项突破免打扰').fontSize(14).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.settings.urgentException }).enabled(!this.busy)
                .onChange((value: boolean) => { if (value !== this.settings.urgentException) { this.settings.urgentException = value; void this.save(this.settings.enabled); } })
            }.width('100%')
            Row({ space: 16 }) {
              Text(`摘要时段：${this.settings.summaryHour}:00起`).fontSize(12).fontColor('#667085')
              ForEach([9, 12, 18], (hour: number) => {
                Text(`${hour}点`).fontSize(13).fontColor('#2563EB').onClick(() => {
                  if (!this.busy) { this.settings.summaryHour = hour; void this.save(this.settings.enabled); }
                })
              })
            }.width('100%')
            Text(`每天最多${this.settings.dailyLimit}次，普通摘要最多1次；两次主动提醒至少间隔4小时。首页建议不受通知权限影响。`)
              .fontSize(12).fontColor('#667085').width('100%')
            Text('外部通知类别（首页事项仍正常显示）').fontSize(12).fontColor('#667085').width('100%')
            ForEach(['task', 'exam', 'conflict', 'gap'], (kind: string) => {
              Row() {
                Text(this.categoryLabel(kind)).fontSize(14).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: (this.settings.categories ?? ['task', 'exam', 'gap', 'conflict']).includes(kind) })
                  .enabled(!this.busy).onChange((value: boolean) => {
                    const current: string[] = this.settings.categories ?? ['task', 'exam', 'gap', 'conflict'];
                    if (value !== current.includes(kind)) {
                      this.settings.categories = value ? current.concat([kind]) : current.filter((item: string) => item !== kind);
                      void this.save(this.settings.enabled);
                    }
                  })
              }.width('100%')
            })
          }.padding(16).backgroundColor('#FFFFFF').borderRadius(12).width('100%')
          this.SnoozeSelector()
          if (this.message) { Text(this.message).fontSize(13).fontColor('#B54708').width('100%') }
          if (this.busy) { LoadingProgress().width(28).height(28) }
          if (!this.busy && this.events.length === 0) { Text('暂无提醒，可先导入课程并建立学习安排。').fontSize(14).fontColor('#667085') }
          ForEach(this.events, (item: ReminderEvent) => {
            Column({ space: 10 }) {
              Text(`${this.statusLabel(item)} · ${item.courseName}`).fontSize(12).fontColor('#667085').width('100%')
              Text(item.title).fontSize(17).fontWeight(FontWeight.Medium).width('100%')
              Text(item.reason).fontSize(13).fontColor('#475467').width('100%')
              if (item.status !== 'completed' && item.status !== 'invalid') {
                Row({ space: 16 }) {
                  Button(item.targetPage === 'pages/StudyPlan' ? '查看安排' : '查看任务').height(40).fontSize(14).backgroundColor('#2563EB').enabled(!this.busy).onClick(() => this.act(item, 'open'))
                  Text('今天忽略').fontSize(13).fontColor('#667085').onClick(() => this.act(item, 'ignore'))
                }.width('100%')
                Button('稍后开始').enabled(!this.busy && item.status !== 'snoozed').onClick(() => this.chooseSnooze(item))

              }
            }.padding(16).backgroundColor('#FFFFFF').borderRadius(12).width('100%')
          }, (item: ReminderEvent) => `${item.eventId}-${item.version}`)
          Button(this.hasMore ? '加载更多' : '刷新提醒').enabled(!this.busy).onClick(() => this.load(this.hasMore))
        }.padding(16).width('100%').constraintSize({ maxWidth: 960 })
      }.layoutWeight(1).width('100%')
    }.height('100%').width('100%').backgroundColor('#F3F6FA')
  }
}
