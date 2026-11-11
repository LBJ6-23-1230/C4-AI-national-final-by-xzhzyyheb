import { UiTheme } from '../utils/UiTheme';
import { ChatCard, ChatMessage } from '../models/ChatModels';

@Component
export struct ChatBubble {
  @Prop message: ChatMessage;
  @State waitSeconds: number = 0;
  private waitTimer: number = -1;
  private waitStartedAt: number = 0;

  aboutToAppear(): void {
    if (this.message.status !== 'sending') return;
    this.waitStartedAt = Date.now();
    this.waitTimer = setInterval(() => {
      if (this.message.status !== 'sending') {
        clearInterval(this.waitTimer);
        this.waitTimer = -1;
        return;
      }
      this.waitSeconds = Math.floor((Date.now() - this.waitStartedAt) / 1000);
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.waitTimer !== -1) clearInterval(this.waitTimer);
    this.waitTimer = -1;
  }

  private isUser(): boolean {
    return this.message.role === 'user';
  }

  build() {
    Row() {
      if (this.isUser()) {
        Blank()
      }

      Column({ space: 8 }) {
        if (this.message.image !== undefined && this.message.image.length > 0) {
          Image(this.message.image)
            .width(112)
            .height(84)
            .objectFit(ImageFit.Cover)
            .borderRadius(8)
            .backgroundColor(UiTheme.line)
        }

        if (this.message.status === 'sending') {
          if (this.message.text.length > 0) {
            Text(this.message.text).fontSize(15).lineHeight(22).fontColor('#1F2933')
              .padding(12).backgroundColor(UiTheme.surface).borderRadius(8)
          }
          Row({ space: 5 }) {
            LoadingProgress().width(18).height(18).color('#8E99A8')
            Text(`${this.message.progressText || '正在等待回复'} · ${this.waitSeconds}秒`)
              .fontSize(12)
              .fontColor(UiTheme.secondary)
          }
          .padding({ left: 14, right: 14, top: 12, bottom: 12 })
          .backgroundColor(UiTheme.surface)
          .borderRadius(8)
        } else {
          Text(this.message.text)
            .fontSize(15)
            .lineHeight(22)
            .fontColor(this.isUser() ? UiTheme.surface : '#1F2933')
            .padding({ left: 14, right: 14, top: 11, bottom: 11 })
            .backgroundColor(this.isUser() ? UiTheme.accent : UiTheme.surface)
            .borderRadius(8)
        }

        if (this.message.card !== undefined) {
          this.CardView(this.message.card)
        }
      }
      .alignItems(this.isUser() ? HorizontalAlign.End : HorizontalAlign.Start)
      .width('78%')

      if (!this.isUser()) {
        Blank()
      }
    }
    .width('100%')
    .justifyContent(this.isUser() ? FlexAlign.End : FlexAlign.Start)
    .padding({ left: 16, right: 16, top: 5, bottom: 5 })
  }

  @Builder
  private CardView(card: ChatCard) {
    Column({ space: 6 }) {
      Row() {
        Text(this.getCardLabel(card))
          .fontSize(12)
          .fontColor(UiTheme.accent)
          .fontWeight(FontWeight.Medium)
        Blank()
        Text('查看')
          .fontSize(12)
          .fontColor(UiTheme.secondary)
      }
      .width('100%')

      Text(card.title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(UiTheme.ink)
        .maxLines(1)
      Text(card.summary)
        .fontSize(13)
        .fontColor(UiTheme.secondary)
        .lineHeight(18)
        .maxLines(2)
    }
    .width(226)
    .padding(12)
    .backgroundColor(UiTheme.subtle)
    .border({ width: 1, color: UiTheme.line })
    .borderRadius(8)
  }

  private getCardLabel(card: ChatCard): string {
    if (card.type === 'weakness') {
      return '学情画像';
    }
    if (card.type === 'partner') {
      return '学习搭子';
    }
    if (card.type === 'tasks') {
      return '今日任务';
    }
    if (card.type === 'wrong') {
      return '错题诊断';
    }
    return '今日学习建议';
  }
}
