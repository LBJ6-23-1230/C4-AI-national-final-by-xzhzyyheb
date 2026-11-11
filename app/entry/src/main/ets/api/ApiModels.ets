import { CourseInfo } from '../models/AgentModels';

export const API_CONTRACT_VERSION: string = 'api-contract-v0.3';

export type WorkflowStatus = 'running' | 'completed' | 'failed' | 'fallback' | 'error';
export type PlanTaskStatus = 'pending' | 'in_progress' | 'completed';


export type KnowledgeDocumentStatus = 'ready' | 'failed' | 'processing';

export interface KnowledgeBase {
  kbId: string;
  userId: string;
  courseName: string;
  name: string;
  description?: string;
  documentCount?: number;
  chunkCount?: number;
  knowledgePoints?: string[];
  createdAt?: string;
  updatedAt?: string;
}

export interface KnowledgeBaseDetail extends KnowledgeBase {
  documents?: KnowledgeDocument[];
}

export interface KnowledgeDocument {
  parseSource?: string;
  tagsConfirmed?: boolean;
  documentId: string;
  kbId: string;
  userId: string;
  fileName: string;
  mimeType?: string;
  sizeBytes?: number;
  status: KnowledgeDocumentStatus;
  statusMessage?: string;
  charCount?: number;
  chunkCount?: number;
  knowledgePoints?: string[];
  errorPointCandidates?: string[];
  uploadedAt?: string;
  parsedAt?: string;
}

export interface KnowledgeDocumentChunk {
  chunkId: string;
  index: number;
  headingPath?: string;
  text: string;
  knowledgePoints?: string[];
}

export interface KnowledgeDocumentDetail extends KnowledgeDocument {
  knowledgePointEvidence?: KnowledgePointEvidence[];
  chunks: KnowledgeDocumentChunk[];
  chunkTotal: number;
  chunksTruncated: boolean;
}

export interface KnowledgeChunkHit {
  chunkId: string;
  documentId: string;
  fileName?: string;
  headingPath?: string;
  text: string;
  knowledgePoints?: string[];
  score: number;
}

export interface KnowledgeBaseListResponse {
  knowledgeBases: KnowledgeBase[];
  total: number;
}

export interface KnowledgeDocumentListResponse {
  kbId: string;
  documents: KnowledgeDocument[];
  total: number;
}

export interface KnowledgeSearchRequest {
  query: string;
  topK?: number;
  knowledgePointId?: string;
  userId?: string;
}

export interface KnowledgeSearchResponse {
  kbId: string;
  query: string;
  hits: KnowledgeChunkHit[];
  totalScanned: number;
  retrievalMode: string;
  semanticAvailable: boolean;
  semanticWeight: number;
}

export interface KnowledgeBaseCreateRequest {
  courseName: string;
  name: string;
  description?: string;
  userId?: string;
}

export interface KnowledgeDocumentUploadRequest {
  fileName: string;
  contentBase64: string;
  mimeType?: string;
  sizeBytes?: number;
  userId?: string;
}

export interface ScheduleRecognitionRequest {
  imageBase64: string;
}

export interface ScheduleRecognitionResponse {
  courses: CourseInfo[];
  recognizedCount: number;
  model: string;
  recognizedAt: string;
}

export interface Evidence {
  id: string;
  sourceType: string;
  sourceId: string;
  knowledgePointId: string;
  metric: string;
  value: Object;
  timestamp: string;
  reliability: number;
}

export interface TopicMember { knowledgePointId: string; name: string; masteryScore: number | null; evidenceQuestionCount: number; }
export interface TopicGroup { topicGroupId: string; topicGroupName: string; sourceCourse: string; memberCount: number; memberPointIds: string[]; masteryScore: number | null; recentAccuracy: number | null; evidenceQuestionCount: number; memberPoints: TopicMember[]; }
export interface PointClassification { knowledgePointId: string; courseName: string; topicName: string; expectedProfileVersion: number; }
export interface ManualKnowledgePointRequest { courseName: string; knowledgePointName: string; }
export interface KnowledgeMastery {
  classificationRequired?: boolean;
  topicGroupId?: string;
  topicGroupName?: string;
  topicGroupConfidence?: number;
  topicGroup?: string;
  assessmentStatus?: string;
  effectiveQuestionCount?: number;
  evidenceAdjustedScore?: number;
  totalEvidenceQuestionCount?: number;
  correctCount?: number;
  recentAccuracy?: number | null;
  lastAssessedAt?: string;
  assessmentRoundCount?: number;
  performanceChange?: number | null;
  retentionStatus?: string;
  photoPracticeCount?: number;
  photoPracticeStatus?: string;
  photoPracticeType?: string;
  photoPracticeScore?: number | null;
  photoPracticeMaxScore?: number | null;
  ruleVersion?: string;
  sourceCourse?: string;
  knowledgePointId: string;
  knowledgePointName: string;
  masteryScore: number;
  confidence: number;
  lastUpdated: string;
}

export interface MasteryHistory {
  knowledgePointId?: string;
  questionCount?: number;
  oldScore: number;
  newScore: number;
  evidenceIds: string[];
  source: string;
  timestamp: string;
}

export interface LearnerProfile {
  topicGroups?: TopicGroup[];
  targetCourses?: string[];
  targetCourse?: string;
  userId: string;
  goal: string;
  examDate: string | null;
  freeTimeSlots: string[];
  profileVersion: number;
  mastery: KnowledgeMastery[];
}

export interface ProfileResponse {
  source?: string;
  parseStatus?: string;
  profileVersion: number;
  profile?: LearnerProfile;
  mastery: KnowledgeMastery[];
  history: MasteryHistory[];
  evidence: Evidence[];
}

export interface WorkflowCreateRequest {
  goal: string;
  sessionId?: string;
  userId?: string;
  maxSteps?: number;
}

export interface WorkflowResponse {
  sessionId: string;
  traceId: string;
  status: WorkflowStatus;
  currentStep: string;
  nextAction: string;
}

export interface LearningHandoff {
  goalId: string;
  agentTaskId: string;
  sender: string;
  receiver: string;
  objective: string;
  dependsOn: string[];
  inputVersion: number;
  outputVersion: number;
  status: string;
  reason: string;
  toolCalls: string[];
  decisionSource: string;
}

export interface LearningContextAction {
  label: string;
  targetPage: string;
}

export interface LearningContext {
  chatSessionId?: string;
  updatedAt?: string;
  needsConfirmation?: boolean;
  assessmentStatus: string;
  assessedQuestionCount: number;
  goalId: string;
  sessionId: string;
  traceId: string;
  assessmentTraceId: string;
  goal: string;
  stateVersion: number;
  status: string;
  currentAgent: string;
  waitingFor: string;
  nextAction: string;
  decisionSource: string;
  knowledgePointId: string;
  knowledgePointName: string;
  profileVersion: number;
  planId: string;
  planVersion: number;
  sourceMode: string;
  kbId: string;
  action: LearningContextAction;
  handoffs: LearningHandoff[];
}

export interface WorkflowStatusResponse {
  learningContext?: LearningContext;
  status: WorkflowStatus;
  currentAgent: string | null;
  stateVersion: number;
  finalAction: string | null;
}

export interface WorkflowRunResponse {
  learningContext?: LearningContext;
  sessionId: string;
  traceId: string;
  status: WorkflowStatus;
  currentStep: string;
  currentAgent: string;
  stateVersion: number;
  finalAction: string | null;
  state?: Record<string, Object>;
}

export interface WorkflowRunRequest {
  expectedStateVersion?: number;
  submissionId?: string;
  answers?: ExerciseAnswer[];
}

export interface DecisionFactor {
  name: string;
  value: number;
  weight: number;
  contribution: number;
}

export interface ProactiveContext {
  now: string;
  location?: string;
  foreground: boolean;
  lastStudyAt?: string;
  focusSessionActive: boolean;
  masteryScore?: number;
  errorIntensity?: number;
  daysLeft?: number;
  importance?: number;
  pendingTasks?: PendingTaskSignal[];
}

export interface PendingTaskSignal {
  taskId?: string;
  title?: string;
  status?: string;
  started?: boolean;
  daysLeft?: number;
}

export interface ProactiveRequest {
  userId: string;
  context: ProactiveContext;
}

export interface ProactiveActionPreset {
  taskId?: string;
  durationMinutes?: number;
}

export interface ProactiveAction {
  type: string;
  targetPage: string;
  preset: ProactiveActionPreset;
}

export interface ProactiveCardData {
  taskName?: string;
  durationMinutes?: number;
  examCountdownDays?: number;
  hint?: string;
}

export interface ProactiveResponse {
  userId?: string;
  shouldNotify: boolean;
  channel: 'reminder' | 'silent';
  title: string;
  body: string;
  action: ProactiveAction;
  contextTags: string[];
  reason: string;
  factors: DecisionFactor[];
  cardData: ProactiveCardData;
}

export interface PlanTask {
  parentTaskId?: string;
  steps?: string[];
  scheduledDate?: string;
  dueAt?: string;
  baseDurationMinutes?: number;
  extraMinutes?: number;
  allocationReason?: string;
  taskId: string;
  knowledgePointId: string;
  knowledgePointName: string;
  durationMinutes: number;
  status: PlanTaskStatus;
  priority?: string;
  deferredReason?: string;
  source?: string;
  sourceCourse?: string;
  dueDate?: string;
}

export interface AssignmentSnapshot {
  id: string;
  title: string;
  courseName: string;
  dueDate: string;
  estimatedMinutes: number;
  priority: string;
  completed: boolean;
}

export interface AssignmentSyncRequest {
  scheduleToday?: boolean;
  assignments: AssignmentSnapshot[];
  selectedId?: string;
}

export interface PlanBudgetRequest {
  targetCourse?: string;
  availableMinutes: number;
  expectedPlanVersion: number;
  idempotencyKey: string;
}

export interface PlanTaskScheduleRequest {
  taskId: string;
  expectedPlanVersion: number;
  idempotencyKey: string;
}

export interface PlanBudgetSummary {
  baseTotalMinutes?: number;
  allocationMode?: string;
  allocationReason?: string;
  availableMinutes: number;
  scheduledMinutes: number;
  unallocatedMinutes: number;
  unscheduledMinutes: number;
}

export interface PlanBudgetResponse {
  plan: LearningPlan;
  planDiff: PlanDiff;
  changed: boolean;
  traceId: string;
  eventId: string;
}

export interface AssessmentActionRequest { knowledgePointId: string; }
export interface PlanStep { title: string; minutes: number; }
export interface TaskSplitRequest { taskId: string; expectedPlanVersion: number; steps: PlanStep[]; }
export interface CalendarDay { date: string; minutes: number; scheduledMinutes?: number; }
export interface CalendarRequest { days: CalendarDay[]; expectedPlanVersion: number; targetCourse?: string; }
export interface LearningPlan {
  calendarDays?: CalendarDay[];
  calendarUnscheduledMinutes?: number;
  candidatePool?: KnowledgeMastery[];
  targetCourse?: string;
  planId: string | null;
  version: number;
  tasks: PlanTask[];
  reason?: string;
  factors?: DecisionFactor[];
  generatedFromProfileVersion: number;
  unscheduledTasks?: PlanTask[];
  budgetSummary?: PlanBudgetSummary;
}

export interface ExerciseSource {
  chunkId: string;
  documentId: string;
  kbId: string;
  fileName: string;
  headingPath: string;
  chunkIndex: number;
  contentHash: string;
  parsedAt: string;
  text?: string;
}

export interface ExerciseSourcesResponse {
  exerciseId: string;
  sources: ExerciseSource[];
}

export interface Exercise {
  exerciseId: string;
  knowledgePointId: string;
  knowledgePointName: string;
  difficulty?: string;
  stem: string;
  options: string[];
  source?: string;
  sources?: ExerciseSource[];
  grounding?: string;
}

export interface ExerciseSetResponse {
  setId: string;
  exercises: Exercise[];
  sourceMode?: string;
  kbId?: string;
  documentId?: string;
  knowledgePointId?: string;
  generationFailed?: boolean;
  message?: string;
}

export interface ExerciseMaterialOption {
  kbId: string;
  documentId: string;
  fileName: string;
}

export interface ExerciseMaterialOptions {
  options: ExerciseMaterialOption[];
}

export interface DocumentBankOption {
  kbId: string;
  documentId: string;
  fileName: string;
  count: number;
  remaining: number;
}

export interface DocumentBankOptions {
  banks: DocumentBankOption[];
  maxCount: number;
}

export interface OutlinePracticePoint {
  knowledgePointId: string;
  knowledgePointName: string;
  outlineFileName: string;
}

export interface OutlinePracticeRecommendations {
  points: OutlinePracticePoint[];
  status?: string;
}

export interface ExerciseQuery {
  roundId?: string;
  forceGenerate?: boolean;
  courseName?: string;
  sourceMode?: string;
  kbId?: string;
  documentId?: string;
  knowledgePointId?: string;
  difficulty?: string;
  count?: number;
  excludeExerciseIds?: string[];
  generate?: boolean;
}

export interface ExerciseAnswer {
  exerciseId: string;
  answer: string;
}

export interface ExerciseSubmission {
  goalId?: string;
  goalStateVersion?: number;
  userId?: string;
  sessionId?: string;
  idempotencyKey: string;
  answers: ExerciseAnswer[];
}

export interface AssessmentResult {
  score: number;
  perKnowledgeAccuracy: Record<string, number>;
  errorTypes: string[];
  oldMastery: number;
  suggestedNewMastery: number;
  masteryUpdates?: PointMasteryUpdate[];
}

export interface PointMasteryUpdate {
  knowledgePointId: string;
  oldScore: number;
  newScore: number;
  accuracy: number;
  questionCount: number;
  correctCount: number;
}

export interface FocusSaveResponse {
  userId: string;
  eventId: string;
  planTaskMatched: boolean;
}

export interface MasteryUpdate {
  knowledgePointId: string;
  oldScore: number;
  newScore: number;
}

export interface PlanTaskChange {
  knowledgePointName?: string;
  taskId: string;
  knowledgePointId?: string;
  durationMinutes?: number;
  change?: string;
}

export interface PlanDiff {
  planId?: string;
  oldVersion: number;
  newVersion: number;
  changedTasks: PlanTaskChange[];
  adjustmentReason: string;
  triggerEvidence: string[];
}

export interface ExerciseSubmissionResult {
  planChangeSummary?: string;
  reviewStatus?: string;
  goalId?: string;
  learningContext?: LearningContext;
  userId?: string;
  submissionId?: string;
  assessment: AssessmentResult;
  masteryUpdate: MasteryUpdate | null;
  needReplan: boolean;
  plan?: LearningPlan;
  planDiff?: PlanDiff;
  traceId?: string;
  evidenceIds?: string[];
  replanDecision?: Record<string, Object>;
  review: ExerciseReview[];
}

export interface ExerciseReview {
  exerciseId: string;
  selectedAnswer: string;
  correctAnswer: string;
  correct: boolean;
  explanation: string;
  explanationSource?: string;
  sources?: ExerciseSource[];
  inWrongBook: boolean;
}

export interface WrongBookItem extends Exercise {
  canAutoGrade?: boolean;
  photoPracticeType?: string;
  knowledgeGroup?: string;
  courseName: string;
  explanation: string;
  correctCount: number;
  wrongCount: number;
  addedAutomatically: boolean;
  addedAt: string;
  lastPracticedAt?: string;
}

export interface WrongBookClassifyRequest {
  exerciseIds: string[];
  courseName: string;
}
export interface WrongBookClassifyResponse {
  courseName: string;
  updatedCount: number;
}

export interface WrongBookCourse {
  courseName: string;
  items: WrongBookItem[];
}

export interface WrongBookResponse {
  userId: string;
  total: number;
  courses: WrongBookCourse[];
}

export interface WrongBookToggleRequest { added: boolean; }
export interface WrongBookToggleResponse {
  exerciseId: string;
  added: boolean;
  removed: boolean;
  item?: WrongBookItem;
}
export interface WrongBookAttemptRequest { answer: string; }
export interface WrongBookAttemptResponse {
  exerciseId: string;
  correct: boolean;
  correctAnswer: string;
  explanation: string;
  correctCount: number;
  removed: boolean;
}

export interface TraceEvent {
  agent: string;
  toolCalls: string[];
  inputSummary: string;
  outputSummary: string;
  evidenceIds: string[];
  stateVersion: number;
  timestamp: string;
  status: string;
}

export interface TraceResponse {
  traceId: string;
  events: TraceEvent[];
}

export interface DemoResetResponse {
  status: 'reset';
  userId: string;
  profile: LearnerProfile | null;
  plan: LearningPlan | null;
  traceId: string;
}


export interface PartnerMatchFactors {
  goal: number;
  timeOverlap: number;
  knowledgeComplement: number;
  basicMatch: number;
  stability: number;
  overlapMinutes: number;
}

export interface PartnerCandidateProfile {
  userId: string;
  avatar?: string;
  basicInfo?: PartnerCandidateBasicInfo;
  learningGoal?: PartnerCandidateGoal;
  time?: PartnerCandidateTime;
  knowledge?: PartnerCandidateKnowledge;
  accountKind?: string;
}

export interface PartnerCandidateBasicInfo {
  name?: string;
  grade?: string;
  major?: string;
}

export interface PartnerCandidateGoal {
  courses?: string[];
  course?: string;
  goal?: string;
}

export interface PartnerCandidateTime {
  freeTime?: string[];
}

export interface PartnerCandidateKnowledge {
  weakness?: string[];
  strength?: string[];
}

export interface PartnerRankedCandidate {
  sharedCourses?: string[];
  courseMatch?: string;
  goalMatch?: string;
  candidate: PartnerCandidateProfile;
  score: number;
  factors: PartnerMatchFactors;
}

export interface PartnerMatchResponse {
  userId: string;
  matchedCandidate: PartnerRankedCandidate | null;
  candidates: PartnerRankedCandidate[];
  generatedAt: string;
  realModeUnavailable: boolean;
}

export interface PartnerMatchRequest {
  userId?: string;
  user?: PartnerCandidateProfile;
  candidates?: PartnerCandidateProfile[];
}

export interface PartnerInvitation {
  courseName?: string;
  invitationId: string;
  fromUserId: string;
  fromName: string;
  toUserId: string;
  toName: string;
  message: string;
  status: string;
  targetKind: string;
  createdAt: string;
  respondedAt: string;
}

export interface PartnerInvitationCreateRequest {
  courseName?: string;
  toUserId: string;
  message?: string;
}

export interface PartnerInvitationListResponse {
  box: string;
  userId: string;
  invitations: PartnerInvitation[];
  pendingCount: number;
}

export interface PartnerInvitationResponse {
  invitation: PartnerInvitation;
}

export interface PartnerContact {
  partnerUserId: string;
  partnerName: string;
  pairedAt: string;
}

export interface PartnerContactListResponse {
  userId: string;
  contacts: PartnerContact[];
}

export interface LearningPreferencesRequest {
  expectedProfileVersion?: number;
  targetCourses?: string[];
  targetCourse: string;
  goal: string;
  freeTimeSlots: string[];
}
export interface DocumentPointsRequest {
  knowledgePoints: string[];
  reparse: boolean;
  expectedParsedAt: string;
}

export interface GoalActionRequest { action: string; goalId?: string; diagnosisId?: string; knowledgePoint?: string; }
export interface GoalActionResponse { status: string; learningContext?: LearningContext; }
export interface LearningRecord extends LearningContext { recordId: string; chatSessionId: string; updatedAt: string; learningContext: LearningContext; }
export interface LearningRecords { records: LearningRecord[]; nextCursor: string | null; }
export interface GoalHistoryResponse { goals: LearningContext[]; }

export interface KnowledgePointEvidence { name: string; excerpt: string; headingPath: string; chunkId: string; }
