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
      const name: string = p.sourceCourse || '待分类'; if (!names.includes(name)) names.push(name);
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
    return point.assessmentStatus === 'retest_due' ? '用新题验证当前表现 ›' : '针对练习 ›';
  }
  private lastPractice(point: KnowledgeMastery): string {
    const date: Date = new Date(point.lastAssessedAt || '');
    if (Number.isNaN(date.getTime())) return '';
    return `最近练习 ${date.getMonth() + 1}月${date.getDate()}日`;
  }
  private practice(point?: KnowledgeMastery): void {
    const params: Record<string, Object> = {};
    if (point !== undefined) {
      params['knowledgePointId'] = point.knowledgePointId; params['courseName'] = point.sourceCourse || '';
      if (point.assessmentStatus === 'retest_due') params['forceGenerate'] = true;
    } else if (this.course) {
      params['courseName'] = this.course;
    }
    router.pushUrl({ url: 'pages/ExercisePractice', params: params });
  }
  @Builder
  Metric(value: string, label: string) {
    Column({ space: 6 }) {
      Text(value).fontSize(21).fontWeight(FontWeight.Bold).fontColor('#1F2937')
      Text(label).fontSize(12).fontColor('#667085')
    }.layoutWeight(1).padding(14).backgroundColor('#FFFFFF').borderRadius(14)
  }
  build() {
    Column() {
      Row() {
        Text('← 返回').fontSize(14).fontColor('#64748B').onClick(() => router.back())
        Blank()
        Text('练习表现与复盘').fontSize(14).fontColor('#2563EB')
      }.width('100%').padding(20).backgroundColor('#FFFFFF')
      Scroll(this.scroller) {
        Column({ space: 16 }) {
          Text('练习负责做题与解析，这里汇总作答记录，查看表现变化和复测建议。').fontSize(13).fontColor('#667085').lineHeight(21).width('100%')
          Text(this.days === 1 ? '今日学习概况' : '近7天学习概况').fontSize(18).fontWeight(FontWeight.Bold).width('100%')
          Row({ space: 12 }) {
            Button('今天').backgroundColor(this.days === 1 ? '#2563EB' : '#EFF6FF')
              .fontColor(this.days === 1 ? '#FFFFFF' : '#2563EB').onClick(() => { this.days = 1; void this.load(); })
            Button('近7天').backgroundColor(this.days === 7 ? '#2563EB' : '#EFF6FF')
              .fontColor(this.days === 7 ? '#FFFFFF' : '#2563EB').onClick(() => { this.days = 7; void this.load(); })
          }.width('100%')
          if (this.loading) Text('正在读取学习记录…').fontSize(14).fontColor('#667085')
          if (this.notice) Text(this.notice).fontSize(14).fontColor('#667085').onClick(() => this.load())
          if (this.data !== null) {
            Text(this.data!.answeredCount === 0 && this.data!.focusMinutes === 0 ?
              (this.days === 1 ? '今天还没有学习记录' : '近7天还没有学习记录') : this.data!.conclusion)
              .fontSize(20).fontWeight(FontWeight.Bold).fontColor('#1F2937').width('100%')
            Row({ space: 10 }) {
              this.Metric(`${this.data!.focusMinutes} 分钟`, '实际专注')
              this.Metric(this.data!.practiceAccuracy === null ? '—' : `${this.data!.practiceAccuracy}%`, '作答正确率')
              this.Metric(`${this.data!.completedFocusSessions}`, '自评完成次数')
            }.width('100%')
            Text(`本${this.days === 1 ? '日' : '期'}作答 ${this.data!.answeredCount} 题，答对 ${this.data!.correctCount} 题。专注与自评记录用于了解投入，掌握情况需通过作答验证。`)
              .fontSize(13).fontColor('#667085').lineHeight(21).width('100%')
            Button(this.practiceLabel()).width('100%').height(46).fontSize(14).backgroundColor('#2563EB').onClick(() => this.practice())
            Row() {
              Text(`历史知识点表现 · ${this.points().length} 个`).fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
              if (this.pointsExpanded) Text('收起 ∧').fontSize(13).fontColor('#2563EB').padding(8).onClick(() => this.togglePoints())
            }.width('100%').onAreaChange((_old: Area, area: Area) => this.pointsOffset = Number(area.position.y))
            Text('包含以往练习结果；每个知识点取最近20道不同题目的首次作答，重复原题不增加验证记录。').fontSize(12).fontColor('#667085').lineHeight(19).width('100%')
            Select(['全部课程'].concat(this.courses()).map((name: string): SelectOption => { return { value: name }; }))
              .value(this.course || '全部课程').width('100%').fontColor('#344054').backgroundColor('#FFFFFF')
              .onSelect((index: number) => this.selectCourse(index === 0 ? '' : this.courses()[index - 1]))
            Text(this.hiddenCount() > 0 ? `已显示 ${this.visiblePoints().length} 个，另有 ${this.hiddenCount()} 个知识点已折叠` : `已显示全部 ${this.points().length} 个知识点`)
              .fontSize(12).fontColor('#667085').width('100%')
            ForEach(this.visiblePoints(), (point: KnowledgeMastery) => {
              Column({ space: 9 }) {
                Text(point.knowledgePointName).fontSize(16).fontWeight(FontWeight.Medium).width('100%')
                Text(LearningEvidence.label(point)).fontSize(12).fontColor('#2563EB').width('100%')
                Text(LearningEvidence.detail(point)).fontSize(13).fontColor('#475467').width('100%')
                if (this.lastPractice(point)) Text(this.lastPractice(point)).fontSize(12).fontColor('#667085').width('100%')
                Text(this.detailPointIds.includes(point.knowledgePointId) ? '收起表现详情 ∧' : '表现详情 ∨')
                  .fontSize(12).fontColor('#667085').width('100%').padding({ top: 4, bottom: 4 })
                  .onClick(() => this.togglePointDetails(point.knowledgePointId))
                if (this.detailPointIds.includes(point.knowledgePointId)) {
                if (point.performanceChange !== undefined && point.performanceChange !== null) {
                  Text(`与相近难度的首次记录相比，正确率变化 ${point.performanceChange! > 0 ? '+' : ''}${point.performanceChange} 个百分点（初步比较）。`)
                    .fontSize(12).fontColor('#667085').width('100%')
                } else Text('暂无可比前测，暂不判断提升。').fontSize(12).fontColor('#667085').width('100%')
                Text(point.retentionStatus === 'preliminary_good' ? '延迟复测初步保持较好' : point.retentionStatus === 'needs_review' ? '延迟复测提示仍需巩固' : '保持情况待验证')
                  .fontSize(12).fontColor('#667085').width('100%')
                }
                Text(this.pointAction(point))
                  .fontSize(14).fontColor('#2563EB').width('100%').padding({ top: 6, bottom: 6 }).onClick(() => this.practice(point))
              }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(14)
            }, (point: KnowledgeMastery) => point.knowledgePointId)
            if (this.points().length > 3) Button(this.pointsExpanded ? '收起知识点（保留3个） ∧' : `展开其余 ${this.hiddenCount()} 个知识点 ∨`)
              .width('100%').fontSize(14).backgroundColor('#EFF6FF').fontColor('#2563EB').onClick(() => this.togglePoints())
            if (this.points().length === 0) Text('完成一组练习后，可在这里查看知识点表现。').fontSize(13).fontColor('#667085')
            Text(this.showDetails ? '收起评估依据 ∧' : '评估依据 ∨').fontSize(13).fontColor('#667085').width('100%').onClick(() => this.showDetails = !this.showDetails)
            if (this.showDetails) {
              Text(this.data!.timeAttribution ?? '').fontSize(12).fontColor('#667085').width('100%')
              Text('首次少量作答只提供初步结果。至少两轮、8道不同题、包含基础与应用且正确率达到80%，标为当前表现较稳定；24—72小时后的相近难度新题用于初步观察保持情况。以上是试行规则，仍需结合真实课程校准。没有可比前测时不计算提升。')
                .fontSize(12).fontColor('#667085').lineHeight(21).width('100%')
            }
            Button('查看当前学习安排').width('100%').backgroundColor('#EFF6FF').fontColor('#2563EB')
              .onClick(() => router.pushUrl({ url: 'pages/StudyPlan' }))
          }
        }.width('100%').padding(20).alignItems(HorizontalAlign.Start)
      }.layoutWeight(1).width('100%')
    }.width('100%').height('100%').backgroundColor('#F5F6F8')
  }
}
