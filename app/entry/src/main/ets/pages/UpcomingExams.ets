import { AIFloatButton } from '../components/AIFloatButton';
import { UiTheme } from '../utils/UiTheme';
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
    if (result.ok) this.courses = result.data.courses.slice().sort((a: CourseSetting, b: CourseSetting) => (a.examDate || '9999').localeCompare(b.examDate || '9999'));
    else this.notice = '考试信息读取失败，点击重试';
  }
  private review(course: CourseSetting): void {
    router.pushUrl({ url: 'pages/LearningReview', params: { courseName: course.courseName } });
  }
  build() {
    Stack() {
    Column() {
      PageHeader({ title: '学习目标与考试', assistant: true, detail: `${this.courses.length} 门` })
      List({ space: 12 }) {
        ListItem() { Button('添加课程', { type: ButtonType.Normal }).width('100%').height(44).fontColor(UiTheme.accent).backgroundColor(UiTheme.tint).onClick(() => router.pushUrl({ url: 'pages/LearningSetup', params: { newCourse: 'true' } })) }
        ListItem() { Text('添加课程时可设置学习目标和考试日期。已有课程可在列表中编辑。').fontSize(13).fontColor(UiTheme.secondary).width('100%') }
        if (this.loading) ListItem() { Text('正在读取考试安排…').fontSize(14).fontColor(UiTheme.secondary) }
        if (this.notice) ListItem() { Text(this.notice).fontSize(14).fontColor(UiTheme.secondary).padding(14).onClick(() => this.load()) }
        if (!this.loading && !this.notice && this.courses.length === 0) {
          ListItem() { Text('还没有课程目标，添加一门课程开始安排。').fontSize(14).fontColor(UiTheme.secondary).padding(14) }
        }
        ForEach(this.courses, (course: CourseSetting) => {
          ListItem() {
            Row({ space: 12 }) {
              Column({ space: 8 }) {
                Text(course.courseName).fontSize(16).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink)
                Text(course.goal || '尚未设置学习目标').fontSize(14).fontColor(UiTheme.ink)
                Text(course.examDate ? `${course.examDate} · ${UpcomingExamService.countdown(course)}` : '尚未设置考试日期')
                  .fontSize(13).fontColor(course.daysUntilExam === 0 ? UiTheme.danger : UiTheme.secondary)
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              Text('编辑 ›').fontSize(13).fontColor(UiTheme.accent).padding(8).onClick(() => router.pushUrl({ url: 'pages/LearningSetup', params: { courseName: course.courseName } }))
              Text('复习建议 ›').fontSize(13).fontColor(UiTheme.accent).padding(8).onClick(() => this.review(course))
            }.width('100%').padding(18).backgroundColor(UiTheme.surface).borderRadius(8)
          }
        }, (course: CourseSetting) => course.courseName)
      }.layoutWeight(1).width('100%').constraintSize({ maxWidth: UiTheme.contentWidth }).padding(20)
    }.width('100%').height('100%').backgroundColor(UiTheme.canvas)
    AIFloatButton()
    }.width('100%').height('100%')
  }
}
