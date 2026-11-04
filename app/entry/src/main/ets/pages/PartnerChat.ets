import { UiTheme } from '../utils/UiTheme';
import { KeyboardAvoidMode } from '@ohos.arkui.UIContext';
import { PageHeader } from '../components/PageHeader';
import { UserAvatar } from '../components/UserAvatar';
import router from '@ohos.router';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
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
  @State showTools: boolean = false;
  @State showLearningInfo: boolean = false;
  @State summary: PartnerConversation | null = null;
  @State infoNotice: string = '';
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
    void this.voice.stop(false);
    this.getUIContext().setKeyboardAvoidMode(this.previousAvoidMode);
  }
  onPageShow(): void {
    if (!this.active && this.owner === appState.currentUser.userId) {
      this.active = true; this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE); void this.load();
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
    this.messages = this.messages.concat(additions);
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
    const image: string = uri ? await ImageEncoder.toBase64(uri) : '';
    if (uri && (!image || image.length > 3000000)) {
      this.notice = '图片读取失败或超过 2MB，请选择较小图片。'; this.sending = false; return;
    }
    if (!this.retryId || this.retryText !== text || this.retryImage !== image) {
      this.retryId = `${Date.now()}-${Math.random()}`; this.retryText = text; this.retryImage = image;
    }
    this.pendingText = text; this.pendingImage = image; this.sendFailed = false;
    setTimeout(() => { if (this.ownsPage()) this.messageScroller.scrollEdge(Edge.Bottom); }, 80);
    const result = await AgentApiClient.sendPartnerMessage(this.partnerId, { clientId: this.retryId, text: text, image: image });
    if (!this.ownsPage()) return;
    this.sending = false;
    if (!result.ok) { this.sendFailed = true; this.notice = ''; return; }
    this.pendingText = ''; this.pendingImage = '';
    if (!this.messages.some((item: PartnerMessage) => item.messageId === result.data.message.messageId)) this.messages = this.messages.concat([result.data.message]);
    this.retryId = '';
    if (this.draft === text) this.draft = '';
    if (this.imageUri === uri) this.imageUri = '';
    this.notice = '';
    this.showTools = false;
    await this.load();
  }
  private async toggleVoice(): Promise<void> {
    if (this.listening) { await this.voice.stop(true); return; }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const permissions: Permissions[] = ['ohos.permission.MICROPHONE'];
      const result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, permissions);
      if (!this.ownsPage()) return;
      if (!result.authResults.length || result.authResults[0] !== 0) { this.notice = '麦克风未授权，可继续文字输入。'; return; }
      const prefix: string = this.draft;
      await this.voice.start(new VoiceInputCallbacks(
        (state: boolean) => { if (this.ownsPage()) this.listening = state; },
        (text: string, final: boolean) => { if (this.ownsPage()) { this.draft = prefix + text; this.notice = final ? '已转为文字，请确认后发送。' : '正在识别…'; } },
        (message: string) => { if (this.ownsPage()) { this.notice = message; this.listening = false; } }
      ));
    } catch (error) { this.notice = '语音输入不可用，可继续文字输入。'; }
  }
  private async loadSummary(): Promise<void> {
    const result = await AgentApiClient.partnerSummary(this.partnerId);
    if (!this.ownsPage()) return;
    if (result.ok) { this.summary = result.data.conversation; this.infoNotice = ''; }
    else this.infoNotice = '学习信息暂未同步，点击重试';
  }
  @Builder
  LearningInformation() {
    Column({ space: 10 }) {
      Row() {
        Text('学习信息').fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).layoutWeight(1)
        Text(this.showLearningInfo ? '⌃' : '›').fontSize(20).fontColor(UiTheme.secondary)
      }.width('100%').constraintSize({ minHeight: 36 }).onClick(() => { this.showLearningInfo = !this.showLearningInfo; if (this.showLearningInfo && this.summary === null) void this.loadSummary(); })
      if (this.showLearningInfo) {
        if (this.infoNotice) { Text(this.infoNotice).fontSize(12).fontColor(UiTheme.secondary).onClick(() => this.loadSummary()) }
        if (this.summary !== null) {
          Text(`结伴时长　${this.summary.pairedDays}天`).fontSize(13).fontColor(UiTheme.secondary).width('100%')
          Text(`结伴日期　${this.summary.pairedAt.substring(0, 10) || '暂无记录'}`).fontSize(13).fontColor(UiTheme.secondary).width('100%')
          Text(`共同学习课程　${this.summary.sharedCourses.join(' / ') || '待确认'}`).fontSize(13).fontColor(UiTheme.secondary).width('100%')
          Text(`共同关注知识点　${this.summary.sharedKnowledgePoints.join(' / ') || '暂无记录'}`).fontSize(13).fontColor(UiTheme.secondary).width('100%')
          Text(`共同学习时长　${this.summary.sharedStudyMinutes === null ? '暂无已确认记录' : this.summary.sharedStudyMinutes + '分钟'}`)
            .fontSize(13).fontColor(UiTheme.secondary).width('100%')
        } else if (!this.infoNotice) { LoadingProgress().width(20).height(20) }
      }
    }.width('100%').padding({ left: 12, right: 12, bottom: this.showLearningInfo ? 12 : 0 }).backgroundColor(UiTheme.subtle).borderRadius(8)
  }
  build() {
    Stack() {
      Column() {
        PageHeader({ title: this.partnerName, detail: '资料', onTitle: () => router.pushUrl({ url: 'pages/PartnerDetail', params: { partnerId: this.partnerId } }), onDetail: () => router.pushUrl({ url: 'pages/PartnerDetail', params: { partnerId: this.partnerId } }) })
        Button('安排协同任务', { type: ButtonType.Normal }).width('100%').height(44).fontSize(14).fontColor(UiTheme.accent).backgroundColor(UiTheme.tint)
          .onClick(() => router.pushUrl({ url: 'pages/CollaborativeTasks', params: { partnerId: this.partnerId, partnerName: this.partnerName } }))
        Column() { this.LearningInformation() }.width('100%').padding({ left: 16, right: 16, bottom: 8 })
        List({ space: 14, scroller: this.messageScroller }) {
          if (!this.messages.length) {
            ListItem() { Text('和搭子聊聊今天的学习安排吧').fontSize(13).fontColor(UiTheme.muted).width('100%').textAlign(TextAlign.Center).padding(24) }
          }
          ForEach(this.messages, (item: PartnerMessage, index: number) => {
            ListItem() {
              Column({ space: 12 }) {
                if (this.showTime(index)) { Text(this.timeLabel(item.createdAt)).fontSize(11).fontColor(UiTheme.muted).width('100%').textAlign(TextAlign.Center) }
                Row({ space: 10 }) {
                  if (item.senderId === this.owner) { Blank().width('15%') }
                  else { UserAvatar({ nickname: this.partnerName, diameter: 36 }) }
                  Row() {
                    Column({ space: 6 }) {
                      if (item.text) { Text(item.text).fontSize(15).lineHeight(23).fontColor(item.senderId === this.owner ? UiTheme.surface : UiTheme.ink) }
                      if (item.image) {
                        Image(this.imageSource(item.image)).width(160).height(160).objectFit(ImageFit.Cover).borderRadius(6)
                          .onClick(() => this.previewImage = this.imageSource(item.image))
                      }
                    }.padding(12).borderRadius(8).constraintSize({ maxWidth: 360 })
                      .backgroundColor(item.senderId === this.owner ? UiTheme.accent : UiTheme.subtle).alignItems(HorizontalAlign.Start)
                  }.layoutWeight(1).justifyContent(item.senderId === this.owner ? FlexAlign.End : FlexAlign.Start)
                  if (item.senderId === this.owner) { UserAvatar({ nickname: '我', diameter: 36 }) }
                  else { Blank().width('15%') }
                }.width('100%').alignItems(VerticalAlign.Top)
              }.width('100%')
            }
          }, (item: PartnerMessage) => item.messageId)
          if (this.pendingText || this.pendingImage) {
            ListItem() {
              Column({ space: 6 }) {
                Row({ space: 10 }) {
                  Blank().width('15%')
                  Column({ space: 6 }) {
                    if (this.pendingText) { Text(this.pendingText).fontSize(16).fontColor(UiTheme.ink) }
                    if (this.pendingImage) { Image(this.imageSource(this.pendingImage)).width(140).height(140).objectFit(ImageFit.Cover) }
                  }.padding(12).backgroundColor(UiTheme.tint).borderRadius(8).constraintSize({ maxWidth: 360 })
                  UserAvatar({ nickname: '我', diameter: 36 })
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
            ForEach(['一起专注一会吧', '今天的学习任务完成了吗？', '加油，我们一起攻克这个知识点！'], (text: string) => {
              Text(text).fontSize(12).fontColor(UiTheme.secondary).padding(9).backgroundColor(UiTheme.surface).borderRadius(8)
                .onClick(() => this.draft = this.draft + (this.draft ? '\n' : '') + text)
            }, (text: string) => text)
          }.padding({ left: 12, right: 12, top: 8, bottom: 8 })
        }.width('100%').scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).align(Alignment.TopStart)
        }
        Row({ space: 8 }) {
          Button('+', { type: ButtonType.Normal }).width(44).height(44).fontSize(24).fontColor(UiTheme.secondary).backgroundColor(UiTheme.surface).onClick(() => this.showTools = !this.showTools)
          Image($r('app.media.ic_chat_mic')).width(44).height(44).padding(10).opacity(this.listening ? 0.45 : 1)
            .accessibilityText(this.listening ? '停止语音输入' : '语音输入').onClick(() => this.toggleVoice())
          Image($r('app.media.ic_chat_photo')).width(44).height(44).padding(10).accessibilityText('选择图片').onClick(() => this.pickImage())
          TextInput({ text: this.draft, placeholder: this.listening ? '正在听，请说话…' : '发送消息' })
            .layoutWeight(1).height(42).backgroundColor(UiTheme.surface).borderRadius(8).maxLength(3000).onChange((value: string) => this.draft = value)
          if (this.draft.trim() || this.imageUri) {
            Button(this.sending ? '发送中' : '发送', { type: ButtonType.Normal }).height(38).borderRadius(8)
              .backgroundColor(UiTheme.accent).fontColor(UiTheme.surface).fontSize(14).enabled(!this.sending).onClick(() => this.send())
          }
        }.width('100%').padding({ left: 8, right: 8, top: 8, bottom: 10 }).backgroundColor(UiTheme.surface)
      }.width('100%').height('100%').backgroundColor(UiTheme.surface)
      if (this.previewImage) {
        Column() {
          Row() { Blank(); Text('关闭').fontSize(16).fontColor(UiTheme.surface).padding(20).onClick(() => this.previewImage = '') }.width('100%')
          Image(this.previewImage).width('100%').layoutWeight(1).objectFit(ImageFit.Contain)
        }.width('100%').height('100%').backgroundColor('#E6000000')
      }
    }.width('100%').height('100%')
  }
}
