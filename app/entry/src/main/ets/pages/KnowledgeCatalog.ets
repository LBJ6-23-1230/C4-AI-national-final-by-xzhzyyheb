import { KnowledgePointPanel } from '../components/KnowledgePointPanel';
import { PageHeader } from '../components/PageHeader';
import { UiTheme } from '../utils/UiTheme';
import router from '@ohos.router';
@Entry
@Component
struct KnowledgeCatalog {
  @State course: string = '';
  aboutToAppear(): void { const params = router.getParams() as Record<string, string>; this.course = params?.['courseName'] || ''; }
  build() {
    Column() {
      PageHeader({ title: '课程知识点' })
      Scroll() { Column() { KnowledgePointPanel({ initialCourse: this.course }) }.width('100%').padding(20) }.width('100%').layoutWeight(1).align(Alignment.TopStart)
    }.width('100%').height('100%').backgroundColor(UiTheme.surface)
  }
}
