import { UiTheme } from '../utils/UiTheme';
import router from '@ohos.router';
import { appState } from '../data/AppState';

@Component
export struct FocusRecoveryCard {
  @StorageLink('focusDataRevision') @Watch('refresh') revision: number = 0;
  @State label: string = '';

  aboutToAppear(): void { this.refresh(); }

  private refresh(): void {
    this.label = appState.focusResultDraft !== null ? '上次专注尚未结算，可以继续保存。' :
      (appState.focusRuntime !== null ? (appState.focusRuntime.paused
        ? '上次专注已暂停，恢复后点击“继续专注”再计时。' :
        (appState.focusRuntime.task.allowBackgroundTiming ? '后台计时已开启，专注仍在计时。' : '专注仍在计时，可返回查看息屏期间的进度。')) : '');
  }

  build() {
    if (this.label.length > 0) {
      Row({ space: 8 }) {
        Text(this.label).fontSize(12).fontColor(UiTheme.ink).layoutWeight(1)
        Button('恢复').fontSize(12).onClick(() => router.pushUrl({ url: 'pages/FocusSetup' }))
      }.width('100%').padding(10).backgroundColor(UiTheme.tint)
    }
  }
}
