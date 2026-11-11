import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'DeviceLayout';

export class DeviceLayout {
  static readonly PHONE: string = 'phone';
  static readonly TABLET: string = 'tablet';
  static readonly DESKTOP: string = 'desktop';

  static readonly TABLET_MIN_WIDTH: number = 600;
  static readonly DESKTOP_MIN_WIDTH: number = 840;

  static readonly CONTENT_MAX_WIDTH: number = 720;

  private static widthVp: number = 0;
  private static breakpoint: string = DeviceLayout.PHONE;
  private static mainWindow: window.Window | null = null;
  private static sizeListener: ((size: window.Size) => void) | null = null;

  static windowWidth(): number {
    return DeviceLayout.widthVp;
  }

  static current(): string {
    return DeviceLayout.breakpoint;
  }

  static isLargeScreen(): boolean {
    return DeviceLayout.breakpoint !== DeviceLayout.PHONE;
  }

  static contentMaxWidth(): number {
    return DeviceLayout.isLargeScreen() ? DeviceLayout.CONTENT_MAX_WIDTH : 10000;
  }

  static attach(windowStage: window.WindowStage): void {
    DeviceLayout.detach();
    try {
      const mainWindow: window.Window = windowStage.getMainWindowSync();
      const uiContext = mainWindow.getUIContext();
      const listener = (size: window.Size): void => {
        DeviceLayout.update(uiContext.px2vp(size.width));
        AppStorage.setOrCreate('layoutHeightVp', uiContext.px2vp(size.height));
      };
      const rect = mainWindow.getWindowProperties().windowRect;
      listener({ width: rect.width, height: rect.height });
      mainWindow.on('windowSizeChange', listener);
      DeviceLayout.mainWindow = mainWindow;
      DeviceLayout.sizeListener = listener;
    } catch (error) {
      const typed = error as BusinessErrorLike;
      hilog.warn(DOMAIN, TAG, '%{public}s',
        `DeviceLayout.attach failed: ${typed.code} ${typed.message}`);
    }
  }

  static detach(): void {
    if (DeviceLayout.mainWindow !== null && DeviceLayout.sizeListener !== null) {
      try {
        DeviceLayout.mainWindow.off('windowSizeChange', DeviceLayout.sizeListener);
      } catch (error) {
        const typed = error as BusinessErrorLike;
        hilog.warn(DOMAIN, TAG, 'DeviceLayout.detach failed: %{public}d', typed.code);
      }
    }
    DeviceLayout.mainWindow = null;
    DeviceLayout.sizeListener = null;
  }

  static update(widthVp: number): void {
    if (!(widthVp > 0)) {
      return;
    }
    DeviceLayout.widthVp = widthVp;
    DeviceLayout.breakpoint = DeviceLayout.classify(widthVp);
  }

  static classify(widthVp: number): string {
    if (!(widthVp > 0)) {
      return DeviceLayout.PHONE;
    }
    if (widthVp >= DeviceLayout.DESKTOP_MIN_WIDTH) {
      return DeviceLayout.DESKTOP;
    }
    if (widthVp >= DeviceLayout.TABLET_MIN_WIDTH) {
      return DeviceLayout.TABLET;
    }
    return DeviceLayout.PHONE;
  }

  static describe(): string {
    const label: string = DeviceLayout.breakpoint === DeviceLayout.DESKTOP ? '桌面 / 2in1'
      : (DeviceLayout.breakpoint === DeviceLayout.TABLET ? '平板' : '手机');
    return `${label}（${Math.round(DeviceLayout.widthVp)}vp）`;
  }
}

interface BusinessErrorLike {
  code: number;
  message: string;
}
