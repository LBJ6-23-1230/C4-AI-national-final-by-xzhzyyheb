import { PageHeader } from '../components/PageHeader';
import { ApiFailure } from '../api/ApiResult';
import router from '@ohos.router';
import { AgentApiClient } from '../api/AgentApiClient';
import { KnowledgeMastery } from '../api/ApiModels';
import { LearningReview, ReviewTask } from '../api/LearningUpgradeModels';
import { appState } from '../data/AppState';

@Entry
@Component
struct LearningReviewPage {
  @State courses: string[] = [];
  @State course: string = '';
  @State review: LearningReview | null = null;
  @State tasks: ReviewTask[] = [];
  @State busy: boolean = false;
  @State notice: string = '';
  private active: boolean = false;
  private owner: string = '';
  aboutToAppear(): void { this.active = true; this.owner = appState.currentUser.userId; void this.load(); }
  private shown: boolean = false;
  onPageShow(): void { if (this.shown) void this.load(); else this.shown = true; }
  aboutToDisappear(): void { this.active = false; }
  private ownsPage(): boolean { return this.active && this.owner === appState.currentUser.userId; }
  private async load(): Promise<void> {
    const profile = await AgentApiClient.getProfile(this.owner);
    if (!this.ownsPage()) return;
    if (profile.ok) {
      const names: string[] = [];
      profile.data.mastery.forEach((p: KnowledgeMastery) => {
        const name: string = (p.sourceCourse || '').trim(); if (name && names.indexOf(name) < 0) names.push(name);
      });
      this.courses = names; if (!this.course || names.indexOf(this.course) < 0) this.course = names[0] || '';
    } else this.notice = '课程读取失败，请返回后重试。';
    const settings = await AgentApiClient.courseSettings();
    if (this.ownsPage() && settings.ok) {
      settings.data.courses.forEach((item) => {
        if (item.courseName.trim() && this.courses.indexOf(item.courseName) < 0) this.courses = this.courses.concat([item.courseName]);
        if (item.reviewDue) this.notice = this.notice + item.courseName + '距考试 ' + item.daysUntilExam + ' 天，建议进行考前复盘。';
      });
      if (!this.course) this.course = this.courses[0] || '';
    }
    const params = router.getParams() as Record<string, string>;
    if (params && params['courseName'] && this.courses.indexOf(params['courseName']) >= 0) this.course = params['courseName'];
    const tasks = await AgentApiClient.reviewTasks();
    if (this.ownsPage() && tasks.ok) this.tasks = tasks.data.tasks;
  }
  private async generate(): Promise<void> {
    if (this.busy || !this.course) return;
    this.busy = true; this.notice = '正在整理本课程的学习证据…';
    const result = await AgentApiClient.learningReview({ courseName: this.course });
    if (!this.ownsPage()) return;
    this.busy = false;
    if (result.ok) { this.review = result.data; this.notice = ''; }
    else this.notice = (result as ApiFailure).error.statusCode === 404 ? '建议服务未更新，请重启最新后端后重试。' : '暂未生成建议：' + (result as ApiFailure).error.message;
  }
  private async accept(): Promise<void> {
    if (this.review === null || this.busy) return;
    this.busy = true;
    const result = await AgentApiClient.acceptLearningReview(this.review.reviewId);
    if (!this.ownsPage()) return;
    this.busy = false;
    if (result.ok) { this.tasks = result.data.tasks; this.notice = '已加入下方行动清单。'; }
    else this.notice = '加入失败，请重试。';
  }
  private async complete(task: ReviewTask): Promise<void> {
    const result = await AgentApiClient.completeReviewTask({ taskId: task.taskId });
    if (this.ownsPage() && result.ok) this.tasks = result.data.tasks;
  }
  build() {
    Column() {
      PageHeader({ title: '阶段复盘与考前建议' })
      Scroll() {
        Column({ space: 20 }) {
          Text('选择课程').fontSize(13).fontColor('#667085')
          if (this.courses.length) {
            Select(this.courses.map((name: string): SelectOption => { return { value: name }; }).concat([{ value: '＋添加课程' }]))
              .value(this.course).width('100%').fontColor('#344054').backgroundColor('#FFFFFF')
              .onSelect((index: number) => { if (!this.busy) { if (index === this.courses.length) router.pushUrl({ url: 'pages/LearningSetup', params: { newCourse: 'true' } }); else { this.course = this.courses[index]; this.review = null; this.notice = ''; } } })
          } else { Text('＋添加课程').fontSize(14).fontColor('#2563EB').onClick(() => router.pushUrl({ url: 'pages/LearningSetup', params: { newCourse: 'true' } })) }
          Text('结合已完成的练习、错题及考试日期，整理下一步复习重点。').fontSize(14).fontColor('#667085').lineHeight(22)
          Button(this.busy ? '正在整理学习记录…' : '生成本课程建议', { type: ButtonType.Normal })
            .width('100%').height(44).borderRadius(10).backgroundColor('#2563EB').fontColor('#FFFFFF')
            .enabled(!this.busy && !!this.course).onClick(() => this.generate())
          if (this.notice) { Text(this.notice).fontSize(13).fontColor('#667085').lineHeight(21).width('100%') }
          if (this.review !== null) {
            Column({ space: 14 }) {
              Text('本阶段建议').fontSize(18).fontWeight(FontWeight.Medium).width('100%')
              Text(this.review.summary).fontSize(15).lineHeight(25).fontColor('#344054').width('100%')
              ForEach(this.review.actions, (action: string) => { Text('• ' + action).fontSize(14).fontColor('#475467').width('100%') }, (action: string) => action)
              Text(this.review.source === 'model' ? '结合学习记录生成' : '基础建议 · 可继续练习补充测评记录').fontSize(12).fontColor('#98A2B3')
              Text('采纳建议，加入复习清单 ›').fontSize(14).fontColor('#475467').padding({ top: 8, bottom: 8 }).onClick(() => this.accept())
            }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(12).alignItems(HorizontalAlign.Start)
          }
          Text('复习清单').fontSize(18).fontWeight(FontWeight.Medium)
          if (!this.tasks.length) { Text('采纳建议后，复习行动会保存在这里。').fontSize(14).fontColor('#98A2B3') }
          ForEach(this.tasks.filter((task: ReviewTask) => task.courseName === this.course), (task: ReviewTask) => {
            Column({ space: 12 }) {
              Text(task.title).fontSize(15).fontColor('#344054').width('100%')
              if (task.status === 'completed') { Text('已记录完成，可通过练习验证掌握情况').fontSize(12).fontColor('#98A2B3') }
              else {
                Row() {
                  Text(task.actionType === 'settings' || task.title.indexOf('确认考试日期') >= 0 ? '完善设置 ›' : '开始练习 ›').fontSize(14).fontColor('#2563EB').onClick(() => router.pushUrl({ url: task.actionType === 'settings' || task.title.indexOf('确认考试日期') >= 0 ? 'pages/LearningSetup' : 'pages/ExercisePractice', params: { knowledgePointId: task.knowledgePointId, courseName: task.courseName } }))
                  Blank()
                  Text('标记完成').fontSize(13).fontColor('#667085').onClick(() => this.complete(task))
                }.width('100%')
              }
            }.padding(18).width('100%').backgroundColor('#FFFFFF').borderRadius(12).alignItems(HorizontalAlign.Start)
          }, (task: ReviewTask) => task.taskId)
          Text('查看知识画像 ›').fontSize(14).fontColor('#667085').onClick(() => router.pushUrl({ url: 'pages/StudyTags' }))
        }.width('100%').padding(20).alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Start)
      }.align(Alignment.TopStart).layoutWeight(1).width('100%')
    }.width('100%').height('100%').backgroundColor('#F5F6F8')
  }
}
