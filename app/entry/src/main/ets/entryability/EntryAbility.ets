import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import router from '@ohos.router';
import { AgentApiClient } from '../api/AgentApiClient';
import { ApiEnvironmentStore } from '../api/ApiEnvironmentStore';
import { AuthClient } from '../api/AuthClient';
import { AuthResult } from '../api/AuthResult';
import { AuthStore } from '../api/AuthStore';
import { FixtureDemoStateStore } from '../api/FixtureDemoStateStore';
import { WorkflowSessionStore } from '../cache/WorkflowSessionStore';
import { LearningDataStore } from '../cache/LearningDataStore';
import { appState } from '../data/AppState';
import { DistributedStateService } from '../services/DistributedStateService';
import { ProactiveSurfaceService } from '../services/ProactiveSurfaceService';
import { ProactiveSettingsStore } from '../services/ProactiveSettingsStore';
import { DeviceLayout } from '../utils/DeviceLayout';
import { FocusLifecycleService } from '../services/FocusLifecycleService';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  private activeWindowStage: window.WindowStage | null = null;
  private startupReady: boolean = false;
  private pendingLearningCard: boolean = false;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    this.pendingLearningCard = this.isLearningCardLaunch(want);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');
    this.activeWindowStage = windowStage;

    if (!ApiEnvironmentStore.restore(this.context)) {
      hilog.warn(DOMAIN, 'testTag', '%{public}s', 'Failed to restore API environment, using defaults.');
    }
    if (!FixtureDemoStateStore.initialize(this.context)) {
      hilog.warn(DOMAIN, 'testTag', '%{public}s', 'Failed to restore fixture demo state.');
    }
    if (!WorkflowSessionStore.restore(this.context)) {
      hilog.warn(DOMAIN, 'testTag', '%{public}s', 'Failed to restore workflow session.');
    }
    if (!ProactiveSettingsStore.restore(this.context)) {
      hilog.warn(DOMAIN, 'testTag', '%{public}s', 'Failed to restore proactive notification settings.');
    }

    LearningDataStore.initialize(this.context);
    FocusLifecycleService.initialize();

    appState.applyLogout();
    appState.markIdentityPending();

    windowStage.loadContent('pages/ChatMain', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      if (this.activeWindowStage === windowStage) {
        DeviceLayout.attach(windowStage);
        void this.bootstrapAuth(windowStage);
      }
    });

    void DistributedStateService.getInstance().init(this.context);
  }

  private async bootstrapAuth(windowStage: window.WindowStage): Promise<void> {
    try {
      const ready: boolean = await AuthStore.initialize(this.context);
      if (!ready) {
        hilog.warn(DOMAIN, 'testTag', '%{public}s', 'Failed to restore auth session.');
      }
      if (AuthStore.encryptionDegraded()) {
        hilog.warn(DOMAIN, 'testTag', '%{public}s',
          'Token encryption unavailable; credentials remain in memory for this session.');
      }
    } catch (error) {
      hilog.error(DOMAIN, 'testTag', 'AuthStore init failed: %{public}s', JSON.stringify(error));
    }
    if (this.activeWindowStage !== windowStage) return;
    await this.restoreIdentity(windowStage);
    if (this.activeWindowStage !== windowStage) return;
    this.startupReady = true;
    if (this.pendingLearningCard) {
      this.pendingLearningCard = false;
      void this.openLearningCard(windowStage);
    }
    void DistributedStateService.getInstance().refresh();
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    if (!this.isLearningCardLaunch(want)) return;
    if (this.startupReady && this.activeWindowStage !== null) {
      void this.openLearningCard(this.activeWindowStage);
    } else {
      this.pendingLearningCard = true;
    }
  }

  private async restoreIdentity(windowStage: window.WindowStage): Promise<void> {
    try {
      if (!AuthStore.isSignedIn()) {
        appState.applyLogout();
        await windowStage.loadContent('pages/Login');
        return;
      }

      if (AgentApiClient.getConfig().useFixture) {
        const restored: AuthResult = await AuthClient.restore();
        if (restored.ok && restored.user !== null) {
          appState.applyLogin(restored.user, restored.source);
        }
        return;
      }

      const result: AuthResult = await AuthClient.restore();
      if (result.ok && result.user !== null) {
        appState.applyLogin(result.user, result.source);
        if (result.needsPasswordSetup === true) {
          await windowStage.loadContent('pages/PasswordSetup');
          return;
        }
        hilog.info(DOMAIN, 'testTag', 'Restored identity: %{public}s', result.user.userId);
      } else {
        appState.applyLogout();
        await windowStage.loadContent('pages/Login');
      }
    } catch (error) {
      hilog.error(DOMAIN, 'testTag', 'restoreIdentity failed: %{public}s', JSON.stringify(error));
      appState.applyLogout();
    } finally {
      appState.markIdentityReady();
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
    this.activeWindowStage = null;
    this.startupReady = false;
    DeviceLayout.detach();
    FocusLifecycleService.destroy();
    void DistributedStateService.getInstance().leave();
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    FocusLifecycleService.onForeground();
    DistributedStateService.getInstance().setForeground(true);
    void appState.syncFocusSessions();
    void ProactiveSurfaceService.refresh(this.context, true);
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    FocusLifecycleService.onBackground();
    DistributedStateService.getInstance().setForeground(false);
    void ProactiveSurfaceService.refresh(this.context, false);
  }

  private isLearningCardLaunch(want: Want): boolean {
    return want.parameters?.['source'] === 'learning_card';
  }

  private async openLearningCard(windowStage: window.WindowStage): Promise<void> {
    try {
      const pageRouter = windowStage.getMainWindowSync().getUIContext().getRouter();
      const current = pageRouter.getState();
      if (current.name === 'Login' || current.name === 'PasswordSetup') return;
      await pageRouter.pushUrl({ url: 'pages/CourseImport', params: { initialTab: 'ddls', cardLaunch: `${Date.now()}` } },
        router.RouterMode.Single);
    } catch (error) {
      hilog.warn(DOMAIN, 'testTag', 'Failed to open learning card. Cause: %{public}s', JSON.stringify(error));
    }
  }

}
