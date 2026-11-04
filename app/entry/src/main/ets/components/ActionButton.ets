import { UiTheme } from '../utils/UiTheme';
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
      .fontSize(14).fontWeight(FontWeight.Medium).borderRadius(8)
      .fontColor(!this.available ? UiTheme.muted : this.pressing ? UiTheme.surface : UiTheme.accent)
      .backgroundColor(!this.available ? UiTheme.subtle : this.pressing ? UiTheme.accent : UiTheme.surface)
      .border({ width: 1, color: this.available ? UiTheme.accent : '#D0D5DD', radius: 12 })
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
