import { CourseSetting } from '../api/LearningUpgradeModels';

export class UpcomingExamService {
  static sorted(courses: CourseSetting[]): CourseSetting[] {
    return courses.filter((item: CourseSetting) => item.reviewDue && item.examDate.length > 0 &&
      typeof item.daysUntilExam === 'number' && Number.isInteger(item.daysUntilExam) && item.daysUntilExam >= 0 && item.daysUntilExam <= 14)
      .sort((a: CourseSetting, b: CourseSetting) => (a.daysUntilExam ?? 0) - (b.daysUntilExam ?? 0) || a.courseName.localeCompare(b.courseName));
  }
  static countdown(item: CourseSetting): string {
    return item.daysUntilExam === 0 ? '今天考试' : `${item.daysUntilExam} 天后考试`;
  }
}
