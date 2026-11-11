import { LearningContext } from '../api/ApiModels';

export type ChatRole = 'user' | 'agent';
export type ChatStatus = 'sending' | 'done' | 'error';
export type ChatIntent = 'query_tasks' | 'analyze_weakness' | 'get_suggestion'
  | 'match_partner' | 'analyze_wrong' | 'update_profile' | 'free_chat' | 'unknown';
export type ChatCardType = 'suggestion' | 'weakness' | 'profile' | 'partner' | 'tasks' | 'wrong';

export interface ChatCard {
  type: ChatCardType;
  title: string;
  summary: string;
  targetPage: string;
  data: Map<string, string>;
  actions?: ChatAction[];
}

export interface ChatAction {
  label: string;
  targetPage: string;
}

export interface ChatHandoff {
  summary: string;
  nextPrompt: string;
  actionLabel: string;
  targetPage: string;
}

export interface ChatMessage {
  progressText?: string;
  imageFileId?: string;
  wrongAnalysis?: WrongAnalysis;
  attachmentStatus?: string;
  id: string;
  role: ChatRole;
  text: string;
  image?: string;
  card?: ChatCard;
  llmUsed?: boolean;
  sourceLabel?: string;
  time: string;
  status: ChatStatus;
}

export interface AgentHistoryItem {
  role: ChatRole;
  text: string;
}

export interface ChatHistoryRecord {
  image?: string;
  imageFileId?: string;
  userInput: string;
  botResponse: string;
  timestamp: string;
  sessionId: string;
}

export interface ChatHistorySession {
  sessionId: string;
  title: string;
  startedAt: string;
  updatedAt: string;
  turns: ChatHistoryRecord[];
}

export interface AgentRequest {
  message: string;
  image?: string;
  history: AgentHistoryItem[];
}

export interface AgentResponse {
  attachmentStatus?: string;
  learningContext?: LearningContext;
  reply: string;
  intent: string;
  card?: ChatCard;
  llmUsed?: boolean;
  profileUpdates?: ChatProfileUpdates;
  wrongAnalysis?: WrongAnalysis;
}

export interface ChatTaskUpdate {
  taskname?: string;
  taskType?: string;
  deadline?: string;
  taskStatus?: string;
  estimatedMinutes?: number;
}

export interface ChatExamUpdate {
  date?: string;
}

export interface ChatRecentStatusUpdate {
  studyHours?: number;
  status?: string;
}

export interface ChatCourseUpdate {
  courseId?: string;
  courseName?: string;
  tasks?: ChatTaskUpdate[];
  exam?: ChatExamUpdate;
  priority?: string;
  recentStatus?: ChatRecentStatusUpdate;
}

export interface ChatBasicInfoUpdate {
  name?: string;
  grade?: string;
  major?: string;
}

export interface ChatLearningGoalUpdate {
  course?: string;
  goal?: string;
}

export interface ChatTimeUpdate {
  freeTime?: string[];
}

export interface ChatKnowledgeUpdate {
  weakness?: string[];
  strength?: string[];
}

export interface ChatUserUpdate {
  basicInfo?: ChatBasicInfoUpdate;
  learningGoal?: ChatLearningGoalUpdate;
  time?: ChatTimeUpdate;
  knowledge?: ChatKnowledgeUpdate;
}

export interface ChatProfileUpdates {
  user?: ChatUserUpdate;
  course?: ChatCourseUpdate[];
}

export interface WrongAnalysis {
  answer?: string;
  explanation?: string;
  reason?: string;
  courseName?: string;
  questionNumber?: string;
  reply?: string;
  complete?: boolean;
  questionCount?: number;
  questions?: WrongAnalysis[];
  diagnosisId?: string;
  questionText?: string;
  recognitionStatus?: string;
  knowledgePoint?: string;
  wrongType?: string;
}

export interface IntentChip {
  intent: ChatIntent;
  label: string;
  prompt: string;
}
