import { PageHeader } from '../components/PageHeader';
import router from '@ohos.router';
import { AgentApiClient } from '../api/AgentApiClient';
import { CourseSetting } from '../api/LearningUpgradeModels';
import { appState } from '../data/AppState';

@Entry
@Component
struct LearningSetup {
  @State settings: CourseSetting[] = [];
  @State course: string = '';
  @State goal: string = '';
  @State exam: string = '';
  @State message: string = '';
  @State saved: boolean = false;
  @State addingCourse: boolean = false;
  @State busy: boolean = false;
  private owner: string = '';
  private active: boolean = false;
  aboutToAppear(): void { this.active = true; this.owner = appState.currentUser.userId; const params = router.getParams() as Record<string, string>; this.addingCourse = params['newCourse'] === 'true'; void this.load(); }
  aboutToDisappear(): void { this.active = false; }
  private async load(): Promise<void> {
    const result = await AgentApiClient.courseSettings();
    if (!this.active || this.owner !== appState.currentUser.userId) return;
    if (result.ok) {
      this.settings = result.data.courses;
      const params = router.getParams() as Record<string, string>;
      const chosen: CourseSetting | undefined = this.settings.find((item: CourseSetting) => item.courseName === params['courseName']);
      if (!this.addingCourse && this.settings.length) this.select(chosen || this.settings[0]);
    } else this.message = '读取失败，请返回重试。';
  }
  private select(item: CourseSetting): void {
    this.addingCourse = false;
    this.course = item.courseName; this.goal = item.goal; this.exam = item.examDate; this.saved = false;
  }
  private async save(): Promise<void> {
    if (this.busy || !this.course.trim()) return;
    this.busy = true;
    const result = await AgentApiClient.saveCourseSettings({ courseName: this.course, goal: this.goal, examDate: this.exam });
    if (!this.active || this.owner !== appState.currentUser.userId) return;
    this.busy = false;
    if (result.ok) { this.settings = result.data.courses; this.saved = true; this.addingCourse = false; this.message = '已保存，可继续补充资料或开始诊断。'; }
    else this.message = '保存失败，请检查日期格式 YYYY-MM-DD 后重试。';
  }
  private pickDate(): void {
    // Date input stays in the form so this page does not depend on device-specific picker behavior.
    this.message = '请在考试日期输入框填写 YYYY-MM-DD。';
  }
  build() {
    Column() {
      PageHeader({ title: '确认学习目标', detail: '第 2 步 / 共 3 步' })
      Row({ space: 12 }) {
        Text('1  导入课程').fontSize(13).fontColor('#98A2B3')
        Text('→').fontColor('#98A2B3')
        Text('2  确认目标').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#2563EB')
        Text('→').fontColor('#98A2B3')
        Text('3  补充资料').fontSize(13).fontColor(this.saved ? '#2563EB' : '#98A2B3')
      }.width('100%').padding(16).backgroundColor('#EFF6FF')
      Scroll() {
        Column({ space: 18 }) {
          Text('学习课程').fontSize(14).fontColor('#667085')
          TextInput({ placeholder: '课程名称，例如：数据结构', text: this.course })
            .backgroundColor('#FFFFFF').borderRadius(10).onChange((v: string) => { this.course = v; this.saved = false; })
          if (this.settings.length && !this.addingCourse) {
            Text('已有课程：' + this.settings.map((item: CourseSetting) => item.courseName).join('、'))
              .fontSize(12).fontColor('#98A2B3').lineHeight(19).width('100%')
          }
          Text('本课程的学习目标').fontSize(14).fontColor('#667085')
          TextInput({ placeholder: '例如：掌握核心概念，完成期末复习', text: this.goal }).maxLength(200)
            .backgroundColor('#FFFFFF').borderRadius(10).onChange((v: string) => { this.goal = v; this.saved = false; })
          Text('考试日期（可选）').fontSize(14).fontColor('#667085')
          TextInput({ placeholder: '考试日期 YYYY-MM-DD（可选）', text: this.exam })
            .backgroundColor('#FFFFFF').borderRadius(10).onChange((v: string) => { this.exam = v; this.saved = false; })
          Text('作业截止时间在课程与作业中管理，考试日期用于安排考前复习。').fontSize(12).fontColor('#98A2B3').lineHeight(20)
          Button(this.busy ? '正在保存…' : this.saved ? '已保存' : '保存并继续', { type: ButtonType.Normal })
            .width('100%').height(44).backgroundColor('#2563EB').fontColor('#FFFFFF').borderRadius(10).enabled(!this.busy).onClick(() => this.save())
          if (this.message) { Text(this.message).fontSize(13).fontColor('#667085') }
          if (this.saved) {
            Text('✓ 目标已保存 · 第 3 步：补充资料').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#2563EB')
            Text('可稍后补充，知识库也可从学习页随时进入。').fontSize(13).fontColor('#98A2B3')
            this.MaterialRow('课程讲义与笔记', 'pages/KnowledgeBase')
            this.MaterialRow('拍照分析题目', 'pages/WrongQuestion')
            this.MaterialRow('暂不补充，开始练习', 'pages/ExercisePractice')
          }
        }.width('100%').padding(20).alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Start)
      }.align(Alignment.TopStart).layoutWeight(1).width('100%')
    }.width('100%').height('100%').backgroundColor('#F5F6F8')
  }
  @Builder
  MaterialRow(title: string, page: string) {
    Row() {
      Text(title).fontSize(15).fontColor('#344054').layoutWeight(1)
      Text('›').fontSize(22).fontColor('#98A2B3')
    }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(10)
      .onClick(() => router.pushUrl({ url: page, params: { courseName: this.course } }))
  }
}
