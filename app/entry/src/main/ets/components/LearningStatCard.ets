import router from '@ohos.router';
import { UiTheme } from '../utils/UiTheme';

@Component
export struct LearningStatCard {
  @Prop value: string = '';
  @Prop label: string = '';
  @Prop target: string = '';

  build() {
    Column({ space: 6 }) {
      Text(this.value).fontSize(19).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink)
      Text(this.label).fontSize(11).fontColor(UiTheme.secondary)
        .textAlign(TextAlign.Center).lineHeight(17)
    }.layoutWeight(1).constraintSize({ minHeight: 90 }).padding({ left: 3, right: 3, top: 10, bottom: 10 })
      .onClick(() => {
        if (this.target.length > 0) {
          router.pushUrl({ url: this.target, params: { initialTab: 'ddls', ddlFilter: 'pending' } });
        }
      })
  }
}
