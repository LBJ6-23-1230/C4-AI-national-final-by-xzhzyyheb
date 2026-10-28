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
  private async load(more: boolean = false): Promise<void> {
    if (this.loading || !this.active) return;
    this.loading = true;
    const result = await AgentApiClient.partnerInbox(more ? this.nextPageOffset : 0);
    this.loading = false;
    if (!this.active || this.owner !== appState.currentUser.userId) return;
    if (!result.ok) { this.notice = '消息暂未同步：' + (result as ApiFailure).error.message + ' 点击重试。'; return; }
    this.notice = '';
    this.items = more ? this.items.concat(result.data.conversations.filter((next: PartnerConversation) =>
      !this.items.some((old: PartnerConversation) => old.partnerUserId === next.partnerUserId))) : result.data.conversations;
    this.nextPageOffset = result.data.nextOffset; this.hasMore = result.data.hasMore;
  }
  private time(value: string): string {
    if (!value) return '';
    const date: Date = new Date(value);
    return date.toDateString() === new Date().toDateString() ? `${date.getHours().toString().padStart(2, '0')}:${date.getMinutes().toString().padStart(2, '0')}` : `${date.getMonth() + 1}月${date.getDate()}日`;
  }
  build() {
    Column() {
      PageHeader({ title: '搭子消息' })
      List({ space: 1 }) {
        if (this.notice) { ListItem() { Text(this.notice).fontColor('#B45309').padding(20).onClick(() => this.load()) } }
        if (!this.items.length && !this.loading && !this.notice) {
          ListItem() { Text('还没有搭子会话，结伴后可在这里聊天。').fontSize(14).fontColor('#98A2B3').padding(24) }
        }
        ForEach(this.items, (item: PartnerConversation) => {
          ListItem() {
            Row({ space: 12 }) {
              UserAvatar({ nickname: item.partnerName, source: item.avatar, diameter: 44 })
              Column({ space: 7 }) {
                Row() {
                  Text(item.partnerName).fontSize(17).fontWeight(FontWeight.Medium).fontColor('#182230').layoutWeight(1)
                  Text(this.time(item.lastMessageAt)).fontSize(11).fontColor('#98A2B3')
                }.width('100%')
                Text(item.lastMessage || '还没有消息，打个招呼吧').fontSize(14).fontColor('#667085').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                Row() {
                  Text((item.sharedCourses.join('、') || '共同课程待确认') + ` · 已结伴 ${item.pairedDays} 天`).fontSize(11).fontColor('#98A2B3').layoutWeight(1).maxLines(1)
                  if (item.unreadCount > 0) {
                    Text(item.unreadCount > 99 ? '99+' : `${item.unreadCount}`).fontSize(11).fontColor('#FFFFFF').padding({ left: 6, right: 6 }).backgroundColor('#D92D20').borderRadius(9)
                  }
                }.width('100%')
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            }.width('100%').padding(18).backgroundColor('#FFFFFF')
              .onClick(() => router.pushUrl({ url: 'pages/PartnerChat', params: { partnerId: item.partnerUserId, partnerName: item.partnerName } }))
          }
        }, (item: PartnerConversation) => item.partnerUserId)
        if (this.hasMore) { ListItem() { Text('加载更多会话').fontSize(13).fontColor('#667085').padding(20).onClick(() => this.load(true)) } }
      }.layoutWeight(1).width('100%')
    }.width('100%').height('100%').backgroundColor('#F5F6F8')
  }
}
