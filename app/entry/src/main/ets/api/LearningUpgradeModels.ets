export interface PartnerMessage {
  messageId: string;
  senderId: string;
  text: string;
  image: string;
  createdAt: string;
  clientId: string;
}
export interface PartnerMessages {
  messages: PartnerMessage[];
  cursor: string;
  hasMore: boolean;
}
export interface PartnerMessageRequest { clientId: string; text: string; image: string; }
export interface PartnerMessageResult { message: PartnerMessage; }
export interface ScannedQuestionRequest { stem: string; courseName: string; knowledgePointName: string; explanation: string; }
export interface SavedScannedQuestion { item: Object; }
export interface ReviewRequest { courseName: string; }
export interface LearningReview {
  reviewId: string;
  courseName: string;
  summary: string;
  actions: string[];
  source: string;
  createdAt: string;
}
export interface ReviewTask { actionType?: string; knowledgePointId: string; taskId: string; title: string; courseName: string; status: string; }
export interface ReviewTasks { tasks: ReviewTask[]; }
export interface ReviewTaskRequest { taskId: string; }

export interface CourseSetting { courseName: string; goal: string; examDate: string; daysUntilExam: number | null; reviewDue: boolean; }
export interface CourseSettings { courses: CourseSetting[]; }
export interface CourseSettingRequest { courseName: string; goal: string; examDate: string; }

export interface PartnerConversation {
  partnerUserId: string;
  partnerName: string;
  avatar: string;
  pairedAt: string;
  pairedDays: number;
  sharedCourses: string[];
  sharedKnowledgePoints: string[];
  sharedStudyMinutes: number | null;
  lastMessage: string;
  lastMessageId: string;
  lastMessageAt: string;
  unreadCount: number;
}
export interface PartnerInbox { conversations: PartnerConversation[]; totalUnread: number; nextOffset: number; hasMore: boolean; }
export interface PartnerSummary { conversation: PartnerConversation; }
export interface PartnerReadRequest { lastReadMessageId: string; }
export interface PartnerReadResult { status: string; lastReadMessageId: string; }
