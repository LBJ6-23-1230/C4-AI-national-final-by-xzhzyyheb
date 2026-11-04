import { KnowledgePointPanel } from '../components/KnowledgePointPanel';
import { AIFloatButton } from '../components/AIFloatButton';
import { UiTheme } from '../utils/UiTheme';
import { PageHeader } from '../components/PageHeader';
import router from '@ohos.router';
import { AgentApiClient } from '../api/AgentApiClient';
import { LearningEffect } from '../api/LearningSyncModels';
import { KnowledgeMastery } from '../api/ApiModels';
import { LearningEvidence } from '../utils/LearningEvidence';
import { appState } from '../data/AppState';

@Entry
@Component
struct ReviewSummary {
  @State data: LearningEffect | null = null;
  @State loading: boolean = false;
  @State notice: string = '';
  @State days: number = 1;
  @State course: string = '';
  @State showDetails: boolean = false;
  @State pointsExpanded: boolean = false;
  @State detailPointIds: string[] = [];
  private scroller: Scroller = new Scroller();
  private pointsOffset: number = 0;
  private active: boolean = false;
  private requestVersion: number = 0;
  aboutToAppear(): void { this.active = true; void this.load(); }
  onPageShow(): void { this.active = true; if (!this.loading) void this.load(); }
  aboutToDisappear(): void { this.active = false; this.requestVersion++; }
  private async load(): Promise<void> {
    const owner: string = appState.currentUser.userId;
    if (this.data !== null && this.data.userId !== owner) {
      this.data = null; this.selectCourse('');
    }
    const version: number = ++this.requestVersion;
    this.loading = true; this.notice = '';
    const result = await AgentApiClient.getLearningEffect(this.days);
    if (!this.active || version !== this.requestVersion || owner !== appState.currentUser.userId) return;
    this.loading = false;
    if (result.ok && result.data.userId === owner) {
      this.data = result.data;
      if (this.course && !this.courses().includes(this.course)) this.selectCourse('');
    }
    else { this.data = null; this.notice = '读取失败，点击重试'; }
  }
  private courses(): string[] {
    const names: string[] = [];
    this.data?.points.forEach((p: KnowledgeMastery) => {
      const name: string = p.sourceCourse || ''; if (name && !['待分类', '待确认科目'].includes(name) && !names.includes(name)) names.push(name);
    });
    return names;
  }
  private points(): KnowledgeMastery[] {
    return (this.data?.points.filter((p: KnowledgeMastery) => !this.course || (p.sourceCourse || '待分类') === this.course) ?? [])
      .sort((a: KnowledgeMastery, b: KnowledgeMastery) => this.priority(a) - this.priority(b) ||
        (b.lastAssessedAt || '').localeCompare(a.lastAssessedAt || '') || a.knowledgePointName.localeCompare(b.knowledgePointName));
  }
  private priority(point: KnowledgeMastery): number {
    if (point.assessmentStatus === 'retest_due') return 0;
    if (point.assessmentStatus === 'needs_practice') return 1;
    if ((point.effectiveQuestionCount ?? 0) > 0) return 2;
    return 3;
  }
  private visiblePoints(): KnowledgeMastery[] { return this.pointsExpanded ? this.points() : this.points().slice(0, 3); }
  private hiddenCount(): number { return this.points().length - this.visiblePoints().length; }
  private selectCourse(course: string): void {
    this.course = course; this.pointsExpanded = false; this.detailPointIds = [];
  }
  private togglePoints(): void {
    this.pointsExpanded = !this.pointsExpanded;
    if (!this.pointsExpanded) this.scroller.scrollTo({ xOffset: 0, yOffset: this.pointsOffset, animation: true });
  }
  private togglePointDetails(id: string): void {
    this.detailPointIds = this.detailPointIds.includes(id) ? this.detailPointIds.filter((item: string) => item !== id) : this.detailPointIds.concat([id]);
  }
  private practiceLabel(): string {
    return this.data?.points.some((point: KnowledgeMastery) => (point.effectiveQuestionCount ?? 0) > 0) ||
      (this.data?.answeredCount ?? 0) > 0 ? '继续练习，补充测评记录' : '完成一组练习，了解当前表现';
  }
  private pointAction(point: KnowledgeMastery): string {
    if (point.assessmentStatus === 'unassessed' || (point.effectiveQuestionCount ?? 0) === 0) return '做一组，了解当前表现 ›';
    return point.assessmentStatus === 'retest_due' ? '用新题验证当前表现 ›' : '巩固该知识点 ›';
  }
  private lastPractice(point: KnowledgeMastery): string {
    const date: Date = new Date(point.lastAssessedAt || '');
    if (Number.isNaN(date.getTime())) return '';
    return `最近练习 ${date.getMonth() + 1}月${date.getDate()}日`;
  }
  private async addImprovement(point: KnowledgeMastery): Promise<void> {
    if (point.classificationRequired) { router.pushUrl({ url: 'pages/KnowledgeCatalog', params: { matching: 'true' } }); return; }
    if (this.loading) return;
    const owner: string = appState.currentUser.userId;
    const version: number = ++this.requestVersion;
    this.loading = true;
    const result = await AgentApiClient.acceptAssessmentAction({ knowledgePointId: point.knowledgePointId });
    if (!this.active || owner !== appState.currentUser.userId || version !== this.requestVersion) return;
    this.loading = false;
    if (result.ok) router.pushUrl({ url: 'pages/StudyPlan', params: { courseName: point.sourceCourse || '' } });
    else this.notice = '加入失败，请刷新后重试。';
  }
  private practice(point?: KnowledgeMastery, fresh: boolean = false): void {
    if (point?.classificationRequired) { router.pushUrl({ url: 'pages/KnowledgeCatalog', params: { matching: 'true' } }); return; }
    const params: Record<string, Object> = {};
    if (point !== undefined) {
      params['knowledgePointId'] = point.knowledgePointId; params['courseName'] = point.sourceCourse || '';
      if (fresh || point.assessmentStatus === 'retest_due') params['forceGenerate'] = true;
    } else if (this.course) {
      params['courseName'] = this.course;
    }
    router.pushUrl({ url: 'pages/ExercisePractice', params: params });
  }
  @Builder
  Metric(value: string, label: string) {
    Column({ space: 8 }) {
      Text(value).fontSize(22).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink)
      Text(label).fontSize(12).fontColor(UiTheme.secondary)
    }.layoutWeight(1).padding({ top: 12, bottom: 12 })
  }
  build() {
    Stack() {
    Column() {
      PageHeader({ title: '学习报告', assistant: true })
      Scroll(this.scroller) {
        Column({ space: 18 }) {
          Row({ space: 8 }) {
            Button('今天', { type: ButtonType.Normal }).layoutWeight(1).height(40).fontSize(14)
              .fontColor(this.days === 1 ? UiTheme.accent : UiTheme.secondary).backgroundColor(this.days === 1 ? UiTheme.tint : UiTheme.surface)
              .borderRadius(8).onClick(() => { this.days = 1; void this.load(); })
            Button('近7天', { type: ButtonType.Normal }).layoutWeight(1).height(40).fontSize(14)
              .fontColor(this.days === 7 ? UiTheme.accent : UiTheme.secondary).backgroundColor(this.days === 7 ? UiTheme.tint : UiTheme.surface)
              .borderRadius(8).onClick(() => { this.days = 7; void this.load(); })
            Select(['全部课程'].concat(this.courses()).map((name: string): SelectOption => { return { value: name }; }))
              .value(this.course || '全部课程').font({ size: 13 }).layoutWeight(1).backgroundColor(UiTheme.surface)
              .onSelect((index: number) => this.selectCourse(index === 0 ? '' : this.courses()[index - 1]))
          }.width('100%')
          if (this.loading) { LoadingProgress().width(28).height(28) }
          if (this.notice) { Text(this.notice).fontSize(14).fontColor(UiTheme.danger).onClick(() => this.load()) }
          if (this.data !== null) {
            if (this.data.answeredCount === 0 && this.data.focusMinutes === 0) {
              Text(this.days === 1 ? '今天还没有学习记录' : '近7天还没有学习记录').fontSize(18).fontColor(UiTheme.ink).width('100%')
            }
            Row() {
              this.Metric(`${this.data.focusMinutes}分钟`, '专注时长')
              this.Metric(this.data.practiceAccuracy === null ? '—' : `${this.data.practiceAccuracy}%`, '正确率')
              this.Metric(`${this.data.completedFocusSessions}次`, '自评次数')
            }.width('100%')
            Divider().color(UiTheme.line)
            Row() { this.Metric(`${this.data.answeredCount}题`, '作答数量'); this.Metric(`${this.data.correctCount}题`, '答对数') }.width('100%')
            Text('专注和自评用于了解投入；掌握情况由实际作答验证。').fontSize(12).fontColor(UiTheme.secondary).width('100%')
            Text('课程知识点').fontSize(17).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
            KnowledgePointPanel({ initialCourse: this.course })
            if (this.points().length > 0) {
              Divider().color(UiTheme.line)
              Text('下一步练习').fontSize(17).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
              Text(this.points()[0].knowledgePointName).fontSize(15).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
              Text((this.points()[0].effectiveQuestionCount ?? 0) > 0 ? `${LearningEvidence.detail(this.points()[0])}。先巩固，再用新题验证当前表现。` : '还没有作答记录，先用新题了解当前表现。')
                .fontSize(13).fontColor(UiTheme.secondary).lineHeight(21).width('100%')
              Row({ space: 10 }) {
                Button('加入15分钟巩固计划', { type: ButtonType.Normal }).layoutWeight(1).constraintSize({ minHeight: 44 }).fontSize(13)
                  .fontColor(UiTheme.accent).backgroundColor(UiTheme.surface).border({ width: 1, color: UiTheme.accent }).borderRadius(8)
                  .enabled(!this.loading).onClick(() => this.addImprovement(this.points()[0]))
                Button('开始3道新题', { type: ButtonType.Normal }).layoutWeight(1).constraintSize({ minHeight: 44 }).fontSize(13)
                  .fontColor(UiTheme.accent).backgroundColor(UiTheme.surface).border({ width: 1, color: UiTheme.accent }).borderRadius(8)
                  .onClick(() => this.practice(this.points()[0], true))
              }.width('100%')
            } else {
              Button(this.practiceLabel(), { type: ButtonType.Normal }).width('100%').height(46).fontSize(14)
                .backgroundColor(UiTheme.accent).fontColor('#FFFFFF').borderRadius(8).onClick(() => this.practice())
            }
            Button('生成阶段复盘', { type: ButtonType.Normal }).width('100%').height(46).fontSize(15)
              .backgroundColor(UiTheme.accent).fontColor('#FFFFFF').borderRadius(8)
              .onClick(() => router.pushUrl({ url: 'pages/LearningReview', params: { courseName: this.course } }))
            Row() {
              Text('查看当前安排 ›').fontSize(13).fontColor(UiTheme.accent).padding({ top: 12, bottom: 12 })
                .onClick(() => router.pushUrl({ url: 'pages/StudyPlan' }))
              Blank()
              Text(this.showDetails ? '收起评估依据' : '评估依据 ›').fontSize(13).fontColor(UiTheme.accent)
                .padding({ top: 12, bottom: 12 }).onClick(() => this.showDetails = !this.showDetails)
            }.width('100%')
            if (this.showDetails) {
              Text(this.data.timeAttribution || '').fontSize(12).fontColor(UiTheme.secondary).width('100%')
              Text('每个知识点使用最近20道不同题目的首次作答；重复原题不增加验证记录。少量样本只提供初步结果；新题用于复核当前表现，没有可比前测时不计算提升。')
                .fontSize(12).fontColor(UiTheme.secondary).lineHeight(20).width('100%')
            }
          }
        }.width('100%').constraintSize({ maxWidth: UiTheme.contentWidth }).padding(20).alignItems(HorizontalAlign.Start)
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off).align(Alignment.TopStart)
    }.width('100%').height('100%').backgroundColor(UiTheme.surface)
    AIFloatButton()
    }.width('100%').height('100%')
  }
}
