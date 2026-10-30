import { AgentApiClient } from '../api/AgentApiClient';
import { ApiFailure } from '../api/ApiResult';
import { LearningChanges, LearningSnapshot } from '../api/LearningSyncModels';
import { CourseInfo, HomeworkDDL } from '../models/AgentModels';

/** Explicit durable changes, not full-device replacement. One engine per identity. */
export class LearningSync {
  queue: LearningChanges[] = [];
  initialized: boolean = false;
  running: boolean = false;
  conflict: boolean = false;
  message: string = '';
  private courses: CourseInfo[] = [];
  private ddls: HomeworkDDL[] = [];
  private sequence: number = 0;
  private inFlight: Promise<LearningSnapshot | null> | null = null;

  restore(courses: CourseInfo[], ddls: HomeworkDDL[], queue: LearningChanges[], initialized: boolean): void {
    this.courses = JSON.parse(JSON.stringify(courses)) as CourseInfo[];
    this.ddls = JSON.parse(JSON.stringify(ddls)) as HomeworkDDL[];
    this.queue = queue;
    this.initialized = initialized;
    if (!initialized && queue.length === 0 && (courses.length > 0 || ddls.length > 0)) {
      this.queue.push({ courses: courses.slice(), homeworkDDLs: ddls.slice(), deletedCourses: [], deletedDDLs: [],
        idempotencyKey: this.key(), migration: true });
    }
  }
  private key(): string { return `learning-${Date.now()}-${Math.random().toString(36).slice(2)}-${++this.sequence}`; }

  capture(courses: CourseInfo[], ddls: HomeworkDDL[]): void {
    const change: LearningChanges = { courses: [], homeworkDDLs: [], deletedCourses: [], deletedDDLs: [],
      idempotencyKey: this.key(), migration: false };
    courses.forEach((item: CourseInfo) => {
      const old = this.courses.find((v: CourseInfo) => v.courseId === item.courseId);
      if (old !== undefined) item.syncVersion = old.syncVersion;
      if (JSON.stringify(item) !== JSON.stringify(old)) change.courses.push(JSON.parse(JSON.stringify(item)) as CourseInfo);
    });
    ddls.forEach((item: HomeworkDDL) => {
      const old = this.ddls.find((v: HomeworkDDL) => v.id === item.id);
      if (old !== undefined) item.syncVersion = old.syncVersion;
      if (JSON.stringify(item) !== JSON.stringify(old)) change.homeworkDDLs.push(JSON.parse(JSON.stringify(item)) as HomeworkDDL);
    });
    this.courses.filter((old: CourseInfo) => !courses.some((v: CourseInfo) => v.courseId === old.courseId))
      .forEach((old: CourseInfo) => change.deletedCourses.push({ id: old.courseId, expectedVersion: old.syncVersion ?? 0 }));
    this.ddls.filter((old: HomeworkDDL) => !ddls.some((v: HomeworkDDL) => v.id === old.id))
      .forEach((old: HomeworkDDL) => change.deletedDDLs.push({ id: old.id, expectedVersion: old.syncVersion ?? 0 }));
    if (change.courses.length + change.homeworkDDLs.length + change.deletedCourses.length + change.deletedDDLs.length > 0) this.queue.push(change);
    this.courses = JSON.parse(JSON.stringify(courses)) as CourseInfo[];
    this.ddls = JSON.parse(JSON.stringify(ddls)) as HomeworkDDL[];
  }

  private advance(snapshot: LearningSnapshot, sent: LearningChanges): void {
    this.courses.forEach((item: CourseInfo) => {
      if (sent.courses.some((v: CourseInfo) => v.courseId === item.courseId))
        item.syncVersion = snapshot.courses.find((v: CourseInfo) => v.courseId === item.courseId)?.syncVersion ?? item.syncVersion;
    });
    this.ddls.forEach((item: HomeworkDDL) => {
      if (sent.homeworkDDLs.some((v: HomeworkDDL) => v.id === item.id))
        item.syncVersion = snapshot.homeworkDDLs.find((v: HomeworkDDL) => v.id === item.id)?.syncVersion ?? item.syncVersion;
    });
    // Rebase ONLY subsequent edits to records changed by our acknowledged write.
    this.queue.forEach((change: LearningChanges) => {
      change.courses.forEach((item: CourseInfo) => {
        if (sent.courses.some((v: CourseInfo) => v.courseId === item.courseId))
          item.syncVersion = snapshot.courses.find((v: CourseInfo) => v.courseId === item.courseId)?.syncVersion ?? 0;
      });
      change.homeworkDDLs.forEach((item: HomeworkDDL) => {
        if (sent.homeworkDDLs.some((v: HomeworkDDL) => v.id === item.id))
          item.syncVersion = snapshot.homeworkDDLs.find((v: HomeworkDDL) => v.id === item.id)?.syncVersion ?? 0;
      });
      change.deletedCourses.forEach((item) => {
        if (sent.courses.some((v: CourseInfo) => v.courseId === item.id))
          item.expectedVersion = snapshot.courses.find((v: CourseInfo) => v.courseId === item.id)?.syncVersion ?? item.expectedVersion;
      });
      change.deletedDDLs.forEach((item) => {
        if (sent.homeworkDDLs.some((v: HomeworkDDL) => v.id === item.id))
          item.expectedVersion = snapshot.homeworkDDLs.find((v: HomeworkDDL) => v.id === item.id)?.syncVersion ?? item.expectedVersion;
      });
    });
  }
  accept(snapshot: LearningSnapshot): void {
    this.initialized = true;
    this.courses = JSON.parse(JSON.stringify(snapshot.courses)) as CourseInfo[];
    this.ddls = JSON.parse(JSON.stringify(snapshot.homeworkDDLs)) as HomeworkDDL[];
  }

  keepLocal(snapshot: LearningSnapshot): void {
    this.queue.forEach((change: LearningChanges) => {
      change.migration = false;
      change.idempotencyKey = this.key();
      change.courses.forEach((item: CourseInfo) => item.syncVersion =
        snapshot.courses.find((v: CourseInfo) => v.courseId === item.courseId)?.syncVersion ??
        snapshot.deletedCourses?.find((v) => v.id === item.courseId)?.expectedVersion ?? 0);
      change.homeworkDDLs.forEach((item: HomeworkDDL) => item.syncVersion =
        snapshot.homeworkDDLs.find((v: HomeworkDDL) => v.id === item.id)?.syncVersion ??
        snapshot.deletedDDLs?.find((v) => v.id === item.id)?.expectedVersion ?? 0);
      change.deletedCourses.forEach((item) => item.expectedVersion =
        snapshot.courses.find((v: CourseInfo) => v.courseId === item.id)?.syncVersion ??
        snapshot.deletedCourses?.find((v) => v.id === item.id)?.expectedVersion ?? 0);
      change.deletedDDLs.forEach((item) => item.expectedVersion =
        snapshot.homeworkDDLs.find((v: HomeworkDDL) => v.id === item.id)?.syncVersion ??
        snapshot.deletedDDLs?.find((v) => v.id === item.id)?.expectedVersion ?? 0);
    });
    this.conflict = false;
  }

  async sync(owner: string, isCurrent: () => boolean): Promise<LearningSnapshot | null> {
    if (this.inFlight !== null) return this.inFlight;
    const pending: Promise<LearningSnapshot | null> = this.run(owner, isCurrent);
    this.inFlight = pending;
    try { return await pending; }
    finally { if (this.inFlight === pending) this.inFlight = null; }
  }

  private async run(owner: string, isCurrent: () => boolean): Promise<LearningSnapshot | null> {
    if (this.running || this.conflict) return null;
    this.running = true;
    this.message = '正在同步课程与作业…';
    try {
      while (this.queue.length > 0) {
        if (!isCurrent()) return null;
        const sent: LearningChanges = this.queue[0];
        const result = await AgentApiClient.saveLearningData(sent);
        if (!isCurrent()) return null;
        if (!result.ok || result.data.userId !== owner) {
          this.conflict = !result.ok && (result as ApiFailure).error.statusCode === 409;
          this.message = this.conflict ? '其他设备有更新，请确认同步方式。' : '同步失败，本机修改已保留。';
          return null;
        }
        this.queue.shift();
        this.advance(result.data, sent);
      }
      if (!isCurrent()) return null;
      const latest = await AgentApiClient.getLearningData();
      if (!isCurrent()) return null;
      if (!latest.ok || latest.data.userId !== owner) { this.message = '同步失败，请重试。'; return null; }
      this.message = '课程与作业已同步';
      return latest.data;
    } finally { this.running = false; }
  }
}
