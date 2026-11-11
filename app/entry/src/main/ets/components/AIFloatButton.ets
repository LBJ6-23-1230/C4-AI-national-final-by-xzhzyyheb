import { UiTheme } from '../utils/UiTheme';
import { ChatMessage } from '../models/ChatModels';
import { AgentBridge } from '../services/AgentBridge';
import router from '@ohos.router';
import { appState } from '../data/AppState';

@Component
export struct AIFloatButton {
  @Prop bottomGap: number = 24;
  @State hostWidth: number = 400;
  @State hostHeight: number = 760;
  @State panelWidth: number = 376;
  @State panelHeight: number = 500;
  private resizeStartWidth: number = 376;
  private resizeStartHeight: number = 500;
  @State showPanel: boolean = false;
  @State translateX: number = 0;
  @State translateY: number = 0;
  @State messages: ChatMessage[] = [];
  @State inputText: string = '';
  @State isSending: boolean = false;
  @State hasLearningGoal: boolean = false;
  private requestVersion: number = 0;
  private scroller: Scroller = new Scroller();
  private msgIdCounter: number = 0;
  private dragStartX: number = 0;
  private dragStartY: number = 0;

  aboutToAppear(): void {
    this.messages = [{
      id: 'float-welcome',
      role: 'agent',
      text: '可以就当前页面继续提问，我会结合你的学习资料和目标回答。',
      time: '',
      status: 'done'
    }];
  }

  private makeId(): string {
    this.msgIdCounter++;
    return `float-${this.msgIdCounter}`;
  }

  aboutToDisappear(): void {
    this.requestVersion++;
    this.isSending = false;
  }

  private getTimeLabel(): string {
    const d: Date = new Date();
    const h: string = d.getHours().toString().padStart(2, '0');
    const m: string = d.getMinutes().toString().padStart(2, '0');
    return `${h}:${m}`;
  }

  private async sendMessage(): Promise<void> {
    const text: string = this.inputText.trim();
    if (text === '' || this.isSending) {
      return;
    }
    if (appState.chatSessionId.length === 0) appState.chatSessionId = `chat-${Date.now()}`;
    const owner: string = appState.currentUser.userId;
    const chatId: string = appState.chatSessionId;
    const version: number = ++this.requestVersion;

    const userMessage: ChatMessage = {
      id: this.makeId(),
      role: 'user',
      text: text,
      time: this.getTimeLabel(),
      status: 'done'
    };
    this.inputText = '';
    this.isSending = true;

    const loadingMessage: ChatMessage = {
      id: this.makeId(),
      role: 'agent',
      text: '思考中...',
      time: this.getTimeLabel(),
      status: 'sending'
    };
    const historyBeforeSend: ChatMessage[] = this.messages;
    this.messages = [...this.messages, userMessage, loadingMessage];
    this.scrollToBottom();

    try {
      const response = await AgentBridge.callAgent(text, undefined, historyBeforeSend, (progress) => {
        if (owner !== appState.currentUser.userId || chatId !== appState.chatSessionId || version !== this.requestVersion) return;
        this.messages = this.messages.map((item: ChatMessage): ChatMessage => item.id === loadingMessage.id ? {
          id: item.id, role: item.role, text: progress.reply || progress.message, time: item.time, status: 'sending'
        } : item);
      });
      if (owner !== appState.currentUser.userId || chatId !== appState.chatSessionId || version !== this.requestVersion) return;
      this.hasLearningGoal = response.learningContext !== undefined;
      this.messages = this.messages.filter((item: ChatMessage) => item.id !== loadingMessage.id);
      const agentMessage: ChatMessage = {
        id: this.makeId(),
        role: 'agent',
        text: response.reply,
        time: this.getTimeLabel(),
        status: 'done',
        card: response.card
      };
      this.messages = [...this.messages, agentMessage];
    } catch (e) {
      if (owner !== appState.currentUser.userId || chatId !== appState.chatSessionId || version !== this.requestVersion) return;
      this.messages = this.messages.filter((item: ChatMessage) => item.id !== loadingMessage.id);
      const errorMessage: ChatMessage = {
        id: this.makeId(),
        role: 'agent',
        text: '连接失败，请检查网络后重试。',
        time: this.getTimeLabel(),
        status: 'error'
      };
      this.messages = [...this.messages, errorMessage];
    }

    this.isSending = false;
    this.scrollToBottom();
  }

  private scrollToBottom(): void {
    this.scroller.scrollEdge(Edge.Bottom);
  }

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Button('问小知', { type: ButtonType.Normal }).height(44).fontSize(13).fontWeight(FontWeight.Medium)
        .fontColor(UiTheme.accent).backgroundColor(UiTheme.surface).borderRadius(8)
        .margin({ top: 6, right: 12 }).accessibilityText('问小知，打开当前页助手')
        .onClick(() => this.showPanel = !this.showPanel)
      if (this.showPanel) {
        Row() {}.width('100%').height('100%').backgroundColor('#66000000').onClick(() => this.showPanel = false)
        Column({ space: 0 }) {
          Row() {
            Text('问小知').fontSize(17).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).layoutWeight(1)
            Button('关闭', { type: ButtonType.Normal }).height(44).fontSize(13).fontColor(UiTheme.secondary)
              .backgroundColor(UiTheme.surface).onClick(() => this.showPanel = false)
          }.width('100%').padding({ left: 20, right: 12 })
            .gesture(PanGesture({ direction: PanDirection.All, distance: 6 })
              .onActionStart(() => { this.dragStartX = this.translateX; this.dragStartY = this.translateY; })
              .onActionUpdate((event: GestureEvent) => {
                this.translateX = Math.max(-(this.hostWidth - this.panelWidth) / 2, Math.min((this.hostWidth - this.panelWidth) / 2, this.dragStartX + event.offsetX));
                this.translateY = Math.max(-Math.max(0, this.hostHeight - this.panelHeight - this.bottomGap), Math.min(this.bottomGap, this.dragStartY + event.offsetY));
              }))
          Divider().color(UiTheme.line)
          Scroll(this.scroller) {
            Column({ space: 12 }) {
              ForEach(this.messages, (msg: ChatMessage) => {
                Row() {
                  if (msg.role === 'user') { Blank() }
                  Column({ space: 6 }) {
                    Text(msg.text).fontSize(14).lineHeight(22).fontColor(msg.role === 'user' ? UiTheme.surface : UiTheme.ink)
                    if (msg.status === 'sending') { LoadingProgress().width(18).height(18) }
                  }.padding(12).constraintSize({ maxWidth: '88%' }).borderRadius(8)
                    .backgroundColor(msg.role === 'user' ? UiTheme.accent : UiTheme.subtle)
                  if (msg.role !== 'user') { Blank() }
                }.width('100%')
              }, (msg: ChatMessage) => msg.id)
            }.width('100%').padding(16)
          }.layoutWeight(1).width('100%')
          Button('回到对话继续同一学习目标', { type: ButtonType.Normal }).width('100%').height(44)
            .fontSize(13).fontColor(UiTheme.accent).backgroundColor(UiTheme.surface)
            .onClick(() => { this.showPanel = false; router.pushUrl({ url: 'pages/ChatMain' }); })
          Row({ space: 8 }) {
            TextInput({ text: this.inputText, placeholder: '继续提问…' }).layoutWeight(1).height(44)
              .fontSize(14).backgroundColor(UiTheme.subtle).borderRadius(8)
              .onChange((value: string) => this.inputText = value).onSubmit(() => this.sendMessage())
            Button('发送', { type: ButtonType.Normal }).height(44).fontSize(14).fontColor(UiTheme.surface)
              .backgroundColor(UiTheme.accent).borderRadius(8).enabled(!this.isSending && this.inputText.trim().length > 0)
              .onClick(() => this.sendMessage())
          }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 20 })
          Row() {
            Text('拖动右侧调节大小').fontSize(12).fontColor(UiTheme.secondary).layoutWeight(1)
            Text('↗').fontSize(24).fontColor(UiTheme.accent).width(48).height(44).textAlign(TextAlign.Center).accessibilityText('拖动调节小知窗口大小')
              .gesture(PanGesture({ direction: PanDirection.All, distance: 1 })
                .onActionStart(() => { this.resizeStartWidth = this.panelWidth; this.resizeStartHeight = this.panelHeight; })
                .onActionUpdate((event: GestureEvent) => {
                  this.translateX = 0; this.translateY = 0;
                  this.panelWidth = Math.max(Math.min(280, this.hostWidth - 16), Math.min(this.hostWidth - 16, this.resizeStartWidth + event.offsetX));
                  this.panelHeight = Math.max(Math.min(300, this.hostHeight - 16), Math.min(this.hostHeight - 16, this.resizeStartHeight - event.offsetY));
                }))
          }.width('100%').padding({ left: 16, right: 4 })
        }.width(this.panelWidth).height(this.panelHeight).backgroundColor(UiTheme.surface)
          .borderRadius({ topLeft: 12, topRight: 12 }).align(Alignment.Bottom)
          .position({ x: (this.hostWidth - this.panelWidth) / 2 + this.translateX,
            y: Math.max(0, this.hostHeight - this.panelHeight - this.bottomGap) + this.translateY })
      }
    }.width('100%').height('100%').hitTestBehavior(HitTestMode.Transparent)
      .onAreaChange((oldArea: Area, area: Area) => {
        const width = Number(area.width);
        const height = Number(area.height);
        if (width <= 0 || height <= 0 || (width === this.hostWidth && height === this.hostHeight)) return;
        this.hostWidth = width;
        this.hostHeight = height;
        this.panelWidth = Math.max(1, Math.min(width - 16, UiTheme.formWidth));
        this.panelHeight = Math.max(1, Math.min(height - 16, Math.max(320, height * 0.68)));
        this.translateX = 0; this.translateY = 0;
      })
  }
}
