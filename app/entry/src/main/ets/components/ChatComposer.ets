import { UiTheme } from '../utils/UiTheme';

@Component
export struct ChatComposer {
  @Prop draft: string = '';
  @Prop placeholder: string = '发送消息';
  @Prop toolsLabel: string = '更多功能';
  @Prop maxLength: number = 3000;
  @Prop busy: boolean = false;
  @Prop canSend: boolean = false;
  @Prop voiceMode: boolean = false;
  @Prop voiceReady: boolean = false;
  @Prop voicePressing: boolean = false;
  @Prop voiceTurnStarted: boolean = false;
  @Prop startingVoice: boolean = false;
  @Prop listening: boolean = false;
  inputController: TextInputController = new TextInputController();
  onDraftChange: (value: string) => void = () => {};
  onVoiceToggle: () => void = () => {};
  onVoiceDown: () => void = () => {};
  onVoiceStart: () => void = () => {};
  onVoiceEnd: (cancelled: boolean) => void = () => {};
  onImage: () => void = () => {};
  onTools: () => void = () => {};
  onSend: () => void = () => {};

  build() {
    Row({ space: 8 }) {
      // Voice mode keeps a stable press target while the recognized text changes.
      Button({ type: ButtonType.Normal, stateEffect: true }) {
        SymbolGlyph(this.voiceMode ? $r('sys.symbol.camera') : $r('sys.symbol.mic'))
          .fontSize(22).fontColor([UiTheme.ink])
      }
      .backgroundColor(UiTheme.surface).width(44).height(44).borderRadius(8)
      .enabled(!this.busy && !this.startingVoice && !this.listening)
      .accessibilityText(this.voiceMode ? '添加图片' : '切换到按住说话')
      .onClick(() => {
        if (this.voiceMode) this.onImage();
        else this.onVoiceToggle();
      })
      if (this.voiceMode) {
        Button({ type: ButtonType.Normal, stateEffect: false }) {
          Column({ space: 2 }) {
            Text(this.voicePressing && this.draft.length > 0 ? this.draft :
              (this.startingVoice ? '正在打开麦克风…' : (this.listening ? '正在聆听…' : '按住说话')))
              .fontSize(16).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).maxLines(3)
            if (this.voicePressing && this.voiceTurnStarted) {
              Text('松开完成').fontSize(11).fontColor(UiTheme.secondary)
            }
          }.width('100%').padding({ top: 10, bottom: 10 })
        }
        .layoutWeight(1).constraintSize({ minHeight: 44, maxHeight: 108 }).borderRadius(8)
        .backgroundColor(this.voicePressing ? UiTheme.tint : UiTheme.subtle)
        .enabled(this.voiceReady && !this.busy)
        .accessibilityText('按住说话，松开后可编辑识别文字')
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) this.onVoiceDown();
          else if (event.type === TouchType.Up) this.onVoiceEnd(false);
          else if (event.type === TouchType.Cancel) this.onVoiceEnd(true);
        })
        .gesture(LongPressGesture({ repeat: false, duration: 200 })
          .onAction(() => { this.onVoiceStart(); })
          .onActionEnd(() => { this.onVoiceEnd(false); })
          .onActionCancel(() => { this.onVoiceEnd(true); }))
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.keyboard')).fontSize(23).fontColor([UiTheme.ink])
        }
        .width(44).height(44).borderRadius(8).backgroundColor(UiTheme.surface)
        .enabled(!this.startingVoice && !this.listening)
        .accessibilityText('切换到键盘输入').onClick(() => { this.onVoiceToggle(); })
      } else {
        TextInput({ placeholder: this.placeholder, text: this.draft, controller: this.inputController })
          .height(44).layoutWeight(1).fontSize(14).placeholderColor(UiTheme.muted)
          .fontColor(UiTheme.ink).backgroundColor(UiTheme.subtle).borderRadius(8)
          .maxLength(this.maxLength > 0 ? this.maxLength : undefined).onChange((value: string) => this.onDraftChange(value))
      }
      Button({ type: ButtonType.Normal, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.plus')).fontSize(24).fontColor([UiTheme.ink])
      }.backgroundColor(UiTheme.surface).width(44).height(44).borderRadius(8)
        .enabled(!this.busy && !this.startingVoice && !this.listening)
        .accessibilityText(this.toolsLabel).onClick(() => this.onTools())
      if (!this.voiceMode) {
        Button('发送').fontSize(14).fontColor(UiTheme.surface)
          .backgroundColor(this.canSend ? UiTheme.accent : '#CBD5E1').height(44).borderRadius(8)
          .enabled(this.canSend).onClick(() => this.onSend())
      }
    }
    .width('100%')
  }
}
