export interface ReminderEvent {
  eventId: string;
  userId: string;
  kind: string;
  objectId: string;
  title: string;
  courseName: string;
  level: string;
  status: string;
  reason: string;
  version: number;
  sourceVersion: number;
  planId: string;
  knowledgePointId: string;
  durationMinutes: number;
  targetPage: string;
  sourceType?: string;
  sourceId?: string;
  deadline?: string;
  snoozedUntil?: string;
  dataTime: string;
}
export interface TodayOverview {
  userId: string;
  dataTime: string;
  version: string;
  highlight: ReminderEvent | null;
  tasks: ReminderEvent[];
  allTasks?: ReminderEvent[];
  pendingCount: number;
  guidance: string;
  modelCalls: number;
}
export interface ReminderList { events: ReminderEvent[]; cursor: string; hasMore: boolean; }
export interface ReminderAction { action: string; version: number; idempotencyKey: string; minutes?: number; }
export interface ReminderActionResult { event: ReminderEvent; }
export interface ReminderPreferences {
  enabled: boolean;
  timezone: string;
  quietStart: number;
  quietEnd: number;
  dailyLimit: number;
  minimumGapMinutes: number;
  urgentException: boolean;
  summaryHour: number;
  categories?: string[];
}
export interface ReminderSettings { preferences: ReminderPreferences; pushConfigured: boolean; }
export interface ReminderDevice {
  deviceId: string; pushToken: string; permission: boolean; foreground: boolean; focusing: boolean;
}
export interface ReminderDeviceResult { deviceId: string; active: boolean; hasToken: boolean; lastActive: string; }
