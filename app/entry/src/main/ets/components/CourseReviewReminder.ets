import router from '@ohos.router';
import { AgentApiClient } from '../api/AgentApiClient';
import { CourseSetting } from '../api/LearningUpgradeModels';
import { appState } from '../data/AppState';
import { UpcomingExamService } from '../services/UpcomingExamService';

@Component
export struct CourseReviewReminder {
  @Prop @Watch('reload') revision: number = 0;
  @State due: CourseSetting[] = [];
  @State notice: string = '';
  private active: boolean = false;
  private requestVersion: number = 0;
  aboutToAppear(): void { this.active = true; void this.load(); }
  aboutToDisappear(): void { this.active = false; this.requestVersion++; }
  private reload(): void { if (this.active) void this.load(); }
  private async load(): Promise<void> {
    const owner: string = appState.currentUser.userId;
    const version: number = ++this.requestVersion;
    const result = await AgentApiClient.courseSettings();
    if (!this.active || version !== this.requestVersion || owner !== appState.currentUser.userId) return;
    this.due = result.ok ? UpcomingExamService.sorted(result.data.courses) : [];
    this.notice = result.ok ? '' : '考试信息暂未更新，点击重试';
  }
  private openExams(): void {
    router.pushUrl({ url: 'pages/UpcomingExams' });
  }
  build() {
    Column() {
      if (this.due.length > 0) {
        Row({ space: 10 }) {
          Column({ space: 4 }) {
            Text(`近期考试 ${this.due.length} 门`).fontSize(14).fontWeight(FontWeight.Medium).fontColor('#1F2937')
            Text(`最近：${this.due[0].courseName} · ${UpcomingExamService.countdown(this.due[0])}`)
              .fontSize(12).fontColor(this.due[0].daysUntilExam === 0 ? '#B42318' : '#667085').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Text('查看 ›').fontSize(13).fontColor('#2563EB')
        }.width('100%').padding(14).backgroundColor('#FFFFFF').borderRadius(14)
          .accessibilityText(`近期考试 ${this.due.length} 门，查看全部`).onClick(() => this.openExams())
      } else if (this.notice) {
        Text(this.notice).fontSize(12).fontColor('#667085').width('100%').padding(10).onClick(() => this.load())
      }
    }.width('100%')
  }
}
