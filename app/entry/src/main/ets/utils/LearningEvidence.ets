import { Evidence, KnowledgeMastery, MasteryHistory } from '../api/ApiModels';

export class LearningEvidence {
  static hasAccuracy(point: KnowledgeMastery): boolean { return typeof point.recentAccuracy === 'number'; }
  static accuracyText(point: KnowledgeMastery): string { return LearningEvidence.hasAccuracy(point) ? `${point.recentAccuracy}%` : '待验证'; }
  static score(point: KnowledgeMastery): number { return point.recentAccuracy ?? point.masteryScore; }
  static label(point: KnowledgeMastery): string {
    const status: string = point.assessmentStatus ?? '';
    if (status === 'unassessed') return '未测评';
    if (status === 'evidence_limited') return '初步结果';
    if (status === 'needs_practice') return '需巩固';
    if (status === 'stable') return '当前表现较稳定';
    if (status === 'retest_due') return '待复测';
    return '历史估计 · 待验证';
  }
  static detail(point: KnowledgeMastery): string {
    if (point.assessmentStatus === 'unassessed') return '完成一轮诊断，了解当前表现';
    if (point.effectiveQuestionCount !== undefined) return `近期有效作答 ${point.correctCount ?? 0}/${point.effectiveQuestionCount} 正确`;
    return '完成新题练习，补充验证记录';
  }
  static assessed(point: KnowledgeMastery, evidence: Evidence[], history: MasteryHistory[]): boolean {
    if (point.assessmentStatus !== undefined) return (point.effectiveQuestionCount ?? 0) > 0;
    return evidence.some((entry: Evidence) => entry.knowledgePointId === point.knowledgePointId &&
      (entry.sourceType === 'assessment' || entry.sourceType === 'exercise' || entry.sourceType === 'practice')) ||
      history.some((entry: MasteryHistory) => entry.knowledgePointId === point.knowledgePointId && entry.source === 'assessment');
  }
}
