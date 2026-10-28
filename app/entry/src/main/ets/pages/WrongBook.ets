import { PageHeader } from '../components/PageHeader';
import router from '@ohos.router';
import { ClientCache } from '../cache/ClientCache';
import { AgentApiClient } from '../api/AgentApiClient';
import { WrongBookAttemptResponse, WrongBookCourse, WrongBookItem, WrongBookResponse } from '../api/ApiModels';

@Entry
@Component
struct WrongBook {
  @State isLoading: boolean = true;
  @State errorMessage: string = '';
  @State courses: WrongBookCourse[] = [];
  @State total: number = 0;
  @State selectedCourse: string = '';
  @State preview: WrongBookItem | null = null;
  @State selectedPoint: string = '';
  private visibleCount(): number {
    if (this.practiceItem !== null) return this.practiceItems.length;
    const course: WrongBookCourse | undefined = this.courses.find((row: WrongBookCourse) => row.courseName === this.selectedCourse);
    if (!course) return this.total;
    return this.selectedPoint ? this.pointItems(course).length : course.items.length;
  }
  private visibleCourses(): WrongBookCourse[] {
    return this.selectedCourse ? this.courses.filter((course: WrongBookCourse) => course.courseName === this.selectedCourse) : this.courses;
  }
  private points(course: WrongBookCourse): string[] {
    const names: string[] = [];
    course.items.forEach((item: WrongBookItem) => {
      if (names.indexOf((item.knowledgeGroup || item.knowledgePointName)) < 0) names.push(item.knowledgeGroup || item.knowledgePointName);
    });
    return names;
  }
  private pointItems(course: WrongBookCourse): WrongBookItem[] {
    return course.items.filter((item: WrongBookItem) => (item.knowledgeGroup || item.knowledgePointName) === this.selectedPoint);
  }

  @State practiceItem: WrongBookItem | null = null;
  @State selectedAnswer: string = '';
  @State attempt: WrongBookAttemptResponse | null = null;
  @State isSubmitting: boolean = false;
  @State practiceItems: WrongBookItem[] = [];
  @State practiceIndex: number = 0;
  private requestVersion: number = 0;
  private isPageActive: boolean = false;
  /** 首帧的 onPageShow 与 aboutToAppear 属于同一次进入。 */
  private hasShownOnce: boolean = false;

  aboutToAppear(): void {
    this.isPageActive = true;
    void this.load();
  }

  aboutToDisappear(): void {
    this.isPageActive = false;
    this.requestVersion++;
    this.isLoading = false;
    this.isSubmitting = false;
  }

  onPageShow(): void {
    this.isPageActive = true;
    if (!this.hasShownOnce) {
      this.hasShownOnce = true;
      return;
    }
    // 逐题解析或练习页可能刚把题加入/移出错题本，返回后必须重新对账。
    if (this.practiceItem === null) {
      void this.load();
    }
  }

  onPageHide(): void {
    this.isPageActive = false;
    this.requestVersion++;
    this.isLoading = false;
    this.isSubmitting = false;
  }

  private async load(): Promise<void> {
    this.isLoading = true;
    this.errorMessage = '';
    const requestVersion: number = ++this.requestVersion;
    const owner: string = ClientCache.currentOwnerUserId();
    const result = await AgentApiClient.getWrongBook();
    if (!this.isPageActive || requestVersion !== this.requestVersion || owner !== ClientCache.currentOwnerUserId()) {
      return;
    }
    this.isLoading = false;
    if (!result.ok) {
      this.errorMessage = '错题本读取失败，请稍后重试。';
      return;
    }
    const data: WrongBookResponse = result.data;
    this.courses = data.courses;
    this.total = data.total;
  }

  private startPractice(item: WrongBookItem): void {
    const course: WrongBookCourse | undefined = this.courses.find((value: WrongBookCourse): boolean =>
      value.courseName === item.courseName);
    const items: WrongBookItem[] = course !== undefined ? course.items.filter((value: WrongBookItem) => (value.knowledgeGroup || value.knowledgePointName) === (item.knowledgeGroup || item.knowledgePointName) && value.options.length > 0) : [item];
    const startIndex: number = items.findIndex((value: WrongBookItem): boolean =>
      value.exerciseId === item.exerciseId);
    // 从用户点中的题开始，练到末尾后再接上前面的题，确保这一轮覆盖整个科目。
    this.practiceItems = startIndex > 0
      ? items.slice(startIndex).concat(items.slice(0, startIndex)) : items.slice();
    if (this.practiceItems.length === 0) return;
    this.practiceIndex = 0;
    this.practiceItem = this.practiceItems[0];
    this.selectedAnswer = '';
    this.attempt = null;
  }

  private leavePractice(): void {
    this.practiceItem = null;
    this.practiceItems = [];
    this.practiceIndex = 0;
    this.selectedAnswer = '';
    this.attempt = null;
  }

  private continuePractice(): void {
    const nextIndex: number = this.practiceIndex + 1;
    if (nextIndex >= this.practiceItems.length) {
      this.leavePractice();
      return;
    }
    this.practiceIndex = nextIndex;
    this.practiceItem = this.practiceItems[nextIndex];
    this.selectedAnswer = '';
    this.attempt = null;
    this.errorMessage = '';
  }

  private async submitAttempt(): Promise<void> {
    if (this.practiceItem === null || this.selectedAnswer.length === 0 || this.isSubmitting) return;
    this.isSubmitting = true;
    const owner: string = ClientCache.currentOwnerUserId();
    const requestVersion: number = this.requestVersion;
    const result = await AgentApiClient.attemptWrongBook(this.practiceItem.exerciseId, this.selectedAnswer);
    if (!this.isPageActive || requestVersion !== this.requestVersion || owner !== ClientCache.currentOwnerUserId()) return;
    this.isSubmitting = false;
    if (!result.ok) {
      this.errorMessage = '本次作答提交失败，请重试。';
      return;
    }
    this.attempt = result.data;
    if (result.data.removed) await this.load();
  }

  private async removeItem(item: WrongBookItem): Promise<void> {
    const owner: string = ClientCache.currentOwnerUserId();
    const requestVersion: number = this.requestVersion;
    const result = await AgentApiClient.toggleWrongBook(item.exerciseId, false);
    if (!this.isPageActive || requestVersion !== this.requestVersion || owner !== ClientCache.currentOwnerUserId()) return;
    if (result.ok) {
      if (this.practiceItem?.exerciseId === item.exerciseId) this.practiceItem = null;
      await this.load();
    }
  }

  @Builder
  PracticePanel(item: WrongBookItem) {
    Column({ space: 12 }) {
      Row() {
        Text(`${item.courseName} · 第 ${this.practiceIndex + 1}/${this.practiceItems.length} 题`)
          .fontSize(13).fontColor('#2563EB')
        Blank()
        Text('返回题目列表').fontSize(13).fontColor('#64748B').onClick(() => this.leavePractice())
      }.width('100%')
      Text(item.stem).fontSize(17).fontWeight(FontWeight.Medium).fontColor('#1F2937').lineHeight(24)
      ForEach(item.options, (option: string) => {
        Button(option).width('100%').height(42).fontSize(14)
          .fontColor(this.selectedAnswer === option.substring(0, 1) ? '#FFFFFF' : '#344054')
          .backgroundColor(this.selectedAnswer === option.substring(0, 1) ? '#2563EB' : '#F8FAFC')
          .border({ width: 1, color: '#D0D5DD' }).borderRadius(10)
          .enabled(this.attempt === null)
          .onClick(() => this.selectedAnswer = option.substring(0, 1))
      }, (option: string) => option)
      if (this.attempt !== null) {
        Text(this.attempt.correct ? '回答正确' : `回答错误，正确答案：${this.attempt.correctAnswer}`)
          .fontSize(15).fontWeight(FontWeight.Bold)
          .fontColor(this.attempt.correct ? '#0F766E' : '#DC2626').width('100%')
        Text(this.attempt.explanation).fontSize(14).fontColor('#475467').lineHeight(21).width('100%')
        Text(this.attempt.removed ? '已累计答对 3 次，自动移出错题本。'
          : `已答对 ${this.attempt.correctCount} / 3 次。`)
          .fontSize(13).fontColor('#2563EB').width('100%')
        Button(this.practiceIndex + 1 < this.practiceItems.length ? '继续下一题' : '完成本知识点刷题，返回列表')
          .width('100%').height(42).fontSize(14).fontColor('#FFFFFF')
          .backgroundColor('#2563EB').borderRadius(10)
          .onClick(() => this.continuePractice())
      } else {
        Button(this.isSubmitting ? '提交中…' : '提交答案').width('100%').height(44)
          .fontSize(15).fontColor('#FFFFFF').backgroundColor('#2563EB').borderRadius(10)
          .enabled(this.selectedAnswer.length > 0 && !this.isSubmitting)
          .onClick(() => this.submitAttempt())
      }
    }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(16)
      .border({ width: 1, color: '#BFDBFE' })
  }

  build() {
    Column() {
      PageHeader({ title: this.selectedPoint || this.selectedCourse || '错题本', detail: this.practiceItem !== null ? `${this.practiceIndex + 1}/${this.practiceItems.length} 题` : `${this.visibleCount()} 题`, onBack: () => {
        if (this.practiceItem !== null) this.leavePractice();
        else if (this.preview !== null) this.preview = null;
        else if (this.selectedPoint) this.selectedPoint = '';
        else if (this.selectedCourse) this.selectedCourse = '';
        else router.back();
      } })
      Scroll() {
        Column({ space: 14 }) {
          Text('按课程整理；在这里刷对同一道题 3 次后，系统会自动移出。')
            .fontSize(13).fontColor('#667085').lineHeight(20).width('100%')
          if (this.isLoading) {
            LoadingProgress().width(34).height(34).margin({ top: 48 })
          } else if (this.errorMessage.length > 0) {
            Text(this.errorMessage).fontSize(14).fontColor('#B42318')
          } else if (this.practiceItem !== null) {
            // 最后一题答对并被自动移除后 total 会立刻变成 0，仍要保留本题反馈与
            // “完成本学科”按钮；用户主动返回列表后再展示空状态。
            this.PracticePanel(this.practiceItem)
          } else if (this.preview !== null) {
            Text(this.preview.stem).fontSize(17)
            Text('拍照收藏题 · 答案尚待核对，不进行自动判分').fontSize(12).fontColor('#64748B')
            Text(this.preview.explanation).fontSize(15)
            Button('返回知识点题目').onClick(() => this.preview = null)
            Button('选择知识点练习同类题').onClick(() => router.pushUrl({ url: 'pages/ExercisePractice', params: { courseName: this.preview?.courseName || '', knowledgePointId: this.preview?.knowledgePointId || '' } }))
          } else if (this.total === 0) {
            Column({ space: 10 }) {
              Text('错题本还是空的').fontSize(18).fontWeight(FontWeight.Bold)
              Text('练习中答错的题会自动出现在这里，也可以在逐题解析页手动添加。')
                .fontSize(13).fontColor('#667085').lineHeight(20).textAlign(TextAlign.Center)
            }.width('100%').padding(32).alignItems(HorizontalAlign.Center)
          } else {
            if (!this.selectedCourse) {
              ForEach(this.courses, (course: WrongBookCourse) => {
                Row({ space: 12 }) {
                  Column({ space: 6 }) {
                    Text(course.courseName).fontSize(17).fontWeight(FontWeight.Medium).fontColor('#182230')
                    Text(`${this.points(course).length} 个知识点 · ${course.items.length} 道题`).fontSize(13).fontColor('#667085')
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Text('›').fontSize(24).fontColor('#98A2B3')
                }.width('100%').padding(20).backgroundColor('#FFFFFF').borderRadius(12)
                  .onClick(() => { this.selectedCourse = course.courseName; this.selectedPoint = ''; })
              }, (course: WrongBookCourse) => course.courseName)
            } else {
              ForEach(this.visibleCourses(), (course: WrongBookCourse) => {
                if (!this.selectedPoint) {
                  ForEach(this.points(course), (point: string) => {
                    Row() {
                      Text(point).fontSize(16).fontColor('#344054').layoutWeight(1)
                      Text(`${course.items.filter((item: WrongBookItem) => (item.knowledgeGroup || item.knowledgePointName) === point).length} 题  ›`)
                        .fontSize(13).fontColor('#98A2B3')
                    }.width('100%').padding(20).backgroundColor('#FFFFFF').borderRadius(12)
                      .onClick(() => this.selectedPoint = point)
                  }, (point: string) => point)
                } else {
                  ForEach(this.pointItems(course), (item: WrongBookItem) => {
                    Column({ space: 12 }) {
                      Text(item.stem).fontSize(16).fontColor('#344054').maxLines(3).width('100%')
                      Row() {
                        Text(`已答对 ${item.correctCount}/3 次`).fontSize(12).fontColor('#98A2B3').layoutWeight(1)
                        Button(item.options.length ? '开始刷题' : '查看题目', { type: ButtonType.Normal }).height(34).fontSize(13).fontColor('#FFFFFF').backgroundColor('#2563EB').borderRadius(8)
                          .onClick(() => { if (item.options.length) this.startPractice(item); else this.preview = item; })
                        Text('移除').fontSize(13).fontColor('#98A2B3').padding({ left: 18 }).onClick(() => this.removeItem(item))
                      }.width('100%')
                    }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(12)
                  }, (item: WrongBookItem) => item.exerciseId)
                }
              }, (course: WrongBookCourse) => course.courseName)
            }
          }
        }.width('100%').padding({ left: 16, right: 16, top: 16, bottom: 40 })
      }.align(Alignment.TopStart).layoutWeight(1).backgroundColor('#F5F6F8')
    }.width('100%').height('100%')
  }
}
