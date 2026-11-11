import router from '@ohos.router';
import { common } from '@kit.AbilityKit';
import { camera, cameraPicker } from '@kit.CameraKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { AgentApiClient } from '../api/AgentApiClient';
import { KnowledgeMastery } from '../api/ApiModels';
import { ApiFailure } from '../api/ApiResult';
import { AuthStore } from '../api/AuthStore';
import { PhotoPracticeCriterion, PhotoPracticeExercise, PhotoPracticeGrade, PhotoPracticeQuery, PhotoPracticeType } from '../api/PhotoPracticeModels';
import { DemoSnapshot } from '../cache/DemoSnapshot';
import { ClientCache } from '../cache/ClientCache';
import { PageHeader } from '../components/PageHeader';
import { appState } from '../data/AppState';
import { ImageEncoder } from '../utils/ImageEncoder';
import { UiTheme } from '../utils/UiTheme';
import { ProfileViewModel } from '../viewmodels/ProfileViewModel';

@Component
struct PhotoPracticePrimary {
  @Prop label: string = '';
  @Prop available: boolean = true;
  onAction: () => void = () => {};

  build() {
    Button(this.label, { type: ButtonType.Normal }).width('100%').constraintSize({ minHeight: 48 })
      .padding({ top: 12, bottom: 12, left: 16, right: 16 }).borderRadius(UiTheme.radius)
      .fontSize(16).fontWeight(FontWeight.Medium).enabled(this.available)
      .fontColor(this.available ? UiTheme.surface : UiTheme.secondary)
      .backgroundColor(this.available ? UiTheme.accent : UiTheme.subtle)
      .onClick(() => this.onAction())
  }
}

@Component
struct PhotoPracticeError {
  @Prop label: string = '';

  build() {
    if (this.label.length > 0) {
      Text(this.label).fontSize(14).lineHeight(22).fontColor(UiTheme.danger).width('100%')
    }
  }
}

@Entry
@Component
struct PhotoPractice {
  @State private points: KnowledgeMastery[] = [];
  @State private recommended: KnowledgeMastery | null = null;
  @State private pointId: string = '';
  @State private topic: string = '';
  @State private course: string = '';
  @State private type: PhotoPracticeType = 'calculation';
  @State private editing: boolean = true;
  @State private offline: boolean = false;
  @State private selected: PhotoPracticeExercise | null = null;
  @State private photoUri: string = '';
  @State private result: PhotoPracticeGrade | null = null;
  @State private draftText: string = '';
  @State private savedWrong: boolean = false;
  @State private savingWrong: boolean = false;
  @State private generating: boolean = false;
  @State private selecting: boolean = false;
  @State private grading: boolean = false;
  @State private message: string = '';
  @State private generationError: string = '';
  private activeQuery: PhotoPracticeQuery | null = null;
  private photoBase64: string = '';
  private disposed: boolean = false;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.disposed = false;
    const route = router.getParams() as Record<string, Object>;
    if (typeof route?.['knowledgePointName'] === 'string') this.topic = (route['knowledgePointName'] as string).slice(0, 120);
    if (typeof route?.['courseName'] === 'string') this.course = (route['courseName'] as string).slice(0, 120);
    if (typeof route?.['knowledgePointId'] === 'string') this.pointId = route['knowledgePointId'] as string;
    if (route?.['type'] === 'written') this.type = 'written';
    this.offline = AgentApiClient.getConfig().useFixture;
    if (!this.offline) void this.loadPoints();
  }

  aboutToDisappear(): void {
    this.disposed = true;
    this.photoBase64 = '';
  }

  onBackPress(): boolean {
    if (this.editing && !this.generating && this.activeQuery !== null) {
      this.restoreQuestion();
      return true;
    }
    return false;
  }

  private scope(): string {
    return `${AgentApiClient.getConfig().baseUrl}|${AuthStore.getToken()}`;
  }

  private async loadPoints(): Promise<void> {
    const scope: string = this.scope();
    const state = await new ProfileViewModel().load(appState.currentUser.userId || DemoSnapshot.USER_ID);
    if (this.disposed || scope !== this.scope()) return;
    this.points = state.mastery.filter((item: KnowledgeMastery) => !item.classificationRequired &&
      item.knowledgePointName.trim().length > 0 && item.knowledgePointName.length <= 120);
    this.recommended = this.points.find((item: KnowledgeMastery) => item.photoPracticeStatus === 'unknown' ||
      (item.photoPracticeStatus === 'graded' && (item.photoPracticeScore ?? 0) < (item.photoPracticeMaxScore ?? 0))) ??
      this.points.find((item: KnowledgeMastery) => item.assessmentStatus === 'needs_practice' ||
        item.assessmentStatus === 'retest_due') ?? null;
  }

  private restoreQuestion(): void {
    if (this.activeQuery === null) return;
    this.topic = this.activeQuery.knowledgePointName;
    this.pointId = this.activeQuery.knowledgePointId ?? '';
    this.course = this.activeQuery.courseName;
    this.type = this.activeQuery.type;
    this.generationError = '';
    this.editing = false;
    this.scrollTop();
  }

  private scrollTop(): void {
    setTimeout(() => {
      if (!this.disposed) this.scroller.scrollEdge(Edge.Top);
    }, 50);
  }

  private busy(): boolean {
    return this.generating || this.selecting || this.grading || this.savingWrong;
  }

  private resetPhoto(): void {
    this.photoUri = '';
    this.photoBase64 = '';
    this.result = null;
    this.draftText = '';
    this.savedWrong = false;
    this.message = '';
    this.scrollTop();
  }

  private async generate(): Promise<void> {
    if (this.offline || this.busy() || this.topic.trim().length === 0) return;
    const query: PhotoPracticeQuery = {
      knowledgePointName: this.topic.trim(), knowledgePointId: this.pointId || undefined, courseName: this.course, type: this.type,
      previousExerciseId: this.activeQuery?.knowledgePointName === this.topic.trim() && this.activeQuery?.courseName === this.course &&
        this.activeQuery?.type === this.type ? this.selected?.exerciseId : undefined
    };
    this.generating = true;
    this.generationError = '';
    const scope: string = this.scope();
    const response = await AgentApiClient.generatePhotoPractice(query);
    if (this.disposed) return;
    this.generating = false;
    if (scope !== this.scope()) {
      this.generationError = '账号或后端已切换，请重新进入练习。';
      return;
    }
    if (!response.ok) {
      this.generationError = (response as ApiFailure).error.message;
      return;
    }
    if (response.data.type !== query.type) {
      this.generationError = '题型与本次选择不一致，请重试。';
      return;
    }
    this.activeQuery = query;
    this.selected = response.data;
    this.editing = false;
    this.resetPhoto();
  }

  private async choosePhoto(fromCamera: boolean): Promise<void> {
    if (this.busy() || this.selected === null) return;
    this.selecting = true;
    this.message = '';
    const scope: string = this.scope();
    try {
      let uri: string = '';
      if (fromCamera) {
        const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
        const photo = await cameraPicker.pick(context, [cameraPicker.PickerMediaType.PHOTO],
          { cameraPosition: camera.CameraPosition.CAMERA_POSITION_BACK });
        if (photo.resultCode === 0) uri = photo.resultUri;
      } else {
        const picker = new photoAccessHelper.PhotoViewPicker();
        const photos = await picker.select({ MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE, maxSelectNumber: 1 });
        if (photos.photoUris.length > 0) uri = photos.photoUris[0];
      }
      if (this.disposed || uri.length === 0) return;
      const encoded: string = await ImageEncoder.encodePracticePhoto(uri);
      if (this.disposed || scope !== this.scope()) return;
      if (encoded.length === 0) {
        this.message = '照片读取或压缩失败，请重新拍摄，或从相册换一张。';
        return;
      }
      this.photoUri = uri;
      this.photoBase64 = encoded;
      this.result = null;
      this.draftText = '';
    } catch (error) {
      if (!this.disposed) this.message = '暂时无法获取照片，请重试或从相册选择。';
    } finally {
      if (!this.disposed) this.selecting = false;
    }
  }

  private async submit(): Promise<void> {
    const question: PhotoPracticeExercise | null = this.selected;
    if (question === null || this.photoBase64.length === 0 || this.busy()) return;
    this.grading = true;
    this.message = '';
    const scope: string = this.scope();
    const response = await AgentApiClient.gradePracticePhoto(question.exerciseId, { image: this.photoBase64, review: true });
    if (this.disposed) return;
    this.grading = false;
    if (scope !== this.scope()) {
      this.photoBase64 = '';
      this.photoUri = '';
      this.message = '登录状态已变更，请重新选择照片。';
      return;
    }
    if (!response.ok) {
      this.message = (response as ApiFailure).error.message;
      return;
    }
    if (response.data.exerciseId !== question.exerciseId) {
      this.message = '批改结果和本题不匹配，请重试。';
      return;
    }
    if (response.data.status === 'graded') {
      this.message = '请连接新版后端后重试，以便核对和修改识别结果。';
      return;
    }
    this.result = response.data;
    this.draftText = response.data.transcript ?? '';
    if (response.data.status === 'review') this.scrollTop();
  }

  private selectPoint(point: KnowledgeMastery, useRecommendedType: boolean = false): void {
    this.topic = point.knowledgePointName;
    this.pointId = point.knowledgePointId;
    this.course = (point.sourceCourse || '').slice(0, 120);
    this.generationError = '';
    if (useRecommendedType && (point.photoPracticeType === 'calculation' || point.photoPracticeType === 'written')) {
      this.type = point.photoPracticeType;
    }
  }

  private async complete(unknown: boolean): Promise<void> {
    if (this.selected === null || this.busy()) return;
    const exerciseId: string = this.selected.exerciseId;
    const attemptId: string = this.result?.attemptId ?? '';
    const transcript: string = this.draftText.trim();
    if (!unknown && (!attemptId || !transcript)) return;
    this.grading = true;
    this.message = '';
    const scope: string = this.scope();
    const response = await AgentApiClient.completePhotoPractice(exerciseId,
      unknown ? { outcome: 'unknown' } : { attemptId: attemptId, transcript: transcript });
    if (this.disposed) return;
    this.grading = false;
    if (scope !== this.scope()) {
      this.message = '账号或后端已切换，请重新进入练习。';
      return;
    }
    if (!response.ok) {
      this.message = (response as ApiFailure).error.message;
      return;
    }
    this.result = response.data;
    this.savedWrong = false;
    ClientCache.invalidateProfile();
    void this.loadPoints();
    this.scrollTop();
  }

  private async saveWrong(): Promise<void> {
    const attemptId: string = this.result?.attemptId ?? '';
    const exerciseId: string = this.selected?.exerciseId ?? '';
    if (!attemptId || !exerciseId || this.busy() || this.savedWrong) return;
    this.savingWrong = true;
    this.message = '';
    const scope: string = this.scope();
    const response = await AgentApiClient.savePhotoPracticeWrongBook(exerciseId, { attemptId: attemptId });
    if (this.disposed) return;
    this.savingWrong = false;
    if (scope !== this.scope()) return;
    if (!response.ok) {
      this.message = (response as ApiFailure).error.message;
      return;
    }
    this.savedWrong = true;
  }

  @Builder
  Status(label: string) {
    Row({ space: 8 }) {
      LoadingProgress().width(20).height(20).color(UiTheme.accent)
      Text(label).fontSize(14).fontColor(UiTheme.secondary).layoutWeight(1)
    }.width('100%')
  }

  @Builder
  TypeOption(label: string, value: PhotoPracticeType) {
    Button(this.type === value ? `${label} · 已选` : label, { type: ButtonType.Normal })
      .layoutWeight(1).constraintSize({ minHeight: 48 }).borderRadius(UiTheme.radius)
      .fontSize(15).fontWeight(this.type === value ? FontWeight.Bold : FontWeight.Regular)
      .fontColor(this.type === value ? UiTheme.accent : UiTheme.ink)
      .backgroundColor(this.type === value ? UiTheme.tint : UiTheme.surface)
      .border({ width: 1, color: this.type === value ? UiTheme.accent : UiTheme.line, radius: UiTheme.radius })
      .enabled(!this.generating && !this.offline)
      .onClick(() => { this.type = value; this.generationError = ''; })
  }

  @Builder
  Setup() {
    Column({ space: 8 }) {
      Text('按知识点出题').fontSize(24).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).width('100%')
      Text('AI 生成一道题。写完过程后，拍照提交批改。')
        .fontSize(15).lineHeight(23).fontColor(UiTheme.secondary).width('100%')
    }.width('100%')

    if (this.recommended !== null && this.topic.trim().length === 0) {
      Button(`推荐练习 · ${this.recommended.knowledgePointName}`, { type: ButtonType.Normal })
        .width('100%').constraintSize({ minHeight: 48 }).borderRadius(UiTheme.radius)
        .fontColor(UiTheme.accent).backgroundColor(UiTheme.tint).enabled(!this.busy())
        .onClick(() => { if (this.recommended !== null) this.selectPoint(this.recommended, true); })
    }

    Column({ space: 8 }) {
      Text('知识点').fontSize(16).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
      TextInput({ text: this.topic, placeholder: '例如传输时延' }).width('100%').height(48)
        .fontSize(16).fontColor(UiTheme.ink).placeholderColor(UiTheme.secondary)
        .backgroundColor(UiTheme.subtle).borderRadius(UiTheme.radius).maxLength(120)
        .accessibilityText('知识点').enabled(!this.generating && !this.offline)
        .onChange((value: string) => {
          if (value === this.topic) return;
          this.topic = value;
          this.pointId = '';
          this.course = '';
          this.generationError = '';
        })
      if (this.points.length > 0) {
        Select(this.points.map((point: KnowledgeMastery): SelectOption => ({
          value: point.sourceCourse ? `${point.sourceCourse} · ${point.knowledgePointName}` : point.knowledgePointName
        }))).value('从已学知识点选择').width('100%').height(48)
          .backgroundColor(UiTheme.surface).fontColor(UiTheme.ink).font({ size: 14 })
          .border({ width: 1, color: UiTheme.line, radius: UiTheme.radius })
          .accessibilityText('从已学知识点选择').enabled(!this.generating && !this.offline)
          .onSelect((index: number) => {
            this.selectPoint(this.points[index]);
          })
      }
      if (this.course.length > 0) {
        Text(`课程 · ${this.course}`).fontSize(13).fontColor(UiTheme.secondary).width('100%')
      }
    }.width('100%')

    Column({ space: 8 }) {
      Text('选择出题题型').fontSize(16).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
      Row({ space: 8 }) {
        this.TypeOption('计算题', 'calculation')
        this.TypeOption('简答题', 'written')
      }.width('100%')
      Text('计算题需要列式求解，简答题需要用文字解释概念或说明原因。')
        .fontSize(13).lineHeight(20).fontColor(UiTheme.secondary).width('100%')
    }.width('100%')

    PhotoPracticePrimary({ label: this.generating ? '正在生成…' : '生成题目',
      available: !this.offline && !this.generating && this.topic.trim().length > 0,
      onAction: () => { void this.generate(); } })
    if (this.generating) this.Status('正在生成题干、参考解法和评分点')
    PhotoPracticeError({ label: this.offline ? 'AI 出题需要在线后端，请在接口环境切换到在线模式。' : this.generationError })
    if (this.selected !== null && !this.generating) {
      Button('返回本题', { type: ButtonType.Normal }).height(48)
        .backgroundColor(Color.Transparent).fontColor(UiTheme.secondary).onClick(() => this.restoreQuestion())
    }
  }

  @Builder
  QuestionCard() {
    Column({ space: 8 }) {
      Text(`AI 生成 · ${this.selected?.type === 'calculation' ? '计算题' : '简答题'}`)
        .fontSize(13).fontColor(UiTheme.accent).fontWeight(FontWeight.Medium).width('100%')
      Text(this.selected?.title ?? '').fontSize(21).lineHeight(29).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).width('100%')
      Text(this.selected?.stem ?? '').fontSize(16).lineHeight(25).fontColor(UiTheme.ink).width('100%')
    }.width('100%').padding(16).borderRadius(UiTheme.radius).backgroundColor(UiTheme.subtle)
  }

  @Builder
  PhotoActions() {
    Column({ space: 12 }) {
      Text('上传作答').fontSize(18).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).width('100%')
      Text('在纸上写出过程，上传一张清晰照片。')
        .fontSize(15).lineHeight(23).fontColor(UiTheme.secondary).width('100%')
      if (this.result?.status === 'retake') PhotoPracticeError({ label: `请重新拍摄。${this.result?.message ?? ''}` })
      if (this.photoUri.length > 0) {
        Image(this.photoUri).width('100%').height(144).objectFit(ImageFit.Contain)
          .borderRadius(UiTheme.radius).backgroundColor(UiTheme.subtle).accessibilityText('本次作答照片')
      }
      Row({ space: 8 }) {
        Button(this.photoUri.length > 0 ? '重新拍照' : '拍照', { type: ButtonType.Normal })
          .layoutWeight(1).height(48).borderRadius(UiTheme.radius)
          .fontColor(this.photoUri.length === 0 || this.result?.status === 'retake' ? UiTheme.surface : UiTheme.accent)
          .backgroundColor(this.photoUri.length === 0 || this.result?.status === 'retake' ? UiTheme.accent : UiTheme.tint)
          .enabled(!this.busy()).onClick(() => { void this.choosePhoto(true); })
        Button('从相册选择', { type: ButtonType.Normal }).layoutWeight(1).height(48).borderRadius(UiTheme.radius)
          .backgroundColor(UiTheme.surface).fontColor(UiTheme.accent).border({ width: 1, color: UiTheme.line })
          .enabled(!this.busy()).onClick(() => { void this.choosePhoto(false); })
      }.width('100%')
      if (this.selecting) this.Status('正在准备照片')
      if (this.photoUri.length > 0 && this.result === null) {
        PhotoPracticePrimary({ label: this.grading ? '正在处理…' : '识别作答',
          available: !this.busy(), onAction: () => { void this.submit(); } })
      }
      if (this.grading) this.Status('正在处理本题')
      PhotoPracticeError({ label: this.message })
    }.width('100%')
  }

  @Builder
  QuestionActions() {
    Row({ space: 8 }) {
      Button('不会做，查看解析', { type: ButtonType.Normal }).layoutWeight(1).height(48).borderRadius(UiTheme.radius)
        .backgroundColor(UiTheme.surface).fontColor(UiTheme.secondary).enabled(!this.busy())
        .onClick(() => { void this.complete(true); })
      Button(this.generating ? '正在生成…' : '下一题', { type: ButtonType.Normal }).layoutWeight(1).height(48)
        .borderRadius(UiTheme.radius).backgroundColor(UiTheme.tint).fontColor(UiTheme.accent).enabled(!this.busy())
        .onClick(() => { void this.generate(); })
    }.width('100%')
    Button('调整出题条件', { type: ButtonType.Normal }).height(48)
      .backgroundColor(Color.Transparent).fontColor(UiTheme.secondary).enabled(!this.busy())
      .onClick(() => { this.editing = true; this.generationError = ''; this.scrollTop(); })
    if (this.generating) this.Status('正在生成一道新题')
    PhotoPracticeError({ label: this.generationError })
  }

  @Builder
  ResultCard() {
    if (this.result?.status === 'review') {
      Column({ space: 8 }) {
        Text('核对识别结果').fontSize(24).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).width('100%')
        Text('可直接修正识别有误的文字和公式，评分以确认后的内容为准。')
          .fontSize(15).lineHeight(23).fontColor(UiTheme.secondary).width('100%')
        TextArea({ text: this.draftText, placeholder: '输入原作答的文字和公式' })
          .width('100%').height(232).maxLength(1500).fontSize(16).lineHeight(25).fontColor(UiTheme.ink)
          .padding(16).borderRadius(UiTheme.radius).backgroundColor(UiTheme.subtle).enabled(!this.busy())
          .accessibilityText('可编辑的识别作答').onChange((value: string) => this.draftText = value)
      }.width('100%')
      PhotoPracticePrimary({ label: this.grading ? '正在评分…' : '确认并查看评分',
        available: !this.busy() && this.draftText.trim().length > 0, onAction: () => { void this.complete(false); } })
      PhotoPracticeError({ label: this.message })
      Button('重新选图', { type: ButtonType.Normal }).width('100%').height(48).enabled(!this.busy())
        .backgroundColor(UiTheme.surface).fontColor(UiTheme.accent)
        .onClick(() => this.resetPhoto())
    } else {
      Column({ space: 8 }) {
        Text(this.selected?.title ?? '').fontSize(15).fontColor(UiTheme.secondary).width('100%')
        Text(this.result?.status === 'unknown' ? '已标记不会做' :
          `参考得分 ${this.result?.score ?? 0} / ${this.result?.maxScore ?? 0}`).fontSize(26)
          .fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).width('100%')
        Text(`已记录到「${this.result?.knowledgePointName ?? this.topic}」的解答题练习。`)
          .fontSize(14).fontColor(UiTheme.secondary).width('100%')
      }.width('100%')
      if (this.result?.status === 'graded') {
      Column({ space: 12 }) {
        Text('评分明细').fontSize(18).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).width('100%')
        ForEach(this.result?.criteria ?? [], (item: PhotoPracticeCriterion) => {
          Column({ space: 4 }) {
            Text(`${item.label}　${item.points} / ${item.maxPoints}`).fontSize(16)
              .fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
            Text(item.feedback).fontSize(15).fontColor(UiTheme.secondary).lineHeight(23).width('100%')
          }.width('100%')
        }, (item: PhotoPracticeCriterion) => item.id)
      }.width('100%').padding(16).borderRadius(UiTheme.radius).backgroundColor(UiTheme.subtle)
      }
      Column({ space: 8 }) {
        Text('参考解析').fontSize(18).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).width('100%')
        Text(this.result?.explanation ?? '').fontSize(16).lineHeight(25).fontColor(UiTheme.ink).width('100%')
      }.width('100%')
      PhotoPracticePrimary({ label: this.generating ? '正在生成…' : '下一题',
        available: !this.busy(), onAction: () => { void this.generate(); } })
      if (this.generating) this.Status('正在生成一道新题')
      PhotoPracticeError({ label: this.generationError })
      if (this.result?.status === 'unknown' || (this.result?.score ?? 0) < (this.result?.maxScore ?? 0)) {
        Button(this.savedWrong ? '已加入错题本' : this.savingWrong ? '正在保存…' : '加入错题本', { type: ButtonType.Normal })
          .width('100%').height(48).borderRadius(UiTheme.radius).fontColor(UiTheme.accent).backgroundColor(UiTheme.tint)
          .enabled(!this.busy() && !this.savedWrong).onClick(() => { void this.saveWrong(); })
        PhotoPracticeError({ label: this.message })
      }
      Row({ space: 8 }) {
        Button('重做本题', { type: ButtonType.Normal }).layoutWeight(1).height(48)
          .backgroundColor(UiTheme.surface).fontColor(UiTheme.accent).enabled(!this.busy())
          .onClick(() => this.resetPhoto())
        Button('调整出题条件', { type: ButtonType.Normal }).layoutWeight(1).height(48)
          .backgroundColor(UiTheme.surface).fontColor(UiTheme.secondary).enabled(!this.busy())
          .onClick(() => { this.editing = true; this.generationError = ''; this.scrollTop(); })
      }.width('100%')
    }
  }

  build() {
    Column() {
      PageHeader({ title: '解答题', onBack: () => { if (!this.onBackPress()) router.back(); } })
      Scroll(this.scroller) {
        Column({ space: 24 }) {
          if (this.editing || this.selected === null) {
            this.Setup()
          } else if (this.result !== null && this.result.status !== 'retake') {
            this.ResultCard()
          } else {
            this.QuestionCard()
            this.PhotoActions()
            this.QuestionActions()
          }
        }.width('100%').constraintSize({ maxWidth: UiTheme.contentWidth })
          .padding({ left: 20, right: 20, top: 16, bottom: 32 })
      }.width('100%').layoutWeight(1).align(Alignment.Top)
    }.width('100%').height('100%').backgroundColor(UiTheme.canvas)
  }
}
