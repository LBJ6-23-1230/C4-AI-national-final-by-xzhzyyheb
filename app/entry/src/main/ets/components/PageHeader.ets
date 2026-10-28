import router from '@ohos.router';

@Component
export struct PageHeader {
  @Prop title: string = '';
  @Prop detail: string = '';
  onBack?: () => void;
  onTitle?: () => void;
  build() {
    Row({ space: 8 }) {
      Text('‹').fontSize(30).fontColor('#344054').width(38).height(44)
        .textAlign(TextAlign.Center).onClick(() => { if (this.onBack) this.onBack(); else router.back(); })
      Text(this.title).fontSize(18).fontWeight(FontWeight.Medium).fontColor('#182230').layoutWeight(1).onClick(() => { if (this.onTitle) this.onTitle(); })
      if (this.detail) { Text(this.detail).fontSize(12).fontColor('#667085') }
    }.width('100%').height(58).padding({ left: 8, right: 20 }).backgroundColor('#FFFFFF')
  }
}
