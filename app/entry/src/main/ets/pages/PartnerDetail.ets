import router from '@ohos.router';
import { PageHeader } from '../components/PageHeader';
import { UserAvatar } from '../components/UserAvatar';
import { AgentApiClient } from '../api/AgentApiClient';
import { PartnerConversation } from '../api/LearningUpgradeModels';
import { appState } from '../data/AppState';

@Entry
@Component
struct PartnerDetail {
  @State item: PartnerConversation | null = null;
  @State notice: string = '';
  private active: boolean = false;
  aboutToAppear(): void { this.active = true; void this.load(); }
  aboutToDisappear(): void { this.active = false; }
  private async load(): Promise<void> {
    const owner: string = appState.currentUser.userId;
    const params = router.getParams() as Record<string, string>;
    const result = await AgentApiClient.partnerSummary(params['partnerId'] || '');
    if (!this.active || owner !== appState.currentUser.userId) return;
    if (result.ok) this.item = result.data.conversation;
    else this.notice = '搭子资料读取失败，请稍后重试。';
  }
  build() {
    Column() {
      PageHeader({ title: '搭子资料' })
      Scroll() {
        Column({ space: 20 }) {
          if (this.item !== null) {
            UserAvatar({ nickname: this.item.partnerName, source: this.item.avatar, diameter: 64 })
            Text(this.item.partnerName).fontSize(22).fontWeight(FontWeight.Medium)
            Text(`已结伴 ${this.item.pairedDays} 天`).fontSize(15).fontColor('#667085')
            Text('结伴日期：' + (this.item.pairedAt ? new Date(this.item.pairedAt).toLocaleDateString() : '暂无记录')).fontSize(13).fontColor('#98A2B3')
            Text('共同学习课程').fontSize(17).fontWeight(FontWeight.Medium)
            Text(this.item.sharedCourses.join('、') || '待双方确认').fontSize(15).fontColor('#475467')
            Text('共同关注的知识点').fontSize(17).fontWeight(FontWeight.Medium)
            Text(this.item.sharedKnowledgePoints.join('、') || '暂无共同知识点记录').fontSize(15).fontColor('#475467')
            Text(this.item.sharedStudyMinutes === null ? '暂无已确认的共同学习时长' : `共同学习 ${this.item.sharedStudyMinutes} 分钟`).fontSize(13).fontColor('#98A2B3')
          }
          if (this.notice) { Text(this.notice).fontColor('#667085') }
        }.width('100%').padding(24).alignItems(HorizontalAlign.Start)
      }.align(Alignment.TopStart).layoutWeight(1).width('100%')
    }.width('100%').height('100%').backgroundColor('#F5F6F8')
  }
}
