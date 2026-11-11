export class CourseLabels {
  static valid(value: string): boolean {
    return value.trim().length > 0 && !['待确认科目', '待分类', '其他', '未分类', '待确认'].includes(value.trim());
  }
}
