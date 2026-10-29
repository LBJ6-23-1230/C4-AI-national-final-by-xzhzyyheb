import { appState } from '../data/AppState';
import { CourseInfo } from '../models/AgentModels';
import { ApiFailure } from '../api/ApiResult';
import { ActionButton } from '../components/ActionButton';
import { PageHeader } from '../components/PageHeader';
import router from '@ohos.router';
import { ClientCache } from '../cache/ClientCache';
import { AgentApiClient } from '../api/AgentApiClient';
import { WrongBookAttemptResponse, WrongBookCourse, WrongBookItem, WrongBookResponse } from '../api/ApiModels';

@Entry
@Component
struct WrongBook {
  @State assigningIds: string[] = [];
  @State assignmentCourse: string = '';
  @State assignmentMessage: string = '';
  @State assignmentSaving: boolean = false;
  private assignmentChoices(): string[] {
    const names: string[] = this.courses.map((c: WrongBookCourse) => c.courseName);
    appState.courses.forEach((c: CourseInfo) => { if (names.indexOf(c.courseName) < 0) names.push(c.courseName); });
    return names.filter((name: string) => ['待确认科目', '待分类', '其他', ''].indexOf(name) < 0);
  }
  private beginAssignment(items: WrongBookItem[]): void {
    this.assigningIds = items.map((item: WrongBookItem) => item.exerciseId).slice(0, 100);
    this.assignmentCourse = ''; this.assignmentMessage = '';
  }
  private async assignCourse(): Promise<void> {
    if (this.assignmentSaving || !this.assigningIds.length || !this.assignmentCourse.trim()) return;
    if (AgentApiClient.getConfig().useFixture) {
      this.assignmentMessage = '修改科目需要连接服务，请先切换到在线模式。';
      return;
    }
    this.assignmentSaving = true;
    const owner: string = ClientCache.currentOwnerUserId();
    const version: number = this.requestVersion;
    const result = await AgentApiClient.classifyWrongBook(this.assigningIds, this.assignmentCourse.trim());
    if (!this.isPageActive || version !== this.requestVersion || owner !== ClientCache.currentOwnerUserId()) return;
    this.assignmentSaving = false;
    if (!result.ok) { this.assignmentMessage = (result as ApiFailure).error.message; return; }
    this.assigningIds = []; this.selectedCourse = result.data.courseName; this.selectedPoint = '';
    this.preview = null; this.assignmentMessage = `已归入「${result.data.courseName}」，共 ${result.data.updatedCount} 道题。`;
    await this.load();
  }

  @Builder
  AssignmentPanel() {
    Column({ space: 12 }) {
      Text(`为 ${this.assigningIds.length} 道题选择科目`).fontSize(17).fontWeight(FontWeight.Bold).width('100%')
      Text('可选已有科目，也可输入新科目名称。仅修改所选题目的归属，作答记录保持不变。').fontSize(13).fontColor('#667085').width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.assignmentChoices(), (name: string) => {
          Button(name).fontSize(13).margin(4).enabled(!this.assignmentSaving)
            .fontColor(this.assignmentCourse === name ? '#FFFFFF' : '#2563EB')
            .backgroundColor(this.assignmentCourse === name ? '#2563EB' : '#EFF6FF')
            .onClick(() => this.assignmentCourse = name)
        }, (name: string) => name)
      }.width('100%')
      TextInput({ text: this.assignmentCourse, placeholder: '选择已有科目或输入新科目' }).maxLength(30)
        .enabled(!this.assignmentSaving).onChange((value: string) => this.assignmentCourse = value)
      ActionButton({ label: this.assignmentSaving ? '保存中…' : '确认归类', available: !this.assignmentSaving && this.assignmentCourse.trim().length > 0, onAction: () => { void this.assignCourse(); } })
      ActionButton({ label: '取消', available: !this.assignmentSaving, onAction: () => { this.assigningIds = []; this.assignmentMessage = ''; } })
    }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(12)
  }

  @State contentWidth: number = 320;
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
    this.assignmentSaving = false;
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
    this.assignmentSaving = false;
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
        if (this.assignmentSaving) return;
        if (this.assigningIds.length) this.assigningIds = [];
        else if (this.practiceItem !== null) this.leavePractice();
        else if (this.preview !== null) this.preview = null;
        else if (this.selectedPoint) this.selectedPoint = '';
        else if (this.selectedCourse) this.selectedCourse = '';
        else router.back();
      } })
      Scroll() {
        Column({ space: 14 }) {
          Text('按课程整理；在这里刷对同一道题 3 次后，系统会自动移出。')
            .fontSize(13).fontColor('#667085').lineHeight(20).width('100%')
          if (this.assignmentMessage) Text(this.assignmentMessage).fontSize(13).fontColor('#475467').width('100%')
          if (this.assigningIds.length > 0) {
            this.AssignmentPanel()
          } else if (this.isLoading) {
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
            Flex({ direction: this.contentWidth >= 360 ? FlexDirection.Row : FlexDirection.Column, justifyContent: FlexAlign.Center }) {
              Column() { ActionButton({ label: '返回题目', onAction: () => this.preview = null }) }
                .width(this.contentWidth >= 360 ? '48%' : '100%').margin({ bottom: 10, right: this.contentWidth >= 360 ? 12 : 0 })
              Column() { ActionButton({ label: '同类练习', onAction: () => router.pushUrl({ url: 'pages/ExercisePractice', params: { courseName: this.preview?.courseName || '', knowledgePointId: this.preview?.knowledgePointId || '' } }) }) }
                .width(this.contentWidth >= 360 ? '48%' : '100%')
            }.width('100%')
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
                if (course.courseName === '待确认科目') {
                  Text('这些题目的科目尚不明确。可逐题选择，或将同一科目的题目批量归类。').fontSize(13).fontColor('#667085').width('100%')
                  ActionButton({ label: this.selectedPoint ? '归类本知识点题目' : '归类本科目题目（最多100题）', onAction: () => this.beginAssignment(this.selectedPoint ? this.pointItems(course) : course.items) })
                }
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
                      ActionButton({ label: '修改所属科目', onAction: () => this.beginAssignment([item]) })
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
        }.width('100%').alignItems(HorizontalAlign.Start).onAreaChange((_old: Area, area: Area) => { this.contentWidth = Number(area.width) - 32; }).padding({ left: 16, right: 16, top: 16, bottom: 40 })
      }.align(Alignment.TopStart).layoutWeight(1).backgroundColor('#F5F6F8')
    }.width('100%').height('100%')
  }
}
