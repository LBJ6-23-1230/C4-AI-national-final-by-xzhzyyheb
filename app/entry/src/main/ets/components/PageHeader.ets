import router from '@ohos.router';
import { UiTheme } from '../utils/UiTheme';

@Component
export struct PageHeader {
  @Prop title: string = '';
  @Prop detail: string = '';
  onBack?: () => void;
  onTitle?: () => void;
  onDetail?: () => void;
  @Prop assistant: boolean = false;
  build() {
    Stack() {
      Text(this.title).fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink)
        .width(this.assistant || this.detail ? '58%' : '76%').maxLines(2).textAlign(TextAlign.Center)
        .onClick(() => { if (this.onTitle) this.onTitle(); })
      Row({ space: 8 }) {
      Text('‹').fontSize(22).fontColor(UiTheme.ink).width(44).height(44)
        .textAlign(TextAlign.Center).onClick(() => { if (this.onBack) this.onBack(); else router.back(); })
        .accessibilityText('返回').accessibilityLevel('yes')
      Blank()
      if (this.detail) {
        Text(this.detail).fontSize(12).fontColor(this.onDetail ? UiTheme.accent : UiTheme.secondary)
          .constraintSize({ minHeight: 44 }).padding({ top: 14, bottom: 14 })
          .onClick(() => { if (this.onDetail) this.onDetail(); })
      }
      if (this.assistant) { Blank().width(64) }
      }.width('100%').padding({ left: 8, right: 20 })
    }.width('100%').constraintSize({ minHeight: 56 }).padding({ top: 4, bottom: 4 })
      .backgroundColor(UiTheme.surface)
  }
}
