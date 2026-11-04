import router from '@ohos.router';
import { UiTheme } from '../utils/UiTheme';

@Component
export struct AppBottomBar {
  @Prop selected: number = 0;
  onSelect?: (index: number) => void;

  private selectTab(index: number): void {
    if (this.onSelect) { this.onSelect(index); return; }
    if (index === 0) router.replaceUrl({ url: 'pages/ChatMain' });
    else router.replaceUrl({ url: 'pages/Index', params: { initialTab: index } });
  }

  @Builder
  Item(icon: Resource, active: Resource, label: string, index: number) {
    Column({ space: 4 }) {
      Image(this.selected === index ? active : icon).width(22).height(22).objectFit(ImageFit.Contain)
      Text(label).fontSize(11).fontWeight(this.selected === index ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.selected === index ? UiTheme.accent : UiTheme.secondary)
    }.layoutWeight(1).constraintSize({ minHeight: 56 }).justifyContent(FlexAlign.Center)
      .accessibilityText(label).accessibilityLevel('yes')
      .onClick(() => this.selectTab(index))
  }

  build() {
    Row() {
      this.Item($r('app.media.nav_chat'), $r('app.media.nav_chat_selected'), '对话', 0)
      this.Item($r('app.media.nav_agent'), $r('app.media.nav_agent_selected'), '智能体', 1)
      this.Item($r('app.media.nav_study'), $r('app.media.nav_study_selected'), '学习', 2)
      this.Item($r('app.media.nav_profile'), $r('app.media.nav_profile_selected'), '我的', 3)
    }.width('100%').padding({ left: 12, right: 12, top: 4, bottom: 8 })
      .backgroundColor(UiTheme.surface).border({ width: { top: 1 }, color: UiTheme.line })
  }
}
