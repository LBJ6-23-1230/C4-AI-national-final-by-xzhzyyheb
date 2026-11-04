export interface ManualTaskRequest {
  action: string;
  taskId: string;
  title: string;
  courseName: string;
  scheduledDate: string;
  durationMinutes: number;
  expectedPlanVersion: number;
}
export interface SharedTask {
  taskId: string;
  title: string;
  courseName: string;
  scheduledDate: string;
  durationMinutes: number;
  status: string;
  fromUserId: string;
  partnerId: string;
  partnerName: string;
  myStatus: string;
  partnerStatus: string;
  myPart: string;
  partnerPart: string;
}
export interface SharedTasks { tasks: SharedTask[]; }
export interface TodayItemRequest { eventId: string; expectedPlanVersion: number; availableMinutes: number; }
export interface ChatFileRequest { fileName: string; contentBase64: string; }
export interface ChatFile { fileName: string; text: string; truncated: boolean; }
export interface SharedTaskRequest {
  action: string;
  taskId: string;
  partnerId?: string;
  title?: string;
  courseName?: string;
  scheduledDate?: string;
  durationMinutes?: number;
  myPart?: string;
  partnerPart?: string;
}
