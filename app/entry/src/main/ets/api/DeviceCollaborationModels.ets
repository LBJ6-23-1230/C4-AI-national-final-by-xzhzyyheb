import { FocusTask } from '../models/AgentModels';

export interface CollaborationDevice {
  deviceId: string;
  deviceLabel: string;
  online: boolean;
  lastSeen: number;
}
export interface CollaborationMessage {
  messageId: string;
  task: FocusTask | null;
  sentAt: number;
  ackedAt: number;
}
export interface CollaborationLink {
  invitationId: string;
  peerDeviceId: string;
  peerDeviceLabel: string;
  state: string;
  incoming: boolean;
  expiresAt: number;
  received: CollaborationMessage | null;
  sentMessageId: string;
  acknowledgedAt: number;
}
export interface CollaborationResponse {
  userId: string;
  deviceId: string;
  serverTime: number;
  devices: CollaborationDevice[];
  links: CollaborationLink[];
}
export interface CollaborationRequest {
  action: string;
  deviceId: string;
  deviceKey: string;
  deviceLabel?: string;
  targetDeviceId?: string;
  invitationId?: string;
  messageId?: string;
  task?: FocusTask;
}
