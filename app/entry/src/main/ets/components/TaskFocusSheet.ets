import { PlanTask } from '../api/ApiModels';
import { FocusMode } from '../models/AgentModels';
import { appState } from '../data/AppState';
import { ReminderNavigation } from '../services/ReminderNavigation';

@Component
export struct TaskFocusSheet {
  @Prop @Watch('resetSelection') task: PlanTask | null = null;
  onClose: () => void = () => {};
  isOpen: () => boolean = () => true;
  @State private minutes: string = '30';
  @State private mode: FocusMode = 'normal';
  @State private error: string = '';
  @State private busy: boolean = false;
  private owner: string = '';
  private active: boolean = false;
  private requestVersion: number = 0;

  aboutToAppear(): void {
    this.active = true;
    this.resetSelection();
  }

  aboutToDisappear(): void {
    this.active = false;
    this.requestVersion++;
  }

  private resetSelection(): void {
    this.owner = appState.currentUser.userId;
    const suggested: number = this.task?.durationMinutes ?? 30;
    this.minutes = (Number.isInteger(suggested) && suggested >= 1 ? Math.min(180, suggested) : 30).toString();
    this.mode = 'normal';
    this.error = '';
    this.busy = false;
    this.requestVersion++;
  }

  private close(): void {
    this.active = false;
    this.requestVersion++;
    this.onClose();
  }

  private async start(): Promise<void> {
    if (this.busy || this.task === null) return;
    this.busy = true;
    this.error = '';
    const version: number = ++this.requestVersion;
    try {
      const message: string = await ReminderNavigation.confirmFocus(this.task.taskId, Number(this.minutes), this.mode,
        this.owner, (): boolean => this.active && this.isOpen() && version === this.requestVersion);
      if (!this.active || version !== this.requestVersion) return;
      this.busy = false;
      if (message.length > 0) this.error = message;
      else this.close();
    } catch (_) {
      if (!this.active || version !== this.requestVersion) return;
      this.busy = false;
      this.error = '暂时无法开始专注，请重试。';
    }
  }

  @Builder
  DurationButton(value: number) {
    Button(`${value} 分钟`).layoutWeight(1).height(38).fontSize(14)
      .fontColor(this.minutes === value.toString() ? '#2563EB' : '#475467')
      .backgroundColor(this.minutes === value.toString() ? '#EFF6FF' : '#F5F7FA')
      .borderRadius(10).enabled(!this.busy)
      .onClick(() => this.minutes = value.toString())
  }

  build() {
    Column({ space: 16 }) {
      Row() {
        Text('开始任务').fontSize(22).fontWeight(FontWeight.Bold).fontColor('#101828')
        Blank()
        Button('取消').fontSize(14).fontColor('#667085').backgroundColor('#F5F7FA')
          .height(36).onClick(() => this.close())
      }.width('100%')
      Column({ space: 6 }) {
        Text(this.task?.knowledgePointName ?? '').fontSize(18).fontWeight(FontWeight.Medium)
          .fontColor('#202522').width('100%').maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.task?.sourceCourse ?? '').fontSize(13).fontColor('#667085').width('100%')
      }.width('100%')
      Column({ space: 10 }) {
        Text('本次专注时长').fontSize(15).fontWeight(FontWeight.Medium).width('100%')
        Row({ space: 8 }) {
          this.DurationButton(25)
          this.DurationButton(30)
          this.DurationButton(60)
        }.width('100%')
        Row({ space: 10 }) {
          Text('自定义').fontSize(14).fontColor('#475467')
          TextInput({ text: this.minutes, placeholder: '1–180' }).type(InputType.Number)
            .layoutWeight(1).height(42).backgroundColor('#F5F7FA').borderRadius(10).enabled(!this.busy)
            .onChange((value: string) => this.minutes = value)
          Text('分钟').fontSize(14).fontColor('#475467')
        }.width('100%')
        Text('1–180 分钟，可按本次安排调整').fontSize(12).fontColor('#667085').width('100%')
      }.width('100%')
      Column({ space: 10 }) {
        Text('专注模式').fontSize(15).fontWeight(FontWeight.Medium).width('100%')
        Row({ space: 10 }) {
          Button('普通专注').layoutWeight(1).height(42).fontSize(15).borderRadius(10).enabled(!this.busy)
            .fontColor(this.mode === 'normal' ? '#FFFFFF' : '#2563EB')
            .backgroundColor(this.mode === 'normal' ? '#2563EB' : '#EFF6FF')
            .onClick(() => this.mode = 'normal')
          Button('严格专注').layoutWeight(1).height(42).fontSize(15).borderRadius(10).enabled(!this.busy)
            .fontColor(this.mode === 'strict' ? '#FFFFFF' : '#475467')
            .backgroundColor(this.mode === 'strict' ? '#1E3A5F' : '#F5F7FA')
            .onClick(() => this.mode = 'strict')
        }.width('100%')
        Text(this.mode === 'strict' ? '不可暂停；提前退出需确认，并记录为中断。' : '可以暂停、继续，也可以保存未完成记录。')
          .fontSize(13).fontColor('#667085').lineHeight(20).width('100%')
      }.width('100%')
      if (this.error.length > 0) Text(this.error).fontSize(13).fontColor('#B42318').width('100%')
      Button(this.busy ? '正在确认…' : '开始专注').width('100%').height(48).fontSize(16)
        .fontWeight(FontWeight.Bold).fontColor('#FFFFFF').borderRadius(12).enabled(!this.busy && this.task !== null)
        .backgroundColor(this.mode === 'strict' ? '#1E3A5F' : '#2563EB').onClick(() => this.start())
    }.width('100%').padding({ left: 20, right: 20, top: 8, bottom: 24 }).alignItems(HorizontalAlign.Start)
  }
}
