import router from '@ohos.router';
import { AgentApiClient } from '../api/AgentApiClient';
import { appState } from '../data/AppState';

@Component
export struct PartnerInboxButton {
  @Prop @Watch('load') refreshVersion: number = 0;
  @State unread: number = 0;
  private owner: string = '';
  private active: boolean = false;
  private timer: number = -1;
  aboutToAppear(): void {
    this.active = true;
    void this.load();
    this.timer = setInterval(() => { void this.load(); }, 5000);
  }
  aboutToDisappear(): void { this.active = false; if (this.timer >= 0) clearInterval(this.timer); }
  private async load(): Promise<void> {
    const owner: string = appState.currentUser.userId;
    if (owner !== this.owner) { this.owner = owner; this.unread = 0; }
    if (!owner || owner === 'demo-user') { this.unread = 0; return; }
    const result = await AgentApiClient.partnerInbox();
    if (this.active && owner === appState.currentUser.userId && result.ok) this.unread = result.data.totalUnread;
  }
  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Image($r('app.media.ic_partner_messages')).width(38).height(38).padding(8)
      if (this.unread > 0) {
        Text(this.unread > 99 ? '99+' : this.unread.toString()).fontSize(10).fontColor('#FFFFFF')
          .padding({ left: 4, right: 4 }).height(16).constraintSize({ minWidth: 16 })
          .textAlign(TextAlign.Center).backgroundColor('#D92D20').borderRadius(8)
      }
    }.width(40).height(38).accessibilityText(`搭子消息，${this.unread} 条未读`)
      .onClick(() => router.pushUrl({ url: 'pages/PartnerInbox' }))
  }
}
