import { util } from '@kit.ArkTS';
import {
  CourseInfo,
  HomeworkDDL
} from '../models/AgentModels';

interface RawCourseRow {
  courseName: string;
  examDate: string;
  priority: string;
  studyHours: number;
  status: string;
}

interface RawDDLRow {
  courseName: string;
  title: string;
  dueDate: string;
  priority: string;
  estimatedMinutes: number;
}

interface ImportDataContainer {
  courses: RawCourseRow[];
  ddls: RawDDLRow[];
  courseList: RawCourseRow[];
  ddlList: RawDDLRow[];
  homework: RawDDLRow[];
}

interface CSVFieldMap {
  courseName: number;
  examDate: number;
  priority: number;
  studyHours: number;
  status: number;
  title: number;
  dueDate: number;
  estimatedMinutes: number;
}

const COURSE_NAME_ALIASES: string[] = [
  'coursename', 'course', 'name', '课程名称', '课程名', '课程', '科目', '名称', '学科'
];
const EXAM_DATE_ALIASES: string[] = [
  'examdate', 'exam', 'date', '考试日期', '考试时间', '考试', '日期'
];
const PRIORITY_ALIASES: string[] = [
  'priority', '优先级', '重要程度', '重要度', '紧急程度'
];
const STUDY_HOURS_ALIASES: string[] = [
  'studyhours', 'hours', '学习时长', '每周学时', '学时', '时长', '学习时间', '复习时长'
];
const STATUS_ALIASES: string[] = [
  'status', '复习状态', '状态', '进度', '复习进度'
];
const TITLE_ALIASES: string[] = [
  'title', 'name', 'homework', '作业标题', '标题', '作业名称', '作业', '任务', '任务名称', '内容'
];
const DUE_DATE_ALIASES: string[] = [
  'duedate', 'due', 'deadline', 'ddl', '截止日期', '截止时间', '截止', '到期', '到期日'
];
const ESTIMATED_MINUTES_ALIASES: string[] = [
  'estimatedminutes', 'minutes', '预计时长', '预计时间', '预计用时', '预计分钟', '预计', '分钟'
];

function headerMatches(aliases: string[], cell: string): boolean {
  return aliases.indexOf(cell.trim().toLowerCase()) >= 0;
}

const JSON_COURSE_NAME_KEYS: string[] = [
  'courseName', 'coursename', 'course_name', 'course', 'name', '课程名称', '课程名', '科目', '名称'
];
const JSON_EXAM_DATE_KEYS: string[] = [
  'examDate', 'examdate', 'exam_date', 'exam', 'examTime', 'date', '考试日期', '考试时间', '日期'
];
const JSON_PRIORITY_KEYS: string[] = ['priority', 'level', '优先级', '重要程度'];
const JSON_STUDY_HOURS_KEYS: string[] = [
  'studyHours', 'studyhours', 'study_hours', 'hours', 'weeklyHours', '学习时长', '每周学时', '学时'
];
const JSON_STATUS_KEYS: string[] = ['status', 'reviewStatus', '复习状态', '状态'];
const JSON_TITLE_KEYS: string[] = [
  'title', 'homework', 'homeworkTitle', 'task', 'name', '作业标题', '标题', '作业名称', '任务', '内容'
];
const JSON_DUE_DATE_KEYS: string[] = [
  'dueDate', 'duedate', 'due_date', 'due', 'deadline', 'ddl', '截止日期', '截止时间', '到期'
];
const JSON_EST_MINUTES_KEYS: string[] = [
  'estimatedMinutes', 'estimatedminutes', 'estimated_minutes', 'minutes', 'duration',
  '预计时长', '预计时间', '预计分钟', '分钟'
];

interface CourseTemplateContainer {
  courses: RawCourseRow[];
}

interface DDLTemplateContainer {
  ddls: RawDDLRow[];
}

export class FileParserService {


  static parseCoursesFromJSON(jsonText: string): CourseInfo[] {
    const parsed: Object = JSON.parse(jsonText);
    const courses: CourseInfo[] = [];

    const rawList: Object[] | null = FileParserService.jsonArrayOf(parsed, ['courses', 'courseList']);
    if (rawList === null) {
      throw new Error('未找到有效的课程数组，请检查 JSON 格式');
    }

    for (let i: number = 0; i < rawList.length; i++) {
      const row: Record<string, Object> = rawList[i] as Record<string, Object>;
      const courseName: string = FileParserService.pickString(row, JSON_COURSE_NAME_KEYS);
      if (courseName.length === 0) {
        continue;
      }

      const examDate: string = FileParserService.resolveDate(
        FileParserService.pickString(row, JSON_EXAM_DATE_KEYS), `${i + 1}`, '考试日期');
      const daysLeft: number = FileParserService.calcDaysLeft(examDate);
      const rawPriority: string = FileParserService.pickString(row, JSON_PRIORITY_KEYS);
      const studyHours: number = Number(FileParserService.pickString(row, JSON_STUDY_HOURS_KEYS)) || 0;
      const rawStatus: string = FileParserService.pickString(row, JSON_STATUS_KEYS);

      const course: CourseInfo = {
        courseId: `imported-${Date.now()}-${i}`,
        courseName: courseName,
        exam: {
          date: examDate,
          daysLeft: daysLeft
        },
        priority: rawPriority.length > 0 ? rawPriority : FileParserService.guessPriority(daysLeft),
        recentStatus: {
          studyHours: studyHours,
          status: rawStatus.length > 0 ? rawStatus : FileParserService.guessStatus(studyHours)
        }
      };
      courses.push(course);
    }

    return courses;
  }

  static parseDDLsFromJSON(jsonText: string): HomeworkDDL[] {
    const parsed: Object = JSON.parse(jsonText);
    const ddls: HomeworkDDL[] = [];

    const rawList: Object[] | null =
      FileParserService.jsonArrayOf(parsed, ['ddls', 'ddlList', 'homework']);
    if (rawList === null) {
      throw new Error('未找到有效的 DDL 数组，请检查 JSON 格式');
    }

    for (let i: number = 0; i < rawList.length; i++) {
      const row: Record<string, Object> = rawList[i] as Record<string, Object>;
      const title: string = FileParserService.pickString(row, JSON_TITLE_KEYS);
      const rawCourse: string = FileParserService.pickString(row, JSON_COURSE_NAME_KEYS);
      if (title.length === 0 && rawCourse.length === 0) {
        continue;
      }

      const dueDate: string = FileParserService.resolveDate(
        FileParserService.pickString(row, JSON_DUE_DATE_KEYS), `${i + 1}`, '截止日期');
      const daysLeft: number = FileParserService.calcDaysLeft(dueDate);
      const rawPriority: string = FileParserService.pickString(row, JSON_PRIORITY_KEYS);

      const ddl: HomeworkDDL = {
        id: `ddl-imported-${Date.now()}-${i}`,
        courseName: rawCourse.length > 0 ? rawCourse : '未分类',
        title: title.length > 0 ? title : '未命名任务',
        dueDate: dueDate,
        daysLeft: daysLeft,
        priority: rawPriority.length > 0 ? rawPriority : FileParserService.guessPriority(daysLeft),
        estimatedMinutes: Number(FileParserService.pickString(row, JSON_EST_MINUTES_KEYS)) || 30
      };
      ddls.push(ddl);
    }

    return ddls;
  }


  static parseCoursesFromCSV(csvText: string): CourseInfo[] {
    const lines: string[] = csvText.replace(/\r/g, '').split('\n');
    const headerIndex: number = FileParserService.firstDataLine(lines);
    if (headerIndex === -1) {
      throw new Error('CSV 内容为空');
    }

    const delimiter: string = FileParserService.detectDelimiter(lines[headerIndex]);
    const header: string[] = FileParserService.splitRow(lines[headerIndex], delimiter);
    const idxMap: CSVFieldMap = {
      courseName: -1, examDate: -1, priority: -1, studyHours: -1, status: -1,
      title: -1, dueDate: -1, estimatedMinutes: -1
    };

    for (let i: number = 0; i < header.length; i++) {
      const cell: string = header[i];
      if (idxMap.courseName === -1 && headerMatches(COURSE_NAME_ALIASES, cell)) idxMap.courseName = i;
      if (idxMap.examDate === -1 && headerMatches(EXAM_DATE_ALIASES, cell)) idxMap.examDate = i;
      if (idxMap.priority === -1 && headerMatches(PRIORITY_ALIASES, cell)) idxMap.priority = i;
      if (idxMap.studyHours === -1 && headerMatches(STUDY_HOURS_ALIASES, cell)) idxMap.studyHours = i;
      if (idxMap.status === -1 && headerMatches(STATUS_ALIASES, cell)) idxMap.status = i;
    }

    let startRow: number = headerIndex + 1;
    if (idxMap.courseName === -1) {
      if (!FileParserService.looksLikeDataRow(header)) {
        throw new Error('CSV 表头缺少课程名称列。可识别的列名：课程名称 / 课程名 / 科目 / 名称 / courseName。'
          + '若文件本来就没有表头，请保证第 1 列是课程名、第 2 列是日期。');
      }
      idxMap.courseName = 0;
      idxMap.examDate = header.length > 1 ? 1 : -1;
      idxMap.priority = header.length > 2 ? 2 : -1;
      idxMap.studyHours = header.length > 3 ? 3 : -1;
      idxMap.status = header.length > 4 ? 4 : -1;
      startRow = headerIndex;
    }

    const courses: CourseInfo[] = [];
    for (let i: number = startRow; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.length === 0) continue;

      const cols: string[] = FileParserService.splitRow(line, delimiter);
      const courseName: string = (cols[idxMap.courseName] ?? '').trim();
      if (courseName.length === 0) continue;

      const rowLabel: string = `${i + 1}`;
      const rawDate: string = idxMap.examDate !== -1 ? (cols[idxMap.examDate] ?? '') : '';
      const examDate: string = FileParserService.resolveDate(rawDate, rowLabel, '考试日期');
      const daysLeft: number = FileParserService.calcDaysLeft(examDate);
      const priority: string = idxMap.priority !== -1 && (cols[idxMap.priority] ?? '').trim().length > 0
        ? (cols[idxMap.priority] ?? '').trim() : FileParserService.guessPriority(daysLeft);
      const studyHours: number = idxMap.studyHours !== -1 ? (Number(cols[idxMap.studyHours]) || 0) : 0;
      const status: string = idxMap.status !== -1 && (cols[idxMap.status] ?? '').trim().length > 0
        ? (cols[idxMap.status] ?? '').trim() : FileParserService.guessStatus(studyHours);

      const course: CourseInfo = {
        courseId: `csv-import-${Date.now()}-${i}`,
        courseName: courseName,
        exam: { date: examDate, daysLeft: daysLeft },
        priority: priority,
        recentStatus: { studyHours: studyHours, status: status }
      };
      courses.push(course);
    }

    if (courses.length === 0) {
      throw new Error('CSV 中未解析到任何有效课程数据');
    }

    return courses;
  }

  static parseDDLsFromCSV(csvText: string): HomeworkDDL[] {
    const lines: string[] = csvText.replace(/\r/g, '').split('\n');
    const headerIndex: number = FileParserService.firstDataLine(lines);
    if (headerIndex === -1) {
      throw new Error('CSV 内容为空');
    }

    const delimiter: string = FileParserService.detectDelimiter(lines[headerIndex]);
    const header: string[] = FileParserService.splitRow(lines[headerIndex], delimiter);
    const idxMap: CSVFieldMap = {
      courseName: -1, examDate: -1, priority: -1, studyHours: -1, status: -1,
      title: -1, dueDate: -1, estimatedMinutes: -1
    };

    for (let i: number = 0; i < header.length; i++) {
      const cell: string = header[i];
      if (idxMap.courseName === -1 && headerMatches(COURSE_NAME_ALIASES, cell)) idxMap.courseName = i;
      if (idxMap.title === -1 && headerMatches(TITLE_ALIASES, cell)) idxMap.title = i;
      if (idxMap.dueDate === -1 && headerMatches(DUE_DATE_ALIASES, cell)) idxMap.dueDate = i;
      if (idxMap.priority === -1 && headerMatches(PRIORITY_ALIASES, cell)) idxMap.priority = i;
      if (idxMap.estimatedMinutes === -1 && headerMatches(ESTIMATED_MINUTES_ALIASES, cell)) {
        idxMap.estimatedMinutes = i;
      }
    }

    let startRow: number = headerIndex + 1;
    if (idxMap.title === -1 && idxMap.dueDate === -1) {
      if (!FileParserService.looksLikeDataRow(header)) {
        throw new Error('CSV 表头缺少作业标题列或截止日期列。'
          + '可识别的列名：作业标题 / 标题 / 任务 / title，截止日期 / 截止时间 / DDL / Deadline。'
          + '若文件本来就没有表头，请保证第 1 列是课程名、第 2 列是作业标题、第 3 列是截止日期。');
      }
      idxMap.courseName = 0;
      idxMap.title = header.length > 1 ? 1 : -1;
      idxMap.dueDate = header.length > 2 ? 2 : -1;
      idxMap.priority = header.length > 3 ? 3 : -1;
      idxMap.estimatedMinutes = header.length > 4 ? 4 : -1;
      startRow = headerIndex;
    }

    const ddls: HomeworkDDL[] = [];
    for (let i: number = startRow; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.length === 0) continue;

      const cols: string[] = FileParserService.splitRow(line, delimiter);
      const rawCourse: string = idxMap.courseName !== -1 ? (cols[idxMap.courseName] ?? '').trim() : '';
      const courseName: string = rawCourse.length > 0 ? rawCourse : '未分类';
      const title: string = idxMap.title !== -1 ? (cols[idxMap.title] ?? '').trim() : '';

      if (title.length === 0 && courseName === '未分类') continue;

      const rowLabel: string = `${i + 1}`;
      const rawDate: string = idxMap.dueDate !== -1 ? (cols[idxMap.dueDate] ?? '') : '';
      const dueDate: string = FileParserService.resolveDate(rawDate, rowLabel, '截止日期');
      const daysLeft: number = FileParserService.calcDaysLeft(dueDate);
      const priority: string = idxMap.priority !== -1 && (cols[idxMap.priority] ?? '').trim().length > 0
        ? (cols[idxMap.priority] ?? '').trim() : FileParserService.guessPriority(daysLeft);
      const estimatedMinutes: number = idxMap.estimatedMinutes !== -1
        ? (Number(cols[idxMap.estimatedMinutes]) || 30) : 30;

      const ddl: HomeworkDDL = {
        id: `ddl-csv-${Date.now()}-${i}`,
        courseName: courseName,
        title: title.length > 0 ? title : '未命名任务',
        dueDate: dueDate,
        daysLeft: daysLeft,
        priority: priority,
        estimatedMinutes: estimatedMinutes
      };
      ddls.push(ddl);
    }

    if (ddls.length === 0) {
      throw new Error('CSV 中未解析到任何有效作业数据');
    }

    return ddls;
  }


  static autoParseCourses(content: string): CourseInfo[] {
    const trimmed: string = content.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      return FileParserService.parseCoursesFromJSON(trimmed);
    }
    return FileParserService.parseCoursesFromCSV(trimmed);
  }

  static autoParseDDLs(content: string): HomeworkDDL[] {
    const trimmed: string = content.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      return FileParserService.parseDDLsFromJSON(trimmed);
    }
    return FileParserService.parseDDLsFromCSV(trimmed);
  }

  static detectImportType(content: string): string {
    const trimmed: string = content.trim();
    if (trimmed.length === 0) return '';
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        const parsed: Object = JSON.parse(trimmed);
        if (FileParserService.jsonArrayOf(parsed, ['ddls', 'ddlList', 'homework']) !== null) {
          return 'ddl';
        }
        if (FileParserService.jsonArrayOf(parsed, ['courses', 'courseList']) !== null) {
          return 'course';
        }
      } catch (error) {
        return '';
      }
      return '';
    }

    const lines: string[] = trimmed.replace(/\r/g, '').split('\n');
    const first: number = FileParserService.firstDataLine(lines);
    if (first < 0) return '';
    const delimiter: string = FileParserService.detectDelimiter(lines[first]);
    const header: string[] = FileParserService.splitRow(lines[first], delimiter);
    let ddlSignals: number = 0;
    let courseSignals: number = 0;
    for (let i: number = 0; i < header.length; i++) {
      const cell: string = header[i];
      if (headerMatches(TITLE_ALIASES, cell) || headerMatches(DUE_DATE_ALIASES, cell)
        || headerMatches(ESTIMATED_MINUTES_ALIASES, cell)) ddlSignals++;
      if (headerMatches(EXAM_DATE_ALIASES, cell) || headerMatches(STUDY_HOURS_ALIASES, cell)
        || headerMatches(STATUS_ALIASES, cell)) courseSignals++;
    }
    if (ddlSignals >= 2 && ddlSignals > courseSignals) return 'ddl';
    if (courseSignals >= 1 && courseSignals > ddlSignals) return 'course';
    return '';
  }


  static generateCourseJSONTemplate(): string {
    const course1: RawCourseRow = {
      courseName: '数据结构',
      examDate: '2026-07-20',
      priority: '高',
      studyHours: 2,
      status: '近期复习不足'
    };
    const course2: RawCourseRow = {
      courseName: '操作系统',
      examDate: '2026-07-28',
      priority: '中',
      studyHours: 5,
      status: '近期复习正常'
    };
    const courseList: RawCourseRow[] = [course1, course2];
    const template: CourseTemplateContainer = {
      courses: courseList
    };
    return JSON.stringify(template, null, 2);
  }

  static generateCourseCSVTemplate(): string {
    return '课程名称,考试日期,优先级,学习时长,复习状态\n数据结构,2026-07-20,高,2,近期复习不足\n操作系统,2026-07-28,中,5,近期复习正常';
  }

  static generateDDLJSONTemplate(): string {
    const ddl1: RawDDLRow = {
      courseName: '数据结构',
      title: '二叉树遍历实验报告',
      dueDate: '2026-07-15',
      priority: '高',
      estimatedMinutes: 45
    };
    const ddl2: RawDDLRow = {
      courseName: '操作系统',
      title: '进程调度算法分析',
      dueDate: '2026-07-20',
      priority: '中',
      estimatedMinutes: 60
    };
    const ddlList: RawDDLRow[] = [ddl1, ddl2];
    const template: DDLTemplateContainer = {
      ddls: ddlList
    };
    return JSON.stringify(template, null, 2);
  }

  static generateDDLCSVTemplate(): string {
    return '课程名称,作业标题,截止日期,优先级,预计时长\n数据结构,二叉树遍历实验报告,2026-07-15,高,45\n操作系统,进程调度算法分析,2026-07-20,中,60';
  }


  private static normalizeDate(raw: string): string | null {
    const text: string = raw.trim();
    if (text.length === 0) {
      return null;
    }

    const full: RegExpMatchArray | null =
      text.match(/^(\d{4})\s*[-\/.年]\s*(\d{1,2})\s*[-\/.月]\s*(\d{1,2})\s*日?$/);
    if (full !== null) {
      return FileParserService.buildDate(Number(full[1]), Number(full[2]), Number(full[3]));
    }

    const monthDay: RegExpMatchArray | null =
      text.match(/^(\d{1,2})\s*[-\/.月]\s*(\d{1,2})\s*日?$/);
    if (monthDay !== null) {
      const month: number = Number(monthDay[1]);
      const day: number = Number(monthDay[2]);
      const today: Date = new Date();
      let year: number = today.getFullYear();
      let built: string | null = FileParserService.buildDate(year, month, day);
      if (built === null) {
        return null;
      }
      const probe: Date = new Date(year, month - 1, day);
      const startOfToday: Date = new Date(today.getFullYear(), today.getMonth(), today.getDate());
      if (probe.getTime() < startOfToday.getTime()) {
        built = FileParserService.buildDate(year + 1, month, day);
      }
      return built;
    }

    return null;
  }

  private static buildDate(year: number, month: number, day: number): string | null {
    if (year < 1970 || year > 9999) return null;
    if (month < 1 || month > 12) return null;
    if (day < 1 || day > 31) return null;
    const probe: Date = new Date(year, month - 1, day);
    if (probe.getFullYear() !== year || probe.getMonth() !== month - 1 || probe.getDate() !== day) {
      return null;
    }
    const mm: string = month < 10 ? `0${month}` : `${month}`;
    const dd: string = day < 10 ? `0${day}` : `${day}`;
    return `${year}-${mm}-${dd}`;
  }

  private static resolveDate(raw: string, rowLabel: string, fieldLabel: string): string {
    const text: string = raw.trim();
    if (text.length === 0 || text === '未设置' || text === '-' || text === '—'
      || text === '/' || text === '无') {
      return '未设置';
    }
    const normalized: string | null = FileParserService.normalizeDate(text);
    if (normalized === null) {
      throw new Error(
        `第 ${rowLabel} 行的${fieldLabel}认不出来：「${text}」。` +
        `支持的写法：2026-10-15、2026/10/15、2026.10.15、2026年10月15日、10月15日。`);
    }
    return normalized;
  }

  private static calcDaysLeft(dateStr: string): number {
    if (dateStr === '未设置') return 30;
    const parts: string[] = dateStr.split('-');
    if (parts.length !== 3) return 30;
    const year: number = Number(parts[0]);
    const month: number = Number(parts[1]);
    const day: number = Number(parts[2]);
    const target: number = new Date(year, month - 1, day).getTime();
    if (Number.isNaN(target)) return 30;
    const today: Date = new Date();
    const todayStart: number = new Date(
      today.getFullYear(), today.getMonth(), today.getDate()).getTime();
    const targetStart: number = new Date(year, month - 1, day).getTime();
    return Math.max(0, Math.round((targetStart - todayStart) / (1000 * 60 * 60 * 24)));
  }

  private static detectDelimiter(line: string): string {
    const candidates: string[] = [',', '\t', '，', ';'];
    let best: string = ',';
    let bestCount: number = 0;
    for (let c: number = 0; c < candidates.length; c++) {
      let count: number = 0;
      let inQuotes: boolean = false;
      for (let i: number = 0; i < line.length; i++) {
        const ch: string = line[i];
        if (ch === '"') {
          inQuotes = !inQuotes;
        } else if (ch === candidates[c] && !inQuotes) {
          count++;
        }
      }
      if (count > bestCount) {
        bestCount = count;
        best = candidates[c];
      }
    }
    return best;
  }

  private static guessPriority(daysLeft: number): string {
    if (daysLeft <= 3) return '高';
    if (daysLeft <= 10) return '中';
    return '低';
  }

  private static guessStatus(studyHours: number): string {
    if (studyHours <= 1) return '近期复习不足';
    if (studyHours <= 4) return '近期复习正常';
    return '近期复习良好';
  }

  private static firstDataLine(lines: string[]): number {
    for (let i: number = 0; i < lines.length; i++) {
      if (lines[i].trim().length > 0) return i;
    }
    return -1;
  }

  private static jsonArrayOf(parsed: Object, containerKeys: string[]): Object[] | null {
    if (Array.isArray(parsed)) {
      return parsed as Object[];
    }
    const container: Record<string, Object> = parsed as Record<string, Object>;
    for (let i: number = 0; i < containerKeys.length; i++) {
      const value: Object | undefined = container[containerKeys[i]];
      if (value !== undefined && value !== null && Array.isArray(value)) {
        return value as Object[];
      }
    }
    return null;
  }

  private static pickString(row: Record<string, Object>, aliases: string[]): string {
    for (let i: number = 0; i < aliases.length; i++) {
      const value: Object | undefined = row[aliases[i]];
      if (value !== undefined && value !== null) {
        const text: string = String(value).trim();
        if (text.length > 0) return text;
      }
    }
    return '';
  }

  private static looksLikeDataRow(row: string[]): boolean {
    return row.length >= 2
      && row[0].trim().length > 0
      && FileParserService.normalizeDate(row[1]) !== null;
  }

  private static parseCSVLine(line: string): string[] {
    return FileParserService.splitRow(line, FileParserService.detectDelimiter(line));
  }

  private static splitRow(line: string, delimiter: string): string[] {
    const result: string[] = [];
    let current: string = '';
    let inQuotes: boolean = false;

    for (let i: number = 0; i < line.length; i++) {
      const ch: string = line[i];
      if (ch === '"') {
        inQuotes = !inQuotes;
      } else if (ch === delimiter && !inQuotes) {
        result.push(current.trim());
        current = '';
      } else {
        current += ch;
      }
    }
    result.push(current.trim());
    return result;
  }

  static arrayBufferToString(buffer: ArrayBuffer): string {
    try {
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: false });
      return decoder.decodeToString(new Uint8Array(buffer));
    } catch (error) {
      return FileParserService.decodeUtf8Manually(new Uint8Array(buffer));
    }
  }

  private static decodeUtf8Manually(bytes: Uint8Array): string {
    let result: string = '';
    let i: number = 0;
    while (i < bytes.length) {
      const b0: number = bytes[i];
      let codePoint: number = -1;
      let size: number = 1;

      if (b0 < 0x80) {
        codePoint = b0;
        size = 1;
      } else if ((b0 & 0xE0) === 0xC0) {
        size = 2;
        codePoint = b0 & 0x1F;
      } else if ((b0 & 0xF0) === 0xE0) {
        size = 3;
        codePoint = b0 & 0x0F;
      } else if ((b0 & 0xF8) === 0xF0) {
        size = 4;
        codePoint = b0 & 0x07;
      }

      if (codePoint < 0 || i + size > bytes.length) {
        result += '\uFFFD';
        i += 1;
        continue;
      }

      let valid: boolean = true;
      for (let k: number = 1; k < size; k++) {
        const cont: number = bytes[i + k];
        if ((cont & 0xC0) !== 0x80) {
          valid = false;
          break;
        }
        codePoint = (codePoint << 6) | (cont & 0x3F);
      }

      if (!valid) {
        result += '\uFFFD';
        i += 1;
        continue;
      }

      result += String.fromCodePoint(codePoint);
      i += size;
    }
    return result;
  }
}
