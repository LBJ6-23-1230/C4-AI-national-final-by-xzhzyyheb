import { FocusDepartureReason, FocusRuntime, FocusTask } from '../models/AgentModels';

/** Persistable timing facts. Normal focus is paused by departure/recovery hooks. */
export class FocusClock {
  static create(ownerId: string, task: FocusTask, now: number = Date.now()): FocusRuntime {
    return { sessionId: `focus-${now}-${Math.random().toString(36).substring(2, 10)}`,
      ownerId: ownerId, task: task, elapsedMs: 0, lastUpdatedAt: now,
      paused: false, pauseCount: 0, interruptionCount: 0 };
  }

  static advance(value: FocusRuntime, now: number = Date.now()): FocusRuntime {
    const elapsed: number = value.elapsedMs + (value.paused ? 0 : Math.max(0, now - value.lastUpdatedAt));
    const limit: number = value.task.timerType === 'stopwatch' ? 86400000 : value.task.plannedMinutes * 60000;
    const finishedAt: number | undefined = value.finishedAt ?? ((!value.paused && elapsed >= limit)
      ? value.lastUpdatedAt + Math.max(0, limit - value.elapsedMs) : undefined);
    return { sessionId: value.sessionId, ownerId: value.ownerId, task: value.task, shared: value.shared,
      elapsedMs: Math.min(limit, elapsed), lastUpdatedAt: Math.max(now, value.lastUpdatedAt),
      paused: value.paused, pauseCount: value.pauseCount, interruptionCount: value.interruptionCount,
      finishedAt: finishedAt, autoPaused: value.autoPaused, backgroundReason: value.backgroundReason };
  }

  static pauseOnDeparture(value: FocusRuntime, now: number = Date.now()): FocusRuntime {
    if (value.task.mode === 'strict' || value.paused) return value;
    const next: FocusRuntime = FocusClock.advance(value, now);
    next.paused = true;
    next.autoPaused = true;
    next.backgroundReason = undefined;
    next.pauseCount++;
    return next;
  }

  static depart(value: FocusRuntime, reason: FocusDepartureReason, now: number = Date.now()): FocusRuntime {
    if (reason === 'navigation' || value.shared === true) return FocusClock.advance(value, now);
    if (value.paused) return value;
    if (reason !== 'screenOff' && value.task.mode !== 'strict' && value.task.allowBackgroundTiming !== true) {
      return FocusClock.pauseOnDeparture(value, now);
    }
    const next: FocusRuntime = FocusClock.advance(value, now);
    if (value.task.mode === 'strict' && reason !== 'screenOff' && value.backgroundReason !== 'background') next.interruptionCount++;
    next.backgroundReason = reason === 'screenOff' ? 'screenOff' : 'background';
    return next;
  }

  static valid(value: FocusRuntime | undefined, ownerId: string): boolean {
    return value !== undefined && value !== null && value.ownerId === ownerId && typeof value.sessionId === 'string' &&
      value.sessionId.length > 0 && value.task !== undefined && value.task !== null && typeof value.task.task === 'string' &&
      typeof value.task.plannedMinutes === 'number' && value.task.plannedMinutes >= 0 &&
      value.task.plannedMinutes <= 1440 && Number.isFinite(value.elapsedMs) && value.elapsedMs >= 0 &&
      Number.isFinite(value.lastUpdatedAt) && value.lastUpdatedAt > 0 &&
      typeof value.paused === 'boolean' && Number.isInteger(value.pauseCount) && value.pauseCount >= 0 &&
      Number.isInteger(value.interruptionCount) && value.interruptionCount >= 0;
  }
}
