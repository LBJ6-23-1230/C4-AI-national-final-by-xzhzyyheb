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
  private active: boolean = false;
  private requestVersion: number = 0;
  aboutToAppear(): void { this.active = true; void this.load(); }
  onPageShow(): void { if (this.active && !this.loading) void this.load(); }
  aboutToDisappear(): void { this.active = false; this.requestVersion++; }
  private async load(): Promise<void> {
    const owner: string = appState.currentUser.userId;
    const version: number = ++this.requestVersion;
    this.loading = true; this.notice = '';
    const result = await AgentApiClient.getLearningEffect(this.days);
    if (!this.active || version !== this.requestVersion || owner !== appState.currentUser.userId) return;
    this.loading = false;
    if (result.ok && result.data.userId === owner) this.data = result.data;
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
    return this.data?.points.filter((p: KnowledgeMastery) => !this.course || (p.sourceCourse || '待分类') === this.course) ?? [];
  }
  private practice(point?: KnowledgeMastery): void {
    const params: Record<string, string> = {};
    if (point !== undefined) {
      params['knowledgePointId'] = point.knowledgePointId; params['courseName'] = point.sourceCourse || '';
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
      Scroll() {
        Column({ space: 16 }) {
          Row({ space: 12 }) {
            Button('今天').backgroundColor(this.days === 1 ? '#2563EB' : '#EFF6FF')
              .fontColor(this.days === 1 ? '#FFFFFF' : '#2563EB').onClick(() => { this.days = 1; void this.load(); })
            Button('近7天').backgroundColor(this.days === 7 ? '#2563EB' : '#EFF6FF')
              .fontColor(this.days === 7 ? '#FFFFFF' : '#2563EB').onClick(() => { this.days = 7; void this.load(); })
          }.width('100%')
          if (this.loading) Text('正在读取学习记录…').fontSize(14).fontColor('#667085')
          if (this.notice) Text(this.notice).fontSize(14).fontColor('#667085').onClick(() => this.load())
          if (this.data !== null) {
            Text(this.data!.conclusion).fontSize(23).fontWeight(FontWeight.Bold).fontColor('#1F2937').width('100%')
            Row({ space: 10 }) {
              this.Metric(`${this.data!.focusMinutes} 分钟`, '实际专注')
              this.Metric(this.data!.practiceAccuracy === null ? '—' : `${this.data!.practiceAccuracy}%`, '作答正确率')
              this.Metric(`${this.data!.completedFocusSessions}`, '自评完成次数')
            }.width('100%')
            Text(`本${this.days === 1 ? '日' : '期'}作答 ${this.data!.answeredCount} 题，答对 ${this.data!.correctCount} 题。专注与自评记录用于了解投入，掌握情况需通过作答验证。`)
              .fontSize(13).fontColor('#667085').lineHeight(21).width('100%')
            Button('开始诊断 / 继续练习').width('100%').height(46).backgroundColor('#2563EB').onClick(() => this.practice())
            Text('知识点近期表现').fontSize(18).fontWeight(FontWeight.Bold).width('100%')
            Text('每个知识点取最近20道不同题目的首次作答；重复原题不重复增加验证记录。').fontSize(12).fontColor('#667085').width('100%')
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(['全部课程'].concat(this.courses()), (name: string) => {
                Button(name).fontSize(12).margin(4).backgroundColor((this.course || '全部课程') === name ? '#2563EB' : '#EFF6FF')
                  .fontColor((this.course || '全部课程') === name ? '#FFFFFF' : '#2563EB')
                  .onClick(() => this.course = name === '全部课程' ? '' : name)
              }, (name: string) => name)
            }.width('100%')
            ForEach(this.points(), (point: KnowledgeMastery) => {
              Column({ space: 9 }) {
                Text(point.knowledgePointName).fontSize(16).fontWeight(FontWeight.Medium).width('100%')
                Text(LearningEvidence.label(point)).fontSize(12).fontColor('#2563EB').width('100%')
                Text(LearningEvidence.detail(point)).fontSize(13).fontColor('#475467').width('100%')
                if (point.performanceChange !== undefined && point.performanceChange !== null) {
                  Text(`与相近难度的首次记录相比，正确率变化 ${point.performanceChange! > 0 ? '+' : ''}${point.performanceChange} 个百分点（初步比较）。`)
                    .fontSize(12).fontColor('#667085').width('100%')
                }
                Text(point.retentionStatus === 'preliminary_good' ? '延迟复测初步保持较好' : point.retentionStatus === 'needs_review' ? '延迟复测提示仍需巩固' : '保持情况待验证')
                  .fontSize(12).fontColor('#667085').width('100%')
                Text(point.assessmentStatus === 'unassessed' ? '开始诊断 ›' : point.assessmentStatus === 'retest_due' ? '开始复测 ›' : '再练一组 ›')
                  .fontSize(14).fontColor('#2563EB').width('100%').padding({ top: 6, bottom: 6 }).onClick(() => this.practice(point))
              }.width('100%').padding(16).backgroundColor('#FFFFFF').borderRadius(14)
            }, (point: KnowledgeMastery) => point.knowledgePointId)
            if (this.points().length === 0) Text('选择课程并完成诊断后，可在这里查看逐知识点结果。').fontSize(13).fontColor('#667085')
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
