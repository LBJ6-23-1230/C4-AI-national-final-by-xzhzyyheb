import { Evidence, KnowledgeMastery, MasteryHistory } from '../api/ApiModels';

export class LearningEvidence {
  static assessed(point: KnowledgeMastery, evidence: Evidence[], history: MasteryHistory[]): boolean {
    return evidence.some((entry: Evidence) => entry.knowledgePointId === point.knowledgePointId &&
      (entry.sourceType === 'assessment' || entry.sourceType === 'exercise' || entry.sourceType === 'practice')) ||
      history.some((entry: MasteryHistory) => entry.knowledgePointId === point.knowledgePointId && entry.source === 'assessment');
  }
}
