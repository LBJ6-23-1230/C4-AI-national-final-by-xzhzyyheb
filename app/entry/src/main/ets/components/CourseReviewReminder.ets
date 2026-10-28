import router from '@ohos.router';
import { AgentApiClient } from '../api/AgentApiClient';
import { CourseSetting } from '../api/LearningUpgradeModels';
import { appState } from '../data/AppState';

@Component
export struct CourseReviewReminder {
  @State due: CourseSetting[] = [];
  private active: boolean = false;
  aboutToAppear(): void { this.active = true; void this.load(); }
  aboutToDisappear(): void { this.active = false; }
  private async load(): Promise<void> {
    const owner: string = appState.currentUser.userId;
    const result = await AgentApiClient.courseSettings();
    if (!this.active || owner !== appState.currentUser.userId) return;
    if (result.ok) this.due = result.data.courses.filter((item: CourseSetting) => item.reviewDue);
  }
  build() {
    Column({ space: 8 }) {
      ForEach(this.due, (item: CourseSetting) => {
        Column({ space: 6 }) {
          Text(`${item.courseName} · 距考试 ${item.daysUntilExam} 天`).fontSize(16).fontWeight(FontWeight.Bold)
          Text('结合近期测评与错题，确认接下来的复习重点。').fontSize(12).fontColor('#64748B')
          Text('查看考前建议 ›').fontSize(13).fontColor('#667085').padding(8).onClick(() => router.pushUrl({ url: 'pages/LearningReview', params: { courseName: item.courseName } }))
        }.width('100%').padding(14).backgroundColor('#FFFFFF').borderRadius(14)
      }, (item: CourseSetting) => item.courseName)
    }.width('100%')
  }
}
