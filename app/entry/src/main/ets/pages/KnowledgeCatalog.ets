import router from '@ohos.router';
import { AgentApiClient } from '../api/AgentApiClient';
import { KnowledgeMastery } from '../api/ApiModels';
import { ApiFailure } from '../api/ApiResult';
import { appState } from '../data/AppState';
import { LearningEvidence } from '../utils/LearningEvidence';
import { ClientCache } from '../cache/ClientCache';
import { PageHeader } from '../components/PageHeader';

@Entry
@Component
struct KnowledgeCatalog {
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
    const params = router.getParams() as Record<string, string>;
    this.course = params?.['courseName'] || '';
    if (params?.['matching'] === 'true') this.status = '需要匹配';
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
      if (this.status === '需要匹配' && !this.points.some((point: KnowledgeMastery) => point.classificationRequired === true)) { this.status = '全部'; this.notice = '现有知识点均已匹配科目，可直接开始练习。'; }
    } else this.notice = (result as ApiFailure).error.message;
  }
  private courses(): string[] {
    const names: string[] = [];
    this.points.forEach((p: KnowledgeMastery) => {
      const name: string = p.sourceCourse || '';
      if (name && !['待分类', '待确认科目', '其他'].includes(name) && !names.includes(name)) names.push(name);
    });
    return names.filter((name: string) => !this.courseSearch || name.includes(this.courseSearch)).sort();
  }
  private filtered(): KnowledgeMastery[] {
    return this.points.filter((p: KnowledgeMastery) => (!this.course || p.sourceCourse === this.course) &&
      (!this.search || p.knowledgePointName.includes(this.search) || (p.topicGroupName || '').includes(this.search)) &&
      (this.status === '全部' || (this.status === '需要匹配' ? p.classificationRequired === true : LearningEvidence.label(p) === this.status)))
      .sort((a: KnowledgeMastery, b: KnowledgeMastery) => Number(a.classificationRequired === true) - Number(b.classificationRequired === true) ||
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
      ClientCache.cacheProfile(result.data); this.editing = ''; this.notice = '匹配已保存，画像和练习使用同一归属。';
    } else {
      this.notice = (result as ApiFailure).error.message;
      if ((result as ApiFailure).error.statusCode === 409) await this.load();
    }
  }
  build() {
    Column() {
      PageHeader({ title: '全部知识点', detail: '按课程查找' })
      Scroll() {
        Column({ space: 14 }) {
          TextInput({ text: this.courseSearch, placeholder: '搜索课程' }).onChange((value: string) => this.courseSearch = value)
          Select(['全部课程'].concat(this.courses()).map((name: string): SelectOption => { return { value: name }; }))
            .value(this.course || '全部课程').width('100%').onSelect((index: number) => { this.course = index === 0 ? '' : this.courses()[index - 1]; this.limit = 20; })
          TextInput({ text: this.search, placeholder: '搜索知识点或主题' }).onChange((value: string) => { this.search = value; this.limit = 20; })
          Select(['全部', '需要匹配', '未测评', '初步结果', '需巩固', '待复测', '当前表现较稳定'].map((name: string): SelectOption => { return { value: name }; }))
            .value(this.status).width('100%').onSelect((index: number) => { this.status = ['全部', '需要匹配', '未测评', '初步结果', '需巩固', '待复测', '当前表现较稳定'][index]; this.limit = 20; })
          if (this.points.some((p: KnowledgeMastery) => p.classificationRequired === true)) {
            Text('部分内容未能识别所属课程，请点击手动匹配。内容与原有作答记录均已保留。').fontSize(13).fontColor('#B45309').width('100%')
          }
          if (this.notice) Text(this.notice).fontSize(13).fontColor('#475467').width('100%')
          if (this.busy) LoadingProgress().width(32).height(32)
          Text(`已展示 ${Math.min(this.limit, this.filtered().length)} 项，共 ${this.filtered().length} 项`).fontSize(13).fontColor('#667085').width('100%')
          ForEach(this.filtered().slice(0, this.limit), (point: KnowledgeMastery) => {
            Column({ space: 10 }) {
              Text(point.knowledgePointName).fontSize(17).fontWeight(FontWeight.Medium).width('100%')
              if (point.sourceCourse) Text(point.sourceCourse + (point.topicGroupName ? ' · ' + point.topicGroupName : '')).fontSize(12).fontColor('#667085').width('100%')
              Text(LearningEvidence.label(point) + ' · ' + LearningEvidence.detail(point)).fontSize(13).fontColor('#475467').width('100%')
              if (this.editing === point.knowledgePointId) {
                if (this.courses().length > 0) Select(this.courses().map((name: string): SelectOption => { return { value: name }; }))
                  .value(this.matchCourse || '选择已有课程').width('100%').onSelect((index: number) => this.matchCourse = this.courses()[index])
                TextInput({ text: this.matchCourse, placeholder: '课程名称，也可填写新课程' }).onChange((value: string) => this.matchCourse = value)
                TextInput({ text: this.matchTopic, placeholder: '主题分组（选填，不影响练习）' }).onChange((value: string) => this.matchTopic = value)
                Row({ space: 16 }) {
                  Button('保存匹配').enabled(!this.busy).onClick(() => this.save())
                  Text('取消').fontColor('#667085').onClick(() => this.editing = '')
                }
              } else {
                Row({ space: 16 }) {
                  Text(point.classificationRequired ? '选择所属课程 ›' : '修改科目 ›').fontSize(13).fontColor('#2563EB').onClick(() => this.beginMatch(point))
                  if (!point.classificationRequired) Text('开始练习 ›').fontSize(13).fontColor('#2563EB').onClick(() => router.pushUrl({ url: 'pages/ExercisePractice', params: { knowledgePointId: point.knowledgePointId, courseName: point.sourceCourse || '' } }))
                }.width('100%')
              }
            }.padding(16).width('100%').backgroundColor('#FFFFFF').borderRadius(14)
          }, (point: KnowledgeMastery) => point.knowledgePointId)
          if (this.filtered().length > this.limit) Button('加载更多20项').width('100%').onClick(() => this.limit += 20)
          if (!this.busy && this.filtered().length === 0) Text('没有匹配的知识点，请调整筛选或导入资料。').fontSize(14).fontColor('#667085')
          Button('刷新').width('100%').enabled(!this.busy).onClick(() => this.load())
        }.padding(20).width('100%')
      }.align(Alignment.TopStart).layoutWeight(1).width('100%')
    }.width('100%').height('100%').backgroundColor('#F5F6F8')
  }
}
