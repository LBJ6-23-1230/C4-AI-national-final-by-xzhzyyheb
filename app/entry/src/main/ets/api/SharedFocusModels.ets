import { FocusTask, FocusSession, FocusSelfAssessment } from '../models/AgentModels';

export interface SharedFocusParticipant {
  deviceId: string;
  deviceLabel: string;
  role: string;
  lastSeen: number;
  online: boolean;
  background: boolean;
}
export interface SharedFocusEvent {
  action: string;
  by: string;
  deviceLabel: string;
  at: number;
  clientId: string;
}
export interface SharedFocusSession {
  sessionId: string;
  revision: number;
  state: string;
  task: FocusTask;
  leaderDeviceId: string;
  leaderLabel: string;
  elapsedMs: number;
  remainingMs: number;
  startedAt: number;
  updatedAt: number;
  participants: SharedFocusParticipant[];
  lastEvent: SharedFocusEvent;
  pauseCount?: number;
  interruptionCount?: number;
  record?: FocusSession | null;
}
export interface SharedFocusResponse {
  userId: string;
  deviceId: string;
  serverTime: number;
  session: SharedFocusSession | null;
}
export interface SharedFocusRequest {
  action: string;
  deviceId: string;
  deviceKey: string;
  clientId: string;
  expectedRevision: number;
  sessionId?: string;
  targetDeviceId?: string;
  task?: FocusTask;
  selfAssessment?: FocusSelfAssessment;
  occurredAt?: number;
}
