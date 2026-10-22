import router from '@ohos.router';
import { appState } from '../data/AppState';

@Component
export struct FocusRecoveryCard {
  @StorageLink('focusDataRevision') @Watch('refresh') revision: number = 0;
  @State label: string = '';

  aboutToAppear(): void { this.refresh(); }

  private refresh(): void {
    this.label = appState.focusResultDraft !== null ? '上次专注尚未结算，可以继续保存。' :
      (appState.focusRuntime !== null ? '有一项未结束的专注，可以恢复计时。' : '');
  }

  build() {
    if (this.label.length > 0) {
      Row({ space: 8 }) {
        Text(this.label).fontSize(12).fontColor('#344054').layoutWeight(1)
        Button('恢复').fontSize(12).onClick(() => router.pushUrl({ url: 'pages/FocusSetup' }))
      }.width('100%').padding(10).backgroundColor('#EFF6FF')
    }
  }
}
