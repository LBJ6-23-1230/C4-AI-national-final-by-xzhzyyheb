@Component
export struct UserAvatar {
  @Prop source: string = '';
  @Prop nickname: string = '';
  @Prop diameter: number = 44;

  build() {
    Stack() {
      Text(this.nickname.trim().substring(0, 1) || '学')
        .fontSize(this.diameter * 0.42).fontWeight(FontWeight.Medium).fontColor('#2563EB')
      if (this.source.length > 0) {
        Image(this.source).width(this.diameter).height(this.diameter).objectFit(ImageFit.Cover)
      }
    }.width(this.diameter).height(this.diameter).borderRadius(this.diameter / 2)
      .backgroundColor('#EFF6FF').clip(true).accessibilityText('头像')
  }
}
