import router from '@ohos.router';
import { UiTheme } from '../utils/UiTheme';
import { PageHeader } from '../components/PageHeader';
import { appState } from '../data/AppState';
import { FocusTask } from '../models/AgentModels';
import { PartnerContact } from '../api/ApiModels';
import { SharedTask, SharedTaskRequest } from '../api/StudyTaskModels';
import { AgentApiClient } from '../api/AgentApiClient';
import { ApiFailure } from '../api/ApiResult';

@Entry
@Component
struct CollaborativeTasks {
  @State tasks: SharedTask[] = [];
  @State contacts: PartnerContact[] = [];
  @State notice: string = '';
  @State busy: boolean = false;
  @State showCreate: boolean = false;
  @State partnerId: string = '';
  @State partnerName: string = '';
  @State focusedTaskId: string = '';
  private conversationPartner: string = '';
  @State title: string = '';
  @State course: string = '';
  @State day: string = '';
  @State minutes: string = '30';
  @State myPart: string = '';
  @State partnerPart: string = '';
  private revision: number = 0;
  private draftId: string = '';
  private owner: string = '';
  private active: boolean = false;
  private timer: number = -1;
  aboutToAppear(): void {
    this.owner = appState.currentUser.userId;
    const params = router.getParams() as Record<string, string>;
    this.partnerId = params?.['partnerId'] || ''; this.partnerName = params?.['partnerName'] || '';
    this.conversationPartner = this.partnerId;
    this.focusedTaskId = params?.['taskId'] || '';
    const now: Date = new Date(); this.day = `${now.getFullYear()}-${(now.getMonth() + 1).toString().padStart(2, '0')}-${now.getDate().toString().padStart(2, '0')}`;
    this.active = true; void this.load(); void this.loadContacts();
  }
  onPageShow(): void { this.active = true; void this.load(); if (this.timer < 0) this.timer = setInterval(() => { void this.load(); }, 5000); }
  onPageHide(): void { this.active = false; if (this.timer >= 0) clearInterval(this.timer); this.timer = -1; }
  aboutToDisappear(): void { this.onPageHide(); }
  private owns(): boolean { return this.active && this.owner === appState.currentUser.userId; }
  private async load(): Promise<void> {
    if (!this.owns() || this.busy) return;
    const revision: number = ++this.revision;
    const result = await AgentApiClient.sharedTasks();
    if (!this.owns() || revision !== this.revision) return;
    if (result.ok) this.tasks = result.data.tasks;
    else this.notice = (result as ApiFailure).error.message;
  }
  private async loadContacts(): Promise<void> {
    const result = await AgentApiClient.listPartnerContacts();
    if (this.owns() && result.ok) this.contacts = result.data.contacts.filter((contact: PartnerContact) =>
      !this.conversationPartner || contact.partnerUserId === this.conversationPartner);
  }
  private async action(request: SharedTaskRequest): Promise<void> {
    if (this.busy) return;
    this.revision++;
    this.busy = true; this.notice = '';
    const result = await AgentApiClient.sharedTaskAction(request);
    this.busy = false;
    if (!this.owns()) return;
    if (result.ok) {
      this.tasks = result.data.tasks;
      this.notice = request.action === 'remind' ? '提醒已发送到搭子消息。' : request.action === 'create' ? '安排已发送，等待对方确认；确认后加入双方计划。' : '已同步双方进度。';
      if (request.action === 'create') { this.showCreate = false; this.draftId = ''; }
    } else this.notice = (result as ApiFailure).error.message;
  }
  private create(): void {
    const minutes: number = Number(this.minutes);
    if (!this.partnerId || !this.title.trim() || !this.course.trim() || !this.myPart.trim() || !this.partnerPart.trim() || !Number.isInteger(minutes) || minutes < 1 || minutes > 1440) {
      this.notice = '请选择搭子，填写课程、任务、双方分工和有效分钟数。'; return;
    }
    if (!this.draftId) this.draftId = `shared-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
    void this.action({ action: 'create', taskId: this.draftId, partnerId: this.partnerId, title: this.title,
      courseName: this.course, scheduledDate: this.day, durationMinutes: minutes, myPart: this.myPart, partnerPart: this.partnerPart });
  }
  private start(task: SharedTask): void {
    if (!this.owns() || task.status !== 'accepted' || task.myStatus === 'completed') return;
    appState.setFocusTask({ course: task.courseName, task: task.title + ' · ' + task.myPart,
      plannedMinutes: task.durationMinutes, source: 'collaborative', mode: 'normal', timerType: 'countdown', planTaskId: task.taskId } as FocusTask);
    router.pushUrl({ url: 'pages/FocusSetup' });
  }
  private visibleTasks(): SharedTask[] {
    return this.tasks.filter((task: SharedTask) => this.focusedTaskId ? task.taskId === this.focusedTaskId :
      !this.conversationPartner || task.partnerId === this.conversationPartner);
  }
  @Builder
  CreateForm() {
    Column({ space: 12 }) {
      Select(this.contacts.map((contact: PartnerContact): SelectOption => { return { value: contact.partnerName }; }))
        .value(this.partnerName || '选择已添加的搭子').width('100%').onSelect((index: number) => { this.partnerId = this.contacts[index].partnerUserId; this.partnerName = this.contacts[index].partnerName; })
      TextInput({ text: this.title, placeholder: '一起完成什么任务' }).maxLength(200).onChange((v: string) => this.title = v)
      TextInput({ text: this.course, placeholder: '所属课程' }).maxLength(80).onChange((v: string) => this.course = v)
      TextInput({ text: this.day, placeholder: '安排日期 YYYY-MM-DD' }).onChange((v: string) => this.day = v)
      TextInput({ text: this.minutes, placeholder: '双方各自预计分钟数' }).type(InputType.Number).onChange((v: string) => this.minutes = v)
      TextInput({ text: this.myPart, placeholder: '我的分工与完成标准' }).maxLength(300).onChange((v: string) => this.myPart = v)
      TextInput({ text: this.partnerPart, placeholder: '搭子的分工与完成标准' }).maxLength(300).onChange((v: string) => this.partnerPart = v)
      if (this.notice) { Text(this.notice).fontSize(13).fontColor(UiTheme.secondary).width('100%') }
      Button('发送安排，等待搭子确认', { type: ButtonType.Normal }).width('100%').height(44).backgroundColor(UiTheme.accent).fontColor('#FFFFFF').enabled(!this.busy).onClick(() => this.create())
    }.width('100%').padding(20)
  }
  build() {
    Column() {
      PageHeader({ title: '搭子协同任务', detail: '搭子消息', onDetail: () => router.pushUrl({ url: 'pages/PartnerInbox' }) })
      Scroll() {
        Column({ space: 16 }) {
          Text('一起完成一件事').fontSize(23).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
          Text('双方确认安排后加入各自的学习计划，完成进度分别同步。').fontSize(13).lineHeight(21).fontColor(UiTheme.secondary).width('100%')
          if (!this.focusedTaskId) {
            Button('新建协同任务', { type: ButtonType.Normal }).width('100%').height(46).fontSize(15).fontColor('#FFFFFF').backgroundColor(UiTheme.accent).borderRadius(8).onClick(() => { this.notice = ''; this.showCreate = true; })
          }
          if (this.notice) { Text(this.notice).fontSize(13).fontColor(UiTheme.secondary).width('100%') }
          if (!this.visibleTasks().length) { Text(this.focusedTaskId ? '暂无可显示的协同任务详情。' : '还没有协同安排，先与搭子约定任务和分工。').fontSize(14).fontColor(UiTheme.secondary).width('100%') }
          ForEach(this.visibleTasks(), (task: SharedTask) => {
            Column({ space: 10 }) {
              Text(task.title).fontSize(17).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
              Text(`${task.courseName} · ${task.scheduledDate} · 各${task.durationMinutes}分钟`).fontSize(13).fontColor(UiTheme.secondary).width('100%')
              Text(`与${task.partnerName} · ${task.status === 'pending' ? '等待确认' : task.status === 'declined' ? '未接受安排' : '已加入双方计划'}`).fontSize(13).fontColor(UiTheme.accent).width('100%')
              Text(`我：${task.myPart} · ${task.myStatus === 'completed' ? '已完成' : '待完成'}`).fontSize(14).fontColor(UiTheme.ink).width('100%')
              Text(`${task.partnerName}：${task.partnerPart} · ${task.partnerStatus === 'completed' ? '已完成' : '待完成'}`).fontSize(14).fontColor(UiTheme.ink).width('100%')
              if (task.status === 'pending' && task.fromUserId !== this.owner) {
                Row({ space: 12 }) {
                  Button('确认并加入计划').enabled(!this.busy).onClick(() => this.action({ action: 'accept', taskId: task.taskId }))
                  Button('暂不接受').enabled(!this.busy).onClick(() => this.action({ action: 'decline', taskId: task.taskId }))
                }.width('100%')
              }
              if (task.status === 'accepted') {
                if (task.myStatus !== 'completed') {
                  Row({ space: 8 }) {
                    Button('开始我的部分', { type: ButtonType.Normal }).height(44).fontSize(13).backgroundColor(UiTheme.accent).fontColor('#FFFFFF').onClick(() => this.start(task))
                    Button('标记我的部分完成', { type: ButtonType.Normal }).height(44).fontSize(13).fontColor(UiTheme.accent).backgroundColor(UiTheme.tint).enabled(!this.busy).onClick(() => this.action({ action: 'complete', taskId: task.taskId }))
                  }.width('100%')
                }
                if (task.partnerStatus !== 'completed') {
                  Text('提醒搭子完成 ›').fontSize(14).fontColor(UiTheme.accent).height(44).padding({ top: 12 }).onClick(() => this.action({ action: 'remind', taskId: task.taskId }))
                }
              }
              Text('联系搭子，商量或提供帮助 ›').fontSize(13).fontColor(UiTheme.accent).height(44).padding({ top: 12 })
                .onClick(() => router.pushUrl({ url: 'pages/PartnerChat', params: { partnerId: task.partnerId, partnerName: task.partnerName } }))
            }.width('100%').padding(16).backgroundColor(UiTheme.subtle).borderRadius(8).alignItems(HorizontalAlign.Start)
          }, (task: SharedTask) => task.taskId)
        }.width('100%').constraintSize({ maxWidth: UiTheme.contentWidth }).padding(20).alignItems(HorizontalAlign.Start)
      }.width('100%').layoutWeight(1).align(Alignment.TopStart)
    }.width('100%').height('100%').backgroundColor(UiTheme.surface)
      .bindSheet($$this.showCreate, this.CreateForm(), { height: SheetSize.FIT_CONTENT, title: { title: '约定协同任务与分工' }, showClose: true, dragBar: true })
  }
}
