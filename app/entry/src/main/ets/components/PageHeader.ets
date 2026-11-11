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
    Row({ space: 4 }) {
      Text('‹').fontSize(22).fontColor(UiTheme.ink).width(UiTheme.touch).height(UiTheme.touch).flexShrink(0)
        .textAlign(TextAlign.Center).onClick(() => { if (this.onBack) this.onBack(); else router.back(); })
        .accessibilityText('返回').accessibilityLevel('yes')
      Text(this.title).fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink)
        .layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(TextAlign.Center)
        .onClick(() => { if (this.onTitle) this.onTitle(); })
      if (this.detail) {
        Text(this.detail).fontSize(12).fontColor(this.onDetail ? UiTheme.accent : UiTheme.secondary)
          .constraintSize({ minHeight: UiTheme.touch, maxWidth: '26%' })
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(TextAlign.End)
          .onClick(() => { if (this.onDetail) this.onDetail(); })
      }
      if (this.assistant || !this.detail) {
        Blank().width(this.assistant ? 64 : UiTheme.touch).flexShrink(0)
      }
    }.width('100%').constraintSize({ minHeight: 56, maxWidth: UiTheme.workspaceWidth })
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .backgroundColor(UiTheme.surface)
  }
}
