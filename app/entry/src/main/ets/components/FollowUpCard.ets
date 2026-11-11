import { UiTheme } from '../utils/UiTheme';
import { ActionButton } from './ActionButton';
import router from '@ohos.router';

@Component
export struct FollowUpCard {
  @Prop outlinedActions: boolean = false;
  @Prop title: string = '接下来';
  @Prop reason: string = '';
  @Prop primaryText: string = '';
  @Prop primaryTarget: string = '';
  @Prop secondaryText: string = '';
  @Prop secondaryTarget: string = '';
  @Prop showAgentTraceLink: boolean = false;

  onPrimary?: () => void;
  onSecondary?: () => void;

  private go(target: string): void {
    if (target.length === 0) {
      return;
    }
    router.pushUrl({ url: target });
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text(this.title).fontSize(16).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink)
        Blank()
      }.width('100%')

      if (this.reason.length > 0) {
        Text(this.reason)
          .fontSize(13).fontColor(UiTheme.secondary).lineHeight(20).width('100%')
      }

      if (this.primaryText.length > 0 && this.outlinedActions) {
        ActionButton({ label: this.primaryText, onAction: () => { if (this.onPrimary) this.onPrimary(); else this.go(this.primaryTarget); } })
      } else if (this.primaryText.length > 0) {
        Button(this.primaryText)
          .width('100%').height(48).fontSize(15).fontWeight(FontWeight.Bold)
          .fontColor(UiTheme.surface).backgroundColor(UiTheme.accent).borderRadius(8)
          .onClick(() => {
            if (this.onPrimary !== undefined) {
              this.onPrimary();
            } else {
              this.go(this.primaryTarget);
            }
          })
      }

      if (this.secondaryText.length > 0 && this.outlinedActions) {
        ActionButton({ label: this.secondaryText, onAction: () => { if (this.onSecondary) this.onSecondary(); else this.go(this.secondaryTarget); } })
      } else if (this.secondaryText.length > 0) {
        Button(this.secondaryText)
          .width('100%').height(44).fontSize(14).fontColor(UiTheme.accent)
          .backgroundColor(UiTheme.surface).border({ width: 1, color: '#BFDBFE' }).borderRadius(8)
          .onClick(() => {
            if (this.onSecondary !== undefined) {
              this.onSecondary();
            } else {
              this.go(this.secondaryTarget);
            }
          })
      }

      if (this.showAgentTraceLink) {
        Row({ space: 4 }) {
          Text('想知道它为什么这么安排？').fontSize(12).fontColor(UiTheme.secondary)
          Text('看 Agent 决策过程 →').fontSize(12).fontWeight(FontWeight.Medium).fontColor(UiTheme.accent)
        }
        .width('100%')
        .onClick(() => this.go('pages/AgentTrace'))
      }
    }
    .width('100%').padding(18).backgroundColor(UiTheme.surface).borderRadius(8)
    .border({ width: 1, color: '#BFDBFE' })
  }
}
