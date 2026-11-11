import { CourseInfo, HomeworkDDL } from '../models/AgentModels';
import { KnowledgeMastery } from './ApiModels';

export interface LearningDeletion { id: string; expectedVersion: number; }
export interface LearningChanges {
  courses: CourseInfo[];
  homeworkDDLs: HomeworkDDL[];
  deletedCourses: LearningDeletion[];
  deletedDDLs: LearningDeletion[];
  idempotencyKey: string;
  migration: boolean;
}
export interface LearningSnapshot {
  userId: string; revision: number; courses: CourseInfo[]; homeworkDDLs: HomeworkDDL[];
  deletedCourses?: LearningDeletion[];
  deletedDDLs?: LearningDeletion[];
}
export interface LearningEffect {
  userId: string; days: number; timezone: string; focusMinutes: number;
  completedFocusSessions: number; answeredCount: number; correctCount: number;
  practiceAccuracy: number | null; conclusion: string; points: KnowledgeMastery[]; ruleVersion: string;
  timeAttribution?: string;
}
