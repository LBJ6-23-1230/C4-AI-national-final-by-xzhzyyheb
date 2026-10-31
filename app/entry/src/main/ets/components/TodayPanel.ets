import { ReminderNavigation } from '../services/ReminderNavigation';
import router from '@ohos.router';
import { common } from '@kit.AbilityKit';
import { AgentApiClient } from '../api/AgentApiClient';
import { ReminderEvent, TodayOverview } from '../api/ReminderModels';
import { ApiFailure } from '../api/ApiResult';
import { appState } from '../data/AppState';
import { TodayStore } from '../services/TodayStore';
import { FocusTask } from '../models/AgentModels';
import { LearningCardService } from '../services/LearningCardService';
import { ReminderDeviceService } from '../services/ReminderDeviceService';

@Component
export struct TodayPanel {
  @Prop @Watch('refresh') revision: number = 0;
  @State data: TodayOverview | null = null;
  @State message: string = '';
  @State loading: boolean = false;
  @State busy: boolean = false;
  @State expanded: boolean = false;
  @State panelOpen: boolean = false;
  @State actionMessage: string = '';
  private displayOwner: string = '';
  private requestVersion: number = 0;
  private active: boolean = true;
  aboutToAppear(): void {
    this.active = true;
    ReminderDeviceService.heartbeat(getContext(this) as common.Context, true);
    this.data = TodayStore.read(getContext(this) as common.Context, appState.currentUser.userId);
    void this.refresh();
  }
  aboutToDisappear(): void { this.active = false; this.requestVersion++; }
  private async refresh(): Promise<void> {
    const owner: string = appState.currentUser.userId;
    if (owner !== this.displayOwner) {
      this.displayOwner = owner;
      this.panelOpen = appState.isSignedIn && TodayStore.firstDisplay(getContext(this) as common.Context, owner);
      this.expanded = false; this.actionMessage = ''; this.busy = false;
    }
    if (this.data?.userId !== owner) this.data = null;
    const version: number = ++this.requestVersion;
    this.loading = true;
    const result = await AgentApiClient.getToday();
    if (!this.active || version !== this.requestVersion || owner !== appState.currentUser.userId) return;
    this.loading = false;
    if (result.ok && result.data.userId === owner) {
      if (this.data?.highlight?.eventId !== result.data.highlight?.eventId ||
        this.data?.highlight?.version !== result.data.highlight?.version) this.expanded = false;
      this.data = result.data; this.message = '';
      TodayStore.save(getContext(this) as common.Context, result.data);
      void LearningCardService.saveOverview(getContext(this) as common.Context, result.data);
    } else this.message = '更新失败，点击重试';
  }
  private toggleReason(): void {
    if (this.data?.highlight) this.expanded = !this.expanded;
  }
  private async act(event: ReminderEvent, action: string, minutes: number = 30): Promise<void> {
    if (this.busy) return;
    const owner: string = appState.currentUser.userId;
    this.busy = true;
    const result = await AgentApiClient.reminderAction(event.eventId, { action: action, version: event.version,
      idempotencyKey: `${event.eventId}-${event.version}-${action}-${minutes}`, minutes: minutes });
    if (!this.active || owner !== appState.currentUser.userId) return;
    this.busy = false;
    if (!result.ok) { this.actionMessage = (result as ApiFailure).error.code === 'RESULT_UNCONFIRMED' ? '暂未确认，请重试' : '操作失败，请重试'; return; }
    this.actionMessage = action === 'snooze' ? '已稍后提醒' : action === 'ignore' ? '今日已忽略' : '';
    if (action === 'open') ReminderNavigation.open(event);
    void this.refresh();
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
    Column({ space: 8 }) {
      Row() {
        Text(this.data?.pendingCount ? `! 今日有 ${this.data!.pendingCount} 项待处理` : '今日安排')
          .fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.data?.highlight?.level === 'urgent' ? '#B42318' : '#101828').layoutWeight(1).maxLines(1)
        Blank()
        Text(this.panelOpen ? '收起 ∧' : '展开 ∨').fontSize(12).fontColor('#2563EB').padding(8)
          .onClick(() => this.panelOpen = !this.panelOpen)
      }.width('100%')
      if (this.panelOpen) {
      if (this.data?.highlight) {
        Text(this.data!.highlight!.title).fontSize(18).fontWeight(FontWeight.Medium)
          .fontColor(this.data!.highlight!.level === 'urgent' ? '#B42318' : '#101828').width('100%').maxLines(2)
        Text(`${this.data!.highlight!.courseName}${this.data!.highlight!.durationMinutes > 0 ? ' · ' + this.data!.highlight!.durationMinutes + ' 分钟' : ''}`)
          .fontSize(12).fontColor('#667085').width('100%')
        Row({ space: 16 }) {
          Button(this.data!.highlight!.targetPage === 'pages/StudyPlan' ? '查看安排' : '查看任务').height(40).fontSize(14).backgroundColor('#2563EB').enabled(!this.busy)
            .onClick(() => this.act(this.data!.highlight!, 'open'))
          Text('稍后开始').fontSize(12).fontColor('#475467').onClick(() => this.chooseSnooze(this.data!.highlight!))
          Text('今天忽略').fontSize(12).fontColor('#667085').onClick(() => this.act(this.data!.highlight!, 'ignore'))
        }.width('100%')
        Text(this.expanded ? '收起本任务依据 ∧' : '为什么建议现在做 ›').fontSize(12).fontColor('#667085').width('100%')
          .onClick(() => this.toggleReason())
        if (this.expanded) {
          Column({ space: 5 }) {
            Text(`「${this.data!.highlight!.title}」的建议依据`).fontSize(12).fontWeight(FontWeight.Medium).fontColor('#475467').width('100%')
            Text(this.data!.highlight!.reason).fontSize(12).fontColor('#667085').width('100%')
          }.width('100%').padding(10).backgroundColor('#F8FAFC').borderRadius(8)
        }
      } else {
        Text(this.loading ? '正在读取今日安排…' : this.data?.guidance ?? '今日安排暂未读取').fontSize(13).fontColor('#667085').width('100%')
        Text('查看今日安排 ›').fontSize(13).fontColor('#2563EB').width('100%').onClick(() => router.pushUrl({ url: 'pages/StudyPlan' }))
      }
      Text(`展开全部 · 还有 ${Math.max(0, (this.data?.pendingCount ?? 0) - 1)} 项 ›`).fontSize(13).fontColor('#2563EB').onClick(() => router.pushUrl({ url: 'pages/Reminders' }))
      Text('提醒与设置 ›').fontSize(12).fontColor('#475467').width('100%').onClick(() => router.pushUrl({ url: 'pages/Reminders' }))
      }
      this.SnoozeSelector()
      if (this.actionMessage) Text(this.actionMessage).fontSize(12).fontColor('#667085').width('100%')
      if (this.message) {
        Text(this.message)
          .fontSize(11).fontColor('#B54708').width('100%').onClick(() => this.refresh())
      }
    }.padding(14).width('100%').backgroundColor('#FFFFFF').borderRadius(12)
      .border({ width: 1, color: '#E4E7EC' })
  }
}
