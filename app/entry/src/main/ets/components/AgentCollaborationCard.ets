import router from '@ohos.router';
import { AgentApiClient } from '../api/AgentApiClient';
import { TraceEvent } from '../api/ApiModels';
import { appState } from '../data/AppState';

@Component
export struct AgentCollaborationCard {
  @Prop @Watch('reload') traceId: string = '';
  @State events: TraceEvent[] = [];
  @State notice: string = '';
  private version: number = 0;
  aboutToAppear(): void { void this.reload(); }
  aboutToDisappear(): void { this.version++; }
  private async reload(): Promise<void> {
    const version: number = ++this.version;
    const owner: string = appState.currentUser.userId;
    this.events = [];
    if (!this.traceId) { this.notice = '开始学习任务后展示实际协作记录'; return; }
    const result = await AgentApiClient.getTrace(this.traceId);
    if (version !== this.version || owner !== appState.currentUser.userId) return;
    if (result.ok) { this.events = result.data.events.slice(-5); this.notice = this.events.length ? '' : '等待智能体处理记录'; }
    else this.notice = '协作记录暂时不可用';
  }
  private role(agent: string): string {
    if (agent.toLowerCase().indexOf('secretary') >= 0) return '流程编排 · 协调下一步';
    if (agent.toLowerCase().indexOf('diagnos') >= 0) return '诊断 · 确认学习状态';
    if (agent.toLowerCase().indexOf('plan') >= 0) return '规划 · 安排学习任务';
    if (agent.toLowerCase().indexOf('exercise') >= 0) return '练习 · 准备针对性题目';
    if (agent.toLowerCase().indexOf('assess') >= 0) return '评估 · 测评并反馈';
    return agent;
  }
  build() {
    Column({ space: 8 }) {
      Text('学习助手协作进度').fontSize(16).fontWeight(FontWeight.Bold).width('100%')
      Text(this.notice).fontSize(12).fontColor('#64748B')
      ForEach(this.events, (event: TraceEvent, index: number) => {
        Column({ space: 4 }) {
          Text(this.role(event.agent) + ' · ' + event.status).fontSize(13).fontWeight(FontWeight.Medium)
          Text(event.outputSummary).fontSize(12).fontColor('#475569').maxLines(3)
        }.width('100%').padding(10).backgroundColor('#EFF6FF').borderRadius(10)
      }, (event: TraceEvent, index: number) => `${event.timestamp}-${index}`)
      if (this.traceId) {
        Button('查看实际交接与调整依据').fontSize(12)
          .onClick(() => router.pushUrl({ url: 'pages/AgentTrace', params: { traceId: this.traceId } }))
      }
    }.width('100%').padding(12).backgroundColor('#FFFFFF').borderRadius(12)
  }
}
