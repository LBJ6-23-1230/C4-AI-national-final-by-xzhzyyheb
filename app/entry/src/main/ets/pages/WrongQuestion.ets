import { UiTheme } from '../utils/UiTheme';
import { PageHeader } from '../components/PageHeader';
import router from '@ohos.router';
import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { appState } from '../data/AppState';
import { WrongAnalysisResult } from '../models/AgentModels';
import { FollowUpCard } from '../components/FollowUpCard';
import { LocalAgentService } from '../services/LocalAgentService';
import { ChatNavigation } from '../services/ChatNavigation';
import { AIFloatButton } from '../components/AIFloatButton';
import { AgentApiClient } from '../api/AgentApiClient';
import { WrongBookItem } from '../api/ApiModels';
import { AgentBridge } from '../services/AgentBridge';
import { ChatProgress } from '../services/ChatEventParser';
import { AgentResponse, WrongAnalysis } from '../models/ChatModels';
import { ImageEncoder } from '../utils/ImageEncoder';

@Entry
@Component
struct WrongQuestion {
  @State savedQuestions: number[] = [];
  @State selectedForBook: number[] = [];
  @State savingQuestion: boolean = false;
  @State bookStatus: string = '';
  @State bookSaveError: string = '';
  @State saveStem: string = '';
  @State saveCourse: string = '';
  @State savePoint: string = '';
  private bookRequestVersion: number = 0;
  private bookScope: string = '';

  private wrongBookScope(): string {
    const config = AgentApiClient.getConfig();
    return `${config.useFixture ? 'fixture' : config.baseUrl}:${appState.currentUser.userId}`;
  }

  private async refreshSavedQuestions(): Promise<void> {
    if (!this.analysisResults.length || this.savingQuestion || this.isFixture()) return;
    const scope: string = this.wrongBookScope();
    if (this.bookScope !== scope) {
      this.bookScope = scope;
      this.savedQuestions = [];
      this.selectedForBook = [];
    }
    const request: number = ++this.bookRequestVersion;
    const version: number = this.analysisRequestVersion;
    const owner: string = appState.currentUser.userId;
    this.bookStatus = 'loading';
    const response = await AgentApiClient.getWrongBook();
    if (!this.isPageActive || request !== this.bookRequestVersion ||
      version !== this.analysisRequestVersion || scope !== this.wrongBookScope()) return;
    if (!response.ok || response.data.userId !== owner) {
      this.bookStatus = 'unavailable';
      return;
    }
    const items: WrongBookItem[] = [];
    response.data.courses.forEach(course => course.items.forEach(item => {
      if (item.source === 'scan') items.push(item);
    }));
    const saved: number[] = [];
    this.analysisResults.forEach((question: WrongAnalysisResult, index: number) => {
      const stem: string = (question.questionText ?? '').trim();
      const course: string = question.course.trim();
      const matches: WrongBookItem[] = items.filter((item: WrongBookItem) =>
        !!stem && item.stem.trim() === stem && (!course || item.courseName.trim() === course));
      const match: WrongBookItem | undefined = items.find((item: WrongBookItem) =>
        item.exerciseId === question.savedWrongBookId) ?? (matches.length === 1 ? matches[0] : undefined);
      if (match !== undefined) {
        question.savedWrongBookId = match.exerciseId;
        saved.push(index);
      }
    });
    this.savedQuestions = saved;
    this.selectedForBook = this.selectedForBook.filter((index: number) => !saved.includes(index));
    this.bookStatus = '';
  }

  private async saveQuestion(): Promise<void> {
    if (this.analysisResult === null || this.savingQuestion || this.bookStatus ||
      this.savedQuestions.includes(this.selectedQuestionIndex)) return;
    this.savingQuestion = true;
    this.bookSaveError = '';
    const question: WrongAnalysisResult = this.analysisResult;
    const index: number = this.selectedQuestionIndex;
    const version: number = this.analysisRequestVersion;
    const scope: string = this.wrongBookScope();
    const solution: string = (this.analysisResult.answer ? `答案：${this.analysisResult.answer}\n` : '') +
      (this.analysisResult.explanation || this.analysisResult.reason);
    const result = await AgentApiClient.saveScannedQuestion({ stem: this.saveStem,
      courseName: this.saveCourse, knowledgePointName: this.savePoint, explanation: solution });
    if (!this.isPageActive || version !== this.analysisRequestVersion || scope !== this.wrongBookScope()) return;
    this.savingQuestion = false;
    if (result.ok) {
      question.savedWrongBookId = result.data.item.exerciseId;
      this.savedQuestions = this.savedQuestions.concat([index]);
      this.selectedForBook = this.selectedForBook.filter((selected: number) => selected !== index);
    } else if (this.selectedQuestionIndex === index) {
      this.bookSaveError = '保存失败，请核对题干后重试。';
    }
  }
  @State hasPhoto: boolean = false;
  @State selectedImageUri: string = '';
  @State isSampleImage: boolean = false;
  @State selectedImageName: string = '';
  @State isAnalyzing: boolean = false;
  @State analysisResults: WrongAnalysisResult[] = [];
  @State selectedQuestionIndex: number = 0;
  @State analysisResult: WrongAnalysisResult | null = null;
  @State showAnalysis: boolean = false;
  @State reviewAdded: boolean = false;
  @State analysisMessage: string = '';
  @State analysisStage: string = '';
  @State questionNumber: string = '';
  private analysisRequestVersion: number = 0;
  private isPageActive: boolean = false;

  aboutToAppear(): void {
    this.isPageActive = true;
    if (appState.selectedImageUri.length > 0) {
      this.selectedImageUri = appState.selectedImageUri;
      this.hasPhoto = true;
      const latestImage = appState.getLatestImage();
      if (latestImage !== null) {
        this.selectedImageName = latestImage.fileName;
      }
    }
    if (appState.latestWrongAnalysis !== null) {
      this.analysisResults = appState.latestWrongAnalyses;
      this.analysisResult = appState.latestWrongAnalysis;
      const selected: number = this.analysisResults.indexOf(this.analysisResult);
      this.selectedQuestionIndex = selected >= 0 ? selected : 0;
      this.selectQuestion(this.selectedQuestionIndex);
      this.showAnalysis = true;
      this.reviewAdded = false;
    }
  }

  aboutToDisappear(): void {
    this.isPageActive = false;
    this.analysisRequestVersion++;
  }

  onPageShow(): void {
    void this.refreshSavedQuestions();
  }

  private goBack(): void {
    this.onBackPress();
    router.back();
  }

  onBackPress(): boolean {
    appState.leaveChatTask();
    return false;
  }

  private async pickFromGallery(): Promise<void> {
    try {
      const photoPicker = new photoAccessHelper.PhotoViewPicker();
      const result = await photoPicker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1
      });
      if (result.photoUris.length > 0) {
        const uri: string = result.photoUris[0];
        this.selectedImageUri = uri;
        this.isSampleImage = false;
        this.selectedImageName = `photo_${Date.now()}.jpg`;
        this.hasPhoto = true;
        appState.addWrongQuestionImage(uri, this.selectedImageName);
        this.startAnalysis(uri);
      }
    } catch (error) {
      console.error(`选图失败: ${JSON.stringify(error)}`);
      if (this.isFixture()) this.useMockImage();
      else this.analysisMessage = '无法读取图片，请检查媒体权限后重试。';
    }
  }

  private useSampleImage(): void {
    if (this.isFixture()) {
      this.useMockImage();
      return;
    }
    void this.startOnlineAnalysisFromSample();
  }

  private useMockImage(): void {
    const mockUri: string = `mock_${Date.now()}.jpg`;
    this.selectedImageUri = mockUri;
    this.isSampleImage = false;
    this.selectedImageName = '模拟错题图片.jpg';
    this.hasPhoto = true;
    appState.addWrongQuestionImage(mockUri, this.selectedImageName);
    this.startAnalysis(mockUri);
  }

  private isFixture(): boolean {
    return AgentApiClient.getConfig().useFixture;
  }

  private startAnalysis(imageUri: string): void {
    if (!this.isFixture()) {
      void this.startOnlineAnalysis(imageUri);
      return;
    }
    const requestVersion: number = ++this.analysisRequestVersion;
    this.isAnalyzing = true;
    this.showAnalysis = false;
    this.analysisResult = null;
    this.analysisResults = [];
    this.savedQuestions = [];
    this.selectedForBook = [];
    this.savingQuestion = false;
    this.selectedQuestionIndex = 0;
    this.reviewAdded = false;
    this.analysisMessage = '';
    appState.latestWrongAnalysis = null;
    appState.latestWrongAnalyses = [];
    setTimeout(() => {
      if (!this.isPageActive || requestVersion !== this.analysisRequestVersion) {
        return;
      }
      const result: WrongAnalysisResult = LocalAgentService.analyzeWrongQuestion(imageUri);
      this.analysisResults = [result];
      appState.latestWrongAnalyses = this.analysisResults;
      this.selectQuestion(0);
      this.showAnalysis = true;
      this.isAnalyzing = false;
      appState.latestWrongAnalysis = result;
    }, 1200);
  }

  private async startOnlineAnalysis(imageUri: string): Promise<void> {
    const requestVersion: number = ++this.analysisRequestVersion;
    this.isAnalyzing = true;
    this.showAnalysis = false;
    this.analysisResult = null;
    this.analysisResults = [];
    this.savedQuestions = [];
    this.selectedForBook = [];
    this.savingQuestion = false;
    this.selectedQuestionIndex = 0;
    this.reviewAdded = false;
    this.analysisMessage = '';
    appState.latestWrongAnalysis = null;
    appState.latestWrongAnalyses = [];

    const encoded: string = await ImageEncoder.toBase64(imageUri);
    if (!this.isPageActive || requestVersion !== this.analysisRequestVersion) {
      return;
    }
    if (encoded.length === 0) {
      this.isAnalyzing = false;
      this.analysisMessage = ImageEncoder.describeFailure();
      return;
    }
    await this.runOnlineAnalysis(encoded, imageUri);
  }

  private async startOnlineAnalysisFromSample(): Promise<void> {
    const requestVersion: number = ++this.analysisRequestVersion;
    this.isAnalyzing = true;
    this.showAnalysis = false;
    this.analysisResult = null;
    this.analysisResults = [];
    this.savedQuestions = [];
    this.selectedForBook = [];
    this.savingQuestion = false;
    this.selectedQuestionIndex = 0;
    this.reviewAdded = false;
    this.analysisMessage = '';
    appState.latestWrongAnalysis = null;
    appState.latestWrongAnalyses = [];

    const context: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    const encoded: string = ImageEncoder.fromResource(context, $r('app.media.sample_wrong').id);
    if (!this.isPageActive || requestVersion !== this.analysisRequestVersion) {
      return;
    }
    if (encoded.length === 0) {
      this.isAnalyzing = false;
      this.analysisMessage = '内置示例图读取失败。';
      return;
    }
    this.selectedImageUri = '';
    this.isSampleImage = true;
    this.selectedImageName = '内置示例错题.png';
    this.hasPhoto = true;
    appState.addWrongQuestionImage('', this.selectedImageName);
    await this.runOnlineAnalysis(encoded, '');
  }

  private async runOnlineAnalysis(encoded: string, imageUri: string): Promise<void> {
    const requestVersion: number = this.analysisRequestVersion;
    const owner: string = appState.currentUser.userId;
    const number: string = this.questionNumber.trim();
    this.analysisStage = '正在上传题目照片…';
    try {
      const prompt: string = number ? `仅识别并分析图片中的第${number}题，保留该题的所有小问。` :
        '请识别并逐题分析这张图片中的全部题目，保留题号和所有小问';
      const response: AgentResponse = await AgentBridge.callAgent(prompt, encoded, [], (event: ChatProgress) => {
        if (this.isPageActive && requestVersion === this.analysisRequestVersion && owner === appState.currentUser.userId && event.message) {
          this.analysisStage = event.message;
        }
      });
      if (!this.isPageActive || requestVersion !== this.analysisRequestVersion || owner !== appState.currentUser.userId) {
        return;
      }
      const analysis: WrongAnalysis | undefined = response.wrongAnalysis;
      const questions: WrongAnalysis[] = analysis !== undefined && analysis.questions !== undefined
        ? analysis.questions : (analysis !== undefined ? [analysis] : []);
      this.analysisResults = questions.map((question: WrongAnalysis): WrongAnalysisResult => {
        const point: string = (question.knowledgePoint ?? '').trim();
        return { course: question.courseName || '', knowledge: point.length > 0 ? [point] : [],
          wrongType: question.wrongType ?? '', reason: question.reason || '',
          answer: question.answer || '', explanation: question.explanation || question.reply || '',
          suggestions: [], tags: [], imageUri: imageUri,
          questionNumber: question.questionNumber ?? '', questionText: question.questionText ?? '',
          recognitionStatus: question.recognitionStatus ?? '' };
      });
      this.isAnalyzing = false;
      appState.latestWrongAnalyses = this.analysisResults;
      if (this.analysisResults.length > 0) {
        this.selectQuestion(0);
        this.showAnalysis = true;
        void this.refreshSavedQuestions();
      } else {
        this.analysisMessage = response.reply || '图片已接收，但识别未完成，请重试。';
        return;
      }
      if (analysis !== undefined && analysis.recognitionStatus !== 'recognized') {
        this.analysisMessage = '部分题目尚未识别或解析完整，请核对题数，并补拍不清晰的题目或重试。';
      }
    } catch (error) {
      if (!this.isPageActive || requestVersion !== this.analysisRequestVersion || owner !== appState.currentUser.userId) {
        return;
      }
      this.isAnalyzing = false;
      this.analysisMessage = error instanceof Error && error.message.includes('::') ?
        error.message.split('::').slice(1).join('::') : '错题分析失败，可用这张图片重试。';
    }
  }

  private selectQuestion(index: number): void {
    if (index < 0 || index >= this.analysisResults.length) return;
    this.selectedQuestionIndex = index;
    this.bookSaveError = '';
    this.saveStem = this.analysisResults[index].questionText || '';
    this.saveCourse = this.analysisResults[index].course;
    this.savePoint = this.analysisResults[index].knowledge.join('、');
    this.analysisResult = this.analysisResults[index];
    this.reviewAdded = false;
    appState.latestWrongAnalysis = this.analysisResult;
  }

  private practiceDiagnosedPoint(): void {
    const points: string[] = this.analysisResult !== null ? this.analysisResult.knowledge : [];
    const point: string = points.length > 0 ? points[0].trim() : '';
    if (point.length === 0) {
      router.pushUrl({ url: 'pages/ExercisePractice' });
      return;
    }
    router.pushUrl({
      url: 'pages/ExercisePractice',
      params: { knowledgePointId: point, knowledgePointName: point, materialCourseName: this.analysisResult?.course ?? '' }
    });
  }

  private addToTomorrowPlan(): void {
    if (this.analysisResult === null) {
      return;
    }
    if (appState.weeklyPlan === null) {
      appState.setWeeklyPlan(LocalAgentService.generateWeeklyPlan(
        appState.courses, appState.homeworkDDLs, appState.currentUser
      ));
    }
    const added: boolean = appState.addReviewTask(
      LocalAgentService.createWrongQuestionReviewTask(this.analysisResult),
      'Agent 已将这道错题加入明日复习，并提高了它的优先级。'
    );
    this.reviewAdded = added;
    appState.completeChatTask(
      added ? '这道错题已加入明日复习，并已提高优先级。' : '这道错题已经在明日复习计划中，没有重复添加。',
      '现在可以确认本周复习计划。',
      '查看复习计划',
      'pages/StudyPlan'
    );
    ChatNavigation.returnToChat();
  }

  private reviewButtonText(): string {
    if (this.reviewAdded) {
      return '已加入明日复习';
    }
    if (this.analysisResult !== null && this.analysisResult.knowledge.length > 0 &&
      appState.hasPendingWrongQuestionReview(this.analysisResult.course, this.analysisResult.knowledge[0])) {
      return '已在明日复习计划中';
    }
    return '加入明日复习';
  }

  @Builder
  AnalysisCard(result: WrongAnalysisResult) {
    Column({ space: 14 }) {
      Text(`第${result.questionNumber || (this.selectedQuestionIndex + 1).toString()}题`).fontSize(16)
        .fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
      if (result.questionText) {
        Text(result.questionText).fontSize(15).lineHeight(23).fontColor(UiTheme.ink).width('100%')
      }
      Row({ space: 12 }) {
        Text('课程').fontSize(13).fontColor(UiTheme.secondary).width(60)
        Text(result.course || '待确认').fontSize(14).fontColor(UiTheme.ink).layoutWeight(1)
      }.width('100%')
      Row({ space: 12 }) {
        Text('知识点').fontSize(13).fontColor(UiTheme.secondary).width(60)
        Text(result.knowledge.join('、') || '待确认').fontSize(14).fontColor(UiTheme.ink).layoutWeight(1)
      }.width('100%')
      Divider().color(UiTheme.line)
      Text('答案与解题解析').fontSize(16).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
      if (result.answer) {
        Text(`答案：${result.answer}`).fontSize(15).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
      }
      Text(result.explanation || (this.isFixture() ? result.reason : '本题尚未返回完整解析，请核对题干后重新识别。'))
        .fontSize(14).lineHeight(23).fontColor(UiTheme.ink).width('100%').copyOption(CopyOptions.InApp)
        .padding(12).backgroundColor(UiTheme.subtle).borderRadius(8)
      Row({ space: 12 }) {
        Text('错误类型').fontSize(13).fontColor(UiTheme.secondary).width(60)
        Text(result.wrongType || '未确认个人错因').fontSize(14).fontColor(UiTheme.ink).layoutWeight(1)
      }.width('100%')
      if (result.reason && result.explanation) {
        Text('原因分析').fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
        Text(result.reason).fontSize(14).lineHeight(22).fontColor(UiTheme.secondary).width('100%')
      }
      if (result.suggestions.length > 0) {
        Text('补强建议').fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
        ForEach(result.suggestions, (tip: string) => {
          Text(tip).fontSize(14).lineHeight(22).fontColor(UiTheme.secondary).width('100%')
        }, (tip: string) => tip)
      }
      if (result.tags.length > 0) {
        Text(result.tags.join(' · ')).fontSize(12).fontColor(UiTheme.secondary).width('100%')
      }
    }.width('100%').padding({ top: 16, bottom: 16 }).alignItems(HorizontalAlign.Start)
      .border({ width: { bottom: 1 }, color: UiTheme.line })
  }

  @Builder
  NavButtons() {
    Column({ space: 12 }) {
      FollowUpCard({
        title: '接下来',
        reason: this.analysisResult !== null && this.analysisResult.knowledge.length > 0
          ? `已经定位到「${this.analysisResult.knowledge[0]}」的薄弱点。立刻做几道同类题，掌握度才会真正更新。`
          : '立刻做几道同类题，掌握度才会真正更新。',
        primaryText: '做 3 道同类专项题',
        primaryTarget: 'pages/ExercisePractice',
        secondaryText: this.reviewButtonText(),
        showAgentTraceLink: true,
        onPrimary: (): void => { this.practiceDiagnosedPoint(); },
        onSecondary: (): void => { this.addToTomorrowPlan(); }
      })

      Button('继续上传错题')
        .width('100%').height(44).fontSize(14).fontColor(UiTheme.accent)
        .backgroundColor(UiTheme.surface).border({ width: 1, color: '#BFDBFE' }).borderRadius(8)
        .onClick(() => {
          this.hasPhoto = false;
          this.showAnalysis = false;
          this.analysisResult = null;
          this.analysisResults = [];
    this.savedQuestions = [];
    this.selectedForBook = [];
    this.savingQuestion = false;
          this.selectedQuestionIndex = 0;
          this.selectedImageUri = '';
          this.isSampleImage = false;
          this.selectedImageName = '';
          this.questionNumber = '';
          this.reviewAdded = false;
          this.analysisRequestVersion++;
          this.isAnalyzing = false;
          appState.clearCurrentWrongQuestionDraft();
        })
    }
    .width('100%')
  }

  build() {
    Stack() {
      Column() {
        PageHeader({ title: this.showAnalysis ? '逐题诊断结果' : '错题诊断', assistant: true })
        Scroll() {
          Column({ space: 16 }) {
            if (!this.showAnalysis) {
              Text('上传错题，获取诊断与建议').fontSize(22).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
              Text('支持拍照或从相册选择，识别题目并给出错误原因、知识点与补强建议。')
                .fontSize(14).fontColor(UiTheme.secondary).lineHeight(22).width('100%')
              if (!this.isFixture() && !this.isAnalyzing) {
                TextInput({ text: this.questionNumber, placeholder: '指定题号（选填，留空识别整页）' })
                  .type(InputType.Number).maxLength(4).height(44)
                  .onChange((value: string) => this.questionNumber = value.replace(/[^0-9]/g, ''))
              }
            }
            if (!this.hasPhoto) {
              Column({ space: 16 }) {
                Text('选择清晰的题目照片').fontSize(14).fontColor(UiTheme.secondary)
                Button('从相册选择', { type: ButtonType.Normal }).width('100%').height(46).fontSize(15)
                  .fontColor('#FFFFFF').backgroundColor(UiTheme.accent).borderRadius(8).onClick(() => this.pickFromGallery())
                Button(this.isFixture() ? '使用模拟错题体验' : '用示例体验（真实识别）', { type: ButtonType.Normal })
                  .fontSize(14).fontColor(UiTheme.accent).backgroundColor(UiTheme.surface).height(44)
                  .enabled(!this.isAnalyzing).onClick(() => this.useSampleImage())
              }.width('100%').padding(20).border({ width: 1, color: UiTheme.line }).borderRadius(8)
            } else {
              Column({ space: 10 }) {
                if (this.isSampleImage) {
                  Image($r('app.media.sample_wrong')).width('100%').height(this.showAnalysis ? 120 : 190).objectFit(ImageFit.Contain)
                } else if (!this.selectedImageUri.startsWith('mock_')) {
                  Image(this.selectedImageUri).width('100%').height(this.showAnalysis ? 120 : 190).objectFit(ImageFit.Contain)
                } else { Text('模拟错题图片').fontSize(14).fontColor(UiTheme.secondary).padding(24) }
                Text(this.selectedImageName).fontSize(12).fontColor(UiTheme.secondary)
                Button('重新选择图片', { type: ButtonType.Normal }).height(44).fontSize(13).fontColor(UiTheme.accent)
                  .backgroundColor(UiTheme.surface).enabled(!this.isAnalyzing).onClick(() => this.pickFromGallery())
                if (!this.showAnalysis && !this.isAnalyzing && !this.isFixture()) {
                  Button('使用这张图重新诊断', { type: ButtonType.Normal }).height(44).fontSize(13)
                    .fontColor(UiTheme.surface).backgroundColor(UiTheme.accent)
                    .onClick(() => {
                      if (this.isSampleImage) void this.startOnlineAnalysisFromSample();
                      else this.startAnalysis(this.selectedImageUri);
                    })
                }
              }.width('100%').backgroundColor(UiTheme.subtle).borderRadius(8).padding(12)
            }
            if (!this.showAnalysis && !this.isAnalyzing) {
              Text('三步完成诊断').fontSize(17).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
              Text('1　选择题目\n2　核对识别内容\n3　查看解析与建议').fontSize(14).fontColor(UiTheme.secondary).lineHeight(32).width('100%')
              Text('仅分析本次上传的题目，不会自动加入错题本。').fontSize(12).fontColor(UiTheme.secondary).width('100%')
            }
            if (this.isAnalyzing) {
              Row({ space: 12 }) {
                LoadingProgress().width(28).height(28)
                Text(this.analysisStage || '正在读取题目照片…').fontSize(14).fontColor(UiTheme.secondary).layoutWeight(1)
              }.width('100%').padding({ top: 16, bottom: 16 })
            }
            if (this.analysisMessage) { Text(this.analysisMessage).fontSize(13).fontColor(UiTheme.danger).lineHeight(21).width('100%') }
            if (this.showAnalysis && this.analysisResult !== null) {
              Text(`本页返回 ${this.analysisResults.length || 1} 道题，可逐题核对`).fontSize(13).fontColor(UiTheme.secondary).width('100%')
              if (this.analysisResults.length > 1) {
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.analysisResults, (item: WrongAnalysisResult, index: number) => {
                    Button(`第${item.questionNumber || (index + 1).toString()}题`, { type: ButtonType.Normal }).height(40).fontSize(13)
                      .backgroundColor(this.selectedQuestionIndex === index ? UiTheme.tint : UiTheme.surface)
                      .fontColor(this.selectedQuestionIndex === index ? UiTheme.accent : UiTheme.secondary)
                      .onClick(() => this.selectQuestion(index))
                  }, (item: WrongAnalysisResult, index: number) => index.toString())
                }.width('100%')
              }
              ForEach([this.selectedQuestionIndex], (index: number) => {
                this.AnalysisCard(this.analysisResults[index])
              }, (index: number) => `${this.analysisRequestVersion}-${index}`)
              if (this.bookStatus === 'loading') {
                Text('正在核对错题本…').fontSize(14).fontColor(UiTheme.secondary).width('100%')
              } else if (this.bookStatus === 'unavailable') {
                Button('无法核对错题本，点击重试', { type: ButtonType.Normal })
                  .height(UiTheme.touch).fontSize(14).fontColor(UiTheme.accent).backgroundColor(UiTheme.tint)
                  .onClick(() => { void this.refreshSavedQuestions(); })
              } else if (this.savedQuestions.includes(this.selectedQuestionIndex)) {
                Column({ space: 4 }) {
                  Text('已加入错题本').fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiTheme.success)
                  Text('已收藏此题，不计作答错记录。').fontSize(12).fontColor(UiTheme.secondary)
                }.width('100%').padding({ top: 8, bottom: 8 }).alignItems(HorizontalAlign.Start)
              } else {
                Row({ space: 10 }) {
                  Checkbox().select(this.selectedForBook.includes(this.selectedQuestionIndex)).onChange((selected: boolean) => {
                    this.selectedForBook = selected ? this.selectedForBook.concat([this.selectedQuestionIndex]) : this.selectedForBook.filter((index: number) => index !== this.selectedQuestionIndex);
                  })
                  Text('加入错题本').fontSize(14).fontColor(UiTheme.ink)
                }.width('100%').constraintSize({ minHeight: 44 })
                if (this.selectedForBook.includes(this.selectedQuestionIndex)) {
                  TextArea({ text: this.saveStem, placeholder: '核对或补充题干后保存' }).height(100).onChange((value: string) => this.saveStem = value)
                  TextInput({ text: this.saveCourse, placeholder: '课程，可手动修正' }).onChange((value: string) => this.saveCourse = value)
                  TextInput({ text: this.savePoint, placeholder: '确认知识点' }).onChange((value: string) => this.savePoint = value)
                  Button(this.savingQuestion ? '保存中…' : '确认加入错题本', { type: ButtonType.Normal })
                    .width('100%').height(44).fontColor('#FFFFFF').backgroundColor(UiTheme.accent).borderRadius(8)
                    .enabled(!this.savingQuestion).onClick(() => this.saveQuestion())
                  if (this.bookSaveError) { Text(this.bookSaveError).fontSize(13).fontColor(UiTheme.danger).width('100%') }
                }
              }
              Text('查看错题本 ›').fontSize(14).fontColor(UiTheme.accent).width('100%').padding({ top: 10, bottom: 10 })
                .onClick(() => router.pushUrl({ url: 'pages/WrongBook' }))
              if (this.analysisResult.knowledge.length > 0) { this.NavButtons() }
            }
          }.width('100%').constraintSize({ maxWidth: UiTheme.contentWidth }).padding(20).alignItems(HorizontalAlign.Start)
        }.width('100%').layoutWeight(1).scrollBar(BarState.Off).align(Alignment.Top)
      }.width('100%').height('100%').backgroundColor(UiTheme.surface)
      AIFloatButton()
    }.width('100%').height('100%')
  }
}
