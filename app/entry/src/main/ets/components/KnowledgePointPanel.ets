import { UiTheme } from '../utils/UiTheme';
import router from '@ohos.router';
import { AgentApiClient } from '../api/AgentApiClient';
import { KnowledgeMastery } from '../api/ApiModels';
import { ApiFailure } from '../api/ApiResult';
import { appState } from '../data/AppState';
import { LearningEvidence } from '../utils/LearningEvidence';
import { ClientCache } from '../cache/ClientCache';
import { PageHeader } from '../components/PageHeader';

@Component
export struct KnowledgePointPanel {
  @Prop @Watch('changeCourse') initialCourse: string = '';
  @Prop pointIds: string[] = [];
  @Prop restrictPoints: boolean = false;
  @State openCourses: string[] = [];
  @State expandedCourses: string[] = [];
  @State points: KnowledgeMastery[] = [];
  @State version: number = 0;
  @State course: string = '';
  @State search: string = '';
  @State courseSearch: string = '';
  @State status: string = '全部';
  @State limit: number = 20;
  @State busy: boolean = false;
  @State notice: string = '';
  @State editing: string = '';
  @State matchCourse: string = '';
  @State matchTopic: string = '';
  private active: boolean = false;
  private requestVersion: number = 0;
  private owner: string = '';
  aboutToAppear(): void {
    this.active = true; this.owner = appState.currentUser.userId;
    this.course = this.initialCourse;
    void this.load();
  }
  aboutToDisappear(): void { this.active = false; this.requestVersion++; }
  private owns(version: number): boolean {
    return this.active && this.owner === appState.currentUser.userId && version === this.requestVersion;
  }
  private async load(): Promise<void> {
    const version: number = ++this.requestVersion;
    this.busy = true;
    const result = await AgentApiClient.getProfile(this.owner);
    if (!this.owns(version)) return;
    this.busy = false;
    if (result.ok) {
      this.points = result.data.mastery; this.version = result.data.profileVersion;
      ClientCache.cacheProfile(result.data);
      if (!this.openCourses.length && this.groups().length) this.openCourses = [this.groups()[0]];
      if (this.status === '需要匹配' && !this.points.some((point: KnowledgeMastery) => point.classificationRequired === true)) { this.status = '全部'; this.notice = '现有知识点均已匹配科目，可直接开始练习。'; }
    } else this.notice = (result as ApiFailure).error.message;
  }
  private changeCourse(): void { this.course = this.initialCourse; this.expandedCourses = []; this.openCourses = this.initialCourse ? [this.initialCourse] : []; }
  private groupName(point: KnowledgeMastery): string { return point.classificationRequired ? '待确认课程' : point.sourceCourse || '待确认课程'; }
  private groups(): string[] {
    const names: string[] = [];
    this.filtered().forEach((point: KnowledgeMastery) => { const name: string = this.groupName(point); if (!names.includes(name)) names.push(name); });
    return names.sort();
  }
  private groupPoints(course: string): KnowledgeMastery[] { return this.filtered().filter((p: KnowledgeMastery) => this.groupName(p) === course); }
  private shownPoints(course: string): KnowledgeMastery[] { return this.expandedCourses.includes(course) ? this.groupPoints(course) : this.groupPoints(course).slice(0, 3); }
  private courses(): string[] {
    const names: string[] = [];
    this.points.forEach((p: KnowledgeMastery) => {
      const name: string = p.sourceCourse || '';
      if (name && !['待分类', '待确认科目', '其他'].includes(name) && !names.includes(name)) names.push(name);
    });
    return names.filter((name: string) => !this.courseSearch || name.includes(this.courseSearch)).sort();
  }
  private filtered(): KnowledgeMastery[] {
    return this.points.filter((p: KnowledgeMastery) => (!this.restrictPoints || this.pointIds.includes(p.knowledgePointId)) && (!this.course || this.groupName(p) === this.course) &&
      (!this.search || p.knowledgePointName.includes(this.search) || (p.topicGroupName || '').includes(this.search) || this.groupName(p).includes(this.search)) &&
      true)
      .sort((a: KnowledgeMastery, b: KnowledgeMastery) => Number(b.classificationRequired === true) - Number(a.classificationRequired === true) ||
        Number((a.effectiveQuestionCount ?? 0) === 0) - Number((b.effectiveQuestionCount ?? 0) === 0) ||
        LearningEvidence.score(a) - LearningEvidence.score(b) || a.knowledgePointName.localeCompare(b.knowledgePointName));
  }
  private beginMatch(point: KnowledgeMastery): void {
    this.editing = point.knowledgePointId; this.matchCourse = point.sourceCourse || '';
    this.matchTopic = point.topicGroupName || ''; this.notice = '';
  }
  private async save(): Promise<void> {
    if (this.busy || !this.matchCourse.trim()) { this.notice = '请选择或填写所属课程。'; return; }
    const version: number = ++this.requestVersion;
    this.busy = true;
    const result = await AgentApiClient.classifyKnowledgePoint(this.owner, { knowledgePointId: this.editing,
      courseName: this.matchCourse.trim(), topicName: this.matchTopic.trim(), expectedProfileVersion: this.version });
    if (!this.owns(version)) return;
    this.busy = false;
    if (result.ok) {
      this.points = result.data.mastery; this.version = result.data.profileVersion;
      ClientCache.cacheProfile(result.data);
      if (!this.openCourses.length && this.groups().length) this.openCourses = [this.groups()[0]]; this.editing = ''; this.notice = '匹配已保存，画像和练习使用同一归属。';
    } else {
      this.notice = (result as ApiFailure).error.message;
      if ((result as ApiFailure).error.statusCode === 409) await this.load();
    }
  }
  @Builder
  PointRow(point: KnowledgeMastery) {
Column({ space: 10 }) {
              Text(point.knowledgePointName).fontSize(17).fontWeight(FontWeight.Medium).width('100%')
              if (point.sourceCourse) Text(point.sourceCourse + (point.topicGroupName ? ' · ' + point.topicGroupName : '')).fontSize(12).fontColor(UiTheme.secondary).width('100%')
              Text(LearningEvidence.label(point) + ' · ' + LearningEvidence.detail(point)).fontSize(13).fontColor(UiTheme.secondary).width('100%')
              if (this.editing === point.knowledgePointId) {
                if (this.courses().length > 0) Select(this.courses().map((name: string): SelectOption => { return { value: name }; }))
                  .value(this.matchCourse || '选择已有课程').width('100%').onSelect((index: number) => this.matchCourse = this.courses()[index])
                TextInput({ text: this.matchCourse, placeholder: '课程名称，也可填写新课程' }).onChange((value: string) => this.matchCourse = value)
                TextInput({ text: this.matchTopic, placeholder: '主题分组（选填，不影响练习）' }).onChange((value: string) => this.matchTopic = value)
                Row({ space: 16 }) {
                  Button('保存匹配').enabled(!this.busy).onClick(() => this.save())
                  Text('取消').fontColor(UiTheme.secondary).onClick(() => this.editing = '')
                }
              } else {
                Row({ space: 16 }) {
                  Text(point.classificationRequired ? '选择所属课程 ›' : '修改科目 ›').fontSize(13).fontColor(UiTheme.accent).onClick(() => this.beginMatch(point))
                  if (!point.classificationRequired) Text('开始练习 ›').fontSize(13).fontColor(UiTheme.accent).onClick(() => router.pushUrl({ url: 'pages/ExercisePractice', params: { knowledgePointId: point.knowledgePointId, courseName: point.sourceCourse || '' } }))
                }.width('100%')
              }
            }.padding(16).width('100%').backgroundColor(UiTheme.surface).borderRadius(8)
  }
  build() {
    Column({ space: 12 }) {
      TextInput({ text: this.search, placeholder: '搜索课程、知识点或主题' }).onChange((value: string) => this.search = value)
      if (this.notice) { Text(this.notice).fontSize(13).fontColor(UiTheme.secondary).width('100%') }
      if (this.busy) { LoadingProgress().width(28).height(28) }
      ForEach(this.groups(), (course: string) => {
        Column({ space: 8 }) {
          Row() {
            Text(course).fontSize(17).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).layoutWeight(1)
            Text(`${this.groupPoints(course).length}个知识点 ${this.openCourses.includes(course) || this.search ? '⌃' : '›'}`).fontSize(12).fontColor(UiTheme.secondary)
          }.width('100%').constraintSize({ minHeight: 48 }).padding({ top: 10, bottom: 6 })
            .onClick(() => this.openCourses = this.openCourses.includes(course) ? this.openCourses.filter((name: string) => name !== course) : this.openCourses.concat([course]))
          if (this.openCourses.includes(course) || this.search.length > 0) {
          ForEach(this.shownPoints(course), (point: KnowledgeMastery) => { this.PointRow(point) }, (point: KnowledgeMastery) => point.knowledgePointId)
          if (this.groupPoints(course).length > 3) {
            Button(this.expandedCourses.includes(course) ? '收起本课程' : `展开本课程全部${this.groupPoints(course).length}项`, { type: ButtonType.Normal })
              .width('100%').height(44).fontSize(13).fontColor(UiTheme.accent).backgroundColor(UiTheme.tint)
              .onClick(() => this.expandedCourses = this.expandedCourses.includes(course) ? this.expandedCourses.filter((name: string) => name !== course) : this.expandedCourses.concat([course]))
          }
          }
        }.width('100%').alignItems(HorizontalAlign.Start).border({ width: { bottom: 1 }, color: UiTheme.line })
      }, (course: string) => course)
      if (!this.busy && this.filtered().length === 0) { Text('暂无匹配知识点，请调整搜索或导入资料。').fontSize(14).fontColor(UiTheme.secondary).width('100%') }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
