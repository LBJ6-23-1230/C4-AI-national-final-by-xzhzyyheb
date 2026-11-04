import { AIFloatButton } from '../components/AIFloatButton';
import { UiTheme } from '../utils/UiTheme';
import { PageHeader } from '../components/PageHeader';
import { ApiDisplayFormatter } from '../utils/ApiDisplayFormatter';
import router from '@ohos.router';
import { appState } from '../data/AppState';
import { FocusSession, FocusSummary } from '../models/AgentModels';

@Entry
@Component
struct LearningHistory {
  @State summary: FocusSummary = appState.getFocusSummary();
  @StorageLink('focusDataRevision') @Watch('refreshSummary') focusDataRevision: number = 0;
  @StorageLink('focusSyncMessage') focusSyncMessage: string = '';
  /** 首次进入由 aboutToAppear 加载；返回本页时再同步，避免首帧重复请求。 */
  private hasShownOnce: boolean = false;

  aboutToAppear(): void {
    this.refreshSummary();
    void appState.syncFocusSessions();
  }

  onPageShow(): void {
    if (!this.hasShownOnce) {
      this.hasShownOnce = true;
      return;
    }
    // 从专注或结算页返回时，先展示本地事实，再补拉服务端记录。
    this.refreshSummary();
    void appState.syncFocusSessions();
  }

  private refreshSummary(): void {
    this.summary = appState.getFocusSummary();
  }

  build() {
    Stack() {
    Column() {
      PageHeader({ title: '专注记录', assistant: true, onBack: () => { router.back(); } })
      Scroll() {
        Column({ space: 16 }) {
          Text('专注投入的记录与统计，用于追踪投入时长；与作答验证和学习目标记录分别展示。').fontSize(12).fontColor(UiTheme.secondary).lineHeight(20).width('100%')
          if (this.focusSyncMessage.length > 0) {
            Text(this.focusSyncMessage).fontSize(12).fontColor(UiTheme.secondary).width('100%')
          }
          Row({ space: 10 }) { this.Metric(`${this.summary.todayMinutes}`, '今日分钟'); this.Metric(`${this.summary.recentSessions.length}`, '近期记录'); this.Metric(`${this.summary.streakDays}`, '连续天数') }.width('100%')
          Column({ space: 10 }) {
            Text('课程时长').fontSize(16).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
            if (this.summary.courseMinutes.size === 0) Text('完成一次专注后，这里会记下你的投入。').fontSize(13).fontColor(UiTheme.secondary)
            ForEach(Array.from(this.summary.courseMinutes.entries()), (item: [string, number]) => {
              Row() { Text(item[0]).fontSize(15).fontColor(UiTheme.ink); Blank(); Text(`${item[1]} 分钟`).fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiTheme.accent) }
                .width('100%').padding({ top: 12, bottom: 12 }).border({ width: { bottom: 1 }, color: UiTheme.line })
            }, (item: [string, number]) => item[0])
          }.width('100%').padding({ top: 16, bottom: 16 }).backgroundColor(UiTheme.surface).border({ width: { bottom: 1 }, color: UiTheme.line })
          Column({ space: 10 }) {
            Text('最近专注').fontSize(16).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
            if (this.summary.recentSessions.length === 0) Text('还没有记录。先从 25 分钟开始就很好。').fontSize(13).fontColor(UiTheme.secondary)
            ForEach(this.summary.recentSessions, (session: FocusSession) => {
              Column({ space: 8 }) {
                Text(session.task).fontSize(15).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
                Text(`${session.course} · 实际 ${session.actualMinutes} 分钟${session.plannedMinutes > 0 ? ' / 计划 ' + session.plannedMinutes + '分钟' : ' · 正计时'}`).fontSize(13).fontColor(UiTheme.secondary).width('100%')
                Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
                  Text(`自评：${session.selfAssessment === 'completed' ? '完成' : session.selfAssessment === 'partial' ? '部分完成' : '未完成'}`).fontSize(12).fontColor(UiTheme.secondary)
                  Text(ApiDisplayFormatter.timestamp(session.endedAt)).fontSize(12).fontColor(UiTheme.secondary)
                }.width('100%')
              }
                .width('100%').padding({ top: 12, bottom: 12 }).border({ width: { bottom: 1 }, color: UiTheme.line })
            }, (session: FocusSession) => session.taskId)
          }.width('100%').padding({ top: 16, bottom: 16 }).backgroundColor(UiTheme.surface).border({ width: { bottom: 1 }, color: UiTheme.line })
          Button('开始一次专注').width('100%').height(52).fontColor(UiTheme.surface).fontWeight(FontWeight.Bold).backgroundColor(UiTheme.accent).borderRadius(8).onClick(() => router.pushUrl({ url: 'pages/FocusSetup' }))
        }.width('100%').padding(20)
      }.layoutWeight(1).align(Alignment.TopStart)
    }.width('100%').height('100%').backgroundColor(UiTheme.surface)
      AIFloatButton()
    }.width('100%').height('100%')
  }

  @Builder
  Metric(value: string, label: string) { Column({ space: 4 }) { Text(value).fontSize(20).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink); Text(label).fontSize(11).fontColor(UiTheme.secondary) }.layoutWeight(1).alignItems(HorizontalAlign.Center).padding(12).backgroundColor(UiTheme.subtle).borderRadius(8) }
}
