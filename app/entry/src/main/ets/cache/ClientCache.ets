import {
  ExerciseSetResponse,
  ExerciseSubmissionResult,
  LearningPlan,
  PlanDiff,
  ProfileResponse,
  TraceResponse,
  WorkflowResponse,
  WorkflowStatusResponse
} from '../api/ApiModels';

export class ClientCache {
  private static profile: ProfileResponse | null = null;
  private static currentPlan: LearningPlan | null = null;
  private static workflow: WorkflowResponse | null = null;
  private static workflowStatus: WorkflowStatusResponse | null = null;
  private static exerciseSet: ExerciseSetResponse | null = null;
  private static latestAssessment: ExerciseSubmissionResult | null = null;
  private static planDiff: PlanDiff | null = null;
  private static trace: TraceResponse | null = null;

  private static ownerUserId: string = '';

  private static pendingWorkflowOwner: string = '';
  private static pendingWorkflow: WorkflowResponse | null = null;

  static bindIdentity(userId: string): void {
    if (ClientCache.ownerUserId !== userId) {
      ClientCache.clearDemoData();
    }
    ClientCache.ownerUserId = userId;
    if (ClientCache.pendingWorkflow !== null && ClientCache.pendingWorkflowOwner === userId) {
      ClientCache.workflow = ClientCache.pendingWorkflow;
      ClientCache.workflowStatus = null;
    }
  }

  static stageRestoredWorkflow(ownerUserId: string, value: WorkflowResponse): void {
    ClientCache.pendingWorkflowOwner = ownerUserId;
    ClientCache.pendingWorkflow = value;
    if (ClientCache.ownerUserId === ownerUserId) {
      ClientCache.workflow = value;
      ClientCache.workflowStatus = null;
    }
  }

  static currentOwnerUserId(): string {
    return ClientCache.ownerUserId;
  }

  static cacheProfile(value: ProfileResponse): void { ClientCache.profile = value; }
  static getProfile(): ProfileResponse | null { return ClientCache.profile; }
  static invalidateProfile(): void { ClientCache.profile = null; }

  static cacheCurrentPlan(value: LearningPlan): void { ClientCache.currentPlan = value; }
  static getCurrentPlan(): LearningPlan | null { return ClientCache.currentPlan; }
  static invalidateCurrentPlan(): void { ClientCache.currentPlan = null; }

  static cacheWorkflow(value: WorkflowResponse): void { ClientCache.workflow = value; }
  static getWorkflow(): WorkflowResponse | null { return ClientCache.workflow; }
  static invalidateWorkflow(): void {
    ClientCache.workflow = null;
    ClientCache.workflowStatus = null;
  }

  static cacheWorkflowStatus(value: WorkflowStatusResponse): void { ClientCache.workflowStatus = value; }
  static getWorkflowStatus(): WorkflowStatusResponse | null { return ClientCache.workflowStatus; }
  static invalidateWorkflowStatus(): void { ClientCache.workflowStatus = null; }

  static cacheExerciseSet(value: ExerciseSetResponse): void { ClientCache.exerciseSet = value; }
  static getExerciseSet(): ExerciseSetResponse | null { return ClientCache.exerciseSet; }
  static invalidateExerciseSet(): void { ClientCache.exerciseSet = null; }

  static cacheAssessment(value: ExerciseSubmissionResult): void { ClientCache.latestAssessment = value; }
  static getAssessment(): ExerciseSubmissionResult | null { return ClientCache.latestAssessment; }

  static cachePlanDiff(value: PlanDiff): void { ClientCache.planDiff = value; }
  static getPlanDiff(): PlanDiff | null { return ClientCache.planDiff; }

  static cacheTrace(value: TraceResponse): void { ClientCache.trace = value; }
  static getTrace(): TraceResponse | null { return ClientCache.trace; }
  static invalidateTrace(): void { ClientCache.trace = null; }

  static clearDemoData(): void {
    ClientCache.profile = null;
    ClientCache.currentPlan = null;
    ClientCache.workflow = null;
    ClientCache.workflowStatus = null;
    ClientCache.exerciseSet = null;
    ClientCache.latestAssessment = null;
    ClientCache.planDiff = null;
    ClientCache.trace = null;
  }
}
