import { ClientCache } from '../cache/ClientCache';
import { LearningPlan, PlanTask } from '../api/ApiModels';
import { AppBottomBar } from '../components/AppBottomBar';
import { UiTheme } from '../utils/UiTheme';
import { PageHeader } from '../components/PageHeader';
import { ReminderNavigation } from '../services/ReminderNavigation';
import { ReminderEvent, TodayOverview } from '../api/ReminderModels';
import { common } from '@kit.AbilityKit';
import { TodayStore } from '../services/TodayStore';
import { PendingTasks } from '../utils/PendingTasks';
import router from '@ohos.router';
import { picker } from '@kit.CoreFileKit';
import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { appState } from '../data/AppState';
import { CourseInfo, HomeworkDDL } from '../models/AgentModels';
import { FileParserService } from '../services/FileParserService';
import { LocalAgentService } from '../services/LocalAgentService';
import { AIFloatButton } from '../components/AIFloatButton';
import { ApiDefaults } from '../api/ApiDefaults';
import { AgentApiClient } from '../api/AgentApiClient';
import { ScheduleRecognitionResponse } from '../api/ApiModels';
import { ApiFailure } from '../api/ApiResult';
import { ImageEncoder } from '../utils/ImageEncoder';
import { PlanViewModel } from '../viewmodels/PlanViewModel';

@Entry
@Component
struct CourseImport {
  @StorageLink('learningSyncMessage') learningSyncMessage: string = '';
  @StorageLink('learningSyncConflict') learningSyncConflict: boolean = false;
  @StorageLink('knowledgeSyncMessage') knowledgeSyncMessage: string = '';
  @StorageLink('learningDataRevision') @Watch('onLearningDataChanged') learningDataRevision: number = 0;
  @StorageLink('focusDataRevision') @Watch('onLearningDataChanged') focusDataRevision: number = 0;
  @State otherTasks: ReminderEvent[] = [];
  @State pendingTodoCount: number = -1;
  @State addingTodo: string = '';
  @State todoMessage: string = '';
  @State todayTaskIds: string[] = [];
  @State todayPointIds: string[] = [];
  private todoActive: boolean = false;
  private todoRevision: number = 0;
  private todoLoadVersion: number = 0;
  private todoOverview: TodayOverview | null = null;
  private todoOverviewKey: string = '';
  private todayDate(): string {
    const now: Date = new Date();
    return `${now.getFullYear()}-${(now.getMonth() + 1).toString().padStart(2, '0')}-${now.getDate().toString().padStart(2, '0')}`;
  }
  private syncTodayMembership(plan: LearningPlan | null): void {
    const tasks: PlanTask[] = (plan?.tasks ?? []).filter((task: PlanTask) => task.status !== 'completed' && (!task.scheduledDate || task.scheduledDate <= this.todayDate()));
    this.todayTaskIds = tasks.map((task: PlanTask) => task.taskId);
    this.todayPointIds = tasks.map((task: PlanTask) => `${task.sourceCourse || ''}::${task.knowledgePointId}`);
  }
  private isTodoInToday(item: ReminderEvent): boolean {
    return item.kind === 'task' ? this.todayTaskIds.includes(item.sourceId || item.objectId) :
      this.todayPointIds.includes(`${item.courseName}::${item.knowledgePointId}`);
  }
  private async loadOtherTasks(): Promise<void> {
    const owner: string = appState.currentUser.userId;
    const key: string = TodayStore.key(owner);
    const version: number = ++this.todoLoadVersion;
    const results = await Promise.all([AgentApiClient.getToday(), AgentApiClient.getCurrentPlan()]);
    if (!this.todoActive || owner !== appState.currentUser.userId || version !== this.todoLoadVersion || key !== TodayStore.key(owner)) return;
    const today = results[0]; const plan = results[1];
    if (today.ok && today.data.userId === owner) {
      this.todoOverviewKey = key;
      this.todoOverview = today.data;
      TodayStore.save(getContext(this) as common.Context, today.data);
      this.syncUrgentCount();
    }
    if (plan.ok) this.syncTodayMembership(plan.data);
    else if ((plan as ApiFailure).error.statusCode === 404) this.syncTodayMembership(null);
  }
  private async confirmTodoToday(item: ReminderEvent): Promise<void> {
    if (this.addingTodo || this.isTodoInToday(item)) return;
    const owner: string = appState.currentUser.userId;
    const revision: number = ++this.todoRevision;
    this.todoLoadVersion++; this.addingTodo = item.eventId; this.todoMessage = '';
    const result = await AgentApiClient.getCurrentPlan();
    if (!this.todoActive || owner !== appState.currentUser.userId || revision !== this.todoRevision) return;
    if (!result.ok && (result as ApiFailure).error.statusCode !== 404) { this.addingTodo = ''; this.todoMessage = '暂时无法读取计划，请重试。'; return; }
    const plan: LearningPlan | null = result.ok ? result.data : null;
    this.syncTodayMembership(plan);
    if (this.isTodoInToday(item)) { this.addingTodo = ''; this.todoMessage = '这项待办已经在今日计划中。'; return; }
    const tasks: PlanTask[] = (plan?.tasks ?? []).concat(plan?.unscheduledTasks ?? []);
    const selected: PlanTask | undefined = tasks.find((task: PlanTask) => task.status !== 'completed' &&
      (item.kind === 'task' ? task.taskId === (item.sourceId || item.objectId) :
        task.knowledgePointId === item.knowledgePointId && task.sourceCourse === item.courseName && !['ddl', 'manual', 'partner'].includes(task.source || '')));
    const duration: number = selected?.durationMinutes ?? item.durationMinutes;
    const used: number = (plan?.tasks ?? []).filter((task: PlanTask) => task.taskId !== selected?.taskId && task.status !== 'completed' && (!task.scheduledDate || task.scheduledDate <= this.todayDate()))
      .reduce((sum: number, task: PlanTask) => sum + task.durationMinutes, 0);
    const available: number = plan?.budgetSummary?.availableMinutes ?? 0;
    const total: number = Math.max(available, used + duration);
    if (!Number.isInteger(duration) || duration <= 0 || total > 1440) { this.addingTodo = ''; this.todoMessage = '任务时长未明确或今日安排超过一天，请先调整计划。'; return; }
    if (total > available) {
      AlertDialog.show({ title: '确认今日可用学习时间', cancel: () => { this.addingTodo = ''; }, message: `加入「${item.title}」后今日需安排${used + duration}分钟，可用时间从${available}分钟调整为${total}分钟。`,
        primaryButton: { value: '暂不加入', action: () => { this.addingTodo = ''; } },
        secondaryButton: { value: '确认并加入', action: () => { void this.saveTodoToday(item, plan?.version ?? 0, total, owner, revision); } } });
    } else await this.saveTodoToday(item, plan?.version ?? 0, total, owner, revision);
  }
  private async saveTodoToday(item: ReminderEvent, version: number, minutes: number, owner: string, revision: number): Promise<void> {
    if (!this.todoActive || owner !== appState.currentUser.userId || revision !== this.todoRevision) return;
    const result = await AgentApiClient.addTodayItem({ eventId: item.eventId, expectedPlanVersion: version, availableMinutes: minutes });
    if (!this.todoActive || owner !== appState.currentUser.userId || revision !== this.todoRevision) return;
    this.addingTodo = '';
    if (result.ok) {
      ClientCache.cacheCurrentPlan(result.data); this.syncTodayMembership(result.data);
      this.todoMessage = `已将「${item.title}」加入今日计划。`;
      void this.loadOtherTasks();
    } else { this.todoMessage = (result as ApiFailure).error.message; void this.loadOtherTasks(); }
  }
  @State addToToday: boolean = false;
  @State ddlFilter: string = 'all';
  @State addingAssignmentId: string = '';
  private assignmentRevision: number = 0;
  @State ddlEditOpen: boolean = false;
  @State editingDdlId: string = '';
  @State editDdlTitle: string = '';
  @State editDdlDate: string = '';
  @State editDdlMinutes: string = '';
  @State editDdlPriority: string = '中';
  @State ddlEditError: string = '';
  private ddlEditOwner: string = '';
  @State ddlDetailId: string = '';
  @State activeTab: string = 'courses';

  aboutToAppear(): void {
    this.todoActive = true;
    const params = router.getParams() as Record<string, string>;
    this.addToToday = params?.['addToToday'] === 'true';
    if (params && (params['initialTab'] === 'import' || params['initialTab'] === 'ddls')) this.activeTab = params['initialTab'];
    if (params && params['focusDdlId']) { this.ddlDetailId = params['focusDdlId']; this.ddlFilter = 'all'; }
    if (params && params['ddlFilter'] === 'pending' && !params['focusDdlId']) this.ddlFilter = 'pending';
    this.refreshLearningData();
    void this.loadOtherTasks();
    void appState.syncLearningData();
  }

  onPageShow(): void {
    this.todoActive = true;
    void this.loadOtherTasks();
    this.refreshLearningData();
    void appState.syncLearningData();
  }
  onPageHide(): void {
    this.todoActive = false;
    this.todoRevision++;
    this.todoLoadVersion++;
    this.assignmentRevision++;
    this.addingTodo = '';
    this.addingAssignmentId = '';
  }
  aboutToDisappear(): void { this.onPageHide(); }
  @State jsonInputText: string = '';
  @State importType: string = 'course';
  @State showJsonInput: boolean = true;
  @State importStatus: string = '';
  @State importMessage: string = '';
  @State imageImportName: string = '';
  @State showImageReview: boolean = false;
  @State recognizedCourses: CourseInfo[] = [];
  @State recognitionModel: string = '';
  @State editingCourseId: string = '';
  @State editCourseName: string = '';
  @State editExamDate: string = '';
  @State editPriority: string = '中';
  @State editCourseError: string = '';
  @State refreshKey: number = 0;
  @State courseList: CourseInfo[] = appState.courses;
  @State ddlList: HomeworkDDL[] = appState.homeworkDDLs;
  /**
   * 「N 项紧急」徽章的数字（7 天内到期的条数）。
   *
   *  必须缓存成 `@State`，**不能在 build 里直接写 `appState.getUrgentDDLs().length`**：
   * `appState` 是普通类实例、不是 `@Observed`，ArkUI 不把它纳入依赖追踪。
   * 实测（模拟器，2026-09-26）：删掉一条 DDL 后**列表已经刷新、这个徽章却还是旧数字**
   * —— 截图里 4 条删成 3 条时，列表变了而右上角仍写着上一步的数。
   * 所有会改 `ddlList` 的地方都调一次 `syncUrgentCount()`，两边才一致。
   */
  @State urgentDdlCount: number = appState.getUrgentDDLs().length;

  private filteredDDLs(): HomeworkDDL[] {
    return this.ddlList.filter((ddl: HomeworkDDL): boolean => {
      const done: boolean = appState.isTaskCompleted(ddl.id, 'pending');
      if (this.ddlFilter === 'completed') return done;
      if (this.ddlFilter === 'pending') return !done;
      if (this.ddlFilter === 'urgent') return !done && ddl.daysLeft <= 7;
      return true;
    }).sort((a: HomeworkDDL, b: HomeworkDDL) => a.dueDate.localeCompare(b.dueDate) || a.title.localeCompare(b.title));
  }

  private onLearningDataChanged(): void {
    this.refreshLearningData();
  }

  private refreshLearningData(): void {
    this.courseList = appState.courses.slice();
    this.ddlList = appState.homeworkDDLs.slice();
    this.syncUrgentCount();
    this.refreshKey++;
  }

  /** 数据变了就同步刷新徽章数字（见 `urgentDdlCount` 的说明）。 */
  private syncUrgentCount(): void {
    this.urgentDdlCount = appState.getUrgentDDLs().length;
    const owner: string = appState.currentUser.userId;
    const key: string = TodayStore.key(owner);
    if (key !== this.todoOverviewKey) {
      this.todoOverviewKey = key;
      this.todoOverview = TodayStore.read(getContext(this) as common.Context, owner);
    }
    this.otherTasks = PendingTasks.otherTasks(this.todoOverview,
      (id: string): boolean => appState.isTaskCompleted(id, 'pending'));
    this.pendingTodoCount = PendingTasks.count(this.todoOverview, appState.getPendingDDLs().length,
      (id: string): boolean => appState.isTaskCompleted(id, 'pending'));
  }

  private goBack(): void {
    try { router.back(); } catch (error) { console.error(`返回失败: ${JSON.stringify(error)}`); }
  }

  /* ==================== 文件导入 ==================== */

  private async pickAndImportFile(): Promise<void> {
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const result: string[] = await documentPicker.select();
      if (result.length === 0) return;

      this.importStatus = 'processing';
      this.importMessage = '正在读取并校验文件…';

      const uri: string = result[0];
      const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(file.fd);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      const read: number = fileIo.readSync(file.fd, buffer);
      fileIo.closeSync(file);
      if (read !== stat.size) {
        throw new Error('文件没有读取完整');
      }

      const content: string = FileParserService.arrayBufferToString(buffer);
      const detected: string = FileParserService.detectImportType(content);
      const intended: string = this.activeTab === 'ddls' ? 'ddl' : 'course';
      const actual: string = detected.length > 0 ? detected : intended;

      if (actual === 'course') {
        const courses: CourseInfo[] = FileParserService.autoParseCourses(content);
        appState.importCourses(courses);
        this.courseList = appState.courses.slice();
        appState.clearWeeklyPlan();
        this.importStatus = 'success';
        this.importMessage = detected === 'course' && intended !== detected
          ? `已自动识别为课程表并导入 ${courses.length} 门课程`
          : `上传成功：已导入 ${courses.length} 门课程`;
        this.activeTab = 'courses';
      } else {
        const ddls: HomeworkDDL[] = FileParserService.autoParseDDLs(content);
        appState.importDDLs(ddls);
        this.ddlList = appState.homeworkDDLs.slice();
        this.syncUrgentCount();
        appState.clearWeeklyPlan();
        this.importStatus = 'success';
        this.importMessage = detected === 'ddl' && intended !== detected
          ? `已自动识别为作业 DDL 并导入 ${ddls.length} 项作业`
          : `上传成功：已导入 ${ddls.length} 项作业`;
        this.activeTab = 'ddls';
      }
    } catch (err) {
      this.importStatus = 'error';
      this.importMessage = '文件选择失败，请使用下方手动输入方式导入数据';
      this.showJsonInput = true;
    }
  }

  /* ==================== JSON 手动导入 ==================== */

  private importFromJSONText(): void {
    if (this.jsonInputText.trim().length === 0) {
      this.importStatus = 'error';
      this.importMessage = '请输入 JSON 或 CSV 数据内容';
      return;
    }

    try {
      const detected: string = FileParserService.detectImportType(this.jsonInputText);
      const actual: string = detected.length > 0 ? detected : this.importType;
      if (actual === 'course') {
        const courses: CourseInfo[] = FileParserService.autoParseCourses(this.jsonInputText);
        appState.importCourses(courses);
        this.courseList = appState.courses.slice();
        appState.clearWeeklyPlan();
        this.importStatus = 'success';
        this.importMessage = detected === 'course' && this.importType !== detected
          ? `已自动识别为课程表并导入 ${courses.length} 门课程`
          : `成功导入 ${courses.length} 门课程`;
        this.activeTab = 'courses';
      } else {
        const ddls: HomeworkDDL[] = FileParserService.autoParseDDLs(this.jsonInputText);
        appState.importDDLs(ddls);
        this.ddlList = appState.homeworkDDLs.slice();
        this.syncUrgentCount();
        appState.clearWeeklyPlan();
        this.importStatus = 'success';
        this.importMessage = detected === 'ddl' && this.importType !== detected
          ? `已自动识别为作业 DDL 并导入 ${ddls.length} 项作业`
          : `成功导入 ${ddls.length} 项作业`;
        this.activeTab = 'ddls';
      }
      this.jsonInputText = '';
      this.showJsonInput = false;
    } catch (err) {
      const errorMsg: string = (err instanceof Error) ? err.message : String(err);
      this.importStatus = 'error';
      this.importMessage = `解析失败：${errorMsg}`;
    }
  }

  private fillTemplate(): void {
    this.showJsonInput = true;
    this.jsonInputText = (this.importType === 'ddl') ?
      FileParserService.generateDDLJSONTemplate() :
      FileParserService.generateCourseJSONTemplate();
  }

  private fillCSVTemplate(): void {
    this.showJsonInput = true;
    this.jsonInputText = (this.importType === 'ddl') ?
      FileParserService.generateDDLCSVTemplate() :
      FileParserService.generateCourseCSVTemplate();
  }

  private resetToMock(): void {
    appState.resetToMockData();
    this.courseList = appState.courses.slice();
    this.ddlList = appState.homeworkDDLs.slice();
    this.importStatus = '';
    this.importMessage = '';
  }

  /* ==================== 计划跳转 ==================== */

  private openPlan(): void {
    router.pushUrl({ url: 'pages/StudyPlan' });
  }

  private async confirmAssignment(ddl: HomeworkDDL): Promise<void> {
    if (this.addingAssignmentId || appState.isTaskCompleted(ddl.id, 'pending')) return;
    const owner: string = appState.currentUser.userId;
    const revision: number = ++this.assignmentRevision;
    this.addingAssignmentId = ddl.id;
    const result = await AgentApiClient.getCurrentPlan();
    if (!this.ownsAssignmentRequest(owner, revision)) return;
    if (!result.ok) {
      if ((result as ApiFailure).error.statusCode === 404) {
        await this.addAssignment(ddl, owner, revision);
      } else {
        this.addingAssignmentId = '';
        this.importMessage = '暂时无法读取学习计划，请重试。';
        this.importStatus = 'error';
      }
      return;
    }
    const today: string = this.todayDate();
    const scheduled: number = result.data.tasks.filter((task) => task.taskId !== ddl.id && task.parentTaskId !== ddl.id && task.status !== 'completed' && (!task.scheduledDate || task.scheduledDate <= today)).reduce((sum: number, task) => sum + task.durationMinutes, 0);
    const available: number = result.data.budgetSummary?.availableMinutes ?? 0;
    const total: number = Math.max(available, scheduled + ddl.estimatedMinutes);
    if (total <= available) { await this.addAssignment(ddl, owner, revision); return; }
    const cancel = (): void => {
      if (this.ownsAssignmentRequest(owner, revision)) this.addingAssignmentId = '';
    };
    AlertDialog.show({
      title: '确认增加可用学习时间',
      message: `加入「${ddl.title}」需要将本次预算从${available}分钟调整为${total}分钟。也可取消后在本周计划安排到其他日期。`,
      cancel: cancel,
      primaryButton: { value: '暂不加入', action: cancel },
      secondaryButton: { value: '确认增加并加入', action: () => { void this.addAssignment(ddl, owner, revision); } }
    });
  }

  private ownsAssignmentRequest(owner: string, revision: number): boolean {
    return this.todoActive && appState.currentUser.userId === owner && revision === this.assignmentRevision;
  }

  private async addAssignment(ddl: HomeworkDDL, owner: string, revision: number): Promise<void> {
    if (!this.ownsAssignmentRequest(owner, revision) || this.addingAssignmentId !== ddl.id) return;
    try {
      const result = await new PlanViewModel().syncAssignments(ddl.id, this.addToToday);
      if (!this.ownsAssignmentRequest(owner, revision)) return;
      if (result.ok) {
        this.openPlan();
      } else {
        this.importMessage = `加入计划失败：${(result as ApiFailure).error.message}`;
        this.importStatus = 'error';
      }
    } finally {
      if (this.ownsAssignmentRequest(owner, revision)) this.addingAssignmentId = '';
    }
  }

  private async pickScheduleImage(): Promise<void> {
    try {
      const photoPicker = new photoAccessHelper.PhotoViewPicker();
      const result = await photoPicker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1
      });
      if (result.photoUris.length === 0) {
        return;
      }
      this.imageImportName = `课表图片_${Date.now()}.jpg`;
      this.importStatus = 'processing';
      this.importMessage = '正在读取课表图片并调用识别服务…';
      const encoded: string = await ImageEncoder.toBase64(result.photoUris[0]);
      if (encoded.length === 0) {
        this.importStatus = 'error';
        this.importMessage = ImageEncoder.describeFailure();
        return;
      }
      const recognized = await AgentApiClient.recognizeScheduleImage({ imageBase64: encoded });
      if (!recognized.ok) {
        this.importStatus = 'error';
        this.importMessage = (recognized as ApiFailure).error.message;
        this.showImageReview = false;
        return;
      }
      const payload: ScheduleRecognitionResponse = recognized.data;
      this.recognizedCourses = payload.courses;
      this.recognitionModel = payload.model;
      this.showImageReview = true;
      this.importStatus = 'success';
      this.importMessage = `已识别 ${payload.recognizedCount} 门课程，请核对后确认导入。`;
    } catch (error) {
      this.importStatus = 'error';
      this.importMessage = '图片选择失败，请重试或改用文件导入。';
    }
  }

  private confirmImageImport(): void {
    if (this.recognizedCourses.some((course: CourseInfo) => !course.courseName.trim() || (course.exam.date !== '' && course.exam.date !== '未设置' && this.calculateDaysLeft(course.exam.date) < 0))) {
      this.importStatus = 'error'; this.importMessage = '请补全课程名称，并核对考试日期格式。'; return;
    }
    if (this.recognizedCourses.length === 0) {
      this.importStatus = 'error';
      this.importMessage = '没有可导入的识别结果，请重新选择图片。';
      return;
    }
    appState.importCourses(this.recognizedCourses);
    this.courseList = appState.courses.slice();
    appState.clearWeeklyPlan();
    this.activeTab = 'courses';
    this.showImageReview = false;
    this.importStatus = 'success';
    this.importMessage = `已确认导入 ${this.recognizedCourses.length} 门课程。`;
    this.recognizedCourses = [];
  }

  private reviseRecognized(courseId: string, name: string, date: string, priority: string): void {
    this.recognizedCourses = this.recognizedCourses.map((course: CourseInfo): CourseInfo => {
      if (course.courseId !== courseId) return course;
      return { courseId: course.courseId, courseName: name, exam: { date: date, daysLeft: date ? this.calculateDaysLeft(date) : 0 },
        priority: priority, recentStatus: course.recentStatus };
    });
  }
  private addRecognizedCourse(): void {
    this.recognizedCourses = this.recognizedCourses.concat([{ courseId: `ocr-${Date.now()}`, courseName: '',
      exam: { date: '', daysLeft: 0 }, priority: '中', recentStatus: { studyHours: 0, status: '待建立复习记录' } }]);
  }

  /* ==================== 单门课程校正 ==================== */

  private beginCourseEdit(course: CourseInfo): void {
    this.editingCourseId = course.courseId;
    this.editCourseName = course.courseName;
    this.editExamDate = course.exam.date === '未设置' ? '' : course.exam.date;
    this.editPriority = course.priority === '高' || course.priority === '低' ? course.priority : '中';
    this.editCourseError = '';
  }

  private cancelCourseEdit(): void {
    this.editingCourseId = '';
    this.editCourseName = '';
    this.editExamDate = '';
    this.editCourseError = '';
  }

  /** 校验 YYYY-MM-DD，并同时返回需要展示的倒计时天数；-1 表示日期无效。 */
  private calculateDaysLeft(dateText: string): number {
    const parts: string[] = dateText.split('-');
    if (parts.length !== 3 || parts[0].length !== 4 || parts[1].length !== 2 || parts[2].length !== 2) return -1;
    const year: number = Number(parts[0]);
    const month: number = Number(parts[1]);
    const day: number = Number(parts[2]);
    if (!Number.isInteger(year) || !Number.isInteger(month) || !Number.isInteger(day)) return -1;
    const target: Date = new Date(year, month - 1, day);
    if (target.getFullYear() !== year || target.getMonth() !== month - 1 || target.getDate() !== day) return -1;
    const today: Date = new Date();
    const todayStart: Date = new Date(today.getFullYear(), today.getMonth(), today.getDate());
    const oneDay: number = 24 * 60 * 60 * 1000;
    return Math.max(0, Math.ceil((target.getTime() - todayStart.getTime()) / oneDay));
  }

  private saveCourseEdit(course: CourseInfo): void {
    const name: string = this.editCourseName.trim();
    const dateText: string = this.editExamDate.trim();
    if (name.length === 0) {
      this.editCourseError = '课程名称不能为空';
      return;
    }
    if (name.length > 80) {
      this.editCourseError = '课程名称不能超过 80 个字符';
      return;
    }
    let daysLeft: number = 30;
    if (dateText.length > 0) {
      daysLeft = this.calculateDaysLeft(dateText);
      if (daysLeft < 0) {
        this.editCourseError = '考试日期请按 YYYY-MM-DD 填写，例如 2026-12-20';
        return;
      }
    }
    const updated: CourseInfo = {
      courseId: course.courseId,
      courseName: name,
      exam: {
        date: dateText.length > 0 ? dateText : '未设置',
        daysLeft: daysLeft
      },
      priority: this.editPriority,
      recentStatus: course.recentStatus
    };
    if (!appState.updateCourse(course.courseId, updated)) {
      this.editCourseError = '课程已不存在，请刷新后重试';
      return;
    }
    this.courseList = appState.courses.slice();
    appState.clearWeeklyPlan();
    this.cancelCourseEdit();
    this.importStatus = 'success';
    this.importMessage = `已保存“${name}”的修改，学习计划将在下次打开时重新生成。`;
  }

  /* ==================== 构建器 ==================== */

  private requestRemoveCourse(course: CourseInfo): void {
    AlertDialog.show({ title: '删除这门课程？', message: `将删除“${course.courseName}”及其关联课程数据，请确认。`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '确认删除', fontColor: UiTheme.danger, action: () => {
        if (this.editingCourseId === course.courseId) this.cancelCourseEdit();
        appState.removeCourse(course.courseId); this.refreshLearningData(); appState.clearWeeklyPlan();
      } } });
  }
  private requestRemoveDdl(ddl: HomeworkDDL): void {
    AlertDialog.show({ title: '删除这份作业？', message: `将删除“${ddl.title}”，课程本身会保留。`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '确认删除', fontColor: UiTheme.danger, action: () => {
        appState.removeDDL(ddl.id); this.refreshLearningData();
      } } });
  }
  private beginDdlEdit(ddl: HomeworkDDL): void {
    this.ddlEditOwner = appState.currentUser.userId; this.editingDdlId = ddl.id; this.editDdlTitle = ddl.title;
    this.editDdlDate = ddl.dueDate; this.editDdlMinutes = ddl.estimatedMinutes.toString(); this.editDdlPriority = ddl.priority;
    this.ddlEditError = ''; this.ddlEditOpen = true;
  }
  private saveDdlEdit(): void {
    if (this.ddlEditOwner !== appState.currentUser.userId) { this.ddlEditError = '账号已切换，请重新打开作业。'; return; }
    const minutes: number = Number(this.editDdlMinutes);
    if (!this.editDdlTitle.trim() || !Number.isInteger(minutes) || minutes < 1 || minutes > 1440 || !Number.isFinite(Date.parse(this.editDdlDate.replace(' ', 'T')))) {
      this.ddlEditError = '请填写作业名称、有效截止日期和1至1440分钟的预计时长。'; return;
    }
    if (!appState.updateDDL(this.editingDdlId, this.editDdlTitle, this.editDdlDate, minutes, this.editDdlPriority)) {
      this.ddlEditError = '修改未保存，请重试。'; return;
    }
    this.ddlEditOpen = false; this.refreshLearningData();
  }
  @Builder
  DdlEditor() {
    Column({ space: 12 }) {
      Text('作业名称').fontSize(14).fontColor(UiTheme.ink).width('100%')
      TextInput({ text: this.editDdlTitle }).maxLength(200).onChange((value: string) => this.editDdlTitle = value)
      Text('截止日期').fontSize(14).fontColor(UiTheme.ink).width('100%')
      TextInput({ text: this.editDdlDate, placeholder: 'YYYY-MM-DD 或 YYYY-MM-DD HH:mm' }).onChange((value: string) => this.editDdlDate = value)
      Text('预计时长（分钟）').fontSize(14).fontColor(UiTheme.ink).width('100%')
      TextInput({ text: this.editDdlMinutes }).type(InputType.Number).onChange((value: string) => this.editDdlMinutes = value)
      Text('优先级').fontSize(14).fontColor(UiTheme.ink).width('100%')
      Select([{ value: '高' }, { value: '中' }, { value: '低' }]).value(this.editDdlPriority).width('100%')
        .onSelect((index: number) => this.editDdlPriority = ['高', '中', '低'][index])
      if (this.ddlEditError) { Text(this.ddlEditError).fontSize(13).fontColor(UiTheme.danger).width('100%') }
      Row({ space: 12 }) {
        Button('取消', { type: ButtonType.Normal }).height(44).layoutWeight(1).fontColor(UiTheme.secondary).backgroundColor(UiTheme.subtle)
          .borderRadius(8).onClick(() => this.ddlEditOpen = false)
        Button('保存修改', { type: ButtonType.Normal }).height(44).layoutWeight(1).fontColor('#FFFFFF').backgroundColor(UiTheme.accent)
          .borderRadius(8).onClick(() => this.saveDdlEdit())
      }.width('100%')
    }.width('100%').padding(20)
  }

  @Builder
  CourseCard(course: CourseInfo) {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Text(course.courseName).fontSize(17).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).layoutWeight(1)
        Text(course.priority + '优').fontSize(11).fontColor(course.priority === '高' ? UiTheme.danger : UiTheme.secondary)
          .padding({ left: 6, right: 6, top: 3, bottom: 3 }).backgroundColor(UiTheme.subtle).borderRadius(4)
        Text('⋯').fontSize(18).fontColor(UiTheme.secondary).width(32).height(44).textAlign(TextAlign.Center)
          .bindMenu([
            { value: '查看课程计划', action: () => { router.pushUrl({ url: 'pages/StudyPlan', params: { courseName: course.courseName } }); } },
            { value: '编辑课程', action: () => { this.beginCourseEdit(course); } },
            { value: '删除课程', action: () => { this.requestRemoveCourse(course); } }
          ])
      }.width('100%')
      Text(course.exam.date ? `考试：${course.exam.date}（${course.exam.daysLeft}天后）` : '考试日期未设置')
        .fontSize(13).fontColor(UiTheme.secondary).width('100%')
      Text(`本周学习 ${course.recentStatus.studyHours} 小时 · ${course.recentStatus.status}`).fontSize(12).fontColor(UiTheme.secondary).width('100%')
      if (this.editingCourseId === course.courseId) {
        Column({ space: 9 }) {
          Text('校正识别结果').fontSize(13).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).width('100%')
          Text('课程名称').fontSize(11).fontColor(UiTheme.secondary).width('100%')
          TextInput({ text: this.editCourseName, placeholder: '请输入课程名称' })
            .width('100%').height(40).fontSize(13).fontColor(UiTheme.ink)
            .backgroundColor(UiTheme.surface).border({ width: 1, color: '#CBD5E1' }).borderRadius(9)
            .padding({ left: 10, right: 10 }).maxLength(80)
            .onChange((value: string) => {
              this.editCourseName = value;
              this.editCourseError = '';
            })
          Text('考试日期（可留空）').fontSize(11).fontColor(UiTheme.secondary).width('100%')
          TextInput({ text: this.editExamDate, placeholder: 'YYYY-MM-DD' })
            .width('100%').height(40).fontSize(13).fontColor(UiTheme.ink)
            .backgroundColor(UiTheme.surface).border({ width: 1, color: '#CBD5E1' }).borderRadius(9)
            .padding({ left: 10, right: 10 }).maxLength(10)
            .onChange((value: string) => {
              this.editExamDate = value;
              this.editCourseError = '';
            })
          Text('优先级').fontSize(11).fontColor(UiTheme.secondary).width('100%')
          Row({ space: 8 }) {
            Button('高').layoutWeight(1).height(34).fontSize(12)
              .fontColor(this.editPriority === '高' ? UiTheme.surface : UiTheme.danger)
              .backgroundColor(this.editPriority === '高' ? UiTheme.danger : UiTheme.surface)
              .border({ width: 1, color: '#FCA5A5' }).borderRadius(8)
              .onClick(() => this.editPriority = '高')
            Button('中').layoutWeight(1).height(34).fontSize(12)
              .fontColor(this.editPriority === '中' ? UiTheme.surface : '#D97706')
              .backgroundColor(this.editPriority === '中' ? '#F59E0B' : UiTheme.surface)
              .border({ width: 1, color: '#FCD34D' }).borderRadius(8)
              .onClick(() => this.editPriority = '中')
            Button('低').layoutWeight(1).height(34).fontSize(12)
              .fontColor(this.editPriority === '低' ? UiTheme.surface : UiTheme.accent)
              .backgroundColor(this.editPriority === '低' ? UiTheme.accent : UiTheme.surface)
              .border({ width: 1, color: '#93C5FD' }).borderRadius(8)
              .onClick(() => this.editPriority = '低')
          }.width('100%')
          if (this.editCourseError.length > 0) {
            Text(this.editCourseError).fontSize(11).fontColor(UiTheme.danger).width('100%')
          }
          Row({ space: 8 }) {
            Button('取消').layoutWeight(1).height(36).fontSize(12).fontColor(UiTheme.secondary)
              .backgroundColor(UiTheme.surface).border({ width: 1, color: '#CBD5E1' }).borderRadius(8)
              .onClick(() => this.cancelCourseEdit())
            Button('保存修改').layoutWeight(1).height(36).fontSize(12).fontWeight(FontWeight.Medium)
              .fontColor(UiTheme.surface).backgroundColor(UiTheme.accent).borderRadius(8)
              .onClick(() => this.saveCourseEdit(course))
          }.width('100%')
        }
        .width('100%').padding(12).margin({ top: 10 })
        .backgroundColor(UiTheme.subtle).border({ width: 1, color: UiTheme.line }).borderRadius(8)
      }
    }.width('100%').padding({ top: 12, bottom: 18 }).alignItems(HorizontalAlign.Start)
      .border({ width: { bottom: 1 }, color: UiTheme.line })
  }

  @Builder
  DDLItem(ddl: HomeworkDDL) {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Column({ space: 6 }) {
          Row({ space: 6 }) {
            Text(ddl.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).layoutWeight(1)
            if (ddl.daysLeft < 0 && !appState.isTaskCompleted(ddl.id, 'pending')) { Text('已过期').fontSize(11).fontColor(UiTheme.danger) }
            if (appState.isTaskCompleted(ddl.id, 'pending')) { Text('已完成').fontSize(11).fontColor(UiTheme.success) }
          }.width('100%')
          Text(`${ddl.courseName} · 课程作业`).fontSize(12).fontColor(UiTheme.secondary).width('100%')
          Text(`截止：${ddl.dueDate}`).fontSize(12).fontColor(UiTheme.secondary).width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if (!appState.isTaskCompleted(ddl.id, 'pending')) {
          Button(this.addingAssignmentId === ddl.id ? '加入中…' : this.addToToday ? '加入本日计划' : '加入计划', { type: ButtonType.Normal }).height(40).fontSize(12)
            .fontColor(UiTheme.accent).backgroundColor(UiTheme.surface).border({ width: 1, color: UiTheme.line }).borderRadius(8)
            .enabled(this.addingAssignmentId.length === 0).onClick(() => { void this.confirmAssignment(ddl); })
        }
      }.width('100%').alignItems(VerticalAlign.Top)
      Row({ space: 20 }) {
        Text('详情').fontSize(13).fontColor(UiTheme.secondary).padding({ top: 8, bottom: 8 })
          .onClick(() => this.ddlDetailId = this.ddlDetailId === ddl.id ? '' : ddl.id)
        Text(`预计 ${ddl.estimatedMinutes} 分钟`).fontSize(12).fontColor(UiTheme.secondary)
        Blank()
        Text('更多').fontSize(13).fontColor(UiTheme.secondary).padding({ top: 8, bottom: 8 }).bindMenu([
          { value: '编辑任务', action: () => { this.beginDdlEdit(ddl); } },
          { value: appState.isTaskCompleted(ddl.id, 'pending') ? '恢复待处理' : '标记完成', action: () => { this.requestDdlCompletion(ddl); } },
          { value: '删除任务', action: () => { this.requestRemoveDdl(ddl); } }
        ])
      }.width('100%')
      if (this.ddlDetailId === ddl.id) {
        Text(`${ddl.courseName}：${ddl.title}\n截止 ${ddl.dueDate}，预计 ${ddl.estimatedMinutes} 分钟\n优先级：${ddl.priority} · ${appState.isTaskCompleted(ddl.id, 'pending') ? '已完成' : '待处理'}`)
          .fontSize(13).fontColor(UiTheme.secondary).lineHeight(22).width('100%').padding(12).backgroundColor(UiTheme.subtle).borderRadius(8)
      }
    }.width('100%').padding({ top: 16, bottom: 12 }).border({ width: { bottom: 1 }, color: UiTheme.line })
  }

  private requestDdlCompletion(ddl: HomeworkDDL): void {
    const owner: string = appState.currentUser.userId;
    const completed: boolean = appState.isTaskCompleted(ddl.id, 'pending');
    AlertDialog.show({ title: completed ? '恢复为待处理？' : '确认作业已完成？',
      message: completed ? `将“${ddl.title}”恢复到待处理列表。` : `请确认“${ddl.title}”已完成；标记后将移到已完成列表。`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: completed ? '确认恢复' : '确认完成', action: () => {
        if (owner !== appState.currentUser.userId) return;
        appState.markPlanTaskStatus(ddl.id, completed ? 'todo' : 'completed'); this.refreshLearningData();
      } } });
  }

  @Builder
  DdlFilter(label: string, key: string) {
    Button(label, { type: ButtonType.Normal }).layoutWeight(1).height(36).fontSize(12).borderRadius(6)
      .fontColor(this.ddlFilter === key ? UiTheme.accent : UiTheme.secondary)
      .backgroundColor(this.ddlFilter === key ? UiTheme.tint : UiTheme.subtle).onClick(() => this.ddlFilter = key)
  }

  @Builder
  ImportPanel() {
    Column({ space: 18 }) {
      if (this.showImageReview) {
        Text('课表 OCR 识别预览').fontSize(16).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
        Text(`${this.imageImportName} · ${this.recognizedCourses.length} 门课程 · ${this.recognitionModel}`)
          .fontSize(12).fontColor(UiTheme.secondary).width('100%')
        Text(this.recognitionModel === 'fixture-schedule-sample' ? '离线识别样例，核对后才写入课程。' : '核对课程名称、日期与优先级，可修改或删除识别结果。')
          .fontSize(13).fontColor(UiTheme.secondary).lineHeight(21).width('100%').padding(12).backgroundColor(UiTheme.tint).borderRadius(8)
        ForEach(this.recognizedCourses, (course: CourseInfo) => {
          Column({ space: 8 }) {
            Row({ space: 8 }) {
              TextInput({ text: course.courseName, placeholder: '课程名称（必填）' }).fontSize(14).height(44).layoutWeight(1).borderRadius(8)
                .onChange((value: string) => this.reviseRecognized(course.courseId, value, course.exam.date, course.priority))
              Button('删除', { type: ButtonType.Normal }).height(44).fontSize(13).backgroundColor(UiTheme.surface).fontColor(UiTheme.danger)
                .onClick(() => this.recognizedCourses = this.recognizedCourses.filter((item: CourseInfo) => item.courseId !== course.courseId))
            }.width('100%')
            Row({ space: 10 }) {
              TextInput({ text: course.exam.date === '未设置' ? '' : course.exam.date, placeholder: '考试日期 YYYY-MM-DD（可选）' })
                .height(40).fontSize(12).layoutWeight(1).borderRadius(8).onChange((value: string) => this.reviseRecognized(course.courseId, course.courseName, value, course.priority))
              Select([{ value: '高' }, { value: '中' }, { value: '低' }]).value(course.priority).font({ size: 13 }).width(80)
                .onSelect((index: number) => this.reviseRecognized(course.courseId, course.courseName, course.exam.date, ['高', '中', '低'][index]))
            }.width('100%')
          }.width('100%').padding({ bottom: 12 }).border({ width: { bottom: 1 }, color: UiTheme.line })
        }, (course: CourseInfo) => course.courseId)
        Text('继续添加课程 ＋').fontSize(14).fontColor(UiTheme.accent).width('100%').padding({ top: 8, bottom: 8 }).onClick(() => this.addRecognizedCourse())
        Row({ space: 10 }) {
          Button('保存修改', { type: ButtonType.Normal }).layoutWeight(1).height(44).fontSize(13).fontColor(UiTheme.accent).backgroundColor(UiTheme.tint).borderRadius(8)
            .onClick(() => { this.importMessage = '校正已保留，请确认导入。'; this.importStatus = 'success'; })
          Button('取消', { type: ButtonType.Normal }).layoutWeight(1).height(44).fontSize(13).fontColor(UiTheme.secondary).backgroundColor(UiTheme.subtle).borderRadius(8)
            .onClick(() => { this.showImageReview = false; this.recognizedCourses = []; })
        }.width('100%')
        Button('确认导入并更新计划', { type: ButtonType.Normal }).width('100%').height(46).fontSize(14)
          .fontColor('#FFFFFF').backgroundColor(UiTheme.accent).borderRadius(8).onClick(() => this.confirmImageImport())
      } else {
        Text('选择导入方式').fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
        Column({ space: 6 }) {
          Row() {
            Text('图片导入：从相册导入课表').fontSize(15).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).layoutWeight(1)
            Text('›').fontSize(22).fontColor(UiTheme.secondary)
          }.width('100%')
          Text('拍摄或选择课表图片，识别后核对再导入。').fontSize(12).fontColor(UiTheme.secondary).width('100%')
        }.width('100%').padding(14).border({ width: 1, color: UiTheme.line }).borderRadius(8).onClick(() => this.pickScheduleImage())
        Column({ space: 4 }) {
          Text('文件导入').fontSize(16).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
          Row() { Text('导入课程表（JSON / CSV）').fontSize(14).fontColor(UiTheme.ink).layoutWeight(1); Text('›').fontSize(20).fontColor(UiTheme.secondary) }
            .width('100%').height(44).onClick(() => { this.activeTab = 'courses'; void this.pickAndImportFile(); })
          Divider().color(UiTheme.line)
          Row() { Text('导入作业DDL（JSON / CSV）').fontSize(14).fontColor(UiTheme.ink).layoutWeight(1); Text('›').fontSize(20).fontColor(UiTheme.secondary) }
            .width('100%').height(44).onClick(() => { this.activeTab = 'ddls'; void this.pickAndImportFile(); })
        }.width('100%').padding(14).border({ width: 1, color: UiTheme.line }).borderRadius(8)
        Column({ space: 12 }) {
          Row() {
            Text('手动粘贴').fontSize(16).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).layoutWeight(1)
            Text(this.showJsonInput ? '⌃' : '›').fontSize(20).fontColor(UiTheme.secondary)
          }.width('100%').height(36).onClick(() => this.showJsonInput = !this.showJsonInput)
          if (this.showJsonInput) {
            Text('粘贴课表或作业信息文本，解析后导入。').fontSize(12).fontColor(UiTheme.secondary).width('100%')
            TextArea({ text: this.jsonInputText, placeholder: '请粘贴 JSON 或 CSV 模板数据' }).height(120).fontSize(13).maxLength(50000)
              .backgroundColor(UiTheme.subtle).borderRadius(8).onChange((value: string) => this.jsonInputText = value)
            Row({ space: 8 }) {
              Radio({ value: 'course', group: 'importType' }).checked(this.importType === 'course').onChange((value: boolean) => { if (value) this.importType = 'course'; })
              Text('课程').fontSize(13).fontColor(UiTheme.ink).onClick(() => this.importType = 'course')
              Radio({ value: 'ddl', group: 'importType' }).checked(this.importType === 'ddl').onChange((value: boolean) => { if (value) this.importType = 'ddl'; })
              Text('作业').fontSize(13).fontColor(UiTheme.ink).onClick(() => this.importType = 'ddl')
              Blank()
              Text('JSON模板').fontSize(12).fontColor(UiTheme.accent).height(44).padding({ top: 14 }).onClick(() => this.fillTemplate())
              Text('CSV模板').fontSize(12).fontColor(UiTheme.accent).height(44).padding({ top: 14 }).onClick(() => this.fillCSVTemplate())
            }.width('100%')
            Button('解析并导入', { type: ButtonType.Normal }).width('100%').height(46).fontSize(15)
              .fontColor('#FFFFFF').backgroundColor(UiTheme.accent).borderRadius(8).onClick(() => this.importFromJSONText())
          }
        }.width('100%').padding(14).border({ width: 1, color: UiTheme.line }).borderRadius(8)
        if (ApiDefaults.ALLOW_DEMO && AgentApiClient.getConfig().useFixture) {
          Text('示例恢复（仅演示模式） ›').fontSize(13).fontColor(UiTheme.secondary).width('100%').padding(14).backgroundColor(UiTheme.subtle).borderRadius(8)
            .onClick(() => AlertDialog.show({ title: '恢复演示数据？', message: '仅恢复当前离线演示环境的数据，联机账号数据不受影响。',
              primaryButton: { value: '取消', action: () => {} }, secondaryButton: { value: '确认恢复', action: () => this.resetToMock() } }))
        }
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  /* ==================== 主构建 ==================== */

  build() {
    Stack() {
    Column() {
      // 顶部导航
      PageHeader({ title: this.showImageReview ? '识别校正与确认' : this.activeTab === 'import' ? '导入课程与作业' : '课程与作业', assistant: false, onBack: () => { if (this.showImageReview) this.showImageReview = false; else this.goBack(); } })

      // 导入状态条
      if (this.learningSyncMessage.length > 0) {
        Row({ space: 10 }) {
          Text(this.learningSyncMessage).fontSize(12).fontColor(UiTheme.secondary).layoutWeight(1)
          if (this.learningSyncConflict) {
            Text('使用云端并备份本机').fontSize(12).fontColor(UiTheme.accent).onClick(() => appState.useServerLearningData())
            Text('保留本机修改').fontSize(12).fontColor(UiTheme.accent).onClick(() => AlertDialog.show({
              title: '保留本机修改？', message: '将用本机待同步的修改更新云端对应记录，其他云端记录会保留。',
              primaryButton: { value: '取消', action: () => {} },
              secondaryButton: { value: '确认同步', action: () => { void appState.keepLocalLearningChanges(); } }
            }))
          } else {
            Text('重新同步').fontSize(12).fontColor(UiTheme.accent).onClick(() => appState.syncLearningData())
          }
        }.width('100%').padding(12)
      }
      if (this.knowledgeSyncMessage.length > 0) {
        Text(this.knowledgeSyncMessage).fontSize(13).fontColor(UiTheme.accent).padding(12)
      }
      if (this.importStatus.length > 0) {
        Row() {
          if (this.importStatus === 'processing') { LoadingProgress().width(18).height(18).margin({ right: 8 }) }
          Text(this.importMessage).fontSize(13)
            .fontColor(this.importStatus === 'error' ? UiTheme.danger : UiTheme.accent)
            .layoutWeight(1)
          Text('关闭').fontSize(13).fontColor(UiTheme.secondary).padding(10).onClick(() => { this.importStatus = ''; this.importMessage = ''; })
        }
        .width('100%').padding({ left: 20, right: 20, top: 10, bottom: 10 })
        .backgroundColor(this.importStatus === 'error' ? '#FEF2F2' : UiTheme.tint)
      }

      // Tab 切换
      Row({ space: 0 }) {
        Button() {
          Text('课程列表').fontSize(14).fontWeight(this.activeTab === 'courses' ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.activeTab === 'courses' ? UiTheme.accent : UiTheme.secondary)
        }
        .layoutWeight(1).height(40).backgroundColor(this.activeTab === 'courses' ? UiTheme.tint : UiTheme.surface)
        .border({ width: { bottom: this.activeTab === 'courses' ? 2 : 1 }, color: this.activeTab === 'courses' ? UiTheme.accent : UiTheme.subtle })
        .onClick(() => this.activeTab = 'courses')

        Button() {
          Text('作业DDL').fontSize(14).fontWeight(this.activeTab === 'ddls' ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.activeTab === 'ddls' ? UiTheme.accent : UiTheme.secondary)
        }
        .layoutWeight(1).height(40).backgroundColor(this.activeTab === 'ddls' ? UiTheme.tint : UiTheme.surface)
        .border({ width: { bottom: this.activeTab === 'ddls' ? 2 : 1 }, color: this.activeTab === 'ddls' ? UiTheme.accent : UiTheme.subtle })
        .onClick(() => this.activeTab = 'ddls')

        Button() {
          Text('导入').fontSize(14).fontWeight(this.activeTab === 'import' ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.activeTab === 'import' ? UiTheme.accent : UiTheme.secondary)
        }
        .layoutWeight(1).height(40).backgroundColor(this.activeTab === 'import' ? UiTheme.tint : UiTheme.surface)
        .border({ width: { bottom: this.activeTab === 'import' ? 2 : 1 }, color: this.activeTab === 'import' ? UiTheme.accent : UiTheme.subtle })
        .onClick(() => this.activeTab = 'import')
      }.width('100%').padding({ left: 20, right: 20 })

      Scroll() {
        Column({ space: 16 }) {
          if (this.courseList.length > 0 && this.activeTab === 'courses') {
            Text('下一步：确认学习目标与考试日期 ›').fontSize(14).fontColor(UiTheme.ink).width('100%').padding(12)
              .backgroundColor(UiTheme.subtle).borderRadius(8).onClick(() => router.pushUrl({ url: 'pages/LearningSetup' }))
          }

          if (this.activeTab === 'import') {
            this.ImportPanel()
          } else if (this.activeTab === 'courses') {
            Column({ space: 4 }) {
              Row() {
                Text('已导入课程').fontSize(18).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).layoutWeight(1)
                Text(`添加课程 ＋`).onClick(() => router.pushUrl({ url: 'pages/LearningSetup', params: { newCourse: 'true' } })).fontSize(12).fontColor(UiTheme.accent).fontWeight(FontWeight.Medium)
                  .backgroundColor(UiTheme.tint).borderRadius(8).padding({ left: 10, right: 10, top: 4, bottom: 4 })
              }.width('100%').margin({ bottom: 8 })

              if (this.courseList.length === 0) {
                Column({ space: 8 }) {

                  Text('还没有课程数据').fontSize(15).fontWeight(FontWeight.Medium).fontColor(UiTheme.secondary)
                  Text('点击上方「导入」标签导入课程表').fontSize(12).fontColor(UiTheme.muted)
                  Button('前往导入').fontSize(13).fontColor(UiTheme.accent).backgroundColor(UiTheme.tint)
                    .border({ width: 1, color: '#BFDBFE' }).borderRadius(8).margin({ top: 4 })
                    .onClick(() => this.activeTab = 'import')
                }.width('100%').padding(24).alignItems(HorizontalAlign.Center)
              } else {
                ForEach(this.courseList, (course: CourseInfo) => {
                  this.CourseCard(course)
                }, (course: CourseInfo) => course.courseId)
              }
            }.width('100%')
          } else if (this.activeTab === 'ddls') {
            Column({ space: 4 }) {
              Row() {
                Text('全部待办').fontSize(18).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink).layoutWeight(1)
                // 读 @State 而不是直接调 appState（后者不在 ArkUI 依赖追踪里，删完不刷新）。
                Text(this.pendingTodoCount < 0 ? '待同步' : `${this.pendingTodoCount}项待处理`).fontSize(12).fontColor(UiTheme.accent).fontWeight(FontWeight.Medium)
                  .backgroundColor(UiTheme.tint).borderRadius(8).padding({ left: 10, right: 10, top: 4, bottom: 4 })
              }.width('100%').margin({ bottom: 8 })
              Text('未完成的作业、复习与学习任务').fontSize(12).fontColor(UiTheme.secondary).width('100%').margin({ bottom: 8 })

              if (this.ddlDetailId.length > 0 && !this.ddlList.some((ddl: HomeworkDDL) => ddl.id === this.ddlDetailId)) {
                Text('该提醒对应的作业已删除或尚未同步，请刷新作业列表。').fontSize(13).fontColor('#B45309')
              }
              if (this.todoMessage) { Text(this.todoMessage).fontSize(13).fontColor(UiTheme.secondary).width('100%').padding({ top: 8, bottom: 8 }) }
              if (this.ddlFilter !== 'completed') ForEach(this.otherTasks, (item: ReminderEvent) => {
                Column({ space: 8 }) {
                  Text(item.title).fontSize(16).fontWeight(FontWeight.Medium).width('100%')
                  Text(`${item.courseName} · ${item.kind === 'exam' ? '复习任务' : '学习任务'}`).fontSize(12).fontColor(UiTheme.secondary).width('100%')
                  Text(item.reason).fontSize(13).fontColor(UiTheme.secondary).width('100%')
                  Row({ space: 10 }) {
                    Text(item.kind === 'task' ? '任务详情 ›' : '开始本项复习 ›').fontSize(13).fontColor(UiTheme.accent).layoutWeight(1).height(44).padding({ top: 12 })
                      .onClick(() => ReminderNavigation.open(item))
                    Button(this.isTodoInToday(item) ? '已在今日计划' : this.addingTodo === item.eventId ? '加入中…' : '加入今日计划', { type: ButtonType.Normal })
                      .height(44).fontSize(12).fontColor(UiTheme.accent).backgroundColor(UiTheme.tint).borderRadius(8)
                      .enabled(!this.addingTodo && !this.isTodoInToday(item)).onClick(() => this.confirmTodoToday(item))
                  }.width('100%')
                }.padding(14).width('100%').backgroundColor(UiTheme.surface).borderRadius(8)
              }, (item: ReminderEvent) => item.eventId)
              if (this.ddlList.length === 0) {
                Column({ space: 8 }) {

                  Text('还没有作业DDL数据').fontSize(15).fontWeight(FontWeight.Medium).fontColor(UiTheme.secondary)
                  Text('点击上方「导入」标签导入作业列表').fontSize(12).fontColor(UiTheme.muted)
                  Button('前往导入').fontSize(13).fontColor(UiTheme.accent).backgroundColor(UiTheme.tint)
                    .border({ width: 1, color: '#BFDBFE' }).borderRadius(8).margin({ top: 4 })
                    .onClick(() => this.activeTab = 'import')
                }.width('100%').padding(24).alignItems(HorizontalAlign.Center)
              } else {
                Row() {
                  Text('作业DDL').fontSize(15).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).layoutWeight(1)
                  Text(`${this.urgentDdlCount}项临近截止`).fontSize(12).fontColor(UiTheme.danger)
                }.width('100%').margin({ top: 12, bottom: 8 })
                Row({ space: 8 }) {
                this.DdlFilter('全部', 'all')
                this.DdlFilter('待处理', 'pending')
                this.DdlFilter('临近截止', 'urgent')
                this.DdlFilter('已完成', 'completed')
              }
              ForEach(this.filteredDDLs(), (ddl: HomeworkDDL) => {
                  this.DDLItem(ddl)
                }, (ddl: HomeworkDDL) => ddl.id)
              }
            }.width('100%')
          }
        }
        .width('100%').padding({ left: 20, right: 20, top: 16, bottom: 40 })
      }
      .layoutWeight(1).align(Alignment.TopStart)

      AppBottomBar({ selected: 2 })
    }
    .width('100%').height('100%').backgroundColor(UiTheme.surface)
    }.width('100%').height('100%')
      .bindSheet($$this.ddlEditOpen, this.DdlEditor(), { height: SheetSize.FIT_CONTENT, title: { title: '编辑作业' }, showClose: true, backgroundColor: UiTheme.surface })
  }
}
