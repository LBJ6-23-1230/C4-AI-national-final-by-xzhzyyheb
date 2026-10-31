import router from '@ohos.router';
import { ReminderEvent } from '../api/ReminderModels';

export class ReminderNavigation {
  static open(item: ReminderEvent): void {
    const ddl: boolean = item.kind === 'task' && item.sourceType === 'ddl';
    router.pushUrl({ url: ddl ? 'pages/CourseImport' : item.targetPage === 'pages/FocusSetup' ? 'pages/StudyPlan' : item.targetPage,
      params: { initialTab: ddl ? 'ddls' : 'today', ddlFilter: 'pending', focusDdlId: ddl ? item.sourceId ?? item.objectId : '',
        courseName: item.courseName, knowledgePointId: item.knowledgePointId, eventId: item.eventId } });
  }
}
