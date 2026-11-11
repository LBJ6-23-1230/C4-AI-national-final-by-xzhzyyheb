import { TaskSplitRequest, AssessmentActionRequest, CalendarRequest, PointClassification, ProfileResponse, ManualKnowledgePointRequest, KnowledgeMastery } from './ApiModels';
import { ManualTaskRequest, SharedTasks, SharedTaskRequest, ChatFileRequest, ChatFile, TodayItemRequest } from './StudyTaskModels';
import { PartnerInbox, PartnerSummary, PartnerReadRequest, PartnerReadResult, EndPartnerRequest, EndPartnerResult } from './LearningUpgradeModels';
import { CourseSettings, CourseSettingRequest } from './LearningUpgradeModels';
import { PartnerMessages, PartnerMessageRequest, PartnerMessageResult, ScannedQuestionRequest, SavedScannedQuestion, LearningReview, ReviewRequest, ReviewTasks, ReviewTaskRequest } from './LearningUpgradeModels';
import { DocumentBankOptions, ExerciseMaterialOptions, OutlinePracticeRecommendations } from './ApiModels';
import { PhotoPracticeCompletion, PhotoPracticeExercise, PhotoPracticeGrade, PhotoPracticeQuery, PhotoPracticeSubmission, PhotoPracticeWrongBookRequest } from './PhotoPracticeModels';
import { AuthSelectAccountRequest } from './AuthModels';
import { LearningRecords, GoalActionRequest, GoalActionResponse, GoalHistoryResponse } from './ApiModels';
import { AuthProfileUpdateRequest } from './AuthModels';
import { LearningPreferencesRequest, DocumentPointsRequest } from './ApiModels';
import { http } from '@kit.NetworkKit';
import { CollaborationRequest, CollaborationResponse } from './DeviceCollaborationModels';
import { SharedFocusRequest, SharedFocusResponse } from './SharedFocusModels';
import { LearningChanges, LearningSnapshot, LearningEffect } from './LearningSyncModels';
import { ExerciseSourcesResponse } from './ApiModels';
import { LearningContext } from './ApiModels';
import { WrongBookClassifyRequest, WrongBookClassifyResponse, API_CONTRACT_VERSION, DemoResetResponse, PartnerContactListResponse, PartnerInvitationCreateRequest, PartnerInvitationListResponse, PartnerInvitationResponse, PartnerMatchRequest, PartnerMatchResponse, ExerciseQuery, ExerciseSetResponse, ExerciseSubmission, ExerciseSubmissionResult, KnowledgeBase, KnowledgeBaseCreateRequest, KnowledgeBaseDetail, KnowledgeBaseListResponse, KnowledgeDocument, KnowledgeDocumentDetail, KnowledgeDocumentUploadRequest, KnowledgeSearchRequest, KnowledgeSearchResponse, LearningPlan, PlanDiff, ProactiveRequest, ProactiveResponse, ScheduleRecognitionRequest, ScheduleRecognitionResponse, TraceResponse, WorkflowCreateRequest, WorkflowResponse, WorkflowRunRequest, WorkflowRunResponse, WorkflowStatusResponse, WrongBookAttemptRequest, WrongBookAttemptResponse, WrongBookResponse, WrongBookToggleRequest, WrongBookToggleResponse } from './ApiModels';
import { ApiFailure, ApiResult, apiFailure, apiSuccess } from './ApiResult';
import { ApiDefaults } from './ApiDefaults';
import { AuthChangePasswordRequest, AuthChangePasswordResponse, AuthHuaweiLoginRequest, AuthLoginOrRegisterRequest, AuthLoginOrRegisterResponse, AuthLoginRequest, AuthRegisterRequest, AuthSendCodeRequest, AuthSendCodeResponse, AuthSessionResponse, AuthStatusResponse, AuthUserResponse, AuthVerifyCodeRequest } from './AuthModels';
import { AuthStore } from './AuthStore';
import { FixtureApiTransport } from './FixtureApiTransport';
import { ApiResponseValidator } from './ApiResponseValidator';
import { FocusSession } from '../models/AgentModels';
import { FocusSaveResponse } from './ApiModels';
import { PlanBudgetRequest, PlanBudgetResponse, PlanTaskScheduleRequest } from './ApiModels';
import { AssignmentSyncRequest } from './ApiModels';
import { TodayOverview, ReminderList, ReminderAction, ReminderActionResult, ReminderSettings, ReminderPreferences, ReminderDevice, ReminderDeviceResult } from './ReminderModels';

export interface FocusHistoryResponse {
  userId: string;
  sessions: FocusSession[];
}

export interface ApiClientConfig {
  baseUrl: string;
  useFixture: boolean;
  timeoutMs: number;
}

export interface BackendReadiness {
  status: string;
}

interface KnowledgePointImportRequest {
  courses: string[];
}

export class AgentApiClient {
  static async generatePhotoPractice(body: PhotoPracticeQuery): Promise<ApiResult<PhotoPracticeExercise>> {
    return AgentApiClient.request<PhotoPracticeExercise>(http.RequestMethod.POST, '/api/v1/exercises/photo-practice/generate',
      body, ApiDefaults.LLM_BOUND_READ_TIMEOUT_MS);
  }

  static async gradePracticePhoto(exerciseId: string, body: PhotoPracticeSubmission): Promise<ApiResult<PhotoPracticeGrade>> {
    return AgentApiClient.request<PhotoPracticeGrade>(http.RequestMethod.POST,
      `/api/v1/exercises/photo-practice/${encodeURIComponent(exerciseId)}/grade`, body, 60000);
  }

  static async completePhotoPractice(exerciseId: string, body: PhotoPracticeCompletion): Promise<ApiResult<PhotoPracticeGrade>> {
    return AgentApiClient.request<PhotoPracticeGrade>(http.RequestMethod.POST,
      `/api/v1/exercises/photo-practice/${encodeURIComponent(exerciseId)}/complete`, body, 60000);
  }

  static async savePhotoPracticeWrongBook(exerciseId: string, body: PhotoPracticeWrongBookRequest): Promise<ApiResult<WrongBookToggleResponse>> {
    return AgentApiClient.request<WrongBookToggleResponse>(http.RequestMethod.POST,
      `/api/v1/exercises/photo-practice/${encodeURIComponent(exerciseId)}/wrong-book`, body);
  }

  static async addTodayItem(body: TodayItemRequest): Promise<ApiResult<LearningPlan>> {
    return AgentApiClient.request<LearningPlan>(http.RequestMethod.POST, '/api/v1/plans/current/today-items', body);
  }
  static async readChatFile(body: ChatFileRequest): Promise<ApiResult<ChatFile>> {
    return AgentApiClient.request<ChatFile>(http.RequestMethod.POST, '/api/v1/chat-files', body, 60000);
  }
  static async saveManualTask(body: ManualTaskRequest): Promise<ApiResult<LearningPlan>> {
    return AgentApiClient.request<LearningPlan>(http.RequestMethod.POST, '/api/v1/study-tasks', body);
  }
  static async sharedTasks(): Promise<ApiResult<SharedTasks>> {
    return AgentApiClient.request<SharedTasks>(http.RequestMethod.GET, '/api/v1/shared-study-tasks');
  }
  static async sharedTaskAction(body: SharedTaskRequest): Promise<ApiResult<SharedTasks>> {
    return AgentApiClient.request<SharedTasks>(http.RequestMethod.POST, '/api/v1/shared-study-tasks', body);
  }
  static async deviceCollaboration(body: CollaborationRequest): Promise<ApiResult<CollaborationResponse>> {
    return AgentApiClient.request<CollaborationResponse>(http.RequestMethod.POST, '/api/v1/device-collaboration', body, 10000);
  }
  static async sharedFocus(deviceId: string, deviceKey: string): Promise<ApiResult<SharedFocusResponse>> {
    return AgentApiClient.request<SharedFocusResponse>(http.RequestMethod.GET,
      '/api/v1/focus-session', undefined, 10000, { 'X-Device-Id': deviceId, 'X-Device-Key': deviceKey });
  }
  static async sharedFocusAction(body: SharedFocusRequest): Promise<ApiResult<SharedFocusResponse>> {
    return AgentApiClient.request<SharedFocusResponse>(http.RequestMethod.POST, '/api/v1/focus-session/actions', body, 10000);
  }
  static async getLearningRecords(cursor: string = '', chatSessionId: string = ''): Promise<ApiResult<LearningRecords>> {
    return AgentApiClient.request<LearningRecords>(http.RequestMethod.GET, `/api/v1/learning-records?limit=20&cursor=${encodeURIComponent(cursor)}&chatSessionId=${encodeURIComponent(chatSessionId)}`);
  }
  static async getLearningData(): Promise<ApiResult<LearningSnapshot>> {
    return AgentApiClient.request<LearningSnapshot>(http.RequestMethod.GET, '/api/v1/learning-data');
  }
  static async saveLearningData(body: LearningChanges): Promise<ApiResult<LearningSnapshot>> {
    return AgentApiClient.request<LearningSnapshot>(http.RequestMethod.POST, '/api/v1/learning-data', body);
  }
  static async getLearningEffect(days: number = 1): Promise<ApiResult<LearningEffect>> {
    return AgentApiClient.request<LearningEffect>(http.RequestMethod.GET, `/api/v1/learning-effect?days=${days}`);
  }
  static async getToday(): Promise<ApiResult<TodayOverview>> {
    return AgentApiClient.request<TodayOverview>(http.RequestMethod.GET, '/api/v1/today');
  }
  static async getReminders(cursor: string = ''): Promise<ApiResult<ReminderList>> {
    return AgentApiClient.request<ReminderList>(http.RequestMethod.GET, `/api/v1/reminders?after=${encodeURIComponent(cursor)}`);
  }
  static async reminderAction(eventId: string, data: ReminderAction): Promise<ApiResult<ReminderActionResult>> {
    const token: string = AuthStore.getToken();
    const baseUrl: string = AgentApiClient.config.baseUrl;
    const result = await AgentApiClient.request<ReminderActionResult>(http.RequestMethod.POST, `/api/v1/reminders/${encodeURIComponent(eventId)}/actions`, data);
    if (result.ok) return result;
    const failure: ApiFailure = result as ApiFailure;
    if (!['NETWORK_ERROR', 'INVALID_RESPONSE', 'EMPTY_RESPONSE'].includes(failure.error.code)) return result;
    if (token !== AuthStore.getToken() || baseUrl !== AgentApiClient.config.baseUrl)
      return apiFailure('IDENTITY_CHANGED', '请重新打开页面。', false, 'network');
    const confirmed = await AgentApiClient.request<ReminderActionResult>(http.RequestMethod.GET,
      `/api/v1/reminders/${encodeURIComponent(eventId)}/actions/${encodeURIComponent(data.idempotencyKey)}`);
    if (confirmed.ok) return confirmed;
    return apiFailure('RESULT_UNCONFIRMED', '暂未确认，请重试。', true, 'network');
  }
  static async getReminderSettings(): Promise<ApiResult<ReminderSettings>> {
    return AgentApiClient.request<ReminderSettings>(http.RequestMethod.GET, '/api/v1/reminder-preferences');
  }
  static async saveReminderSettings(data: ReminderPreferences): Promise<ApiResult<ReminderSettings>> {
    return AgentApiClient.request<ReminderSettings>(http.RequestMethod.PUT, '/api/v1/reminder-preferences', data);
  }
  static async bindReminderDevice(data: ReminderDevice): Promise<ApiResult<ReminderDeviceResult>> {
    return AgentApiClient.request<ReminderDeviceResult>(http.RequestMethod.POST, '/api/v1/reminder-devices', data);
  }
  static async partnerInbox(offset: number = 0): Promise<ApiResult<PartnerInbox>> {
    return AgentApiClient.request<PartnerInbox>(http.RequestMethod.GET, `/api/v1/partner-conversations?offset=${offset}`);
  }
  static async partnerSummary(partner: string): Promise<ApiResult<PartnerSummary>> {
    return AgentApiClient.request<PartnerSummary>(http.RequestMethod.GET, `/api/v1/partners/${encodeURIComponent(partner)}/summary`);
  }
  static async markPartnerRead(partner: string, body: PartnerReadRequest): Promise<ApiResult<PartnerReadResult>> {
    return AgentApiClient.request<PartnerReadResult>(http.RequestMethod.POST, `/api/v1/partners/${encodeURIComponent(partner)}/read`, body);
  }
  static async endPartnerRelationship(partner: string, body: EndPartnerRequest): Promise<ApiResult<EndPartnerResult>> {
    return AgentApiClient.request<EndPartnerResult>(http.RequestMethod.POST, `/api/v1/partners/${encodeURIComponent(partner)}/end`, body);
  }

  static async courseSettings(): Promise<ApiResult<CourseSettings>> {
    return AgentApiClient.request<CourseSettings>(http.RequestMethod.GET, '/api/v1/learning-course-settings');
  }
  static async saveCourseSettings(body: CourseSettingRequest): Promise<ApiResult<CourseSettings>> {
    return AgentApiClient.request<CourseSettings>(http.RequestMethod.POST, '/api/v1/learning-course-settings', body);
  }

  static async partnerMessages(partner: string, cursor: string): Promise<ApiResult<PartnerMessages>> {
    return AgentApiClient.request<PartnerMessages>(http.RequestMethod.GET, `/api/v1/partners/${encodeURIComponent(partner)}/messages?after=${encodeURIComponent(cursor)}`);
  }
  static async recallPartnerMessage(partner: string, id: string): Promise<ApiResult<PartnerMessageResult>> {
    return AgentApiClient.request<PartnerMessageResult>(http.RequestMethod.POST,
      `/api/v1/partners/${encodeURIComponent(partner)}/messages/${encodeURIComponent(id)}/recall`);
  }
  static async sendPartnerMessage(partner: string, body: PartnerMessageRequest): Promise<ApiResult<PartnerMessageResult>> {
    return AgentApiClient.request<PartnerMessageResult>(http.RequestMethod.POST, `/api/v1/partners/${encodeURIComponent(partner)}/messages`, body);
  }
  static async saveScannedQuestion(body: ScannedQuestionRequest): Promise<ApiResult<SavedScannedQuestion>> {
    return AgentApiClient.request<SavedScannedQuestion>(http.RequestMethod.POST, '/api/v1/wrong-book/scanned', body);
  }
  static async learningReview(body: ReviewRequest): Promise<ApiResult<LearningReview>> {
    return AgentApiClient.request<LearningReview>(http.RequestMethod.POST, '/api/v1/learning-reviews', body, ApiDefaults.LLM_BOUND_READ_TIMEOUT_MS);
  }
  static async acceptLearningReview(id: string): Promise<ApiResult<ReviewTasks>> {
    return AgentApiClient.request<ReviewTasks>(http.RequestMethod.POST, `/api/v1/learning-reviews/${encodeURIComponent(id)}/accept`);
  }
  static async reviewTasks(): Promise<ApiResult<ReviewTasks>> {
    return AgentApiClient.request<ReviewTasks>(http.RequestMethod.GET, '/api/v1/learning-review-tasks');
  }
  static async completeReviewTask(body: ReviewTaskRequest): Promise<ApiResult<ReviewTasks>> {
    return AgentApiClient.request<ReviewTasks>(http.RequestMethod.POST, '/api/v1/learning-review-tasks/complete', body);
  }

  static async syncAssignments(request: AssignmentSyncRequest): Promise<ApiResult<LearningPlan>> {
    return AgentApiClient.request<LearningPlan>(http.RequestMethod.POST,
      '/api/v1/plans/current/assignments', request);
  }
  private static config: ApiClientConfig = {
    baseUrl: ApiDefaults.DEFAULT_BASE_URL,
    useFixture: ApiDefaults.DEFAULT_USE_FIXTURE,
    timeoutMs: ApiDefaults.DEFAULT_TIMEOUT_MS
  };

  static getConfig(): ApiClientConfig {
    return { baseUrl: AgentApiClient.config.baseUrl, useFixture: AgentApiClient.config.useFixture, timeoutMs: AgentApiClient.config.timeoutMs };
  }

  static configure(config: ApiClientConfig): void {
    if (!ApiDefaults.ALLOW_DEBUG) {
      AgentApiClient.config = { baseUrl: ApiDefaults.DEFAULT_BASE_URL, useFixture: false,
        timeoutMs: ApiDefaults.DEFAULT_TIMEOUT_MS };
      return;
    }
    AgentApiClient.config = { baseUrl: AgentApiClient.normalizeBaseUrl(config.baseUrl), useFixture: config.useFixture, timeoutMs: config.timeoutMs };
  }

  static setBaseUrl(baseUrl: string): void {
    if (ApiDefaults.ALLOW_DEBUG) AgentApiClient.config.baseUrl = AgentApiClient.normalizeBaseUrl(baseUrl);
  }
  static setUseFixture(useFixture: boolean): void {
    AgentApiClient.config.useFixture = ApiDefaults.ALLOW_DEMO && useFixture;
  }

  static async createWorkflow(request: WorkflowCreateRequest): Promise<ApiResult<WorkflowResponse>> {
    return AgentApiClient.request<WorkflowResponse>(http.RequestMethod.POST, '/api/v1/workflows', request);
  }

  static async getWorkflow(sessionId: string): Promise<ApiResult<WorkflowStatusResponse>> {
    return AgentApiClient.request<WorkflowStatusResponse>(http.RequestMethod.GET, `/api/v1/workflows/${encodeURIComponent(sessionId)}`);
  }

  static async runWorkflow(sessionId: string, request?: WorkflowRunRequest): Promise<ApiResult<WorkflowRunResponse>> {
    return AgentApiClient.request<WorkflowRunResponse>(http.RequestMethod.POST,
      `/api/v1/workflows/${encodeURIComponent(sessionId)}/run`, request,
      ApiDefaults.LLM_BOUND_READ_TIMEOUT_MS);
  }

  static async importKnowledgePoints(userId: string, courses: string[]): Promise<ApiResult<ProfileResponse>> {
    const payload: KnowledgePointImportRequest = { courses: courses };
    return AgentApiClient.request<ProfileResponse>(http.RequestMethod.POST,
      `/api/v1/profile/${encodeURIComponent(userId)}/knowledge-points`, payload,
      ApiDefaults.LLM_BOUND_READ_TIMEOUT_MS);
  }

  static async createKnowledgePoint(userId: string, body: ManualKnowledgePointRequest): Promise<ApiResult<KnowledgeMastery>> {
    if (AgentApiClient.getConfig().useFixture) {
      return apiFailure('OFFLINE', '新增知识点需要连接服务端，请联网后重试。', true, 'fixture');
    }
    return AgentApiClient.request<KnowledgeMastery>(http.RequestMethod.POST,
      `/api/v1/profile/${encodeURIComponent(userId)}/knowledge-points/manual`, body);
  }

  static async saveLearningPreferences(userId: string, request: LearningPreferencesRequest): Promise<ApiResult<ProfileResponse>> {
    return AgentApiClient.request<ProfileResponse>(http.RequestMethod.PUT,
      `/api/v1/profile/${encodeURIComponent(userId)}/preferences`, request);
  }
  static async reviseDocumentPoints(id: string, request: DocumentPointsRequest): Promise<ApiResult<KnowledgeDocument>> {
    return AgentApiClient.request<KnowledgeDocument>(http.RequestMethod.PUT,
      `/api/v1/documents/${encodeURIComponent(id)}/knowledge-points`, request);
  }
  static async getSubmissionReview(id: string): Promise<ApiResult<ExerciseSubmissionResult>> {
    return AgentApiClient.request<ExerciseSubmissionResult>(http.RequestMethod.GET,
      `/api/v1/exercise-submissions/${encodeURIComponent(id)}`);
  }
  static async getChatGoalHistory(chatId: string): Promise<ApiResult<GoalHistoryResponse>> {
    return AgentApiClient.request<GoalHistoryResponse>(http.RequestMethod.GET, `/api/v1/workflows/chat/${encodeURIComponent(chatId)}/goals`);
  }
  static async manageChatGoal(chatId: string, request: GoalActionRequest): Promise<ApiResult<GoalActionResponse>> {
    return AgentApiClient.request<GoalActionResponse>(http.RequestMethod.POST, `/api/v1/workflows/chat/${encodeURIComponent(chatId)}/goals`, request);
  }
  static async acceptAssessmentAction(body: AssessmentActionRequest): Promise<ApiResult<LearningPlan>> {
    return AgentApiClient.request<LearningPlan>(http.RequestMethod.POST, '/api/v1/plans/current/recommendation', body);
  }

  static async splitPlanTask(body: TaskSplitRequest): Promise<ApiResult<LearningPlan>> {
    return AgentApiClient.request<LearningPlan>(http.RequestMethod.POST, '/api/v1/plans/current/tasks/split', body);
  }

  static async scheduleCalendar(body: CalendarRequest): Promise<ApiResult<LearningPlan>> {
    return AgentApiClient.request<LearningPlan>(http.RequestMethod.POST, '/api/v1/plans/current/calendar', body);
  }

  static async classifyKnowledgePoint(userId: string, body: PointClassification): Promise<ApiResult<ProfileResponse>> {
    return AgentApiClient.request<ProfileResponse>(http.RequestMethod.PUT, `/api/v1/profile/${encodeURIComponent(userId)}/knowledge-points/classification`, body);
  }

  static async getProfile(userId: string): Promise<ApiResult<ProfileResponse>> {
    return AgentApiClient.request<ProfileResponse>(http.RequestMethod.GET, `/api/v1/profile/${encodeURIComponent(userId)}`);
  }

  static async getCurrentPlan(): Promise<ApiResult<LearningPlan>> {
    return AgentApiClient.request<LearningPlan>(http.RequestMethod.GET, '/api/v1/plans/current');
  }

  static async checkBackendConnection(): Promise<ApiResult<BackendReadiness>> {
    if (AgentApiClient.config.useFixture) {
      return apiFailure('OFFLINE_MODE', '当前为离线演示，请切换到真实后端后检测。', false, 'fixture');
    }
    return AgentApiClient.request<BackendReadiness>(http.RequestMethod.GET, '/ready');
  }

  static async updatePlanBudget(request: PlanBudgetRequest): Promise<ApiResult<PlanBudgetResponse>> {
    return AgentApiClient.request<PlanBudgetResponse>(http.RequestMethod.POST, '/api/v1/plans/current/availability', request);
  }

  static async schedulePlanTask(request: PlanTaskScheduleRequest): Promise<ApiResult<PlanBudgetResponse>> {
    return AgentApiClient.request<PlanBudgetResponse>(http.RequestMethod.POST, '/api/v1/plans/current/tasks/schedule', request);
  }

  static async saveFocusSession(session: FocusSession): Promise<ApiResult<FocusSaveResponse>> {
    return AgentApiClient.request<FocusSaveResponse>(http.RequestMethod.POST, '/api/v1/focus-sessions', session);
  }

  static async getFocusHistory(): Promise<ApiResult<FocusHistoryResponse>> {
    return AgentApiClient.request<FocusHistoryResponse>(http.RequestMethod.GET, '/api/v1/focus-sessions');
  }

  static async getChatLearningContext(chatSessionId: string): Promise<ApiResult<LearningContext>> {
    return AgentApiClient.request<LearningContext>(http.RequestMethod.GET,
      `/api/v1/workflows/chat/${encodeURIComponent(chatSessionId)}`);
  }

  static async getExerciseSources(exerciseId: string): Promise<ApiResult<ExerciseSourcesResponse>> {
    return AgentApiClient.request<ExerciseSourcesResponse>(http.RequestMethod.GET,
      `/api/v1/exercises/${encodeURIComponent(exerciseId)}/sources`);
  }

  static async getExerciseMaterialOptions(point: string, course: string): Promise<ApiResult<ExerciseMaterialOptions>> {
    const path: string = `/api/v1/exercises/material-options?knowledgePointId=${encodeURIComponent(point)}&courseName=${encodeURIComponent(course)}`;
    return AgentApiClient.request<ExerciseMaterialOptions>(http.RequestMethod.GET, path);
  }

  static async getDocumentBanks(course: string, documentId: string): Promise<ApiResult<DocumentBankOptions>> {
    return AgentApiClient.request<DocumentBankOptions>(http.RequestMethod.GET,
      `/api/v1/exercises/document-banks?courseName=${encodeURIComponent(course)}&documentId=${encodeURIComponent(documentId)}`);
  }

  static async getOutlinePracticeRecommendations(course: string): Promise<ApiResult<OutlinePracticeRecommendations>> {
    const path: string = `/api/v1/exercises/outline-recommendations?courseName=${encodeURIComponent(course)}`;
    return AgentApiClient.request<OutlinePracticeRecommendations>(http.RequestMethod.GET, path,
      undefined, ApiDefaults.LLM_BOUND_READ_TIMEOUT_MS);
  }

  static async getExerciseSet(setId: string, query?: ExerciseQuery): Promise<ApiResult<ExerciseSetResponse>> {
    let path: string = `/api/v1/exercises/${encodeURIComponent(setId)}`;
    if (query !== undefined) {
      const parameters: string[] = [];
      if (query.roundId) parameters.push(`roundId=${encodeURIComponent(query.roundId)}`);
      if (query.sourceMode !== undefined) parameters.push(`sourceMode=${encodeURIComponent(query.sourceMode)}`);
      if (query.kbId !== undefined) parameters.push(`kbId=${encodeURIComponent(query.kbId)}`);
      if (query.documentId !== undefined) parameters.push(`documentId=${encodeURIComponent(query.documentId)}`);
      if (query.courseName) parameters.push(`courseName=${encodeURIComponent(query.courseName)}`);
      if (query.knowledgePointId !== undefined && query.knowledgePointId.trim().length > 0) {
        parameters.push(`knowledgePointId=${encodeURIComponent(query.knowledgePointId)}`);
      }
      if (query.difficulty !== undefined && query.difficulty.trim().length > 0) {
        parameters.push(`difficulty=${encodeURIComponent(query.difficulty)}`);
      }
      if (query.count !== undefined) {
        parameters.push(`count=${query.count}`);
      }
      if (query.excludeExerciseIds !== undefined) {
        for (let index: number = 0; index < query.excludeExerciseIds.length; index++) {
          parameters.push(`excludeExerciseId=${encodeURIComponent(query.excludeExerciseIds[index])}`);
        }
      }
      if (query.generate === true) {
        parameters.push('generate=1');
      }
      if (query.forceGenerate === true) parameters.push('forceGenerate=1');
      if (parameters.length > 0) {
        path = `${path}?${parameters.join('&')}`;
      }
    }
    return AgentApiClient.request<ExerciseSetResponse>(http.RequestMethod.GET, path, undefined,
      query !== undefined && (query.generate === true || query.forceGenerate === true || query.sourceMode === 'materials')
        ? ApiDefaults.LLM_BOUND_READ_TIMEOUT_MS : undefined);
  }

  static async submitExercise(setId: string, submission: ExerciseSubmission): Promise<ApiResult<ExerciseSubmissionResult>> {
    return AgentApiClient.request<ExerciseSubmissionResult>(http.RequestMethod.POST,
      `/api/v1/exercises/${encodeURIComponent(setId)}/submit`, submission,
      ApiDefaults.LLM_BOUND_READ_TIMEOUT_MS);
  }

  static async classifyWrongBook(exerciseIds: string[], courseName: string): Promise<ApiResult<WrongBookClassifyResponse>> {
    const body: WrongBookClassifyRequest = { exerciseIds: exerciseIds, courseName: courseName };
    return AgentApiClient.request<WrongBookClassifyResponse>(http.RequestMethod.POST, '/api/v1/wrong-book/classify', body);
  }

  static async getWrongBook(): Promise<ApiResult<WrongBookResponse>> {
    return AgentApiClient.request<WrongBookResponse>(http.RequestMethod.GET, '/api/v1/wrong-book');
  }

  static async toggleWrongBook(exerciseId: string, added: boolean): Promise<ApiResult<WrongBookToggleResponse>> {
    const request: WrongBookToggleRequest = { added: added };
    return AgentApiClient.request<WrongBookToggleResponse>(http.RequestMethod.POST,
      `/api/v1/wrong-book/${encodeURIComponent(exerciseId)}`, request);
  }

  static async attemptWrongBook(exerciseId: string, answer: string): Promise<ApiResult<WrongBookAttemptResponse>> {
    const request: WrongBookAttemptRequest = { answer: answer };
    return AgentApiClient.request<WrongBookAttemptResponse>(http.RequestMethod.POST,
      `/api/v1/wrong-book/${encodeURIComponent(exerciseId)}/attempt`, request);
  }

  static async getPlanDiff(planId: string): Promise<ApiResult<PlanDiff>> {
    return AgentApiClient.request<PlanDiff>(http.RequestMethod.GET, `/api/v1/plans/${encodeURIComponent(planId)}/diff`);
  }

  static async getTrace(traceId: string): Promise<ApiResult<TraceResponse>> {
    return AgentApiClient.request<TraceResponse>(http.RequestMethod.GET, `/api/v1/traces/${encodeURIComponent(traceId)}`);
  }

  static async resetDemo(): Promise<ApiResult<DemoResetResponse>> {
    return AgentApiClient.request<DemoResetResponse>(http.RequestMethod.POST, '/api/v1/demo/reset');
  }

  static async recognizeScheduleImage(
    request: ScheduleRecognitionRequest): Promise<ApiResult<ScheduleRecognitionResponse>> {
    return AgentApiClient.request<ScheduleRecognitionResponse>(http.RequestMethod.POST,
      '/api/v1/import/schedule-image', request, ApiDefaults.VISION_READ_TIMEOUT_MS);
  }

  static async getProactiveDecision(request: ProactiveRequest): Promise<ApiResult<ProactiveResponse>> {
    return AgentApiClient.request<ProactiveResponse>(http.RequestMethod.POST, '/api/v1/agent/proactive', request);
  }

  static async matchPartner(request: PartnerMatchRequest): Promise<ApiResult<PartnerMatchResponse>> {
    return AgentApiClient.request<PartnerMatchResponse>(http.RequestMethod.POST,
      '/api/v1/agent/partner-match', request);
  }

  static async createPartnerInvitation(
    request: PartnerInvitationCreateRequest): Promise<ApiResult<PartnerInvitationResponse>> {
    return AgentApiClient.request<PartnerInvitationResponse>(http.RequestMethod.POST,
      '/api/v1/agent/partner-invitations', request);
  }

  static async listPartnerInvitations(
    box: string = 'inbox'): Promise<ApiResult<PartnerInvitationListResponse>> {
    return AgentApiClient.request<PartnerInvitationListResponse>(http.RequestMethod.GET,
      `/api/v1/agent/partner-invitations?box=${encodeURIComponent(box)}`);
  }

  static async acceptPartnerInvitation(invitationId: string): Promise<ApiResult<PartnerInvitationResponse>> {
    return AgentApiClient.request<PartnerInvitationResponse>(http.RequestMethod.POST,
      `/api/v1/agent/partner-invitations/${encodeURIComponent(invitationId)}/accept`);
  }

  static async declinePartnerInvitation(invitationId: string): Promise<ApiResult<PartnerInvitationResponse>> {
    return AgentApiClient.request<PartnerInvitationResponse>(http.RequestMethod.POST,
      `/api/v1/agent/partner-invitations/${encodeURIComponent(invitationId)}/decline`);
  }

  static async dismissPartnerInvitation(invitationId: string): Promise<ApiResult<PartnerInvitationResponse>> {
    return AgentApiClient.request<PartnerInvitationResponse>(http.RequestMethod.POST,
      `/api/v1/agent/partner-invitations/${encodeURIComponent(invitationId)}/dismiss`);
  }

  static async listPartnerContacts(): Promise<ApiResult<PartnerContactListResponse>> {
    return AgentApiClient.request<PartnerContactListResponse>(http.RequestMethod.GET,
      '/api/v1/agent/partner-contacts');
  }

  static async listKnowledgeBases(userId?: string): Promise<ApiResult<KnowledgeBaseListResponse>> {
    const suffix: string = userId !== undefined && userId.length > 0
      ? `?userId=${encodeURIComponent(userId)}` : '';
    return AgentApiClient.request<KnowledgeBaseListResponse>(http.RequestMethod.GET,
      `/api/v1/knowledge-bases${suffix}`);
  }

  static async createKnowledgeBase(request: KnowledgeBaseCreateRequest): Promise<ApiResult<KnowledgeBase>> {
    return AgentApiClient.request<KnowledgeBase>(http.RequestMethod.POST,
      '/api/v1/knowledge-bases', request);
  }

  static async getKnowledgeBase(kbId: string): Promise<ApiResult<KnowledgeBaseDetail>> {
    return AgentApiClient.request<KnowledgeBaseDetail>(http.RequestMethod.GET,
      `/api/v1/knowledge-bases/${encodeURIComponent(kbId)}`);
  }

  static async deleteKnowledgeBase(kbId: string): Promise<ApiResult<KnowledgeBase>> {
    return AgentApiClient.request<KnowledgeBase>(http.RequestMethod.DELETE,
      `/api/v1/knowledge-bases/${encodeURIComponent(kbId)}`, undefined,
      ApiDefaults.DELETE_PROCESSING_READ_TIMEOUT_MS);
  }

  static async uploadKnowledgeDocument(kbId: string,
    request: KnowledgeDocumentUploadRequest): Promise<ApiResult<KnowledgeDocument>> {
    return AgentApiClient.request<KnowledgeDocument>(http.RequestMethod.POST,
      `/api/v1/knowledge-bases/${encodeURIComponent(kbId)}/documents`, request,
      ApiDefaults.DOCUMENT_PROCESSING_READ_TIMEOUT_MS);
  }

  static async getKnowledgeDocument(documentId: string): Promise<ApiResult<KnowledgeDocumentDetail>> {
    return AgentApiClient.request<KnowledgeDocumentDetail>(http.RequestMethod.GET,
      `/api/v1/documents/${encodeURIComponent(documentId)}`);
  }

  static async deleteKnowledgeDocument(documentId: string): Promise<ApiResult<KnowledgeDocument>> {
    return AgentApiClient.request<KnowledgeDocument>(http.RequestMethod.DELETE,
      `/api/v1/documents/${encodeURIComponent(documentId)}`, undefined,
      ApiDefaults.DELETE_PROCESSING_READ_TIMEOUT_MS);
  }

  static async searchKnowledgeBase(kbId: string,
    request: KnowledgeSearchRequest): Promise<ApiResult<KnowledgeSearchResponse>> {
    return AgentApiClient.request<KnowledgeSearchResponse>(http.RequestMethod.POST,
      `/api/v1/knowledge-bases/${encodeURIComponent(kbId)}/search`, request);
  }

  static async authRegister(request: AuthRegisterRequest): Promise<ApiResult<AuthSessionResponse>> {
    return AgentApiClient.request<AuthSessionResponse>(http.RequestMethod.POST, '/api/v1/auth/register', request);
  }

  static async authSelectAccount(request: AuthSelectAccountRequest): Promise<ApiResult<AuthSessionResponse>> {
    return AgentApiClient.request<AuthSessionResponse>(http.RequestMethod.POST, '/api/v1/auth/select-account', request);
  }

  static async authLogin(request: AuthLoginRequest): Promise<ApiResult<AuthSessionResponse>> {
    return AgentApiClient.request<AuthSessionResponse>(http.RequestMethod.POST, '/api/v1/auth/login', request);
  }

  static async authLoginOrRegister(request: AuthLoginOrRegisterRequest): Promise<ApiResult<AuthLoginOrRegisterResponse>> {
    return AgentApiClient.request<AuthLoginOrRegisterResponse>(http.RequestMethod.POST, '/api/v1/auth/login-or-register', request);
  }

  static async authLoginWithHuawei(request: AuthHuaweiLoginRequest): Promise<ApiResult<AuthLoginOrRegisterResponse>> {
    if (AgentApiClient.config.useFixture || !ApiDefaults.supportsHuaweiLogin(AgentApiClient.config.baseUrl)) {
      return apiFailure('HUAWEI_LOGIN_UNAVAILABLE', '当前连接无法用于华为账号登录。', false, 'network');
    }
    return AgentApiClient.request<AuthLoginOrRegisterResponse>(http.RequestMethod.POST,
      '/api/v1/auth/login-with-huawei', request, ApiDefaults.HUAWEI_LOGIN_READ_TIMEOUT_MS);
  }

  static async authSendCode(request: AuthSendCodeRequest): Promise<ApiResult<AuthSendCodeResponse>> {
    return AgentApiClient.request<AuthSendCodeResponse>(http.RequestMethod.POST, '/api/v1/auth/send-code', request);
  }

  static async authVerifyCode(request: AuthVerifyCodeRequest): Promise<ApiResult<AuthLoginOrRegisterResponse>> {
    return AgentApiClient.request<AuthLoginOrRegisterResponse>(http.RequestMethod.POST, '/api/v1/auth/verify-code', request);
  }

  static async authMe(): Promise<ApiResult<AuthUserResponse>> {
    return AgentApiClient.request<AuthUserResponse>(http.RequestMethod.GET, '/api/v1/auth/me');
  }

  static async authUpdateProfile(request: AuthProfileUpdateRequest): Promise<ApiResult<AuthUserResponse>> {
    return AgentApiClient.request<AuthUserResponse>(http.RequestMethod.PUT, '/api/v1/auth/me', request,
      ApiDefaults.PROFILE_SAVE_READ_TIMEOUT_MS);
  }

  static async authChangePassword(request: AuthChangePasswordRequest): Promise<ApiResult<AuthChangePasswordResponse>> {
    return AgentApiClient.request<AuthChangePasswordResponse>(http.RequestMethod.POST,
      '/api/v1/auth/change-password', request);
  }

  static async authLogout(): Promise<ApiResult<AuthStatusResponse>> {
    return AgentApiClient.request<AuthStatusResponse>(http.RequestMethod.POST, '/api/v1/auth/logout');
  }

  static async authDeleteAccount(): Promise<ApiResult<AuthStatusResponse>> {
    return AgentApiClient.request<AuthStatusResponse>(http.RequestMethod.DELETE, '/api/v1/auth/account');
  }

  private static async request<T>(method: http.RequestMethod, path: string, body?: Object,
    readTimeoutOverrideMs?: number, extraHeaders?: Record<string, string>): Promise<ApiResult<T>> {
    const methodName: string = AgentApiClient.methodName(method);
    if (AgentApiClient.config.useFixture) return FixtureApiTransport.request<T>(methodName, path, body);

    const readTimeoutMs: number = Math.max(
      AgentApiClient.config.timeoutMs,
      readTimeoutOverrideMs !== undefined ? readTimeoutOverrideMs : 0);

    const httpRequest: http.HttpRequest = http.createHttp();
    try {
      const header: Record<string, string> = {
        'Accept': 'application/json',
        'X-API-Contract-Version': API_CONTRACT_VERSION
      };
      if (extraHeaders !== undefined) Object.keys(extraHeaders).forEach((key: string) => { header[key] = extraHeaders[key]; });
      if (body !== undefined) {
        header['Content-Type'] = 'application/json';
      }
      const token: string = AuthStore.getToken();
      const huaweiLogin: boolean = path === '/api/v1/auth/login-with-huawei';
      const publicAuth: boolean = path === '/api/v1/auth/login' ||
        path === '/api/v1/auth/register' || path === '/api/v1/auth/login-or-register' ||
        path === '/api/v1/auth/send-code' || path === '/api/v1/auth/verify-code' || huaweiLogin;
      if (token.length > 0 && !publicAuth && path !== '/ready') {
        header['Authorization'] = `Bearer ${token}`;
      }
      const requestOptions: http.HttpRequestOptions = {
        method: method,
        header: header,
        extraData: body === undefined ? undefined : JSON.stringify(body),
        expectDataType: http.HttpDataType.STRING,
        usingCache: false,
        connectTimeout: AgentApiClient.config.timeoutMs,
        readTimeout: readTimeoutMs
      };
      if (huaweiLogin) {
        requestOptions.maxRedirects = 0;
        if (AgentApiClient.config.baseUrl === ApiDefaults.LOCALHOST_BASE_URL) {
          requestOptions.usingProxy = false;
        }
      }
      const response: http.HttpResponse =
        await httpRequest.request(`${AgentApiClient.config.baseUrl}${path}`, requestOptions);
      if (response.responseCode < 200 || response.responseCode >= 300) {
        return AgentApiClient.parseServerError(response.result as string, response.responseCode);
      }
      const payload: string = (response.result as string).trim();
      if (payload.length === 0) return apiFailure('EMPTY_RESPONSE', '服务未返回可解析的数据。', true, 'network');
      try {
        const parsed: Object = JSON.parse(payload) as Object;
        if (!ApiResponseValidator.isValid(methodName, path, parsed)) {
          return apiFailure('INVALID_RESPONSE', `服务返回的数据结构与 ${API_CONTRACT_VERSION} 不一致。`, false, 'network');
        }
        return apiSuccess<T>(parsed as T, 'network');
      } catch (parseError) {
        return apiFailure('INVALID_RESPONSE', '服务返回的数据格式不正确，请联系联调同学检查接口响应。', false, 'network');
      }
    } catch (err) {
      return apiFailure('NETWORK_ERROR', '连接超时或网络不可用，请检查服务地址后重试。', true, 'network');
    } finally {
      httpRequest.destroy();
    }
  }

  private static methodName(method: http.RequestMethod): string {
    if (method === http.RequestMethod.GET) return 'GET';
    if (method === http.RequestMethod.DELETE) return 'DELETE';
    if (method === http.RequestMethod.PUT) return 'PUT';
    return 'POST';
  }

  static parseBackendOrigin(baseUrl: string): string {
    const normalized: string = baseUrl.trim().replace(/\/+$/, '');
    const valid: boolean = /^https:\/\/(?:[A-Za-z0-9.-]+|\[[0-9A-Fa-f:.]+\])(?::\d+)?$/.test(normalized) ||
      /^http:\/\/[^\s/:]+:\d+$/.test(normalized) || /^http:\/\/\[[^\]]+\]:\d+$/.test(normalized);
    const port = normalized.match(/:(\d+)$/);
    return valid && (port === null || (Number(port[1]) >= 1 && Number(port[1]) <= 65535)) ? normalized : '';
  }

  private static normalizeBaseUrl(baseUrl: string): string {
    return AgentApiClient.parseBackendOrigin(baseUrl) || ApiDefaults.DEFAULT_BASE_URL;
  }

  static parseServerError(payload: string, statusCode: number): ApiFailure {
    const defaultRecoverable: boolean = statusCode >= 500 || statusCode === 408 || statusCode === 429;
    let code: string = 'HTTP_ERROR';
    let message: string = AgentApiClient.httpErrorMessage(statusCode);
    let recoverable: boolean = defaultRecoverable;
    try {
      const parsed: Record<string, Object> = JSON.parse(payload.trim()) as Record<string, Object>;
      const errorCode: Object | undefined = parsed['errorCode'] as Object | undefined;
      const legacyCode: Object | undefined = parsed['code'] as Object | undefined;
      const serverCode: Object | undefined = errorCode !== undefined ? errorCode : legacyCode;
      const serverMessage: Object | undefined = parsed['message'] as Object | undefined;
      const serverRecoverable: Object | undefined = parsed['recoverable'] as Object | undefined;
      if (typeof serverCode === 'string' && (serverCode as string).trim().length > 0) {
        code = serverCode as string;
      }
      if (typeof serverMessage === 'string' && (serverMessage as string).trim().length > 0) {
        message = serverMessage as string;
      }
      if (typeof serverRecoverable === 'boolean') {
        recoverable = serverRecoverable as boolean;
      }
    } catch (parseError) {
    }
    return apiFailure(code, message, recoverable, 'network', statusCode);
  }

  private static httpErrorMessage(statusCode: number): string {
    if (statusCode === 401) return '登录已过期，请返回登录页重新登录。';
    if (statusCode === 403) return '当前账号没有执行此操作的权限。';
    if (statusCode === 503) return '服务暂时不可用或正在维护，请稍后重试。';
    if (statusCode === 404) return '未找到对应接口，请检查服务地址和接口版本。';
    if (statusCode === 408) return '服务响应超时，请稍后重试。';
    if (statusCode === 429) return '服务请求过于频繁，请稍后重试。';
    return `服务返回 HTTP ${statusCode}。`;
  }
}
