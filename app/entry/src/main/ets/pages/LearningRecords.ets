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
  @State scope: string = 'current';
  @State busy: boolean = false;
  @State error: string = '';
  @State cursor: string | null = null;
  @State selected: LearningRecord | null = null;
  private owner: string = '';
  private chatId: string = '';
  private revision: number = 0;
  private active: boolean = true;
  private hasShown: boolean = false;
  aboutToAppear(): void { this.owner = appState.currentUser.userId; this.chatId = appState.chatSessionId; this.active = true; void this.load(); }
  aboutToDisappear(): void { this.active = false; this.revision++; }
  onPageHide(): void { this.active = false; this.revision++; this.busy = false; }
  onPageShow(): void {
    this.active = true;
    if (!this.hasShown) { this.hasShown = true; return; }
    this.owner = appState.currentUser.userId; this.chatId = appState.chatSessionId;
    this.records = []; this.selected = null; this.cursor = null; void this.load();
  }
  private async load(more: boolean = false): Promise<void> {
    const revision: number = ++this.revision;
    this.busy = true; this.error = '';
    const result = await AgentApiClient.getLearningRecords(more ? this.cursor ?? '' : '', this.scope === 'current' ? this.chatId : '');
    if (!this.active || this.owner !== appState.currentUser.userId || revision !== this.revision || this.chatId !== appState.chatSessionId) return;
    this.busy = false;
    if (!result.ok) { this.error = '学习记录加载失败：' + (result as ApiFailure).error.message; return; }
    this.records = more ? this.records.concat(result.data.records) : result.data.records;
    this.cursor = result.data.nextCursor;
  }
  private label(status: string): string { return status === 'completed' ? '已完成' : status === 'ended' ? '已结束' : status === 'waiting' ? '等待操作' : '学习中'; }
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
      PageHeader({ title: '学习记录' })
      Row({ space: 12 }) {
        Button('本次对话').backgroundColor(this.scope === 'current' ? '#2563EB' : '#E2E8F0')
          .fontColor(this.scope === 'current' ? '#FFFFFF' : '#475467')
          .onClick(() => { this.scope = 'current'; this.selected = null; void this.load(); })
        Button('全部记录').backgroundColor(this.scope === 'all' ? '#2563EB' : '#E2E8F0')
          .fontColor(this.scope === 'all' ? '#FFFFFF' : '#475467')
          .onClick(() => { this.scope = 'all'; this.selected = null; void this.load(); })
      }.padding(12)
      Scroll() {
        Column({ space: 12 }) {
          Text(this.scope === 'current' ? '本次对话中已确认的学习目标' : '当前账号的全部学习记录').fontSize(14).fontColor('#667085')
          if (this.busy) { LoadingProgress().width(32).height(32) }
          if (this.error) { Text(this.error).fontColor('#B42318'); Button('重试').onClick(() => this.load()) }
          else if (!this.busy && !this.records.length) {
            Text(this.scope === 'current' ? '当前对话还没有学习记录' : '尚无已确认的学习记录，请先在对话中确认一个具体学习目标。').fontColor('#667085')
            if (this.scope === 'current') { Button('查看全部记录').onClick(() => { this.scope = 'all'; void this.load(); }) }
          }
          ForEach(this.records, (record: LearningRecord) => {
            Column({ space: 8 }) {
              Text(record.knowledgePointName).fontSize(17).fontWeight(FontWeight.Medium)
              Text(`${this.label(record.status)} · 最近更新 ${new Date(record.updatedAt).toLocaleString()}`).fontSize(12).fontColor('#667085')
              Text(record.nextAction).fontSize(14).fontColor('#475467')
              Button(record.status === 'completed' ? '查看结果' : '查看详情').onClick(() => this.selected = this.selected?.goalId === record.goalId ? null : record)
              if (this.selected?.goalId === record.goalId) {
                Text(`目标：${record.goal}\n测评：${record.assessmentStatus === 'assessed' ? '已测评' : '待测评'}\n计划版本：${record.planVersion}`).fontSize(14).fontColor('#475467')
                if (record.status !== 'ended' && record.status !== 'completed') { Button('继续学习').onClick(() => this.practice(record)) }
                if (record.traceId) { Text('查看过程与结果 ›').fontColor('#2563EB').onClick(() => router.pushUrl({ url: 'pages/AgentTrace', params: { traceId: record.traceId } })) }
              }
            }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(12).alignItems(HorizontalAlign.Start)
          }, (record: LearningRecord) => record.goalId)
          if (this.cursor !== null) { Button('加载更多').enabled(!this.busy).onClick(() => this.load(true)) }
        }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
      }.align(Alignment.TopStart).layoutWeight(1).width('100%')
    }.width('100%').height('100%').backgroundColor('#F5F6F8')
  }
}
