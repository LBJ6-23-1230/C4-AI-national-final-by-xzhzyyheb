import router from '@ohos.router';
import { AgentApiClient } from '../api/AgentApiClient';
import { CourseSetting } from '../api/LearningUpgradeModels';
import { PageHeader } from '../components/PageHeader';
import { appState } from '../data/AppState';
import { UpcomingExamService } from '../services/UpcomingExamService';

@Entry
@Component
struct UpcomingExams {
  @State courses: CourseSetting[] = [];
  @State loading: boolean = false;
  @State notice: string = '';
  private active: boolean = false;
  private requestVersion: number = 0;
  aboutToAppear(): void { this.active = true; void this.load(); }
  onPageShow(): void { this.active = true; if (!this.loading) void this.load(); }
  aboutToDisappear(): void { this.active = false; this.requestVersion++; }
  private async load(): Promise<void> {
    const owner: string = appState.currentUser.userId;
    const version: number = ++this.requestVersion;
    this.loading = true; this.notice = ''; this.courses = [];
    const result = await AgentApiClient.courseSettings();
    if (!this.active || version !== this.requestVersion || owner !== appState.currentUser.userId) return;
    this.loading = false;
    if (result.ok) this.courses = UpcomingExamService.sorted(result.data.courses);
    else this.notice = '考试信息读取失败，点击重试';
  }
  private review(course: CourseSetting): void {
    router.pushUrl({ url: 'pages/LearningReview', params: { courseName: course.courseName } });
  }
  build() {
    Column() {
      PageHeader({ title: '近期考试', detail: `${this.courses.length} 门` })
      List({ space: 12 }) {
        ListItem() { Text('未来14天的考试，按日期由近到远排列。').fontSize(13).fontColor('#667085').width('100%') }
        if (this.loading) ListItem() { Text('正在读取考试安排…').fontSize(14).fontColor('#667085') }
        if (this.notice) ListItem() { Text(this.notice).fontSize(14).fontColor('#667085').padding(14).onClick(() => this.load()) }
        if (!this.loading && !this.notice && this.courses.length === 0) {
          ListItem() { Text('未来14天暂无已安排的考试。').fontSize(14).fontColor('#667085').padding(14) }
        }
        ForEach(this.courses, (course: CourseSetting) => {
          ListItem() {
            Row({ space: 12 }) {
              Column({ space: 8 }) {
                Text(course.courseName).fontSize(16).fontWeight(FontWeight.Medium).fontColor('#1F2937')
                Text(`${course.examDate} · ${UpcomingExamService.countdown(course)}`)
                  .fontSize(13).fontColor(course.daysUntilExam === 0 ? '#B42318' : '#667085')
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              Text('考前建议 ›').fontSize(13).fontColor('#2563EB')
            }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(14).onClick(() => this.review(course))
          }
        }, (course: CourseSetting) => course.courseName)
        ListItem() {
          Button('管理课程与考试日期').width('100%').backgroundColor('#EFF6FF').fontColor('#2563EB')
            .onClick(() => router.pushUrl({ url: 'pages/LearningSetup' }))
        }
      }.layoutWeight(1).width('100%').padding(20)
    }.width('100%').height('100%').backgroundColor('#F5F6F8')
  }
}
