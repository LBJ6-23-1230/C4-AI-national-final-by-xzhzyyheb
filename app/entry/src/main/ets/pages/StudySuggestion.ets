import router from '@ohos.router';
@Entry
@Component
struct StudySuggestion {
  aboutToAppear(): void { router.replaceUrl({ url: 'pages/StudyPlan', params: { initialTab: 'today' } }); }
  build() { Column() { Text('正在打开学习计划…').textAlign(TextAlign.Center) }
    .width('100%').height('100%').padding(20).justifyContent(FlexAlign.Center) }
}
