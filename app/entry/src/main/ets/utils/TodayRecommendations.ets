import { ReminderEvent, TodayOverview } from '../api/ReminderModels';

export class TodayRecommendations {
  static items(overview: TodayOverview | null): ReminderEvent[] {
    if (overview === null) return [];
    if (overview.allTasks !== undefined) {
      return overview.allTasks.filter((item: ReminderEvent): boolean =>
        item.status === 'pending' || item.status === 'ignored');
    }
    return overview.highlight === null ? [] : [overview.highlight, ...overview.tasks];
  }

  static select(overview: TodayOverview | null, eventId: string): ReminderEvent | null {
    const items: ReminderEvent[] = TodayRecommendations.items(overview);
    return items.find((item: ReminderEvent): boolean => item.eventId === eventId) ?? items[0] ?? null;
  }
}
