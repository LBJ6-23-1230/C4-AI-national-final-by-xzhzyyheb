import { ReminderEvent, TodayOverview } from '../api/ReminderModels';

export class PendingTasks {
  static otherTasks(overview: TodayOverview | null, isCompleted: (id: string) => boolean): ReminderEvent[] {
    const items: ReminderEvent[] = (overview?.allTasks ?? []).filter((item: ReminderEvent) =>
      item.status !== 'completed' && item.status !== 'invalid' && item.sourceType !== 'ddl' &&
      (item.kind === 'exam' || item.kind === 'task') &&
      (item.kind !== 'task' || !isCompleted(item.sourceId || item.objectId)));
    const seen: Set<string> = new Set<string>();
    return items.filter((item: ReminderEvent) => {
      if (item.kind === 'task' && items.some((exam: ReminderEvent) => exam.kind === 'exam' &&
        exam.knowledgePointId.length > 0 && exam.knowledgePointId === item.knowledgePointId &&
        exam.courseName === item.courseName)) return false;
      const key: string = item.kind === 'exam'
        ? `exam:${item.courseName}:${item.knowledgePointId || item.objectId}`
        : `task:${item.sourceId || item.objectId}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
  }

  static count(overview: TodayOverview | null, pendingDDLCount: number,
    isCompleted: (id: string) => boolean): number {
    if (overview === null || overview.allTasks === undefined) return -1;
    return pendingDDLCount + PendingTasks.otherTasks(overview, isCompleted).length;
  }
}
