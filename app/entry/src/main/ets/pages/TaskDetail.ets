import { UiTheme } from '../utils/UiTheme';
import router from '@ohos.router';
import { AgentApiClient } from '../api/AgentApiClient';
import { PlanTask } from '../api/ApiModels';
import { ApiFailure } from '../api/ApiResult';
import { appState } from '../data/AppState';
import { PageHeader } from '../components/PageHeader';
import { ReminderNavigation } from '../services/ReminderNavigation';
import { TaskFocusSheet } from '../components/TaskFocusSheet';

@Entry
@Component
struct TaskDetail {
  @State task: PlanTask | null = null;
  @State steps: PlanTask[] = [];
  @State scheduled: boolean = false;
  @State busy: boolean = false;
  @State notice: string = '';
  @State private focusSheetVisible: boolean = false;
  @State private focusTask: PlanTask | null = null;
  private active: boolean = false;
  private version: number = 0;
  private taskId: string = '';
  private shown: boolean = false;
  aboutToAppear(): void {
    this.active = true;
    this.taskId = (router.getParams() as Record<string, string>)?.['taskId'] || '';
    void this.load();
  }
  onPageShow(): void { if (this.shown) void this.load(); this.shown = true; }
  aboutToDisappear(): void { this.active = false; this.version++; }
  private async load(): Promise<void> {
    const owner: string = appState.currentUser.userId;
    const version: number = ++this.version;
    this.busy = true; this.notice = '';
    const result = await AgentApiClient.getCurrentPlan();
    if (!this.active || owner !== appState.currentUser.userId || version !== this.version) return;
    this.busy = false; this.task = null; this.steps = [];
    if (!result.ok) { this.notice = (result as ApiFailure).error.message; return; }
    const tasks: PlanTask[] = result.data.tasks.concat(result.data.unscheduledTasks || []);
    this.task = tasks.find((task: PlanTask) => task.taskId === this.taskId) || null;
    this.steps = tasks.filter((task: PlanTask) => task.parentTaskId === this.taskId);
    this.scheduled = result.data.tasks.some((task: PlanTask) => task.taskId === this.taskId || task.parentTaskId === this.taskId);
    if (this.task === null && this.steps.length > 0) {
      this.task = { taskId: this.taskId, knowledgePointId: this.steps[0].knowledgePointId,
        knowledgePointName: this.steps[0].knowledgePointName.split(' · ')[0], source: 'ddl',
        sourceCourse: this.steps[0].sourceCourse, dueDate: this.steps[0].dueDate,
        durationMinutes: this.steps.reduce((sum: number, step: PlanTask) => sum + step.durationMinutes, 0), status: 'pending' };
    }
    if (this.task === null) this.notice = '这项任务已完成、移除或发生变化，请返回全部待办刷新。';
  }
  private start(task: PlanTask): void {
    this.notice = ReminderNavigation.startTask(task, (selected: PlanTask): string => {
      this.focusTask = selected;
      this.focusSheetVisible = true;
      return '';
    });
  }
  @Builder
  FocusSheet() {
    TaskFocusSheet({ task: this.focusTask, onClose: () => this.focusSheetVisible = false,
      isOpen: () => this.focusSheetVisible })
  }
  build() {
    Column() {
      PageHeader({ title: '任务详情', detail: '查看与开始本项任务' })
      Scroll() {
        Column({ space: 16 }) {
          if (this.busy) LoadingProgress().width(32).height(32)
          if (this.notice) Text(this.notice).fontSize(14).fontColor('#B45309').width('100%')
          if (this.task !== null) {
            Text(this.task!.knowledgePointName).fontSize(24).fontWeight(FontWeight.Bold).width('100%')
            Text(`${this.task!.sourceCourse || '课程未确认'} · ${this.task!.durationMinutes}分钟${this.task!.dueDate ? ' · 截止' + this.task!.dueDate : ''}`).fontSize(14).fontColor(UiTheme.secondary).width('100%')
            Text(this.task!.status === 'completed' ? '这项任务已完成' : this.scheduled ?
              (this.task!.scheduledDate ? '已安排在 ' + this.task!.scheduledDate : '已加入当前学习安排') : '尚未排期，可以先开始本项任务，也可以到整体计划确认时间。')
              .fontSize(14).fontColor(UiTheme.secondary).width('100%')
            if (this.task!.allocationReason) Text(this.task!.allocationReason).fontSize(13).fontColor(UiTheme.secondary).lineHeight(21).width('100%')
            if (this.task!.steps?.length) ForEach(this.task!.steps, (step: string) => {
              Text('· ' + step).fontSize(15).lineHeight(24).fontColor(UiTheme.ink).width('100%')
            })
            if (this.steps.length > 0) {
              Text('按已确认的步骤执行，全部完成后才完成原作业。').fontSize(14).fontColor(UiTheme.secondary).width('100%')
              ForEach(this.steps, (step: PlanTask) => {
                Column({ space: 10 }) {
                  Text(step.knowledgePointName).fontSize(16).width('100%')
                  Text(`${step.durationMinutes}分钟${step.scheduledDate ? ' · ' + step.scheduledDate : ' · 尚未排期'}`).fontSize(13).fontColor(UiTheme.secondary).width('100%')
                  if (step.status !== 'completed') Button(ReminderNavigation.taskActionLabel(step) === '继续专注' ? '继续专注' : '开始这一步').onClick(() => this.start(step))
                  else Text('已完成此步骤').fontSize(13).fontColor('#0F766E')
                }.width('100%').padding(16).backgroundColor(UiTheme.surface).borderRadius(8)
              }, (step: PlanTask) => step.taskId)
            } else if (this.task!.status !== 'completed') {
              Text(ReminderNavigation.practiceTask(this.task!) ? '开始后直接进入这个知识点的练习，提交后查看解析和学习报告。' : '先选择本次时长与专注模式，确认后开始计时；结束时记录实际用时和完成情况。')
                .fontSize(14).fontColor(UiTheme.secondary).lineHeight(23).width('100%')
              Button(ReminderNavigation.taskActionLabel(this.task!)).width('100%').height(48).backgroundColor(UiTheme.accent).onClick(() => this.start(this.task!))
            }
            Text('查看整体学习计划 ›').fontSize(14).fontColor(UiTheme.accent).width('100%')
              .onClick(() => router.pushUrl({ url: 'pages/StudyPlan', params: { courseName: this.task!.sourceCourse || '' } }))
          }
          if (!this.busy && this.task === null) Button('刷新本项任务').width('100%').onClick(() => this.load())
        }.padding(20).width('100%').alignItems(HorizontalAlign.Start)
      }.align(Alignment.TopStart).layoutWeight(1).width('100%')
    }.width('100%').height('100%').backgroundColor(UiTheme.canvas)
      .bindSheet($$this.focusSheetVisible, this.FocusSheet(), {
        height: SheetSize.FIT_CONTENT, showClose: false, dragBar: true, backgroundColor: UiTheme.surface,
        onWillDismiss: (action: DismissSheetAction) => { this.focusSheetVisible = false; action.dismiss(); }
      })
  }
}
