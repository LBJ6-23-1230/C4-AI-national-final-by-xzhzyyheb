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
  private async act(event: ReminderEvent, action: string): Promise<void> {
    if (this.busy) return;
    if (action === 'start' && event.targetPage === 'pages/FocusSetup' && appState.focusRuntime !== null) {
      this.message = '请先处理当前专注任务。'; return;
    }
    const owner: string = appState.currentUser.userId;
    this.busy = true;
    const result = await AgentApiClient.reminderAction(event.eventId, { action: action, version: event.version,
      idempotencyKey: `${event.eventId}-${event.version}-${action}`, minutes: 30 });
    if (!this.active || owner !== appState.currentUser.userId) return;
    this.busy = false;
    if (!result.ok) { this.actionMessage = (result as ApiFailure).error.code === 'RESULT_UNCONFIRMED' ? '暂未确认，请重试' : '操作失败，请重试'; return; }
    this.actionMessage = action === 'snooze' ? '已稍后提醒' : action === 'ignore' ? '今日已忽略' : '';
    if (action === 'start') {
      if (event.targetPage === 'pages/FocusSetup') {
        appState.setFocusTask({ course: event.courseName, task: event.title, plannedMinutes: event.durationMinutes,
          source: 'agent', mode: 'normal', timerType: 'countdown', planTaskId: event.objectId } as FocusTask);
      }
      router.pushUrl({ url: event.targetPage, params: { courseName: event.courseName,
        knowledgePointId: event.knowledgePointId, eventId: event.eventId, eventVersion: result.data.event.version } });
    }
    void this.refresh();
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
          Button(this.data!.highlight!.targetPage === 'pages/StudyPlan' ? '查看安排' : '开始任务').height(40).fontSize(14).backgroundColor('#2563EB').enabled(!this.busy)
            .onClick(() => this.act(this.data!.highlight!, 'start'))
          Text('稍后30分钟').fontSize(12).fontColor('#475467').onClick(() => this.act(this.data!.highlight!, 'snooze'))
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
      Text('提醒与设置 ›').fontSize(12).fontColor('#475467').width('100%').onClick(() => router.pushUrl({ url: 'pages/Reminders' }))
      }
      if (this.actionMessage) Text(this.actionMessage).fontSize(12).fontColor('#667085').width('100%')
      if (this.message) {
        Text(this.message)
          .fontSize(11).fontColor('#B54708').width('100%').onClick(() => this.refresh())
      }
    }.padding(14).width('100%').backgroundColor('#FFFFFF').borderRadius(12)
      .border({ width: 1, color: '#E4E7EC' })
  }
}
