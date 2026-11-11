import { PageHeader } from '../components/PageHeader';
import { UiTheme } from '../utils/UiTheme';
import { CourseLabels } from '../utils/CourseLabels';
import { ActionButton } from '../components/ActionButton';
import { DocumentBankOption, Evidence, KnowledgeBase, MasteryHistory, OutlinePracticePoint } from '../api/ApiModels';
import { LearningEvidence } from '../utils/LearningEvidence';
import router from '@ohos.router';
import { AIFloatButton } from '../components/AIFloatButton';
import { Exercise, ExerciseAnswer, ExerciseReview, ExerciseSetResponse, ExerciseSubmission, ExerciseSubmissionResult, KnowledgeMastery, PointMasteryUpdate } from '../api/ApiModels';
import { AgentApiClient } from '../api/AgentApiClient';
import { DemoSnapshot } from '../cache/DemoSnapshot';
import { PlanDiffCard } from '../components/PlanDiffCard';
import { FollowUpCard } from '../components/FollowUpCard';
import { ExerciseViewModel } from '../viewmodels/ExerciseViewModel';
import { ProfileViewModel, ProfileViewState } from '../viewmodels/ProfileViewModel';
import { appState } from '../data/AppState';
import { ExerciseSource } from '../api/ApiModels';
import { ApiFailure } from '../api/ApiResult';

@Entry
@Component
struct ExercisePractice {
  @State waitSeconds: number = 0;
  private reviewTimer: number = -1;
  private reviewPollCount: number = 0;
  private waitTimer: number = -1;
  private waitStartedAt: number = 0;
  @State isLoading: boolean = true;
  @State isSubmitting: boolean = false;
  @State submissionUnconfirmed: boolean = false;
  @State errorMessage: string = '';
  @State warningMessage: string = '';
  @State setId: string = DemoSnapshot.EXERCISE_SET_ID;
  @State practiceKnowledgePoint: string = DemoSnapshot.EXERCISE_KNOWLEDGE_POINT_ID;
  @State practiceFromRoute: boolean = false;
  @State forceGenerate: boolean = false;
  private initialExcludedIds: string[] = [];
  private roundId: string = '';
  private roundScope: string = '';
  private roundLoaded: boolean = false;
  private roundExcludedIds: string[] = [];
  @State sourceMode: string = 'general';
  @State learningGoalId: string = '';
  @State learningGoalVersion: number = 0;
  @State sourceKbId: string = '';
  @State sourceDocumentId: string = '';
  @State showBankPicker: boolean = false;
  @State bankOptions: DocumentBankOption[] = [];
  @State bankIndex: number = 0;
  @State bankLoading: boolean = false;
  @State bankError: string = '';
  @State bankCount: number = 0;
  @State bankMax: number = 20;
  private bankDocumentFilter: string = '';
  private bankRequestVersion: number = 0;
  @State materialFileName: string = '';
  @State materialPointName: string = '';
  private materialCourseHint: string = '';
  @State sourceVisible: boolean = false;
  @State sourceLoading: boolean = false;
  @State sourceError: string = '';
  @State sourceFragments: ExerciseSource[] = [];
  private sourceRequestVersion: number = 0;
  @State exercises: Exercise[] = [];
  @State answers: string[] = [];
  @State result: ExerciseSubmissionResult | null = null;
  @State showReview: boolean = false;
  @State wrongBookFlags: boolean[] = [];
  @State wrongBookMessage: string = '';
  @State showPicker: boolean = false;
  @State pickerLoading: boolean = false;
  @State pickerErrorMessage: string = '';
  @State pickerEvidence: Evidence[] = [];
  @State pickerHistory: MasteryHistory[] = [];
  private pickerAssessed(item: KnowledgeMastery): boolean { return LearningEvidence.assessed(item, this.pickerEvidence, this.pickerHistory); }
  @State pickerOptions: KnowledgeMastery[] = [];
  @State pickerDataVersion: number = 0;
  @State materialCourses: string[] = [];
  @State outlinePoints: OutlinePracticePoint[] = [];
  @State outlineLoading: boolean = false;
  @State outlineStatus: string = '';
  @State criteriaVisible: boolean = false;
  private outlineRequestVersion: number = 0;
  @State pointFilter: string = '推荐';
  @State pointSearch: string = '';
  @State selectedTopic: string = '全部主题';
  private profileViewModel: ProfileViewModel = new ProfileViewModel();
  private viewModel: ExerciseViewModel = new ExerciseViewModel();
  private pageScroller: Scroller = new Scroller();
  private submissionKey: string = '';
  private pendingSubmission: ExerciseSubmission | null = null;
  private pendingSubmissionOwner: string = '';
  private requestVersion: number = 0;
  private pickerRequestVersion: number = 0;
  private isDisposed: boolean = false;
  private isPageActive: boolean = false;
  private observedResetVersion: number = DemoSnapshot.getResetVersion();
  private hasShownOnce: boolean = false;
  private reviewingSubmission: string = '';

  private hasAiExplanation(item: ExerciseReview): boolean {
    return (item.explanationSource === 'llm' || item.explanationSource === 'materials' || item.explanationSource === 'calculation') && item.explanation.trim().length > 0;
  }

  private unavailableReviewMessage(): string {
    if (this.result?.reviewStatus === 'pending') return '正在生成 AI 解析…';
    if (this.result?.reviewStatus === 'unconfigured') return 'AI 解析服务暂未配置。';
    return '本题暂未生成 AI 解析。';
  }

  private scheduleReviewRefresh(): void {
    if (!this.isPageActive || this.reviewTimer !== -1 || this.result?.reviewStatus !== 'pending' || this.reviewPollCount >= 30) return;
    this.reviewTimer = setTimeout(() => {
      this.reviewTimer = -1;
      void this.refreshReview();
    }, this.reviewPollCount < 6 ? 1000 : 3000);
  }
  private async refreshReview(): Promise<void> {
    const owner: string = appState.currentUser.userId;
    const id: string = this.result?.submissionId ?? '';
    if (this.isDisposed || !this.isPageActive || id.length === 0 || this.reviewingSubmission === id) return;
    this.reviewingSubmission = id;
    this.reviewPollCount++;
    const response = await AgentApiClient.getSubmissionReview(id);
    if (this.reviewingSubmission === id) this.reviewingSubmission = '';
    if (this.isDisposed || !this.isPageActive || owner !== appState.currentUser.userId || id !== this.result?.submissionId) return;
    if (response.ok) this.result = response.data;
    this.scheduleReviewRefresh();
  }
  private startWait(): void {
    this.stopWait();
    this.waitStartedAt = Date.now();
    this.waitSeconds = 0;
    this.waitTimer = setInterval(() => { this.waitSeconds = Math.floor((Date.now() - this.waitStartedAt) / 1000); }, 1000);
  }
  private stopWait(): void {
    if (this.waitTimer !== -1) clearInterval(this.waitTimer);
    this.waitTimer = -1;
    if (this.waitStartedAt > 0) this.waitSeconds = Math.floor((Date.now() - this.waitStartedAt) / 1000);
  }
  private resultOffset: number = 0;
  private pickerVisited: boolean = false;
  private pickerOffset: number = 0;
  private pickerScope: string = '';
  private openReview(): void {
    this.resultOffset = this.pageScroller.currentOffset().yOffset;
    this.showReview = true;
    if (this.result?.reviewStatus === 'pending') void this.refreshReview();
    this.scrollToTop();
  }
  private closeReview(): void {
    this.showReview = false;
    setTimeout(() => { if (this.isPageActive) this.pageScroller.scrollTo({ xOffset: 0, yOffset: this.resultOffset }); }, 50);
  }
  private goBack(): void {
    if (!this.onBackPress()) {
      this.clearPracticeStep();
      router.back();
    }
  }

  onBackPress(): boolean {
    if (this.criteriaVisible) { this.criteriaVisible = false; return true; }
    if (this.sourceVisible) { this.sourceRequestVersion++; this.sourceVisible = false; return true; }
    if (this.showReview) { this.closeReview(); return true; }
    if (this.isSubmitting) return true;
    if (this.sourceMode === 'document_bank') {
      if (this.showBankPicker) return false;
      void this.loadBankOptions();
      return true;
    }
    if (this.showPicker || this.pickerLoading) return false;
    if (this.pickerVisited) {
      this.backToPicker();
      return true;
    }
    return false;
  }

  private leaveWaiting(): void {
    this.goBack();
  }

  aboutToAppear(): void {
    const initial = router.getParams() as Record<string, Object>;
    if (initial && typeof initial['courseName'] === 'string') this.selectedCourse = initial['courseName'] as string;
    this.isDisposed = false;
    this.isPageActive = true;
    this.readRouteParams();
    if (this.consumeDemoReset()) {
      return;
    }
    this.startFlow();
  }

  @State selectedCourse: string = '';

  private pickerCourses(): string[] {
    const names: string[] = this.materialCourses.slice();
    this.pickerOptions.forEach((p: KnowledgeMastery) => {
      const name: string = p.sourceCourse || '';
      if (CourseLabels.valid(name) && names.indexOf(name) < 0) names.push(name);
    });
    return names;
  }

  private coursePoints(): KnowledgeMastery[] {
    const points = this.pickerOptions.filter((p: KnowledgeMastery) => (p.sourceCourse || '待分类') === this.selectedCourse)
      .filter((p: KnowledgeMastery) => !p.classificationRequired)
      .filter((p: KnowledgeMastery) => this.selectedTopic === '全部主题' || p.topicGroup === this.selectedTopic)
      .filter((p: KnowledgeMastery) => !this.pointSearch || p.knowledgePointName.includes(this.pointSearch))
      .filter((p: KnowledgeMastery) => this.pointFilter === '全部' || this.pointFilter === '推荐' ||
        (this.pointFilter === '未测评' ? !this.pickerAssessed(p) : LearningEvidence.label(p) === this.pointFilter));
    if (this.pointFilter !== '推荐' || this.pointSearch) return points;
    if (this.selectedTopic !== '全部主题') return points.slice(0, 3);
    const fromOutline: KnowledgeMastery[] = this.outlinePoints.map((item: OutlinePracticePoint): KnowledgeMastery =>
      points.find((point: KnowledgeMastery) => point.knowledgePointId === item.knowledgePointId) ?? {
        knowledgePointId: item.knowledgePointId, knowledgePointName: item.knowledgePointName, sourceCourse: this.selectedCourse,
        masteryScore: 0, confidence: 0, lastUpdated: '', assessmentStatus: 'unassessed'
      });
    return fromOutline.concat(points.filter((point: KnowledgeMastery) =>
      !fromOutline.some((item: KnowledgeMastery) => item.knowledgePointId === point.knowledgePointId))).slice(0, 3);
  }

  private outlineFile(pointId: string): string {
    return this.outlinePoints.find((item: OutlinePracticePoint) => item.knowledgePointId === pointId)?.outlineFileName ?? '';
  }

  private selectPickerCourse(course: string): void {
    this.selectedCourse = course;
    this.selectedTopic = '全部主题';
    this.pointFilter = '推荐';
    void this.loadOutlinePoints();
  }

  private async loadOutlinePoints(): Promise<void> {
    const version: number = ++this.outlineRequestVersion;
    this.outlinePoints = [];
    this.outlineLoading = false;
    this.outlineStatus = '';
    const course: string = this.selectedCourse;
    if (!course || AgentApiClient.getConfig().useFixture) return;
    const scope: string = this.practiceAccountScope();
    this.outlineLoading = true;
    const response = await AgentApiClient.getOutlinePracticeRecommendations(course);
    if (this.isDisposed || version !== this.outlineRequestVersion || !this.showPicker ||
      course !== this.selectedCourse || scope !== this.practiceAccountScope()) return;
    this.outlineLoading = false;
    if (response.ok) {
      this.outlinePoints = response.data.points;
      this.outlineStatus = response.data.status ?? (this.outlinePoints.length > 0 ? 'ready' : '');
    } else {
      this.outlineStatus = 'model_unavailable';
    }
  }

  private outlineMessage(): string {
    if (this.pointFilter !== '推荐' || this.pointSearch || this.selectedTopic !== '全部主题') return '';
    if (this.outlineLoading) return '正在整理复习重点，可以先选知识点练习。';
    return '';
  }

  private async loadMaterialCourses(version: number, owner: string): Promise<void> {
    const config = AgentApiClient.getConfig();
    if (config.useFixture) return;
    const response = await AgentApiClient.listKnowledgeBases(owner);
    if (!response.ok || this.isDisposed || version !== this.pickerRequestVersion || !this.showPicker ||
      owner !== appState.currentUser.userId || config.baseUrl !== AgentApiClient.getConfig().baseUrl) return;
    this.materialCourses = [];
    response.data.knowledgeBases.forEach((base: KnowledgeBase) => {
      const course: string = base.courseName ?? '';
      if (CourseLabels.valid(course) && !this.materialCourses.includes(course)) this.materialCourses.push(course);
    });
    if (!this.selectedCourse) this.selectPickerCourse(this.pickerCourses()[0] || '');
  }
  private topicChoices(): string[] {
    const names: string[] = ['全部主题'];
    this.pickerOptions.filter((p: KnowledgeMastery) => (p.sourceCourse || '待分类') === this.selectedCourse)
      .forEach((p: KnowledgeMastery) => { if (p.topicGroup && !names.includes(p.topicGroup)) names.push(p.topicGroup); });
    return names;
  }

  private showCriteria(): void {
    this.criteriaVisible = true;
  }

  private startFlow(): void {
    if (this.sourceMode === 'document_bank') {
      void this.loadBankOptions();
      return;
    }
    if (this.practiceFromRoute) {
      void this.loadExercises();
      return;
    }
    this.loadPickerOptions();
  }

  private async loadPickerOptions(refreshVisible: boolean = false): Promise<void> {
    const version: number = ++this.pickerRequestVersion;
    if (!refreshVisible) {
      this.pickerLoading = true;
      this.outlineRequestVersion++;
      this.outlinePoints = [];
      this.outlineLoading = false;
      this.outlineStatus = '';
      this.materialCourses = [];
    }
    this.pickerErrorMessage = '';
    const id: string = appState.currentUser.userId;
    const scope: string = this.practiceAccountScope();
    const state: ProfileViewState =
      await this.profileViewModel.load(id.length > 0 ? id : DemoSnapshot.USER_ID, true);
    if (this.isDisposed || version !== this.pickerRequestVersion || scope !== this.practiceAccountScope()) {
      return;
    }
    this.pickerLoading = false;
    this.pickerErrorMessage = state.errorMessage;
    if (refreshVisible && state.errorMessage) {
      this.pickerErrorMessage = '暂时无法更新知识点，正在显示上次的数据。';
      return;
    }
    const sorted: KnowledgeMastery[] = state.mastery.slice();
    sorted.sort((left: KnowledgeMastery, right: KnowledgeMastery): number =>
      Number((left.effectiveQuestionCount ?? 0) === 0) - Number((right.effectiveQuestionCount ?? 0) === 0) ||
      (left.evidenceAdjustedScore ?? LearningEvidence.score(left)) - (right.evidenceAdjustedScore ?? LearningEvidence.score(right)));
    this.pickerEvidence = state.evidence;
    this.pickerHistory = state.history;
    this.pickerOptions = sorted;
    this.pickerDataVersion++;
    const previousCourse: string = this.selectedCourse;
    if (!this.pickerCourses().includes(this.selectedCourse)) this.selectedCourse = this.pickerCourses()[0] || '';
    if (previousCourse !== this.selectedCourse || !this.topicChoices().includes(this.selectedTopic)) this.selectedTopic = '全部主题';
    this.showPicker = true;
    this.pickerVisited = true;
    this.pickerScope = scope;
    if (!refreshVisible || previousCourse !== this.selectedCourse || this.outlineLoading) void this.loadOutlinePoints();
    void this.loadMaterialCourses(version, id);
  }

  private chooseKnowledgePoint(point: KnowledgeMastery): void {
    if (point.classificationRequired) { router.pushUrl({ url: 'pages/KnowledgeCatalog', params: { matching: 'true' } }); return; }
    this.pickerVisited = true;
    this.pickerScope = this.practiceAccountScope();
    this.pickerOffset = this.pageScroller.currentOffset().yOffset;
    this.selectedCourse = point.sourceCourse || '';
    this.roundId = '';
    this.practiceKnowledgePoint = point.knowledgePointId;
    this.materialPointName = point.knowledgePointName;
    this.practiceFromRoute = true;
    this.showPicker = false;
    this.outlineRequestVersion++;
    this.result = null;
    void this.loadExercises(true);
  }

  private practiceAccountScope(): string {
    const config = AgentApiClient.getConfig();
    return `${config.useFixture ? 'fixture' : config.baseUrl}:${appState.currentUser.userId}`;
  }

  private launchBank(documentId: string = ''): void {
    router.pushUrl({ url: 'pages/ExercisePractice', params: {
      sourceMode: 'document_bank', courseName: CourseLabels.valid(this.selectedCourse) ? this.selectedCourse : '',
      documentId: documentId
    } });
  }

  private async loadBankOptions(): Promise<void> {
    this.clearPracticeStep();
    this.showBankPicker = true;
    this.bankLoading = true;
    this.bankError = '';
    const version: number = ++this.bankRequestVersion;
    const scope: string = this.practiceAccountScope();
    const previousId: string = this.bankOptions[this.bankIndex]?.documentId ?? '';
    const response = await AgentApiClient.getDocumentBanks(this.selectedCourse, this.bankDocumentFilter);
    if (this.isDisposed || version !== this.bankRequestVersion || scope !== this.practiceAccountScope()) return;
    this.bankLoading = false;
    if (response.ok) {
      this.bankOptions = response.data.banks;
      this.bankMax = response.data.maxCount;
      this.selectBank(Math.max(0, this.bankOptions.findIndex((item: DocumentBankOption) => item.documentId === previousId)));
    } else {
      this.bankError = (response as ApiFailure).error.message;
    }
    this.scrollToTop();
  }

  private bankCounts(): number[] {
    const limit: number = Math.min(this.bankOptions[this.bankIndex]?.count ?? 0, this.bankMax);
    return [3, 5, 10, 15, 20, limit].filter((count: number, index: number, values: number[]) =>
      count > 0 && count <= limit && values.indexOf(count) === index).sort((a: number, b: number) => a - b);
  }

  private selectBank(index: number): void {
    this.bankIndex = index;
    const counts: number[] = this.bankCounts();
    if (!counts.includes(this.bankCount)) this.bankCount = counts.includes(5) ? 5 : (counts[0] ?? 0);
  }

  private startBankRound(): void {
    const bank: DocumentBankOption | undefined = this.bankOptions[this.bankIndex];
    if (!bank || this.bankLoading || !this.bankCounts().includes(this.bankCount)) return;
    this.sourceKbId = bank.kbId;
    this.sourceDocumentId = bank.documentId;
    this.materialFileName = bank.fileName;
    this.showBankPicker = false;
    void this.loadExercises(true);
  }

  private practiceDemoPoint(): void {
    this.pickerVisited = true;
    this.pickerScope = this.practiceAccountScope();
    this.pickerOffset = this.pageScroller.currentOffset().yOffset;
    this.practiceKnowledgePoint = DemoSnapshot.EXERCISE_KNOWLEDGE_POINT_ID;
    this.practiceFromRoute = false;
    this.showPicker = false;
    this.result = null;
    this.loadExercises(true);
  }

  private isDemoIdentity(): boolean {
    return appState.currentUser.userId === DemoSnapshot.USER_ID;
  }

  private clearPracticeStep(): void {
    this.requestVersion++;
    this.stopWait();
    if (this.reviewTimer !== -1) clearTimeout(this.reviewTimer);
    this.reviewTimer = -1;
    this.showReview = false;
    this.result = null;
    this.isLoading = false;
  }

  private backToPicker(): void {
    if (this.isSubmitting) return;
    this.clearPracticeStep();
    this.sourceRequestVersion++;
    if (!this.selectedCourse) this.selectedCourse = this.materialCourseHint;
    this.materialCourseHint = '';
    this.materialPointName = '';
    this.materialFileName = '';
    this.sourceVisible = false;
    this.practiceFromRoute = false;
    this.learningGoalId = '';
    this.roundId = '';
    this.learningGoalVersion = 0;
    this.sourceMode = 'general';
    this.sourceKbId = '';
    this.sourceDocumentId = '';
    this.forceGenerate = false;
    this.initialExcludedIds = [];
    if (!this.pickerVisited || this.pickerScope !== this.practiceAccountScope()) {
      void this.loadPickerOptions();
      return;
    }
    this.showPicker = true;
    void this.loadPickerOptions(true);
    setTimeout(() => {
      if (this.showPicker) this.pageScroller.scrollTo({ xOffset: 0, yOffset: this.pickerOffset });
    }, 50);
  }

  private readRouteParams(): void {
    try {
      const params: Record<string, Object> = router.getParams() as Record<string, Object>;
      if (params === undefined || params === null) {
        return;
      }
      const raw: Object | undefined = params['knowledgePointId'];
      this.materialPointName = typeof params['knowledgePointName'] === 'string' ? params['knowledgePointName'] as string : '';
      this.materialCourseHint = typeof params['materialCourseName'] === 'string' ? params['materialCourseName'] as string : '';
      this.forceGenerate = params['forceGenerate'] === true;
      if (Array.isArray(params['excludeExerciseIds'])) {
        this.initialExcludedIds = (params['excludeExerciseIds'] as string[]).filter((id: string) => typeof id === 'string');
      }
      if (typeof params['goalId'] === 'string' && typeof params['goalStateVersion'] === 'number') {
        this.learningGoalId = params['goalId'] as string;
        this.learningGoalVersion = params['goalStateVersion'] as number;
      }
      if (params['sourceMode'] === 'materials' && typeof params['kbId'] === 'string') {
        this.sourceMode = 'materials';
        this.sourceKbId = params['kbId'] as string;
        this.sourceDocumentId = typeof params['documentId'] === 'string' ? params['documentId'] as string : '';
      }
      if (params['sourceMode'] === 'document_bank') {
        this.sourceMode = 'document_bank';
        this.bankDocumentFilter = typeof params['documentId'] === 'string' ? params['documentId'] as string : '';
      }
      if (typeof raw === 'string' && (raw as string).trim().length > 0) {
        this.practiceKnowledgePoint = (raw as string).trim();
        this.practiceFromRoute = true;
      }
    } catch (error) {
    }
  }

  onPageShow(): void {
    this.isPageActive = true;
    if (this.result?.reviewStatus === 'pending') {
      this.reviewPollCount = 0;
      void this.refreshReview();
    }
    if (this.consumeDemoReset()) return;
    if (!this.hasShownOnce) {
      this.hasShownOnce = true;
      return;
    }
    if (this.result !== null) this.scrollToTop();
    if (this.showPicker && !this.pickerLoading && !this.practiceFromRoute && this.result === null ) {
      void this.loadPickerOptions();
    }
  }

  onPageHide(): void {
    this.isPageActive = false;
    if (this.reviewTimer !== -1) clearTimeout(this.reviewTimer);
    this.reviewTimer = -1;
  }

  private consumeDemoReset(): boolean {
    const resetVersion: number = DemoSnapshot.getResetVersion();
    if (resetVersion !== this.observedResetVersion) {
      this.observedResetVersion = resetVersion;
      this.isSubmitting = false;
      this.result = null;
      this.loadExercises(true);
      return true;
    }
    return false;
  }

  aboutToDisappear(): void {
    this.stopWait();
    if (this.reviewTimer !== -1) clearTimeout(this.reviewTimer);
    this.reviewTimer = -1;
    this.isDisposed = true;
    this.isPageActive = false;
    this.requestVersion++;
    this.pickerRequestVersion++;
    this.outlineRequestVersion++;
    this.sourceRequestVersion++;
    this.bankRequestVersion++;
  }

  private restartPractice(): void {
    this.result = null;
    this.showReview = false;
    this.warningMessage = '';
    this.loadExercises(true);
  }

  private generatesNewQuestions(): boolean {
    return this.sourceMode === 'general' && this.practiceFromRoute && !AgentApiClient.getConfig().useFixture &&
      (this.forceGenerate || !this.learningGoalId);
  }

  private async loadExercises(forceRefresh: boolean = false): Promise<void> {
    if (this.isSubmitting) return;
    this.pendingSubmission = null;
    this.submissionUnconfirmed = false;
    this.pickerRequestVersion++;
    this.pickerLoading = false;
    const currentRequestVersion: number = ++this.requestVersion;
    const owner: string = appState.currentUser.userId;
    this.isLoading = true;
    const bankRound: boolean = this.sourceMode === 'document_bank';
    const count: number = bankRound ? this.bankCount : DemoSnapshot.EXERCISE_COUNT;
    const scope: string = `${owner}:${this.selectedCourse}:${this.practiceKnowledgePoint}:${this.sourceMode}:${this.sourceKbId}:${this.sourceDocumentId}:${count}`;
    if (this.roundId.length === 0 || this.roundLoaded || this.roundScope !== scope) {
      this.roundId = `round-${Date.now()}-${Math.random().toString(36).slice(2)}`;
      this.roundScope = scope;
      this.roundLoaded = false;
      this.roundExcludedIds = this.initialExcludedIds.concat(forceRefresh ? this.exercises.map((item: Exercise): string => item.exerciseId) : []);
    }
    this.startWait();
    this.errorMessage = '';
    this.warningMessage = '';
    const data: ExerciseSetResponse | null =
      await this.viewModel.load(DemoSnapshot.EXERCISE_SET_ID, forceRefresh, {
        courseName: this.selectedCourse || (this.sourceMode === 'materials' ? this.materialCourseHint : '') || undefined,
        roundId: this.selectedCourse && this.sourceMode === 'general' ? this.roundId : undefined,
        knowledgePointId: bankRound ? undefined : this.practiceKnowledgePoint,
        count: count,
        sourceMode: this.sourceMode,
        kbId: this.sourceKbId,
        documentId: this.sourceDocumentId,
        excludeExerciseIds: this.roundExcludedIds,
        forceGenerate: this.generatesNewQuestions(),
        generate: !bankRound && this.practiceFromRoute
      });
    if (this.isDisposed || currentRequestVersion !== this.requestVersion || owner !== appState.currentUser.userId) {
      if (currentRequestVersion === this.requestVersion) this.stopWait();
      return;
    }
    this.stopWait();
    const loadError: string = this.viewModel.getErrorMessage();
    if (data === null || (forceRefresh && loadError.length > 0)) {
      this.exercises = [];
      this.answers = [];
      this.errorMessage = loadError || '练习题暂时加载失败，请点击重试。';
      this.isLoading = false;
      return;
    }
    if (data.exercises.length === 0) {
      this.exercises = [];
      this.answers = [];
      this.errorMessage = data.message ?? '这次没能为所选知识点拿到题目（现场出题失败或题库已练完），请点「重新加载」再试一次。';
      this.isLoading = false;
      return;
    }
    this.setId = data.setId;
    this.roundLoaded = true;
    this.exercises = data.exercises;
    this.answers = [];
    for (let index: number = 0; index < data.exercises.length; index++) {
      this.answers.push('');
    }
    this.submissionKey = `practice-${data.setId}-${Date.now()}`;
    this.isLoading = false;
    this.scrollToTop();
  }

  private selectAnswer(questionIndex: number, option: string): void {
    if (this.isSubmitting || this.submissionUnconfirmed || this.result !== null) {
      return;
    }
    const nextAnswers: string[] = this.answers.slice();
    nextAnswers[questionIndex] = option.substring(0, 1);
    this.answers = nextAnswers;
  }

  private useGeneralQuestions(): void {
    this.sourceMode = 'general';
    this.sourceKbId = '';
    this.sourceDocumentId = '';
    this.materialFileName = '';
    this.result = null;
    this.showReview = false;
    this.loadExercises(true);
  }

  private async openSources(exerciseId: string): Promise<void> {
    const owner: string = appState.currentUser.userId;
    const version: number = ++this.sourceRequestVersion;
    this.sourceVisible = true;
    this.sourceLoading = true;
    this.sourceError = '';
    this.sourceFragments = [];
    const response = await AgentApiClient.getExerciseSources(exerciseId);
    if (this.isDisposed || version !== this.sourceRequestVersion || owner !== appState.currentUser.userId) return;
    this.sourceLoading = false;
    if (response.ok) this.sourceFragments = response.data.sources;
    else this.sourceError = (response as ApiFailure).error.message;
  }

  @Builder
  SourcePanel() {
    Column({ space: 14 }) {
      Text('题目资料依据').fontSize(22).fontWeight(FontWeight.Bold).width('100%')
      Text('下列原文用于核对题目。来源链接与引用已检查，模型生成的题目及答案仍可能有误。')
        .fontSize(13).fontColor(UiTheme.secondary).lineHeight(21)
      if (this.sourceLoading) {
        LoadingProgress().width(32).height(32)
      } else if (this.sourceError.length > 0) {
        Text(this.sourceError).fontSize(14).fontColor(UiTheme.danger)
      } else {
        ForEach(this.sourceFragments, (source: ExerciseSource) => {
          Column({ space: 8 }) {
            Text(source.fileName).fontSize(16).fontWeight(FontWeight.Bold).width('100%')
            Text(`${source.headingPath || '无章节标题'} · ${source.chunkIndex > 0 ? '第 ' + source.chunkIndex + '段' : '原文片段'}`)
              .fontSize(12).fontColor(UiTheme.accent).width('100%')
            Text(source.text ?? '').fontSize(14).fontColor(UiTheme.ink).lineHeight(23).width('100%').copyOption(CopyOptions.InApp)
          }.width('100%').padding(16).backgroundColor(UiTheme.surface).borderRadius(8)
        }, (source: ExerciseSource) => source.chunkId)
      }
      Button('返回练习').onClick(() => { this.sourceRequestVersion++; this.sourceVisible = false; })
    }.width('100%')
  }

  private answeredCount(): number {
    let count: number = 0;
    for (let index: number = 0; index < this.answers.length; index++) {
      if (this.answers[index].length > 0) {
        count++;
      }
    }
    return count;
  }

  private isSelected(questionIndex: number, option: string): boolean {
    return this.answers[questionIndex] === option.substring(0, 1);
  }

  private assessedPointName(pointId: string): string {
    for (let index: number = 0; index < this.exercises.length; index++) {
      if (this.exercises[index].knowledgePointId === pointId) {
        return this.exercises[index].knowledgePointName;
      }
    }
    return pointId;
  }

  private practiceTitle(): string {
    if (this.sourceMode === 'document_bank') return '题库原题';
    if (this.exercises.length > 0 && this.exercises[0].knowledgePointName.trim().length > 0) {
      return this.exercises[0].knowledgePointName;
    }
    return this.materialPointName || '智能诊断练习';
  }

  private questionOrigin(item: Exercise): string {
    if (item.source === 'document_bank') return '上传题库原题';
    if (item.source === 'materials') return '上传资料';
    if (item.source === 'llm') return 'AI 生成';
    if (item.source === 'demo' || item.source === 'bank') return '题库';
    return '未标注';
  }

  private roundOrigin(): string {
    if (this.sourceMode === 'document_bank') return `本轮题源：${this.materialFileName}，按文件中的答案判分。`;
    const origins: string[] = this.exercises.map((item: Exercise) => this.questionOrigin(item));
    if (origins.every((origin: string) => origin === '上传资料')) {
      const files: Set<string> = new Set<string>();
      this.exercises.forEach((item: Exercise) => (item.sources ?? []).forEach((source: ExerciseSource) => {
        if (source.fileName) files.add(source.fileName);
      }));
      const names: string = Array.from(files).join('、') || this.materialFileName || '所选上传资料';
      return `本轮题源：${names}。可在题目下查看原文。`;
    }
    if (origins.every((origin: string) => origin === 'AI 生成')) {
      return '本轮题源：AI 根据所选知识点生成，未引用上传资料。';
    }
    if (origins.every((origin: string) => origin === '题库')) {
      return '本轮题源：题库中的已有题目，未引用上传资料。';
    }
    const counts: string[] = ['AI 生成', '题库', '上传资料', '未标注']
      .filter((origin: string) => origins.includes(origin))
      .map((origin: string) => `${origin} ${origins.filter((item: string) => item === origin).length} 题`);
    return `本轮题源：${counts.join(' · ')}。每题下方可查看来源。`;
  }

  private difficultyLabel(difficulty?: string): string {
    if (difficulty === 'easy') return '基础';
    if (difficulty === 'medium') return '中等';
    if (difficulty === 'hard') return '较难';
    return '难度未标注';
  }

  private async submit(): Promise<void> {
    const owner: string = appState.currentUser.userId;
    const version: number = this.requestVersion;
    if (this.isSubmitting) {
      return;
    }
    if (this.pendingSubmission !== null && this.pendingSubmissionOwner !== owner) {
      this.errorMessage = '账号已切换，请返回原账号确认交卷结果。';
      return;
    }
    if (this.exercises.length === 0) {
      this.errorMessage = '当前暂无可用练习题，请重试。';
      return;
    }
    if (this.answeredCount() !== this.exercises.length) {
      this.errorMessage = `请先完成全部 ${this.exercises.length} 道题，再提交。`;
      return;
    }
    const exerciseAnswers: ExerciseAnswer[] = [];
    for (let index: number = 0; index < this.exercises.length; index++) {
      exerciseAnswers.push({ exerciseId: this.exercises[index].exerciseId, answer: this.answers[index] });
    }
    if (this.pendingSubmission === null) {
      this.pendingSubmission = {
        goalId: this.learningGoalId.length > 0 ? this.learningGoalId : undefined,
        goalStateVersion: this.learningGoalId.length > 0 ? this.learningGoalVersion : undefined,
        idempotencyKey: this.submissionKey,
        answers: exerciseAnswers
      };
      this.pendingSubmissionOwner = owner;
    }
    this.isSubmitting = true;
    this.errorMessage = '';
    const submissionResult: ExerciseSubmissionResult | null = await this.viewModel.submit(this.setId, this.pendingSubmission);
    if (this.isDisposed || owner !== appState.currentUser.userId || version !== this.requestVersion) {
      return;
    }
    this.isSubmitting = false;
    if (submissionResult === null) {
      const failure: ApiFailure | null = this.viewModel.getSubmissionFailure();
      const status: number = failure?.error.statusCode ?? 0;
      this.submissionUnconfirmed = !(status >= 400 && status < 500 && status !== 408 && status !== 429);
      if (!this.submissionUnconfirmed) this.pendingSubmission = null;
      this.errorMessage = (this.viewModel.getErrorMessage() || '提交失败，请稍后重试。') +
        (this.submissionUnconfirmed ? '交卷结果尚未确认，已保留原答案；请重试确认结果。' : '');
      return;
    }
    this.pendingSubmission = null;
    this.submissionUnconfirmed = false;
    this.warningMessage = this.viewModel.getWarningMessage();
    this.result = submissionResult;
    this.reviewPollCount = 0;
    this.scheduleReviewRefresh();
    this.wrongBookFlags = submissionResult.review.map((item: ExerciseReview): boolean => item.inWrongBook);
    this.showReview = false;
    this.scrollToTop();
  }

  private scrollToTop(): void {
    setTimeout(() => {
      if (this.isPageActive) this.pageScroller.scrollEdge(Edge.Top);
    }, 100);
  }

  @Builder
  OptionButton(questionIndex: number, option: string) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 10 }) {
        Radio({ value: option.substring(0, 1), group: `question-${questionIndex}` }).checked(this.isSelected(questionIndex, option))
          .width(18).height(18).hitTestBehavior(HitTestMode.None)
        Text(option).fontSize(14).fontColor(UiTheme.ink).lineHeight(22).layoutWeight(1)
      }.width('100%').padding({ left: 12, right: 12, top: 12, bottom: 12 })
    }.width('100%').constraintSize({ minHeight: 48 }).borderRadius(8)
      .backgroundColor(this.isSelected(questionIndex, option) ? UiTheme.tint : UiTheme.surface)
      .border({ width: 1, color: this.isSelected(questionIndex, option) ? UiTheme.accent : UiTheme.line })
      .accessibilityText(option).onClick(() => this.selectAnswer(questionIndex, option))
  }

  @Builder
  QuestionCard(item: Exercise, index: number) {
    Column({ space: 12 }) {
      Text(item.source === 'document_bank' ? `第 ${index + 1} 题 · ${item.options.length === 2 && item.options[0] === 'A. 正确' ? '判断题' : '单选题'}` :
        `第 ${index + 1} 题 · ${item.knowledgePointName} · ${this.difficultyLabel(item.difficulty)}`)
        .fontSize(12).fontColor(UiTheme.accent).fontWeight(FontWeight.Bold).width('100%')
      Text(item.stem).fontSize(16).fontColor(UiTheme.ink).fontWeight(FontWeight.Medium).lineHeight(23).width('100%')
      if (item.source === 'materials') {
        Button('资料生成题 · 查看原文依据').fontSize(12).height(34)
          .onClick(() => this.openSources(item.exerciseId))
      } else {
        Text(`题源：${this.questionOrigin(item)}`).fontSize(12).fontColor(UiTheme.secondary).width('100%')
      }
      ForEach(item.options, (option: string) => {
        this.OptionButton(index, option)
      }, (option: string) => option)
    }
    .width('100%').padding(16).backgroundColor(UiTheme.surface).borderRadius(8)
    .border({ width: 1, color: UiTheme.line })
  }

  private weakPointText(value: ExerciseSubmissionResult): string {
    const names: string[] = [];
    this.exercises.forEach((item: Exercise) => {
      if (value.assessment.perKnowledgeAccuracy[item.knowledgePointId] < 1 &&
        /[\u4e00-\u9fff]/.test(item.knowledgePointName) && names.indexOf(item.knowledgePointName) < 0) {
        names.push(item.knowledgePointName);
      }
    });
    return names.length > 0 ? names.join('、') : '暂无明确薄弱知识点';
  }

  private async toggleReviewWrongBook(index: number): Promise<void> {
    if (this.result === null || index < 0 || index >= this.result.review.length) return;
    const next: boolean = !this.wrongBookFlags[index];
    const review: ExerciseReview = this.result.review[index];
    const response = await AgentApiClient.toggleWrongBook(review.exerciseId, next);
    if (!response.ok) {
      this.wrongBookMessage = '错题本更新失败，请稍后重试。';
      return;
    }
    const flags: boolean[] = this.wrongBookFlags.slice();
    flags[index] = response.data.added;
    this.wrongBookFlags = flags;
    this.wrongBookMessage = response.data.added ? '已加入错题本。' : '已从错题本移除。';
  }

  @Builder
  ReviewPanel() {
    Column({ space: 16 }) {
      if (this.result?.reviewStatus === 'pending') {
        Row({ space: 8 }) {
          LoadingProgress().width(18).height(18).color(UiTheme.accent)
          Text('已交卷，AI 正在逐题生成解析。').fontSize(13).fontColor(UiTheme.secondary).layoutWeight(1)
          Button('刷新').height(44).fontSize(12).onClick(() => { this.reviewPollCount = 0; void this.refreshReview(); })
        }.width('100%')
      }
      Row() {
        Text('逐题解析').fontSize(23).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink)
        Blank()
        Text('返回结果').fontSize(13).fontColor(UiTheme.accent).onClick(() => this.closeReview())
      }.width('100%')
      Text('答错题已自动加入错题本。每道做过的题也可以由你自行加入或移除。')
        .fontSize(13).fontColor(UiTheme.secondary).lineHeight(19).width('100%')
      if (this.wrongBookMessage.length > 0) {
        Text(this.wrongBookMessage).fontSize(13).fontColor('#0F766E').width('100%')
          .padding(10).backgroundColor('#ECFDF5').borderRadius(8)
      }
      ForEach(this.exercises, (item: Exercise, index: number) => {
        Column({ space: 10 }) {
          Row() {
            Text(`第 ${index + 1} 题 · ${item.knowledgePointName}`).fontSize(13)
              .fontWeight(FontWeight.Bold).fontColor(UiTheme.accent).layoutWeight(1)
            Text(this.result!.review[index].correct ? '回答正确' : '回答错误')
              .fontSize(12).fontColor(this.result!.review[index].correct ? '#0F766E' : UiTheme.danger)
          }.width('100%')
          Text(item.stem).fontSize(16).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).lineHeight(23)
          Column({ space: 8 }) {
            ForEach(item.options, (option: string) => {
              Row({ space: 8 }) {
                Text(option).fontSize(14).fontColor(UiTheme.ink).layoutWeight(1).lineHeight(20)
                if (option.substring(0, 1) === this.result!.review[index].correctAnswer) {
                  Text('正确答案').fontSize(11).fontColor('#0F766E')
                    .padding({ left: 7, right: 7, top: 3, bottom: 3 })
                    .backgroundColor('#ECFDF5').borderRadius(6)
                } else if (option.substring(0, 1) === this.result!.review[index].selectedAnswer) {
                  Text('你的选择').fontSize(11).fontColor(UiTheme.danger)
                    .padding({ left: 7, right: 7, top: 3, bottom: 3 })
                    .backgroundColor('#FEF3F2').borderRadius(6)
                }
              }.width('100%').padding(10).backgroundColor(UiTheme.subtle).borderRadius(8)
            }, (option: string) => option)
          }.width('100%')
          Text(`你的答案：${this.result!.review[index].selectedAnswer}　正确答案：${this.result!.review[index].correctAnswer}`)
            .fontSize(13).fontColor(UiTheme.secondary).width('100%')
          Column({ space: 6 }) {
            Text(this.result!.review[index].explanationSource === 'calculation' ? '计算解析' : item.source === 'document_bank' ? '判分依据' : 'AI 解析')
              .fontSize(13).fontWeight(FontWeight.Bold).fontColor(UiTheme.accent).width('100%')
            Text(this.hasAiExplanation(this.result!.review[index]) ? this.result!.review[index].explanation : this.unavailableReviewMessage())
              .fontSize(14).fontColor(UiTheme.ink).lineHeight(22).width('100%')
          }.width('100%').padding(12).backgroundColor(UiTheme.tint).borderRadius(8)
          if (item.source === 'materials') {
            Button('查看本题资料依据').height(36).fontSize(13).onClick(() => this.openSources(item.exerciseId))
          }
          Button(this.wrongBookFlags[index] ? '移出错题本' : '加入错题本')
            .width('100%').height(40).fontSize(13)
            .fontColor(this.wrongBookFlags[index] ? UiTheme.danger : UiTheme.accent)
            .backgroundColor(this.wrongBookFlags[index] ? '#FEF3F2' : UiTheme.tint)
            .borderRadius(8).onClick(() => this.toggleReviewWrongBook(index))
        }.width('100%').padding(16).backgroundColor(UiTheme.surface).borderRadius(8)
          .border({ width: 1, color: this.result!.review[index].correct ? '#A7F3D0' : '#FECACA' })
      }, (item: Exercise) => item.exerciseId)
      Button('进入错题本刷题').width('100%').height(46).fontSize(15).fontColor(UiTheme.surface)
        .backgroundColor(UiTheme.accent).borderRadius(8)
        .onClick(() => router.pushUrl({ url: 'pages/WrongBook' }))
    }.width('100%')
  }

  @Builder
  ResultPanel(value: ExerciseSubmissionResult) {
    Column({ space: 16 }) {
      Text(this.sourceMode === 'document_bank' ? '题库练习结果' : '诊断结果已生成')
        .fontSize(23).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).width('100%')
      Text(this.sourceMode === 'document_bank' ? '已按原题标注的答案判分，可查看错题与正确答案。' :
        '本轮答题已记录。学情画像会结合历次练习更新掌握估计。')
        .fontSize(13).fontColor(UiTheme.secondary).lineHeight(19).width('100%')

      if (this.warningMessage.length > 0) {
        Text(this.warningMessage)
          .fontSize(13).fontColor('#B45309').lineHeight(19).width('100%')
          .padding(12).backgroundColor('#FFFBEB').borderRadius(8)
      }



      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text(`${value.assessment.score}%`).fontSize(22).fontWeight(FontWeight.Bold).fontColor(UiTheme.accent)
          Text('本次正确率').fontSize(12).fontColor(UiTheme.secondary)
        }.layoutWeight(1).alignItems(HorizontalAlign.Center).padding(14).backgroundColor(UiTheme.subtle).borderRadius(8)
        Column({ space: 4 }) {
          Text(`${value.review.filter((item: ExerciseReview) => item.correct).length}/${value.review.length}`)
            .fontSize(22).fontWeight(FontWeight.Bold).fontColor('#0F766E')
          Text('本轮答对题数').fontSize(12).fontColor(UiTheme.secondary).textAlign(TextAlign.Center)
        }.layoutWeight(1).alignItems(HorizontalAlign.Center).padding(14).backgroundColor('#ECFDF5').borderRadius(8)
      }.width('100%')

      if (this.sourceMode !== 'document_bank' && value.assessment.masteryUpdates !== undefined) {
        Column({ space: 8 }) {
          Text('各知识点评估').fontSize(15).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).width('100%')
          ForEach(value.assessment.masteryUpdates, (item: PointMasteryUpdate) => {
            Row({ space: 12 }) {
              Column({ space: 4 }) {
                Text(this.assessedPointName(item.knowledgePointId)).fontSize(14).fontColor(UiTheme.ink)
                Text(`答对 ${item.correctCount}/${item.questionCount} 题`)
                  .fontSize(12).fontColor(UiTheme.secondary)
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              Text(`${item.questionCount > 0 ? Math.round(item.correctCount / item.questionCount * 100) : 0}%`).fontSize(17).fontColor('#0F766E')
            }.width('100%')
          }, (item: PointMasteryUpdate) => item.knowledgePointId)
        }.width('100%').padding(14).backgroundColor(UiTheme.surface).borderRadius(8)
      }

      if (this.sourceMode !== 'document_bank') {
        Text(`本轮需复习：${this.weakPointText(value)}`).fontSize(14).fontColor(UiTheme.secondary)
      }


      Text(value.planChangeSummary ?? '本轮测评结果已保存。').fontSize(14).fontColor('#0F766E')

      Text(this.sourceMode === 'document_bank' ? '查看答案与错题 ›' : '查看题目与逐题解析 ›')
        .fontSize(14).fontColor(UiTheme.accent)
        .width('100%').padding({ top: 12, bottom: 12 }).onClick(() => this.openReview())

      if (value.needReplan && value.planDiff !== undefined) {
        Text('已根据本次结果调整复习安排 · 查看原因 ›').fontSize(13).fontColor(UiTheme.secondary)
          .stateStyles({ normal: { .fontColor(UiTheme.accent).backgroundColor(UiTheme.surface) }, pressed: { .fontColor(UiTheme.surface).backgroundColor(UiTheme.accent) } }).onClick(() => router.pushUrl({ url: 'pages/StudyPlan' }))
      }

      if (this.sourceMode === 'document_bank') {
        Button('继续抽题').width('100%').height(46).backgroundColor(UiTheme.accent)
          .onClick(() => { void this.loadBankOptions(); })
      } else {
      FollowUpCard({
        outlinedActions: false,
        title: '接下来',
        reason: value.needReplan && value.planDiff !== undefined
          ? '已根据本次知识点评估调整计划。建议先查看变化，再选择下一项学习任务。'
          : value.needReplan
            ? '建议根据各知识点评估生成或调整学习计划。'
            : '本次评估已记录，可以查看知识画像或继续练习。',
        primaryText: this.learningGoalId.length > 0 ? '返回对话查看本目标结果' : '再练一组同类题',
        secondaryText: '看更新后的知识画像',
        secondaryTarget: 'pages/StudyTags',
        showAgentTraceLink: false,
        onPrimary: (): void => { if (this.learningGoalId.length > 0) router.back(); else this.restartPractice(); }
      })
      }

      Row({ space: 20 }) {
        if (this.sourceMode !== 'document_bank') {
          Text('换一个知识点练 ›').fontSize(14).fontColor(UiTheme.accent).height(44).onClick(() => this.backToPicker())
        }
        Text('返回首页 ›').fontSize(14).fontColor(UiTheme.secondary).height(44).onClick(() => router.pushUrl({ url: 'pages/Index' }))
      }.width('100%').justifyContent(FlexAlign.Center)
    }.width('100%')
  }

  @Builder
  KnowledgePointPicker() {
    Column({ space: 12 }) {
      Column({ space: 4 }) {
        Text('按知识点练习').fontSize(24).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).width('100%')
        Text(AgentApiClient.getConfig().useFixture ? '选一个知识点开始练习。' : '选一个知识点，AI 会为你生成一组新题。')
          .fontSize(14).fontColor(UiTheme.secondary).lineHeight(21).width('100%')
        Row({ space: 8 }) {
          if (this.sourceMode !== 'document_bank' && !this.isSubmitting && this.result === null && this.learningGoalId.length === 0) {
            this.PhotoPracticeLink(true)
          }
          if (!AgentApiClient.getConfig().useFixture) {
            Button('练题库原题 ›', { type: ButtonType.Normal }).height(UiTheme.touch)
              .fontSize(13).fontColor(UiTheme.accent).backgroundColor(Color.Transparent)
              .padding({ left: 0, right: 8 }).onClick(() => this.launchBank())
          }
        }.width('100%')
      }.width('100%')

      if (this.pickerErrorMessage.length > 0) {
        Text(this.pickerErrorMessage)
          .fontSize(13).fontColor('#B45309').lineHeight(19).width('100%')
          .padding(12).backgroundColor('#FFFBEB').borderRadius(8)
      }

      Column({ space: 8 }) {
        Row() {
          Text('筛选知识点').fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).layoutWeight(1)
          Button('管理知识点 ›', { type: ButtonType.Normal }).height(UiTheme.touch)
            .fontSize(12).fontColor(UiTheme.accent).backgroundColor(Color.Transparent).padding({ left: 8, right: 0 })
            .onClick(() => router.pushUrl({ url: 'pages/KnowledgeCatalog', params: { courseName: this.selectedCourse } }))
        }.width('100%')
        Row({ space: 8 }) {
          Select(this.pickerCourses().map((name: string): SelectOption => { return { value: name }; }))
            .value(this.selectedCourse || '选择课程').layoutWeight(1)
            .onSelect((index: number) => this.selectPickerCourse(this.pickerCourses()[index]))
          if (this.topicChoices().length > 1) {
            Select(this.topicChoices().map((name: string): SelectOption => { return { value: name }; }))
              .value(this.selectedTopic).layoutWeight(1)
              .onSelect((index: number) => this.selectedTopic = this.topicChoices()[index])
          }
        }.width('100%')
        if (this.pickerOptions.length > 0 || this.selectedCourse) {
          TextInput({ text: this.pointSearch, placeholder: '搜索知识点' }).width('100%')
            .backgroundColor(UiTheme.surface).onChange((v: string) => this.pointSearch = v)
        }
      }.width('100%').padding({ left: 12, right: 12, top: 2, bottom: 12 })
        .backgroundColor(UiTheme.subtle).borderRadius(UiTheme.radius)
      if (this.pickerOptions.some((p: KnowledgeMastery) => p.classificationRequired === true)) {
        Text('部分内容未能识别所属课程，请手动匹配后开始练习 ›').fontSize(13).fontColor('#B45309').width('100%')
          .onClick(() => router.pushUrl({ url: 'pages/KnowledgeCatalog', params: { matching: 'true' } }))
      }
      if (this.pickerOptions.length === 0 && !this.selectedCourse) {
        Column({ space: 12 }) {
          Text('还没有可练的知识点').fontSize(16).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).width('100%')
          if (this.isDemoIdentity()) {
            Text('当前是游客演示身份，可以先用演示知识点体验完整练习流程。')
              .fontSize(13).fontColor(UiTheme.secondary).lineHeight(20).width('100%')
            Button('先用演示知识点练一轮')
              .width('100%').height(46).fontSize(15).fontWeight(FontWeight.Bold).fontColor(UiTheme.surface)
              .backgroundColor(UiTheme.accent).borderRadius(8)
              .onClick(() => this.practiceDemoPoint())
          } else {
            Text('先上传课程或资料，或拍一道错题完成诊断。系统会根据你的真实内容生成知识点和练习。')
              .fontSize(13).fontColor(UiTheme.secondary).lineHeight(20).width('100%')
            Button('去上传课程 / 资料')
              .width('100%').height(46).fontSize(15).fontWeight(FontWeight.Bold).fontColor(UiTheme.surface)
              .backgroundColor(UiTheme.accent).borderRadius(8)
              .onClick(() => router.pushUrl({ url: 'pages/CourseImport', params: { initialTab: 'import' } }))
            Button('去做错题诊断')
              .width('100%').height(44).fontSize(14).fontColor(UiTheme.accent).backgroundColor(UiTheme.surface)
              .border({ width: 1, color: '#BFDBFE' }).borderRadius(8)
              .onClick(() => router.pushUrl({ url: 'pages/WrongQuestion' }))
          }
        }.width('100%').padding(16).backgroundColor(UiTheme.surface).borderRadius(8)
      } else {
        Scroll() {
        Row({ space: 4 }) {
          ForEach(['推荐', '需巩固', '待复测', '未测评', '全部'], (name: string) => {
            Button(name).fontSize(12).height(UiTheme.touch).backgroundColor(this.pointFilter === name ? UiTheme.accent : UiTheme.subtle)
              .fontColor(this.pointFilter === name ? UiTheme.surface : UiTheme.secondary).onClick(() => this.pointFilter = name)
          }, (name: string) => name)
        }
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').align(Alignment.TopStart)
        Row({ space: 8 }) {
          Text(this.pointFilter === '推荐' && !this.pointSearch ? '推荐知识点' : '知识点列表')
            .fontSize(17).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).layoutWeight(1)
          Button('判定说明 ›', { type: ButtonType.Normal }).height(UiTheme.touch)
            .fontSize(12).fontColor(UiTheme.secondary).backgroundColor(Color.Transparent)
            .padding({ left: 4, right: 0 }).onClick(() => this.showCriteria())
        }.width('100%')
        if (this.outlineMessage()) {
          Text(this.outlineMessage()).fontSize(13).lineHeight(20).width('100%')
            .fontColor(this.outlineStatus === 'ready' || this.outlineStatus === 'outline_topics' ? UiTheme.accent : UiTheme.secondary)
            .padding(10).backgroundColor(UiTheme.subtle).borderRadius(8)
        }
        if (!this.outlineLoading && this.coursePoints().length === 0) {
          Text('暂无符合条件的知识点，可调整筛选或去资料库确认知识点。').fontSize(13).fontColor(UiTheme.secondary)
        }
        GridRow({
          columns: { xs: 1, sm: 2 }, gutter: { x: 20, y: 12 },
          breakpoints: { value: ['780vp'], reference: BreakpointsReference.ComponentSize }
        }) {
          ForEach(this.coursePoints().slice(0, 20), (item: KnowledgeMastery, index: number) => {
            GridCol() {
              Column({ space: 8 }) {
                Row({ space: 8 }) {
                  Text(item.knowledgePointName)
                    .fontSize(16).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).layoutWeight(1)
                  if (index === 0 && this.pickerAssessed(item)) {
                    Text('可继续练习').fontSize(11).fontColor('#B45309').backgroundColor('#FEF3C7')
                      .borderRadius(8).padding({ left: 8, right: 8, top: 3, bottom: 3 })
                  }
                  Text(LearningEvidence.label(item)).fontSize(12).fontColor(UiTheme.secondary)
                }.width('100%').alignItems(VerticalAlign.Top)
                if (this.outlineFile(item.knowledgePointId)) {
                  Text(`${this.outlineStatus === 'ready' ? '复习重点' : '复习资料提及'} · ${this.outlineFile(item.knowledgePointId)}`)
                    .fontSize(12).fontColor(UiTheme.secondary).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                }
                Row({ space: 8 }) {
                  if ((item.effectiveQuestionCount ?? 0) > 0) {
                    Text(`近期正确率 ${LearningEvidence.score(item)}%`).fontSize(12).fontColor(UiTheme.secondary)
                  }
                  Blank().layoutWeight(1)
                  Text(AgentApiClient.getConfig().useFixture ? '开始练习 ›' : '生成练习 ›')
                    .fontSize(13).fontWeight(FontWeight.Medium).fontColor(UiTheme.accent)
                }.width('100%')
              }
              .width('100%').padding(14).backgroundColor(UiTheme.surface).borderRadius(8)
              .border({ width: 1, color: UiTheme.line })
              .onClick(() => this.chooseKnowledgePoint(item))
            }
          }, (item: KnowledgeMastery) => `${item.knowledgePointId}:${this.pickerDataVersion}`)
        }.width('100%').alignItems(ItemAlign.Start)
      }
    }.width('100%')
  }

  @Builder
  BankPicker() {
    Column({ space: 14 }) {
      Text('选题库和题数').fontSize(21).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink)
      if (this.bankLoading) {
        LoadingProgress().width(26).height(26)
        Text('正在检查文件中可直接判分的原题…').fontSize(14).fontColor(UiTheme.secondary)
      } else if (this.bankError || !this.bankOptions.length) {
        Text(this.bankError || '没有识别到可直接判分的原题。请选择含完整题干、选项和明确答案的 Word 或文本题库。')
          .fontSize(14).lineHeight(21).fontColor(UiTheme.secondary)
        if (this.bankError) Button('重新检查').onClick(() => { void this.loadBankOptions(); })
      } else {
        Select(this.bankOptions.map((item: DocumentBankOption): SelectOption => ({ value: item.fileName })))
          .selected(this.bankIndex).value(this.bankOptions[this.bankIndex]?.fileName ?? '')
          .width('100%').height(UiTheme.touch).onSelect((index: number) => this.selectBank(index))
        Text(`可练 ${this.bankOptions[this.bankIndex]?.count ?? 0} 题 · 未做 ${this.bankOptions[this.bankIndex]?.remaining ?? 0} 题`)
          .fontSize(14).fontColor(UiTheme.ink)
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.bankCounts(), (count: number) => {
            Button(`${count} 题`).height(40).fontSize(14).margin({ right: 8, bottom: 8 })
              .backgroundColor(this.bankCount === count ? UiTheme.accent : UiTheme.tint)
              .fontColor(this.bankCount === count ? UiTheme.surface : UiTheme.accent)
              .onClick(() => this.bankCount = count)
          }, (count: number) => `${count}`)
        }.width('100%')
        Text(this.bankCount > (this.bankOptions[this.bankIndex]?.remaining ?? 0) ?
          '未做题不足，本轮会补入已做过的题。' : '优先抽未做过的题，交卷后按原题答案判分。')
          .fontSize(13).fontColor(UiTheme.secondary).lineHeight(20)
        Button(`开始练 ${this.bankCount} 题`).width('100%').height(46).backgroundColor(UiTheme.accent)
          .enabled(this.bankCount > 0).onClick(() => this.startBankRound())
      }
    }.width('100%').padding(16).backgroundColor(UiTheme.surface).borderRadius(8).alignItems(HorizontalAlign.Start)
  }

  @Builder
  ChangePointButton() {
    Button('换知识点', { type: ButtonType.Normal }).height(UiTheme.touch).fontSize(13)
      .fontColor(UiTheme.accent).backgroundColor(UiTheme.tint).borderRadius(UiTheme.radius).enabled(!this.isSubmitting)
      .onClick(() => this.backToPicker())
  }

  @Builder
  CriteriaSection(label: string, explanation: string) {
    Column({ space: 5 }) {
      Text(label).fontSize(15).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
      Text(explanation).fontSize(14).lineHeight(22).fontColor(UiTheme.secondary).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  CriteriaSheet() {
    Scroll() {
      Column({ space: 16 }) {
        this.CriteriaSection('掌握估计怎么算', '综合有效作答，最近 20 道有效题权重较高。题量少时，估计更接近中间值。重复作答同一道题不增加证据。')
        Divider().color(UiTheme.line)
        this.CriteriaSection('未测评', '暂无有效作答。')
        this.CriteriaSection('证据较少', '近期有效题不足 8 道、少于 2 轮，或难度覆盖不足以确认表现稳定。')
        this.CriteriaSection('需巩固', '已有一定作答记录，但尚未达到稳定标准，或延后复测的表现偏低。')
        this.CriteriaSection('表现较稳定', '近期正确率至少 80%，掌握估计至少 70 分，并达到题量、轮次与难度覆盖要求。')
        this.CriteriaSection('待复测', '距上一次有效作答已满 7 天。')
        Button('知道了').height(UiTheme.touch).width('100%').onClick(() => this.criteriaVisible = false)
      }.width('100%').padding({ left: 20, right: 20, top: 12, bottom: 24 })
    }.width('100%').height('100%').align(Alignment.TopStart)
  }

  @Builder
  PhotoPracticeLink(compact: boolean) {
    Button('解答题练习 ›', { type: ButtonType.Normal })
      .width(compact ? 'auto' : '100%').height(UiTheme.touch).borderRadius(UiTheme.radius)
      .fontSize(compact ? 13 : 15).fontColor(UiTheme.accent)
      .backgroundColor(compact ? Color.Transparent : UiTheme.tint)
      .padding({ left: compact ? 0 : 12, right: 12 })
      .onClick(() => router.pushUrl({ url: 'pages/PhotoPractice', params: {
        courseName: this.selectedCourse,
        knowledgePointId: this.exercises[0]?.knowledgePointId || (this.practiceFromRoute ? this.practiceKnowledgePoint : ''),
        knowledgePointName: this.exercises[0]?.knowledgePointName || this.materialPointName
      } }))
  }

  build() {
    Stack() {
      Column() {
        PageHeader({ title: this.showBankPicker ? '题库原题练习' : this.showPicker || this.pickerLoading ? '选择知识点' :
          this.showReview ? '逐题解析与依据' : this.result !== null ? '练习结果' : '作答与交卷',
          assistant: true, onBack: () => this.goBack() })

        Scroll(this.pageScroller) {
          Column({ space: 16 }) {
            if (this.sourceMode !== 'document_bank' && !this.showPicker && !this.isLoading && !this.sourceVisible && !this.isSubmitting && this.result === null &&
              this.learningGoalId.length === 0) {
              this.PhotoPracticeLink(false)
            }
            if (this.sourceMode !== 'document_bank' && !this.showPicker && !this.pickerLoading && !this.isLoading) {
              Row() { this.ChangePointButton() }.width('100%').justifyContent(FlexAlign.End)
            }
            if (this.sourceVisible) {
              this.SourcePanel()
            } else if (this.showBankPicker) {
              this.BankPicker()
            } else if (this.pickerLoading) {
              Column({ space: 10 }) {
                LoadingProgress().width(32).height(32)
                Text('正在读取你的知识点…').fontSize(14).fontColor(UiTheme.secondary)
              }
              .width('100%').padding(32).alignItems(HorizontalAlign.Center)
            } else if (this.showPicker) {
              this.KnowledgePointPicker()
            } else if (this.isLoading) {
              Column({ space: 12 }) {
                LoadingProgress().width(36).height(36)
                Text(this.generatesNewQuestions() ? 'AI 正在生成新题' :
                  this.sourceMode === 'document_bank' ? '正在抽取题库原题' : '正在加载练习')
                  .fontSize(16).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink)
                Text(this.generatesNewQuestions() && this.materialPointName ? `${this.materialPointName} · 已等待 ${this.waitSeconds} 秒` :
                  `已等待 ${this.waitSeconds} 秒`).fontSize(13).fontColor(UiTheme.secondary)
                Button('退出等待').onClick(() => this.leaveWaiting())
              }.width('100%').padding(28)
            } else if (this.result !== null && this.showReview) {
              this.ReviewPanel()
            } else if (this.result !== null) {
              this.ResultPanel(this.result)
            } else if (this.exercises.length === 0) {
              Column({ space: 14 }) {
                Text('练习题暂未加载成功').fontSize(20).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink)
                Text(this.errorMessage || '暂未取得题目，请稍后重试。')
                  .fontSize(14).fontColor(UiTheme.secondary).lineHeight(21).textAlign(TextAlign.Center)
                Button('重新加载')
                  .height(44).fontSize(15).fontColor(UiTheme.surface).backgroundColor(UiTheme.accent).borderRadius(8)
                  .onClick(() => this.loadExercises(true))
                if (this.sourceMode === 'materials') {
                  if (this.sourceDocumentId) {
                    Button('从该文件抽原题').fontSize(14).height(UiTheme.touch)
                      .onClick(() => this.launchBank(this.sourceDocumentId))
                  }
                  Button('改用 AI 出题').fontSize(14).height(UiTheme.touch).onClick(() => this.useGeneralQuestions())
                }
              }.width('100%').margin({ top: 56 }).alignItems(HorizontalAlign.Center)
            } else {
              Text(`${this.practiceTitle()} · ${this.exercises.length} 题${this.sourceMode === 'document_bank' ? '' : '快速诊断'}`)
                .fontSize(22).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).width('100%')
              Text(this.roundOrigin())
                .fontSize(12).fontColor(UiTheme.secondary).lineHeight(20).width('100%')
              Text(`已完成 ${this.answeredCount()} / ${this.exercises.length} 题`).fontSize(13).fontColor(UiTheme.secondary).width('100%')
              ForEach(this.exercises, (item: Exercise, index: number) => {
                this.QuestionCard(item, index)
              }, (item: Exercise) => item.exerciseId)
              if (this.errorMessage.length > 0) {
                Text(this.errorMessage).fontSize(13).fontColor('#B45309').width('100%').padding(12).backgroundColor('#FFFBEB').borderRadius(8)
              }
              Button(this.isSubmitting ? '正在提交…' : (this.submissionUnconfirmed ? '重试确认交卷结果' :
                this.sourceMode === 'document_bank' ? '交卷判分' : '提交诊断'))
                .width('100%').height(48).fontSize(16).fontWeight(FontWeight.Bold).fontColor(UiTheme.surface)
                .backgroundColor(UiTheme.accent).borderRadius(8)
                .enabled(!this.isSubmitting && this.answeredCount() === this.exercises.length)
                .onClick(() => this.submit())
            }
          }.width('100%').constraintSize({ maxWidth: UiTheme.workspaceWidth }).padding({ left: 16, right: 16, top: 16, bottom: 96 })
        }.width('100%').layoutWeight(1).backgroundColor(UiTheme.canvas).align(Alignment.Top)
      }.width('100%').height('100%')
      AIFloatButton()
    }.width('100%').height('100%').bindSheet($$this.criteriaVisible, this.CriteriaSheet(), {
      height: SheetSize.LARGE, title: { title: '练习状态说明' }, showClose: true, dragBar: true, backgroundColor: UiTheme.surface
    })
  }
}
