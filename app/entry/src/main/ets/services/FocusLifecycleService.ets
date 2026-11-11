import power from '@ohos.power';
import commonEventManager from '@ohos.commonEventManager';
import { appState } from '../data/AppState';
import { FocusDepartureReason, FocusRuntime } from '../models/AgentModels';
import { FocusClock } from '../utils/FocusClock';

export class FocusLifecycleService {
  private static subscriber: commonEventManager.CommonEventSubscriber | null = null;
  private static foreground: boolean = true;
  private static pageVisible: boolean = false;
  private static locked: boolean = false;
  private static pendingId: string = '';
  private static pendingOwner: string = '';
  private static departedAt: number = 0;
  private static screenOffObserved: boolean = false;
  private static pendingWake: boolean = false;
  private static timer: number = -1;

  static initialize(): void {
    if (FocusLifecycleService.subscriber !== null) return;
    try {
      const events = commonEventManager.Support;
      const subscriber = commonEventManager.createSubscriberSync({ events: [events.COMMON_EVENT_SCREEN_OFF,
        events.COMMON_EVENT_SCREEN_ON, events.COMMON_EVENT_SCREEN_LOCKED, events.COMMON_EVENT_SCREEN_UNLOCKED] });
      commonEventManager.subscribe(subscriber, (error, data) => {
        if (error || !data) return;
        if (data.event === events.COMMON_EVENT_SCREEN_OFF || data.event === events.COMMON_EVENT_SCREEN_LOCKED) {
          FocusLifecycleService.locked = true;
          if (FocusLifecycleService.pendingId.length > 0) FocusLifecycleService.screenOffObserved = true;
        } else if (data.event === events.COMMON_EVENT_SCREEN_UNLOCKED) {
          FocusLifecycleService.locked = false;
          FocusLifecycleService.screenUnlocked();
        }
      });
      FocusLifecycleService.subscriber = subscriber;
    } catch (_) {                                                                            }
  }

  private static screenOff(): boolean {
    try { return FocusLifecycleService.locked || !power.isActive(); } catch (_) { return FocusLifecycleService.locked; }
  }

  static onForeground(): void {
    FocusLifecycleService.foreground = true;
    FocusLifecycleService.locked = false;
  }

  static onBackground(): void {
    FocusLifecycleService.foreground = false;
    FocusLifecycleService.pageHidden();
  }

  static enterPage(): void {
    FocusLifecycleService.pageVisible = true;
    FocusLifecycleService.resolvePending();
    const runtime: FocusRuntime | null = appState.focusRuntime;
    if (runtime === null || runtime.ownerId !== appState.currentUser.userId) return;
    const current: FocusRuntime = FocusClock.advance(runtime);
    current.backgroundReason = undefined;
    appState.checkpointFocusRuntime(current);
  }

  static pageHidden(): void {
    FocusLifecycleService.pageVisible = false;
    const runtime: FocusRuntime | null = appState.focusRuntime;
    if (runtime === null || runtime.paused || runtime.ownerId !== appState.currentUser.userId) return;
    if (FocusLifecycleService.pendingId === runtime.sessionId) return;
    FocusLifecycleService.clearPending();
    FocusLifecycleService.pendingId = runtime.sessionId;
    FocusLifecycleService.pendingOwner = runtime.ownerId;
    FocusLifecycleService.departedAt = Date.now();
    FocusLifecycleService.screenOffObserved = FocusLifecycleService.screenOff();
    appState.checkpointFocusRuntime(FocusClock.advance(runtime, FocusLifecycleService.departedAt));
    FocusLifecycleService.timer = setTimeout(() => FocusLifecycleService.resolvePending(), 300);
  }

  static leavePage(): void {
    FocusLifecycleService.pageVisible = false;
    FocusLifecycleService.clearPending();
  }

  private static screenUnlocked(): void {
    if (FocusLifecycleService.foreground) return;
    if (FocusLifecycleService.screenOffObserved) FocusLifecycleService.resolvePending();
    if (appState.focusRuntime?.backgroundReason !== 'screenOff') return;
    FocusLifecycleService.pageHidden();
    FocusLifecycleService.pendingWake = true;
  }

  static resolvePending(): void {
    if (FocusLifecycleService.pendingId.length === 0) return;
    const runtime: FocusRuntime | null = appState.focusRuntime;
    if (runtime !== null && runtime.sessionId === FocusLifecycleService.pendingId &&
      runtime.ownerId === FocusLifecycleService.pendingOwner && runtime.ownerId === appState.currentUser.userId) {
      const reason: FocusDepartureReason = FocusLifecycleService.screenOffObserved || FocusLifecycleService.screenOff()
        ? 'screenOff' : (FocusLifecycleService.foreground ? 'navigation' : 'background');
      if (reason !== 'navigation' && !(FocusLifecycleService.pendingWake && FocusLifecycleService.foreground && FocusLifecycleService.pageVisible)) {
        appState.handleFocusDeparture(reason, FocusLifecycleService.departedAt);
      }
    }
    FocusLifecycleService.clearPending();
  }

  private static clearPending(): void {
    if (FocusLifecycleService.timer >= 0) clearTimeout(FocusLifecycleService.timer);
    FocusLifecycleService.timer = -1;
    FocusLifecycleService.pendingId = '';
    FocusLifecycleService.pendingOwner = '';
    FocusLifecycleService.screenOffObserved = false;
    FocusLifecycleService.pendingWake = false;
  }

  static destroy(): void {
    FocusLifecycleService.resolvePending();
    if (FocusLifecycleService.subscriber !== null) {
      try { commonEventManager.unsubscribe(FocusLifecycleService.subscriber); } catch (_) {}
      FocusLifecycleService.subscriber = null;
    }
    FocusLifecycleService.locked = false;
    FocusLifecycleService.pageVisible = false;
  }
}
