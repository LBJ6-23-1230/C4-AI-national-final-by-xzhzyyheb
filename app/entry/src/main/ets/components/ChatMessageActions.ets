@Component
export struct ChatMessageAction {
  @Prop icon: Resource = $r('sys.symbol.plus');
  @Prop label: string = '';
  @Prop color: string = '#F8FAFC';
  onAction: () => void = () => {};

  build() {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 4 }) {
        SymbolGlyph(this.icon).fontSize(20).fontColor([this.color])
        Text(this.label).fontSize(12).fontColor(this.color)
      }
    }.width(58).height(56).padding(0).backgroundColor(Color.Transparent)
      .accessibilityText(this.label).onClick(() => this.onAction())
  }
}
