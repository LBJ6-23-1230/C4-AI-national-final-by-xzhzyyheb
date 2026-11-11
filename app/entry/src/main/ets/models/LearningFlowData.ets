
export interface DemoCard {
  title: string;
  description: string;
  badge: string;
  bullets: string[];
}

export interface DemoPage {
  title: string;
  subtitle: string;
  step: string;
  primaryAction: string;
  nextUrl: string;
  cards: DemoCard[];
}

export interface PageRoutes {
  hub: string;
  courseImport: string;
  studySuggestion: string;
  wrongQuestion: string;
  studyTags: string;
  partnerMatch: string;
  studyPlan: string;
  reviewSummary: string;
}

export const learningFlowPages: DemoPage[] = [
  {
    title: '课程感知 Agent',
    subtitle: 'Agent 感知你的课程、考试和作业，自动计算学习优先级',
    step: '0 / 8',
    primaryAction: '进入首页',
    nextUrl: 'pages/Index',
    cards: [
      {
        title: 'Agent 已感知 3 门课程',
        description: '数据结构、操作系统、高等数学的考试和作业已自动导入。',
        badge: '课程就绪',
        bullets: ['数据结构：7.20 考试（5天后）', '操作系统：7.28 考试（13天后）', '高等数学：8.5 考试（21天后）']
      }
    ]
  },
  {
    title: 'Agent 仪表盘',
    subtitle: 'Agent 主动理解学习环境，发现学习需求并主动提供帮助',
    step: '1 / 8',
    primaryAction: '查看今日建议',
    nextUrl: 'pages/StudyPlan',
    cards: [
      {
        title: '你好，我是小知',
        description: '你的主动助学 Agent。目标：数据结构期末 80+。',
        badge: 'Agent 就绪',
        bullets: ['空闲时间：20:00-22:00', '薄弱点：二叉树遍历、递归理解']
      }
    ]
  },
  {
    title: '今日学习建议',
    subtitle: '把模糊目标拆成今晚能完成的学习动作',
    step: '2 / 8',
    primaryAction: '上传错题并分析',
    nextUrl: 'pages/WrongQuestion',
    cards: []
  },
  {
    title: '错题理解 Agent',
    subtitle: '拍照上传错题，Agent 自动识别知识点、判断错误类型',
    step: '3 / 8',
    primaryAction: '生成学习标签',
    nextUrl: 'pages/StudyTags',
    cards: []
  },
  {
    title: '知识薄弱卡',
    subtitle: 'Agent 基于错题分析生成薄弱和优势标签',
    step: '4 / 8',
    primaryAction: '匹配学习搭子',
    nextUrl: 'pages/PartnerMatch',
    cards: []
  },
  {
    title: '伙伴匹配 Agent',
    subtitle: '基于课程一致·目标一致·知识互补·时间重合四大因子智能匹配',
    step: '5 / 8',
    primaryAction: '查看协同计划',
    nextUrl: 'pages/StudyPlan',
    cards: []
  },
  {
    title: '学习协同空间',
    subtitle: 'Agent 自动生成 30 分钟三阶段学习流程',
    step: '6 / 8',
    primaryAction: '完成学习 · 查看复盘',
    nextUrl: 'pages/ReviewSummary',
    cards: []
  },
  {
    title: '学习复盘',
    subtitle: 'Agent 总结今日学习成果，颁发徽章',
    step: '7 / 8',
    primaryAction: '返回首页',
    nextUrl: 'pages/Index',
    cards: []
  }
];

export const PAGE_ROUTES: PageRoutes = {
  hub: 'pages/Index',
  courseImport: 'pages/CourseImport',
  studySuggestion: 'pages/StudyPlan',
  wrongQuestion: 'pages/WrongQuestion',
  studyTags: 'pages/StudyTags',
  partnerMatch: 'pages/PartnerMatch',
  studyPlan: 'pages/StudyPlan',
  reviewSummary: 'pages/ReviewSummary'
};
