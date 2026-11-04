import { UiTheme } from '../utils/UiTheme';
@Component
export struct UserAvatar {
  @Prop source: string = '';
  @Prop nickname: string = '';
  @Prop diameter: number = 44;

  build() {
    Stack() {
      Text(this.nickname.trim().substring(0, 1) || '学')
        .fontSize(this.diameter * 0.42).fontWeight(FontWeight.Medium).fontColor(UiTheme.accent)
      if (this.source.length > 0) {
        Image(this.source).width(this.diameter).height(this.diameter).objectFit(ImageFit.Cover)
      }
    }.width(this.diameter).height(this.diameter).borderRadius(this.diameter / 2)
      .backgroundColor(UiTheme.tint).clip(true).accessibilityText('头像')
  }
}
