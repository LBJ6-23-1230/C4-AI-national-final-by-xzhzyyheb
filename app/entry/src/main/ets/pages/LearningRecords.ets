import { UiTheme } from '../utils/UiTheme';
import router from '@ohos.router';
import { AgentApiClient } from '../api/AgentApiClient';
import { LearningRecord, LearningContext } from '../api/ApiModels';
import { ApiFailure } from '../api/ApiResult';
import { PageHeader } from '../components/PageHeader';
import { appState } from '../data/AppState';

@Entry
@Component
struct LearningRecordsPage {
  @State records: LearningRecord[] = [];
  @State busy: boolean = false;
  @State error: string = '';
  @State cursor: string | null = null;
  @State selected: LearningRecord | null = null;
  private owner: string = '';
  private revision: number = 0;
  private active: boolean = true;
  private hasShown: boolean = false;
  aboutToAppear(): void { this.owner = appState.currentUser.userId; this.active = true; void this.load(); }
  aboutToDisappear(): void { this.active = false; this.revision++; }
  onPageHide(): void { this.active = false; this.revision++; this.busy = false; }
  onPageShow(): void {
    this.active = true;
    if (!this.hasShown) { this.hasShown = true; return; }
    this.owner = appState.currentUser.userId;
    this.records = []; this.selected = null; this.cursor = null; void this.load();
  }
  private async load(more: boolean = false): Promise<void> {
    const revision: number = ++this.revision;
    this.busy = true; this.error = '';
    if (!more) { this.records = []; this.selected = null; this.cursor = null; }
    const result = await AgentApiClient.getLearningRecords(more ? this.cursor ?? '' : '');
    if (!this.active || this.owner !== appState.currentUser.userId || revision !== this.revision) return;
    this.busy = false;
    if (!result.ok) { this.error = '学习记录加载失败：' + (result as ApiFailure).error.message; return; }
    this.records = more ? this.records.concat(result.data.records) : result.data.records;
    this.cursor = result.data.nextCursor;
  }
  private label(status: string): string { return status === 'completed' ? '已完成' : status === 'ended' ? '已结束' : status === 'waiting' ? '等待操作' : '学习中'; }
  private updatedLabel(value: string): string {
    const timestamp: number = Date.parse(value);
    return Number.isFinite(timestamp) ? '最近更新 ' + new Date(timestamp).toLocaleString() : '更新时间未记录';
  }
  private practice(record: LearningRecord): void {
    const context: LearningContext = record.learningContext;
    if (context.action.targetPage === 'pages/StudyPlan' || context.action.targetPage === 'pages/CourseImport') {
      router.pushUrl({ url: context.action.targetPage }); return;
    }
    router.pushUrl({ url: 'pages/ExercisePractice', params: { knowledgePointId: context.knowledgePointId,
      goalId: context.goalId, goalStateVersion: context.stateVersion, sourceMode: context.sourceMode, kbId: context.kbId } });
  }
  build() {
    Column() {
      PageHeader({ title: '学习目标记录' })
      Scroll() {
        Column({ space: 12 }) {
          Text('保存每次练习目标与进度，可继续未完成练习、查看已完成结果。完成流程不代表已掌握，掌握情况请看学习报告。').fontSize(14).fontColor(UiTheme.secondary)
          if (this.busy) { LoadingProgress().width(32).height(32) }
          if (this.error) { Text(this.error).fontColor(UiTheme.danger); Button('重试').onClick(() => this.load()) }
          else if (!this.busy && !this.records.length) {
            Text('还没有学习记录。在对话中确认一个学习目标后，会在这里显示。').fontColor(UiTheme.secondary)
          }
          ForEach(this.records, (record: LearningRecord) => {
            Column({ space: 8 }) {
              Text(record.knowledgePointName).fontSize(17).fontWeight(FontWeight.Medium)
              Text(`${this.label(record.status)} · ${this.updatedLabel(record.updatedAt)}`).fontSize(12).fontColor(UiTheme.secondary)
              Text(record.nextAction).fontSize(14).fontColor(UiTheme.secondary)
              Text(record.status === 'completed' ? '查看结果 ›' : '查看详情 ›').fontColor(UiTheme.accent)
                .onClick(() => this.selected = this.selected?.goalId === record.goalId ? null : record)
              if (this.selected?.goalId === record.goalId) {
                Text(`目标：${record.goal}\n测评：${record.assessmentStatus === 'assessed' ? '已测评' : '待测评'}`).fontSize(14).fontColor(UiTheme.secondary)
                if (record.status !== 'ended' && record.status !== 'completed') { Button('继续学习').onClick(() => this.practice(record)) }
                if (record.traceId) { Text('查看过程与结果 ›').fontColor(UiTheme.accent).onClick(() => router.pushUrl({ url: 'pages/AgentTrace', params: { traceId: record.traceId } })) }
              }
            }.width('100%').padding({ top: 18, bottom: 18 }).border({ width: { bottom: 1 }, color: UiTheme.line }).alignItems(HorizontalAlign.Start)
          }, (record: LearningRecord) => record.goalId)
          if (this.cursor !== null) { Button('加载更多').enabled(!this.busy).onClick(() => this.load(true)) }
        }.width('100%').constraintSize({ maxWidth: UiTheme.contentWidth }).padding(16).alignItems(HorizontalAlign.Start)
      }.align(Alignment.Top).layoutWeight(1).width('100%')
    }.width('100%').height('100%').backgroundColor(UiTheme.canvas)
  }
}
