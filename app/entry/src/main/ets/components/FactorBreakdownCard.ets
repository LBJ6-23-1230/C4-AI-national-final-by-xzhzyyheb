import { UiTheme } from '../utils/UiTheme';
import { DecisionFactor } from '../api/ApiModels';

@Component
export struct FactorBreakdownCard {
  @Prop factors: DecisionFactor[];
  @Prop reason: string;
  @State expanded: boolean = false;

  private factorName(name: string): string {
    if (name === '1-Mastery' || name === 'mastery') return '1 − 掌握度';
    if (name === 'ErrorIntensity' || name === 'errorIntensity') return '错误强度';
    if (name === 'Importance' || name === 'importance') return '课程重要性';
    if (name === 'Urgency' || name === 'urgency') return '时间紧迫度';
    if (name === 'PrerequisiteImpact' || name === 'prerequisiteImpact') return '先修影响';
    return name;
  }

  private totalContribution(): number {
    let total: number = 0;
    for (let index: number = 0; index < this.factors.length; index++) {
      total += this.factors[index].contribution;
    }
    return total;
  }

  build() {
    Column({ space: 10 }) {
      Row() {
        Text('为什么是它').fontSize(15).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink)
        Blank()
        Text(this.expanded ? '收起 ↑' : '展开 ↓').fontSize(12).fontWeight(FontWeight.Medium).fontColor(UiTheme.accent)
      }.width('100%').onClick(() => this.expanded = !this.expanded)

      if (!this.expanded) {
        Text(this.reason.length > 0 ? this.reason : '展开查看它为什么这样安排。')
          .fontSize(13).fontColor(UiTheme.secondary).lineHeight(20).width('100%')
      }

      if (this.expanded) {
        ForEach(this.factors, (factor: DecisionFactor) => {
          Row() {
            Text(this.factorName(factor.name)).fontSize(13).fontColor(UiTheme.secondary).layoutWeight(1)
            Text(`${factor.value.toFixed(2)} × ${factor.weight.toFixed(2)} = ${factor.contribution.toFixed(3)}`)
              .fontSize(12).fontColor(UiTheme.accent)
          }.width('100%')
        }, (factor: DecisionFactor) => factor.name)
        Row() {
          Text('综合优先级').fontSize(13).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink)
          Blank()
          Text(this.totalContribution().toFixed(2)).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#0F766E')
        }.width('100%').padding({ top: 8 }).border({ width: { top: 1 }, color: UiTheme.line })
        if (this.reason.length > 0) {
          Text(`结论：${this.reason}`).fontSize(13).fontColor(UiTheme.secondary).lineHeight(20).width('100%')
        }
      }
    }.width('100%').padding(16).backgroundColor(UiTheme.surface).borderRadius(8)
      .border({ width: 1, color: UiTheme.line })
  }
}
