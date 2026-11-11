import { UiTheme } from '../utils/UiTheme';
import { AppBottomBar } from '../components/AppBottomBar';
import { ApiFailure } from '../api/ApiResult';
import router from '@ohos.router';
import { PageHeader } from '../components/PageHeader';
import { UserAvatar } from '../components/UserAvatar';
import { AgentApiClient } from '../api/AgentApiClient';
import { PartnerConversation } from '../api/LearningUpgradeModels';
import { appState } from '../data/AppState';

@Entry
@Component
struct PartnerInboxPage {
  @State items: PartnerConversation[] = [];
  @State notice: string = '';
  @State hasMore: boolean = false;
  @State loading: boolean = false;
  @StorageLink('partnerReadRevision') @Watch('onReadConfirmed') readRevision: number = 0;
  private reloadAfterRead: boolean = false;
  private nextPageOffset: number = 0;
  private owner: string = '';
  private active: boolean = false;
  private timer: number = -1;
  aboutToAppear(): void {
    this.owner = appState.currentUser.userId; this.active = true;
    void this.load();
    this.timer = setInterval(() => { void this.load(); }, 5000);
  }
  onPageShow(): void {
    if (this.owner !== appState.currentUser.userId) return;
    this.active = true; void this.load();
    if (this.timer < 0) this.timer = setInterval(() => { void this.load(); }, 5000);
  }
  onPageHide(): void { this.active = false; if (this.timer >= 0) clearInterval(this.timer); this.timer = -1; }
  aboutToDisappear(): void { this.active = false; if (this.timer >= 0) clearInterval(this.timer); }
  private onReadConfirmed(): void {
    if (!this.active) return;
    if (this.loading) this.reloadAfterRead = true;
    else void this.load();
  }
  private async load(more: boolean = false): Promise<void> {
    if (this.loading || !this.active) return;
    this.loading = true;
    this.reloadAfterRead = false;
    try {
      await this.loadConversations(more);
    } finally {
      this.loading = false;
      if (this.reloadAfterRead && this.active) void this.load();
    }
  }
  private async loadConversations(more: boolean): Promise<void> {
    const owner: string = this.owner;
    const gathered: PartnerConversation[] = more ? this.items.slice() : [];
    let offset: number = more ? this.nextPageOffset : 0;
    let hasNext: boolean = true;
    while (hasNext && this.active && owner === appState.currentUser.userId) {
      const result = await AgentApiClient.partnerInbox(offset);
      if (!this.active || owner !== appState.currentUser.userId || this.reloadAfterRead) return;
      if (!result.ok) {
        this.notice = '消息暂未同步：' + (result as ApiFailure).error.message + '点击重试。';
        return;
      }
      result.data.conversations.forEach((item: PartnerConversation) => {
        if (!gathered.some((old: PartnerConversation) => old.partnerUserId === item.partnerUserId)) gathered.push(item);
      });
      if (result.data.hasMore && result.data.nextOffset <= offset) {
        this.notice = '消息列表尚未完整同步，请点击重试。';
        return;
      }
      hasNext = result.data.hasMore;
      offset = result.data.nextOffset;
    }
    if (this.active && owner === appState.currentUser.userId) {
      this.items = gathered; this.nextPageOffset = offset; this.hasMore = false; this.notice = '';
    }
  }
  private time(value: string): string {
    if (!value) return '';
    const date: Date = new Date(value);
    return date.toDateString() === new Date().toDateString() ? `${date.getHours().toString().padStart(2, '0')}:${date.getMinutes().toString().padStart(2, '0')}` : `${date.getMonth() + 1}月${date.getDate()}日`;
  }
  build() {
    Column() {
      PageHeader({ title: '搭子消息收件箱', detail: '去找搭子', onDetail: () => router.pushUrl({ url: 'pages/PartnerMatch' }) })
      List({ space: 1 }) {
        if (this.notice) { ListItem() { Text(this.notice).fontColor('#B45309').padding(20).onClick(() => this.load()) } }
        if (!this.items.length && !this.loading && !this.notice) {
          ListItem() { Column({ space: 12 }) {
            Text('还没有搭子会话，先匹配一位一起学习的伙伴。').fontSize(14).fontColor(UiTheme.secondary)
            Button('去匹配搭子').onClick(() => router.pushUrl({ url: 'pages/PartnerMatch' }))
          }.width('100%').padding(24) }
        }
        ForEach(this.items, (item: PartnerConversation) => {
          ListItem() {
            Row({ space: 12 }) {
              UserAvatar({ nickname: item.partnerName, source: item.avatar, diameter: 44 })
              Column({ space: 7 }) {
                Row() {
                  Text(item.partnerName).fontSize(17).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).layoutWeight(1)
                  Text(this.time(item.lastMessageAt)).fontSize(11).fontColor(UiTheme.muted)
                }.width('100%')
                Text(item.lastMessage || '还没有消息，打个招呼吧').fontSize(14).fontColor(UiTheme.secondary).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                Row() {
                  Text((item.sharedCourses.join('、') || '共同课程待确认') + ` · 已结伴 ${item.pairedDays} 天`).fontSize(11).fontColor(UiTheme.muted).layoutWeight(1).maxLines(1)
                  if (item.unreadCount > 0) {
                    Text(item.unreadCount > 99 ? '99+' : `${item.unreadCount}`).fontSize(11).fontColor(UiTheme.surface).padding({ left: 6, right: 6 }).backgroundColor(UiTheme.accent).borderRadius(9)
                  }
                }.width('100%')
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            }.width('100%').padding(18).backgroundColor(UiTheme.surface)
              .onClick(() => router.pushUrl({ url: 'pages/PartnerChat', params: { partnerId: item.partnerUserId, partnerName: item.partnerName } }))
          }
        }, (item: PartnerConversation) => JSON.stringify(item))
        if (this.loading && !this.items.length) { ListItem() { LoadingProgress().width(28).height(28).margin(20) } }
      }.layoutWeight(1).width('100%').constraintSize({ maxWidth: UiTheme.contentWidth })
      AppBottomBar({ selected: 0 })
    }.width('100%').height('100%').backgroundColor(UiTheme.canvas)
  }
}
