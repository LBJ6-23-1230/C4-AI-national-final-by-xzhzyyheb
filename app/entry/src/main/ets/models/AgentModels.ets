

export interface BasicInfo {
  name: string;
  grade: string;
  major: string;
}

export interface LearningGoal {
  course: string;
  goal: string;
}

export interface UserTime {
  freeTime: string[];
}

export interface KnowledgeInfo {
  weakness: string[];
  strength: string[];
}

export interface UserProfile {
  userId: string;
  basicInfo: BasicInfo;
  learningGoal: LearningGoal;
  time: UserTime;
  knowledge: KnowledgeInfo;
}

export interface ExamInfo {
  date: string;
  daysLeft: number;
}

export interface RecentStatus {
  studyHours: number;
  status: string;
}

export interface CourseInfo {
  syncVersion?: number;
  courseId: string;
  courseName: string;
  exam: ExamInfo;
  priority: string;
  recentStatus: RecentStatus;
}

export interface HomeworkDDL {
  courseId?: string;
  syncVersion?: number;
  completed?: boolean;
  id: string;
  courseName: string;
  title: string;
  dueDate: string;
  daysLeft: number;
  priority: string;
  estimatedMinutes: number;
  origin?: 'chat' | 'import';
}


export interface KnowledgeResult {
  name: string;
  confidence: number;
}

export interface WrongQuestionSuggestion {
  studyTag: string;
  task: string;
}

export interface WrongQuestionInput {
  image: string;
  myAnswer: string;
  correctAnswer: string;
}

export interface AIAnalysis {
  course: string;
  knowledge: KnowledgeResult[];
  wrongType: string;
  reason: string;
  Tag: string[];
  suggestion: WrongQuestionSuggestion[];
}

export interface WrongQuestionRecord {
  questionId: string;
  userId: string;
  input: WrongQuestionInput;
  AIAnalysis: AIAnalysis;
}


export interface WrongQuestionImage {
  imageUri: string;
  fileName: string;
  uploadTime: string;
}

export interface InputLayerData {
  courses: CourseInfo[];
  homeworkDDLs: HomeworkDDL[];
  wrongQuestionImages: WrongQuestionImage[];
  userGoal: LearningGoal;
  freeTime: string[];
}


export interface KnowledgeAnalysis {
  course: string;
  knowledgePoints: KnowledgeResult[];
  errorType: string;
  rootCause: string;
  difficultyLevel: string;
}

export interface GoalUnderstanding {
  targetCourse: string;
  targetScore: string;
  currentLevel: string;
  gap: string;
}

export interface UnderstandingLayerData {
  courseAnalysis: Map<string, KnowledgeAnalysis>;
  examUrgency: Map<string, number>;
  errorPatternSummary: string;
  goalUnderstanding: GoalUnderstanding;
}


export interface TaskPriority {
  courseName: string;
  task: string;
  priorityScore: number;
  urgencyFactors: string[];
  suggestedDuration: number;
}

export interface WeaknessJudgment {
  knowledgePoint: string;
  weaknessLevel: string;
  missedCount: number;
  relatedExamWeight: number;
}

export interface MatchFeasibility {
  canMatch: boolean;
  availableCandidates: number;
  bestMatchFactor: string;
}

export interface JudgmentLayerData {
  optimalTask: TaskPriority;
  allTasks: TaskPriority[];
  weaknessPoints: WeaknessJudgment[];
  matchFeasibility: MatchFeasibility;
  recommendedAction: string;
}


export interface StudySuggestion {
  course: string;
  task: string;
  reason: string;
  duration: string;
  priority: string;
  priorityScore: number;
}

export interface WrongAnalysisResult {
  savedWrongBookId?: string;
  answer?: string;
  explanation?: string;
  questionNumber?: string;
  questionText?: string;
  recognitionStatus?: string;
  course: string;
  knowledge: string[];
  wrongType: string;
  reason: string;
  suggestions: string[];
  tags: string[];
  imageUri: string;
}

export interface TimeRange {
  start: number;
  end: number;
}

export interface OverlapResult {
  score: number;
  start: string | null;
  end: string | null;
  duration: number;
}

export interface PartnerMatch {
  matchName: string;
  userId: string;
  score: number;
  reasons: string[];
  studyTime: string | null;
  duration: number;
  matchFactors: MatchFactor[];
}

export interface MatchFactor {
  label: string;
  score: string;
  match: boolean;
  detail: string;
}


export interface DailyLearningCard {
  date: string;
  suggestion: StudySuggestion;
  urgentDDLCount: number;
  examDaysLeft: number;
  highPriorityCourse: string;
}

export interface WrongQuestionDiagnosticCard {
  totalAnalyzed: number;
  latestAnalysis: WrongAnalysisResult | null;
  weaknessTags: string[];
  strengthTags: string[];
  summary: string;
}

export interface PartnerCard {
  partner: PartnerMatch | null;
  matchFactors: MatchFactor[];
  suggestion: string;
}

export interface CollaborativePlan {
  totalMinutes: number;
  partnerName: string;
  phases: StudyPhase[];
  commonTopics: string[];
  startTime: string;
}

export interface StudyPhase {
  time: string;
  icon: string;
  title: string;
  desc: string;
}

export interface LearningBadge {
  name: string;
  icon: string;
  description: string;
}

export interface LearningReview {
  totalMinutes: number;
  completedTasks: string[];
  knowledgeReviewed: string[];
  partnerName: string | null;
  badges: LearningBadge[];
  strengthsGained: string[];
  nextSteps: string[];
}


export type FocusSource = 'agent' | 'manual' | 'course' | 'collaborative';
export type FocusMode = 'normal' | 'strict';
export type FocusTimerType = 'countdown' | 'stopwatch';
export type FocusDepartureReason = 'navigation' | 'background' | 'screenOff';
export type FocusSelfAssessment = 'completed' | 'partial' | 'not_completed';
export type FocusSessionStatus = 'completed' | 'not_completed' | 'interrupted';

export interface FocusTask {
  course: string;
  task: string;
  plannedMinutes: number;
  source: FocusSource;
  mode: FocusMode;
  timerType?: FocusTimerType;
  planTaskId?: string;
  parentTaskId?: string;
  allowBackgroundTiming?: boolean;
}

export interface FocusSession {
  shared?: boolean;
  taskId: string;
  planTaskId?: string;
  course: string;
  task: string;
  plannedMinutes: number;
  actualMinutes: number;
  pauseCount: number;
  interruptionCount: number;
  completionRate: number;
  selfAssessment: FocusSelfAssessment;
  timerType: FocusTimerType;
  status: FocusSessionStatus;
  endedAt: string;
}

export interface FocusRuntime {
  shared?: boolean;
  sessionId: string;
  ownerId: string;
  task: FocusTask;
  elapsedMs: number;
  lastUpdatedAt: number;
  finishedAt?: number;
  autoPaused?: boolean;
  backgroundReason?: 'screenOff' | 'background';
  paused: boolean;
  pauseCount: number;
  interruptionCount: number;
}

export interface AgentFeedback {
  level: 'adjust' | 'continue' | 'advance';
  feedback: string;
  nextSuggestion: string;
}

export interface FocusSummary {
  todayMinutes: number;
  streakDays: number;
  courseMinutes: Map<string, number>;
  recentSessions: FocusSession[];
}


export type PlanTaskStatus = 'todo' | 'in_progress' | 'completed' | 'partial' | 'deferred';
export type PlanTaskType = 'learn' | 'practice' | 'review' | 'test' | 'assignment';

export interface LearningPlanTask {
  id: string;
  course: string;
  title: string;
  knowledgePoint: string;
  type: PlanTaskType;
  dateLabel: string;
  plannedMinutes: number;
  priorityScore: number;
  priorityLabel: string;
  reason: string;
  completionCriteria: string;
  steps: string[];
  status: PlanTaskStatus;
  source: 'agent' | 'ddl' | 'wrong_question' | 'focus_feedback' | 'partner_match';
  canCollaborate: boolean;
}

export interface AgentDecisionTrace {
  inputSummary: string;
  urgencyReason: string;
  weaknessReason: string;
  timeReason: string;
  recommendation: string;
  updatedAt: string;
}

export interface WeeklyLearningPlan {
  weekLabel: string;
  tasks: LearningPlanTask[];
  decisionTrace: AgentDecisionTrace;
  adjustmentMessage: string;
}


export type WorkflowStage = 'idle' | 'input' | 'understanding' | 'judgment' | 'action' | 'output';

export type NavigationIntent =
  | 'back_to_hub'
  | 'analyze_wrong_question'
  | 'find_partner'
  | 'view_study_plan'
  | 'view_review'
  | 'view_courses'
  | 'view_tags';


export interface WorkflowContext {
  currentStage: WorkflowStage;
  lastAction: string;
  lastActionTime: string;
  completedStages: WorkflowStage[];
  pendingActions: NavigationIntent[];
}
