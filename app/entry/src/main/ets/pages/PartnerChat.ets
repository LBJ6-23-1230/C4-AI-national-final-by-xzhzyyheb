import { ChatComposer } from '../components/ChatComposer';
import { ChatMessageAction } from '../components/ChatMessageActions';
import { UiTheme } from '../utils/UiTheme';
import { KeyboardAvoidMode } from '@ohos.arkui.UIContext';
import { PageHeader } from '../components/PageHeader';
import { UserAvatar } from '../components/UserAvatar';
import router from '@ohos.router';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { PartnerContact } from '../api/ApiModels';
import { ApiFailure } from '../api/ApiResult';
import { AgentApiClient } from '../api/AgentApiClient';
import { PartnerMessage, PartnerConversation } from '../api/LearningUpgradeModels';
import { appState } from '../data/AppState';
import { ImageEncoder } from '../utils/ImageEncoder';
import { VoiceInputCallbacks, VoiceInputService } from '../services/VoiceInputService';

@Entry
@Component
struct PartnerChat {
  @State partnerId: string = '';
  @State partnerName: string = '';
  @State messages: PartnerMessage[] = [];
  @State draft: string = '';
  @State imageUri: string = '';
  @State notice: string = '';
  @State sending: boolean = false;
  @State pendingText: string = '';
  @State pendingImage: string = '';
  @State sendFailed: boolean = false;
  @State listening: boolean = false;
  @State voiceMode: boolean = false;
  @State voiceReady: boolean = false;
  @State voicePressing: boolean = false;
  @State voiceTurnStarted: boolean = false;
  @State isVoiceStarting: boolean = false;
  @State isVoiceFinalizing: boolean = false;
  private voiceRequestVersion: number = 0;
  private voiceDraft: string = '';
  private inputController: TextInputController = new TextInputController();
  @State showTools: boolean = false;
  @State summary: PartnerConversation | null = null;
  @State replyTo: string = '';
  @State actionsOpen: boolean = false;
  @State menuMessageId: string = '';
  @State actionMessage: PartnerMessage | null = null;
  @State actionBusy: boolean = false;
  @State actionError: string = '';
  @State forwardContacts: PartnerContact[] = [];
  @State forwardIndex: number = -1;
  private forwardId: string = '';
  @State previewImage: string = '';
  private messageScroller: Scroller = new Scroller();
  private imageSource(value: string): string {
    return (value.startsWith('/9j/') ? 'data:image/jpeg;base64,' : value.startsWith('UklGR') ? 'data:image/webp;base64,' : 'data:image/png;base64,') + value;
  }
  private timeLabel(value: string): string {
    const date: Date = new Date(value);
    const today: Date = new Date();
    const time: string = date.getHours().toString().padStart(2, '0') + ':' + date.getMinutes().toString().padStart(2, '0');
    return date.toDateString() === today.toDateString() ? time : `${date.getMonth() + 1}月${date.getDate()}日 ${time}`;
  }
  private showTime(index: number): boolean {
    return index === 0 || new Date(this.messages[index].createdAt).getTime() - new Date(this.messages[index - 1].createdAt).getTime() > 300000;
  }
  private previousAvoidMode: KeyboardAvoidMode = KeyboardAvoidMode.OFFSET;
  private voice: VoiceInputService = new VoiceInputService();
  private timer: number = -1;
  private cursor: string = '';
  private lastReadCursor: string = '';
  private active: boolean = false;
  private owner: string = '';
  private loading: boolean = false;
  private retryId: string = '';
  private retryText: string = '';
  private retryImage: string = '';
  private retryReply: string = '';

  aboutToAppear(): void {
    this.previousAvoidMode = this.getUIContext().getKeyboardAvoidMode();
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    const params = router.getParams() as Record<string, string>;
    this.partnerId = params['partnerId'] || '';
    this.partnerName = params['partnerName'] || '学习搭子';
    this.owner = appState.currentUser.userId;
    this.active = true;
    void this.load();
    void this.loadSummary();
    this.timer = setInterval(() => { void this.load(); }, 3000);
  }
  onPageHide(): void {
    this.active = false;
    if (this.timer >= 0) clearInterval(this.timer);
    this.timer = -1;
    this.cancelVoiceInput();
    this.menuMessageId = '';
    this.getUIContext().setKeyboardAvoidMode(this.previousAvoidMode);
  }
  onPageShow(): void {
    if (!this.active && this.owner === appState.currentUser.userId) {
      this.active = true; this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE); void this.load(); void this.loadSummary();
      if (this.timer < 0) this.timer = setInterval(() => { void this.load(); }, 3000);
    }
  }
  aboutToDisappear(): void {
    this.getUIContext().setKeyboardAvoidMode(this.previousAvoidMode);
    this.active = false;
    if (this.timer >= 0) clearInterval(this.timer);
    void this.voice.dispose();
  }
  private ownsPage(): boolean { return this.active && this.owner === appState.currentUser.userId; }
  private async load(): Promise<void> {
    if (!this.ownsPage() || this.loading) return;
    this.loading = true;
    const result = await AgentApiClient.partnerMessages(this.partnerId, this.cursor);
    this.loading = false;
    if (!this.ownsPage()) return;
    if (!result.ok) { this.notice = '暂时无法同步消息，请检查网络或搭子关系。'; return; }
    const additions: PartnerMessage[] = result.data.messages.filter((item: PartnerMessage) =>
      !this.messages.some((old: PartnerMessage) => old.messageId === item.messageId));
    const nearBottom: boolean = this.messages.length === 0 || this.messageScroller.isAtEnd();
    const recalled: string[] = result.data.recalledMessageIds ?? [];
    if (recalled.length || additions.length) {
      this.messages = this.messages.map((item: PartnerMessage): PartnerMessage =>
        recalled.includes(item.messageId) && !item.recalled ? {
          messageId: item.messageId, senderId: item.senderId, createdAt: item.createdAt, clientId: item.clientId,
          text: '', image: '', recalled: true
        } : item).concat(additions);
    }
    if (nearBottom && additions.length) setTimeout(() => { if (this.ownsPage()) this.messageScroller.scrollEdge(Edge.Bottom); }, 80);
    this.cursor = result.data.cursor;
    if (this.cursor && this.cursor !== this.lastReadCursor && this.ownsPage()) {
      const marked = await AgentApiClient.markPartnerRead(this.partnerId, { lastReadMessageId: this.cursor });
      if (marked.ok && this.ownsPage()) this.lastReadCursor = marked.data.lastReadMessageId;
    }
    if (result.data.hasMore) void this.load();
  }
  private async pickImage(): Promise<void> {
    try {
      const picker = new photoAccessHelper.PhotoViewPicker();
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      const result = await picker.select(options);
      if (this.ownsPage() && result.photoUris.length > 0) this.imageUri = result.photoUris[0];
    } catch (error) { this.notice = '图片未选择，请重试。'; }
  }
  private async send(): Promise<void> {
    if (this.sending || (!this.draft.trim() && !this.imageUri)) return;
    this.sending = true;
    const text: string = this.draft;
    const uri: string = this.imageUri;
    const reply: string = this.replyTo;
    const image: string = uri ? await ImageEncoder.toBase64(uri) : '';
    if (uri && (!image || image.length > 3000000)) {
      this.notice = '图片读取失败或超过 2MB，请选择较小图片。'; this.sending = false; return;
    }
    if (!this.ownsPage()) { this.sending = false; return; }
    if (!this.retryId || this.retryText !== text || this.retryImage !== image || this.retryReply !== reply) {
      this.retryId = `${Date.now()}-${Math.random()}`; this.retryText = text; this.retryImage = image; this.retryReply = reply;
    }
    this.pendingText = text; this.pendingImage = image; this.sendFailed = false;
    setTimeout(() => { if (this.ownsPage()) this.messageScroller.scrollEdge(Edge.Bottom); }, 80);
    const result = await AgentApiClient.sendPartnerMessage(this.partnerId, { clientId: this.retryId, text: text, image: image, replyTo: reply });
    this.sending = false;
    if (!this.ownsPage()) return;
    if (!result.ok) { this.sendFailed = true; this.notice = (result as ApiFailure).error.message; return; }
    this.pendingText = ''; this.pendingImage = '';
    if (!this.messages.some((item: PartnerMessage) => item.messageId === result.data.message.messageId)) this.messages = this.messages.concat([result.data.message]);
    this.retryId = '';
    if (this.draft === text) this.draft = '';
    if (this.replyTo === reply) this.replyTo = '';
    if (this.imageUri === uri) this.imageUri = '';
    this.notice = '';
    this.showTools = false;
    await this.load();
  }
  private async toggleVoiceMode(): Promise<void> {
    if (this.voiceMode) {
      this.cancelVoiceInput();
      return;
    }
    this.cancelVoiceInput();
    this.voiceMode = true;
    this.voiceReady = false;
    this.inputController.stopEditing();
    this.notice = '正在准备麦克风…';
    const revision: number = this.voiceRequestVersion;
    const owner: string = appState.currentUser.userId;
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const permissions: Permissions[] = ['ohos.permission.MICROPHONE'];
    try {
      const result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, permissions);
      if (!this.isCurrentVoiceRequest(revision, owner) || !this.voiceMode) return;
      if (result.authResults.length === 0 || result.authResults[0] !== 0) {
        this.voiceMode = false;
        this.notice = '麦克风权限未开启，可在系统设置中允许后重试。';
        return;
      }
      this.voiceReady = true;
      this.notice = '按住说话，松开后可修改文字再发送。';
    } catch (error) {
      if (!this.isCurrentVoiceRequest(revision, owner)) return;
      this.voiceMode = false;
      this.notice = '无法申请麦克风权限，请在系统设置中检查权限。';
    }
  }

  private isCurrentVoiceRequest(revision: number, owner: string): boolean {
    return this.ownsPage() && revision === this.voiceRequestVersion && owner === appState.currentUser.userId;
  }

  private async startVoiceInput(): Promise<void> {
    if (!this.ownsPage() || !this.voiceMode || !this.voiceReady || !this.voicePressing ||
      this.sending || this.isVoiceStarting || this.listening || this.isVoiceFinalizing) return;
    const revision: number = ++this.voiceRequestVersion;
    const owner: string = appState.currentUser.userId;
    this.voiceTurnStarted = true;
    this.voiceDraft = this.draft;
    this.isVoiceStarting = true;
    this.notice = '正在打开麦克风，请保持按住…';
    const callbacks: VoiceInputCallbacks = new VoiceInputCallbacks(
      (listening: boolean): void => {
        if (!this.isCurrentVoiceRequest(revision, owner)) return;
        this.listening = listening;
        this.isVoiceStarting = false;
        if (listening) this.notice = '正在聆听，松开后可编辑识别文字。';
      },
      (text: string, isFinal: boolean): void => {
        if (!this.isCurrentVoiceRequest(revision, owner)) return;
        this.draft = this.voiceDraft + text;
        this.notice = this.voicePressing ? '正在识别，松开后可修改。' : '正在整理识别结果，可直接修改文字。';
      },
      (message: string): void => {
        if (!this.isCurrentVoiceRequest(revision, owner)) return;
        this.listening = false;
        this.isVoiceStarting = false;
        this.isVoiceFinalizing = false;
        if (!this.voicePressing) this.voiceMode = false;
        this.notice = message;
      },
      (): void => {
        if (!this.isCurrentVoiceRequest(revision, owner)) return;
        this.listening = false;
        this.isVoiceStarting = false;
        this.isVoiceFinalizing = false;
        if (!this.voicePressing) this.voiceMode = false;
        this.notice = this.draft === this.voiceDraft ? '未识别到语音，请重新按住说话。' : '已转换为文字，可修改后发送。';
      }
    );
    await this.voice.start(callbacks);
  }

  private async endVoiceHold(cancelled: boolean): Promise<void> {
    this.voicePressing = false;
    if (!this.voiceTurnStarted) return;
    this.voiceTurnStarted = false;
    if (cancelled) {
      const draft: string = this.voiceDraft;
      this.cancelVoiceInput();
      this.draft = draft;
      this.notice = '已取消本次语音输入。';
      return;
    }
    this.voiceMode = false;
    if (!this.listening && !this.isVoiceStarting) return;
    this.isVoiceFinalizing = true;
    this.notice = '正在整理识别结果，可直接修改文字。';
    await this.voice.stop(true);
  }

  private cancelVoiceInput(): void {
    this.voiceRequestVersion++;
    this.voiceMode = false;
    this.voiceReady = false;
    this.voicePressing = false;
    this.voiceTurnStarted = false;
    this.isVoiceStarting = false;
    this.isVoiceFinalizing = false;
    this.listening = false;
    void this.voice.stop(false);
  }

  private async loadSummary(): Promise<void> {
    const result = await AgentApiClient.partnerSummary(this.partnerId);
    if (!this.ownsPage()) return;
    if (result.ok) {
      this.summary = result.data.conversation;
      this.partnerName = result.data.conversation.partnerName;
    }
  }

  private quotedLabel(id: string): string {
    const quoted: PartnerMessage | undefined = this.messages.find((item: PartnerMessage) => item.messageId === id);
    if (!quoted || quoted.recalled) return '原消息不可用或已撤回';
    return `${quoted.senderId === this.owner ? '我' : this.partnerName}：${quoted.text || '[图片]'}`;
  }

  private isTaskMessage(item: PartnerMessage): boolean {
    return !!item.sharedTaskId || (item.clientId === item.messageId && item.text.startsWith('协同任务邀请：'));
  }

  private openTasks(taskId: string = ''): void {
    router.pushUrl({ url: 'pages/CollaborativeTasks', params: { partnerId: this.partnerId, partnerName: this.partnerName, taskId: taskId } });
  }

  private openActions(item: PartnerMessage): void {
    if (item.recalled || this.isTaskMessage(item) || this.actionBusy) return;
    this.menuMessageId = item.messageId;
  }

  private async copyMessage(item: PartnerMessage): Promise<void> {
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, item.text));
      if (this.ownsPage()) { this.actionsOpen = false; this.notice = '已复制消息'; }
    } catch (error) {
      if (this.ownsPage()) this.notice = '复制失败，请重试。';
    }
  }

  private async recallMessage(item: PartnerMessage): Promise<void> {
    if (this.actionBusy) return;
    this.actionBusy = true;
    const result = await AgentApiClient.recallPartnerMessage(this.partnerId, item.messageId);
    this.actionBusy = false;
    if (!this.ownsPage()) return;
    if (result.ok) {
      this.messages = this.messages.map((old: PartnerMessage) => old.messageId === item.messageId ? result.data.message : old);
      this.actionsOpen = false;
    } else this.notice = (result as ApiFailure).error.message;
  }

  private async loadForwardContacts(): Promise<void> {
    this.actionsOpen = true;
    this.forwardIndex = -1;
    this.forwardId = '';
    this.actionError = '';
    this.actionBusy = true;
    const result = await AgentApiClient.listPartnerContacts();
    this.actionBusy = false;
    if (!this.ownsPage() || !this.actionsOpen) return;
    if (result.ok) this.forwardContacts = result.data.contacts;
    else { this.forwardContacts = []; this.actionError = (result as ApiFailure).error.message; }
  }

  private async forwardMessage(item: PartnerMessage): Promise<void> {
    const contact: PartnerContact | undefined = this.forwardContacts[this.forwardIndex];
    if (!contact || this.actionBusy) return;
    if (!this.messages.some((row: PartnerMessage) => row.messageId === item.messageId && !row.recalled)) {
      this.actionError = '原消息已撤回。';
      return;
    }
    this.actionBusy = true;
    if (!this.forwardId) this.forwardId = `forward-${Date.now()}-${Math.random()}`;
    const result = await AgentApiClient.sendPartnerMessage(contact.partnerUserId,
      { clientId: this.forwardId, text: item.text, image: item.image, forwarded: true });
    this.actionBusy = false;
    if (!this.ownsPage()) return;
    if (result.ok) { this.actionsOpen = false; this.notice = '已转发'; void this.load(); }
    else this.actionError = (result as ApiFailure).error.message;
  }

  @Builder
  QuickMessageActions(item: PartnerMessage) {
    Row() {
      if (item.text) {
        ChatMessageAction({ icon: $r('sys.symbol.rectangle_on_rectangle'), label: '复制', onAction: () => {
          this.menuMessageId = ''; void this.copyMessage(item);
        } })
      }
      ChatMessageAction({ icon: $r('sys.symbol.quote'), label: '引用', onAction: () => {
        this.menuMessageId = ''; this.replyTo = item.messageId;
      } })
      ChatMessageAction({ icon: $r('sys.symbol.arrowshape_turn_up_right'), label: '转发', onAction: () => {
        this.menuMessageId = ''; this.actionMessage = item; void this.loadForwardContacts();
      } })
      if (item.image) {
        ChatMessageAction({ icon: $r('sys.symbol.picture'), label: '查看', onAction: () => {
          this.menuMessageId = ''; this.previewImage = this.imageSource(item.image);
        } })
      }
      if (item.senderId === this.owner && Date.now() - new Date(item.createdAt).getTime() <= 120000) {
        ChatMessageAction({ icon: $r('sys.symbol.undo'), label: '撤回', color: '#FCA5A5', onAction: () => {
          this.menuMessageId = ''; void this.recallMessage(item);
        } })
      }
    }.padding(4)
  }

  @Builder
  ForwardActions() {
    if (this.actionMessage !== null) {
      Column({ space: 10 }) {
        if (this.forwardContacts.length > 0) {
          Select(this.forwardContacts.map((contact: PartnerContact): SelectOption => ({ value: contact.partnerName })))
            .width('100%').value(this.forwardContacts[this.forwardIndex]?.partnerName || '选择接收的搭子')
            .enabled(!this.actionBusy).onSelect((index: number) => { this.forwardIndex = index; this.forwardId = ''; })
          Button('确认转发').width('100%').height(44).enabled(this.forwardIndex >= 0 && !this.actionBusy)
            .onClick(() => { if (this.actionMessage !== null) void this.forwardMessage(this.actionMessage); })
        } else if (!this.actionBusy && !this.actionError) {
          Text('暂无可转发的学习搭子。').fontColor(UiTheme.secondary)
        }
        if (this.actionBusy) LoadingProgress().width(24).height(24)
        if (this.actionError) Text(this.actionError).fontSize(13).fontColor(UiTheme.danger).width('100%')
      }.width('100%').padding(20)
    }
  }

  build() {
    Stack() {
      Column() {
        PageHeader({ title: this.partnerName, detail: '搭子资料', onTitle: () => router.pushUrl({ url: 'pages/PartnerDetail', params: { partnerId: this.partnerId } }), onDetail: () => router.pushUrl({ url: 'pages/PartnerDetail', params: { partnerId: this.partnerId } }) })
        Row({ space: 12 }) {
          Column({ space: 4 }) {
            Text('安排协同任务').fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiTheme.accent)
            Text('查看双方分工与进度').fontSize(12).fontColor(UiTheme.secondary)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Text('›').fontSize(22).fontColor(UiTheme.accent)
        }.padding(12).margin({ left: 16, right: 16, bottom: 8 }).backgroundColor(UiTheme.tint).borderRadius(8)
          .onClick(() => this.openTasks())
        List({ space: 14, scroller: this.messageScroller }) {
          if (!this.messages.length) {
            ListItem() { Text('和搭子聊聊今天的学习安排吧').fontSize(13).fontColor(UiTheme.muted).width('100%').textAlign(TextAlign.Center).padding(24) }
          }
          ForEach(this.messages, (item: PartnerMessage, index: number) => {
            ListItem() {
              Column({ space: 12 }) {
                if (this.showTime(index)) { Text(this.timeLabel(item.createdAt)).fontSize(11).fontColor(UiTheme.muted).width('100%').textAlign(TextAlign.Center) }
                if (item.recalled) {
                  Text(item.senderId === this.owner ? '你撤回了一条消息' : '搭子撤回了一条消息')
                    .fontSize(12).fontColor(UiTheme.muted).width('100%').textAlign(TextAlign.Center)
                } else {
                Row({ space: 10 }) {
                  if (item.senderId === this.owner) { Blank().width('15%') }
                  else { UserAvatar({ nickname: this.partnerName, source: this.summary?.avatar ?? '', diameter: 36 }) }
                  Row() {
                    Column({ space: 6 }) {
                      if (item.replyTo) {
                        Text(this.quotedLabel(item.replyTo)).fontSize(12).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                          .fontColor(item.senderId === this.owner ? UiTheme.surface : UiTheme.secondary)
                      }
                      if (this.isTaskMessage(item)) {
                        Text('协同任务 · 查看详情 ›').fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiTheme.accent)
                      }
                      if (item.forwarded) {
                        Text('转发消息').fontSize(12).fontColor(item.senderId === this.owner ? UiTheme.surface : UiTheme.secondary)
                      }
                      if (item.text) { Text(item.text).fontSize(15).lineHeight(23)
                        .fontColor(item.senderId === this.owner && !this.isTaskMessage(item) ? UiTheme.surface : UiTheme.ink) }
                      if (item.image) {
                        Image(this.imageSource(item.image)).width(160).height(160).objectFit(ImageFit.Cover).borderRadius(6)
                          .onClick(() => this.previewImage = this.imageSource(item.image))
                      }
                    }.padding(12).borderRadius(8).constraintSize({ maxWidth: 360 })
                      .backgroundColor(item.senderId === this.owner && !this.isTaskMessage(item) ? UiTheme.accent : UiTheme.subtle)
                      .alignItems(HorizontalAlign.Start)
                      .onClick(() => { if (this.isTaskMessage(item)) this.openTasks(item.sharedTaskId ?? ''); })
                      .gesture(LongPressGesture().onAction(() => this.openActions(item)))
                      .bindPopup(this.menuMessageId === item.messageId, {
                        builder: this.QuickMessageActions(item), placement: Placement.Top, enableArrow: true,
                        popupColor: '#353535', backgroundBlurStyle: BlurStyle.NONE, autoCancel: true,
                        onStateChange: (event) => {
                          if (!event.isVisible && this.menuMessageId === item.messageId) this.menuMessageId = '';
                        }
                      })
                  }.layoutWeight(1).justifyContent(item.senderId === this.owner ? FlexAlign.End : FlexAlign.Start)
                  if (item.senderId === this.owner) { UserAvatar({ nickname: appState.authNickname || '我', source: appState.authAvatar, diameter: 36 }) }
                  else { Blank().width('15%') }
                }.width('100%').alignItems(VerticalAlign.Top)
                }
              }.width('100%')
            }
          }, (item: PartnerMessage) => `${item.messageId}-${item.recalled === true}`)
          if (this.pendingText || this.pendingImage) {
            ListItem() {
              Column({ space: 6 }) {
                Row({ space: 10 }) {
                  Blank().width('15%')
                  Column({ space: 6 }) {
                    if (this.pendingText) { Text(this.pendingText).fontSize(15).lineHeight(22).fontColor(UiTheme.surface) }
                    if (this.pendingImage) { Image(this.imageSource(this.pendingImage)).width(140).height(140).objectFit(ImageFit.Cover) }
                  }.padding(12).backgroundColor(UiTheme.accent).borderRadius(8).constraintSize({ maxWidth: 360 })
                  UserAvatar({ nickname: appState.authNickname || '我', source: appState.authAvatar, diameter: 36 })
                }.width('100%').justifyContent(FlexAlign.End).alignItems(VerticalAlign.Top)
                Text(this.sendFailed ? '发送失败 · 点击重试' : '发送中…').fontSize(12).fontColor(this.sendFailed ? UiTheme.danger : UiTheme.muted)
                  .width('100%').textAlign(TextAlign.End).padding({ right: 46 }).onClick(() => { if (this.sendFailed) this.send(); })
              }.width('100%')
            }
          }
        }.layoutWeight(1).width('100%').padding({ left: 16, right: 16, top: 12, bottom: 16 })
        if (this.notice) {
          Row() {
            Text(this.notice).fontSize(12).fontColor(UiTheme.secondary).layoutWeight(1)
            if (this.notice.startsWith('发送失败')) { Text('重试').fontSize(13).fontColor('#B45309').onClick(() => this.send()) }
          }.width('100%').padding(12).backgroundColor('#FFFAEB')
        }
        if (this.replyTo) {
          Row({ space: 12 }) {
            Text(this.quotedLabel(this.replyTo)).fontSize(13).fontColor(UiTheme.secondary).layoutWeight(1).maxLines(2)
            Button('取消引用', { type: ButtonType.Normal }).height(40).fontSize(12)
              .backgroundColor(UiTheme.surface).fontColor(UiTheme.accent).onClick(() => this.replyTo = '')
          }.width('100%').padding({ left: 12, right: 12 }).backgroundColor(UiTheme.subtle)
        }
        if (this.imageUri) {
          Row({ space: 12 }) {
            Image(this.imageUri).width(64).height(64).objectFit(ImageFit.Cover).borderRadius(8)
            Text('待发送图片').fontSize(13).fontColor(UiTheme.secondary).layoutWeight(1)
            Text('移除').fontSize(13).fontColor(UiTheme.secondary).onClick(() => this.imageUri = '')
          }.width('100%').padding(12).backgroundColor(UiTheme.surface)
        }
        if (this.showTools) {
        Scroll() {
          Row({ space: 8 }) {
            Button('选择图片', { type: ButtonType.Normal }).height(44).fontSize(12)
              .fontColor(UiTheme.accent).backgroundColor(UiTheme.tint).onClick(() => { void this.pickImage(); })
            ForEach(['一起专注一会吧', '今天的学习任务完成了吗？', '加油，我们一起攻克这个知识点！'], (text: string) => {
              Text(text).fontSize(12).fontColor(UiTheme.secondary).padding(9).backgroundColor(UiTheme.surface).borderRadius(8)
                .onClick(() => this.draft = this.draft + (this.draft ? '\n' : '') + text)
            }, (text: string) => text)
          }.padding({ left: 12, right: 12, top: 8, bottom: 8 })
        }.width('100%').scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).align(Alignment.TopStart)
        }
        Column() {
          ChatComposer({
            draft: this.draft, toolsLabel: '添加图片或选择快捷消息', busy: this.sending,
            canSend: !this.sending && !this.isVoiceStarting && !this.listening && !this.isVoiceFinalizing &&
              (this.draft.trim().length > 0 || this.imageUri.length > 0),
            voiceMode: this.voiceMode, voiceReady: this.voiceReady, voicePressing: this.voicePressing,
            voiceTurnStarted: this.voiceTurnStarted, startingVoice: this.isVoiceStarting, listening: this.listening,
            inputController: this.inputController,
            onDraftChange: (value: string) => {
              if (this.isVoiceFinalizing && value !== this.draft) this.cancelVoiceInput();
              this.draft = value;
            },
            onVoiceToggle: () => { void this.toggleVoiceMode(); },
            onVoiceDown: () => { this.voicePressing = true; },
            onVoiceStart: () => { void this.startVoiceInput(); },
            onVoiceEnd: (cancelled: boolean) => { void this.endVoiceHold(cancelled); },
            onImage: () => { void this.pickImage(); },
            onTools: () => { this.showTools = !this.showTools; },
            onSend: () => { void this.send(); }
          })
        }.width('100%').padding({ left: 14, right: 14, top: 10, bottom: 14 }).backgroundColor(UiTheme.surface)
      }.width('100%').height('100%').backgroundColor(UiTheme.surface)
      if (this.previewImage) {
        Column() {
          Row() { Blank(); Text('关闭').fontSize(16).fontColor(UiTheme.surface).padding(20).onClick(() => this.previewImage = '') }.width('100%')
          Image(this.previewImage).width('100%').layoutWeight(1).objectFit(ImageFit.Contain)
        }.width('100%').height('100%').backgroundColor('#E6000000')
      }
    }.width('100%').height('100%')
      .bindSheet($$this.actionsOpen, this.ForwardActions(), {
        height: SheetSize.FIT_CONTENT, title: { title: '转发消息' }, showClose: true
      })
  }
}
