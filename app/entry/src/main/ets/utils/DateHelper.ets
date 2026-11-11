export interface WeekDay {
  index: number;
  dateStr: string;
  monthDay: string;
  dayOfWeek: string;
  fullLabel: string;
  shortLabel: string;
  isToday: boolean;
  isWeekend: boolean;
}

const WEEK_DAY_NAMES: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

export class DateHelper {
  static getWeekDays(): WeekDay[] {
    const today: Date = new Date();
    const result: WeekDay[] = [];

    for (let i: number = 0; i < 7; i++) {
      const date: Date = new Date(today.getFullYear(), today.getMonth(), today.getDate() + i);
      const month: number = date.getMonth() + 1;
      const day: number = date.getDate();
      const dayOfWeekIndex: number = date.getDay();
      const dayOfWeek: string = WEEK_DAY_NAMES[dayOfWeekIndex];
      const isWeekend: boolean = dayOfWeekIndex === 0 || dayOfWeekIndex === 6;
      const dateStr: string = `${date.getFullYear()}-${DateHelper.pad(month)}-${DateHelper.pad(day)}`;

      result.push({
        index: i,
        dateStr: dateStr,
        monthDay: `${month}月${day}日`,
        dayOfWeek: dayOfWeek,
        fullLabel: `${month}月${day}日 ${dayOfWeek}`,
        shortLabel: `${month}/${day} ${dayOfWeek}`,
        isToday: i === 0,
        isWeekend: isWeekend
      });
    }
    return result;
  }

  static getTodayLabel(): string {
    const today: Date = new Date();
    const month: number = today.getMonth() + 1;
    const day: number = today.getDate();
    return `${month}月${day}日`;
  }

  static getTodayDateStr(): string {
    const today: Date = new Date();
    const month: number = today.getMonth() + 1;
    const day: number = today.getDate();
    return `${today.getFullYear()}-${DateHelper.pad(month)}-${DateHelper.pad(day)}`;
  }

  static mapLegacyLabel(label: string, weekDays: WeekDay[]): string {
    if (label === '今天') {
      return weekDays[0].fullLabel;
    }
    if (label === '明天') {
      return weekDays[1].fullLabel;
    }
    if (label === '后天') {
      return weekDays[2].fullLabel;
    }
    if (label === '周末' || label === '本周末') {
      for (let i: number = 0; i < weekDays.length; i++) {
        if (weekDays[i].isWeekend && i >= 2) {
          return weekDays[i].fullLabel;
        }
      }
      return weekDays[6].fullLabel;
    }
    return label;
  }

  static pad(num: number): string {
    return num < 10 ? `0${num}` : `${num}`;
  }

  static localDateKey(isoLike: string): string {
    const date: Date = new Date(isoLike);
    if (isNaN(date.getTime())) {
      return '';
    }
    return `${date.getFullYear()}-${DateHelper.pad(date.getMonth() + 1)}-${DateHelper.pad(date.getDate())}`;
  }

  static todayKey(): string {
    return DateHelper.localDateKey(new Date().toISOString());
  }

  static getTodayDayOfWeek(): string {
    const today: Date = new Date();
    return WEEK_DAY_NAMES[today.getDay()];
  }

  static getWeekRangeLabel(): string {
    const weekDays: WeekDay[] = DateHelper.getWeekDays();
    return `${weekDays[0].monthDay} - ${weekDays[6].monthDay}`;
  }

  static getDayOfWeekByDate(dateStr: string): string {
    const date: Date = new Date(dateStr);
    if (isNaN(date.getTime())) {
      return '';
    }
    return WEEK_DAY_NAMES[date.getDay()];
  }

  static formatDueDate(dueDateStr: string): string {
    const dueDate: Date = new Date(dueDateStr);
    if (isNaN(dueDate.getTime())) {
      return dueDateStr;
    }
    const month: number = dueDate.getMonth() + 1;
    const day: number = dueDate.getDate();
    const dayOfWeek: string = WEEK_DAY_NAMES[dueDate.getDay()];
    return `${month}月${day}日 ${dayOfWeek}`;
  }

  static calculateDaysLeft(dueDateStr: string): number {
    const today: Date = new Date();
    today.setHours(0, 0, 0, 0);
    const dueDate: Date = new Date(dueDateStr);
    dueDate.setHours(0, 0, 0, 0);
    const diffTime: number = dueDate.getTime() - today.getTime();
    return Math.ceil(diffTime / (1000 * 60 * 60 * 24));
  }
}
