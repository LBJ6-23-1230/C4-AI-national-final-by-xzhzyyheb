import { PlanTask } from '../api/ApiModels';
import { HomeworkDDL, LearningPlanTask } from '../models/AgentModels';

/** Keep course and collaborative entry points inside their requested domain. */
export class PlanScope {
  static courseTasks(tasks: PlanTask[], course: string, assignments: HomeworkDDL[]): PlanTask[] {
    const name: string = course.trim();
    if (!name) return [];
    return tasks.filter((task: PlanTask) => {
      if (task.sourceCourse?.trim()) return task.sourceCourse.trim() === name;
      const assignment: HomeworkDDL | undefined = assignments.find((ddl: HomeworkDDL) => ddl.id === task.taskId);
      return assignment !== undefined && assignment.courseName.trim() === name;
    });
  }

  static collaborativeTasks(tasks: LearningPlanTask[]): LearningPlanTask[] {
    return tasks.filter((task: LearningPlanTask) => task.source === 'partner_match');
  }
}
