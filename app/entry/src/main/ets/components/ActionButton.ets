/** Consistent momentary action; selected filters use their own persistent state. */
@Component
export struct ActionButton {
  @Prop label: string = '';
  @Prop available: boolean = true;
  @State pressing: boolean = false;
  onAction: () => void = () => {};

  build() {
    Button(this.label, { type: ButtonType.Normal })
      .width('100%').constraintSize({ minHeight: 44 }).padding({ left: 12, right: 12, top: 12, bottom: 12 })
      .fontSize(14).fontWeight(FontWeight.Medium).borderRadius(12)
      .fontColor(!this.available ? '#98A2B3' : this.pressing ? '#FFFFFF' : '#2563EB')
      .backgroundColor(!this.available ? '#F2F4F7' : this.pressing ? '#2563EB' : '#FFFFFF')
      .border({ width: 1, color: this.available ? '#2563EB' : '#D0D5DD', radius: 12 })
      .enabled(this.available)
      .onTouch((event: TouchEvent) => {
        this.pressing = this.available && event.type === TouchType.Down;
      })
      .onKeyEvent((event: KeyEvent) => {
        if (event.keyCode === 2054 || event.keyCode === 2050) this.pressing = this.available && event.type === KeyType.Down;
      })
      .onBlur(() => this.pressing = false)
      .onClick(() => { this.pressing = false; if (this.available) this.onAction(); })
  }
}
