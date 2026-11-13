import { ChatFile } from '../api/StudyTaskModels';
import { AgentHistoryItem, AgentRequest, AgentResponse, ChatAction, ChatBasicInfoUpdate, ChatCard, ChatCardType, ChatCourseUpdate, ChatExamUpdate, ChatHistoryRecord, ChatIntent, ChatKnowledgeUpdate, ChatLearningGoalUpdate, ChatMessage, ChatProfileUpdates, ChatRecentStatusUpdate, ChatTaskUpdate, ChatTimeUpdate, ChatUserUpdate, WrongAnalysis } from '../models/ChatModels';
import { http } from '@kit.NetworkKit';
import { appState } from '../data/AppState';
import { AgentApiClient, ApiClientConfig } from '../api/AgentApiClient';
import { API_CONTRACT_VERSION } from '../api/ApiModels';
import { ApiDefaults } from '../api/ApiDefaults';
import { AuthStore } from '../api/AuthStore';
import { LearningContext } from '../api/ApiModels';
import { ApiResponseValidator } from '../api/ApiResponseValidator';
import { util } from '@kit.ArkTS';
import { ChatEventParser, ChatProgress } from './ChatEventParser';

interface IntentRule {
  intent: ChatIntent;
  keywords: string[];
}

const INTENT_RULES: IntentRule[] = [
  { intent: 'match_partner', keywords: ['搭子', '匹配', '伙伴', '搭档', '一起学', '组队', '找个人'] },
  { intent: 'analyze_wrong', keywords: ['这道题', '错题', '为什么错', '图片', '拍照', '错了', '不会做'] },
  { intent: 'update_profile', keywords: ['添加', '设置', '修改', '更新', '删除', '记录', '我掌握了', '学会了'] },
  { intent: 'query_tasks', keywords: ['任务', '作业', 'ddl', '待办', '要交', '有什么', '安排'] },
  { intent: 'get_suggestion', keywords: ['建议', '推荐', '学什么', '计划', '复习', '优先', '今天'] },
  { intent: 'analyze_weakness', keywords: ['薄弱', '短板', '诊断', '弱', '查漏补缺', '哪里不好', '没掌握'] },
];

const CODE_INVALID_RESPONSE: string = 'INVALID_RESPONSE';
const CODE_EMPTY_RESPONSE: string = 'EMPTY_RESPONSE';
const CODE_HTTP_ERROR: string = 'HTTP_ERROR';
const CODE_SEPARATOR: string = '::';

const CHAT_MIN_READ_TIMEOUT_MS: number = ApiDefaults.LLM_BOUND_READ_TIMEOUT_MS;

export class AgentBridge {
  static async loadHistory(): Promise<ChatHistoryRecord[]> {
    const apiConfig: ApiClientConfig = AgentApiClient.getConfig();
    if (apiConfig.useFixture) return [];
    const requestInstance: http.HttpRequest = http.createHttp();
    try {
      const header: Record<string, string> = {
        'Accept': 'application/json',
        'X-API-Contract-Version': API_CONTRACT_VERSION
      };
      const token: string = AuthStore.getToken();
      if (token.length > 0) header['Authorization'] = `Bearer ${token}`;
      const userId: string = encodeURIComponent(appState.currentUser.userId);
      const response: http.HttpResponse = await requestInstance.request(
        `${apiConfig.baseUrl}/api/agent/history?userId=${userId}`, AgentApiClient.prepareBackendRequest(apiConfig.baseUrl, {
          method: http.RequestMethod.GET,
          header: header,
          expectDataType: http.HttpDataType.STRING,
          connectTimeout: apiConfig.timeoutMs,
          readTimeout: apiConfig.timeoutMs
        }));
      if (response.responseCode < 200 || response.responseCode >= 300) return [];
      const root: Record<string, Object> = JSON.parse(response.result as string) as Record<string, Object>;
      const rawHistory: Object | undefined = root['history'];
      if (!Array.isArray(rawHistory)) return [];
      const records: ChatHistoryRecord[] = [];
      for (let i: number = 0; i < rawHistory.length; i++) {
        const raw: Object = rawHistory[i] as Object;
        if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) continue;
        const row: Record<string, Object> = raw as Record<string, Object>;
        const userInput: string = AgentBridge.stringField(row, 'user_input');
        const botResponse: string = AgentBridge.stringField(row, 'bot_response');
        const timestamp: string = AgentBridge.stringField(row, 'timestamp');
        const sessionId: string = AgentBridge.stringField(row, 'session_id');
        if (userInput.length > 0 && botResponse.length > 0) {
          records.push({ userInput: userInput, botResponse: botResponse,
            timestamp: timestamp, sessionId: sessionId,
            image: AgentBridge.stringField(row, 'image_preview'),
            imageFileId: AgentBridge.stringField(row, 'image_file_id') });
        }
      }
      return records.reverse();
    } catch (error) {
      return [];
    } finally {
      requestInstance.destroy();
    }
  }

  static async loadChatImage(fileId: string): Promise<string> {
    const config: ApiClientConfig = AgentApiClient.getConfig();
    const requestInstance: http.HttpRequest = http.createHttp();
    try {
      const header: Record<string, string> = { 'Accept': 'application/json',
        'X-API-Contract-Version': API_CONTRACT_VERSION };
      const token: string = AuthStore.getToken();
      if (token.length > 0) header['Authorization'] = `Bearer ${token}`;
      const response: http.HttpResponse = await requestInstance.request(
        `${config.baseUrl}/api/agent/images/${encodeURIComponent(fileId)}?userId=${encodeURIComponent(appState.currentUser.userId)}`,
        AgentApiClient.prepareBackendRequest(config.baseUrl, {
          method: http.RequestMethod.GET, header: header,
          expectDataType: http.HttpDataType.STRING,
          connectTimeout: config.timeoutMs, readTimeout: config.timeoutMs
        }));
      if (response.responseCode !== 200) return '';
      const body: Record<string, Object> = JSON.parse(response.result as string) as Record<string, Object>;
      const image: string = AgentBridge.stringField(body, 'image');
      return image.startsWith('data:image/') ? image : '';
    } catch (error) {
      return '';
    } finally {
      requestInstance.destroy();
    }
  }

  static matchIntentLocal(message: string): ChatIntent {
    const normalized: string = message.trim().toLowerCase();
    for (let i: number = 0; i < INTENT_RULES.length; i++) {
      const rule: IntentRule = INTENT_RULES[i];
      for (let j: number = 0; j < rule.keywords.length; j++) {
        if (normalized.indexOf(rule.keywords[j]) !== -1) {
          return rule.intent;
        }
      }
    }
    return 'get_suggestion';
  }

  static buildRequest(message: string, image: string | undefined, history: ChatMessage[]): AgentRequest {
    const doneHistory: ChatMessage[] = history
      .filter((item: ChatMessage) => item.status === 'done');
    const lastIndex: number = doneHistory.length - 1;
    const echoOfCurrent: boolean = lastIndex >= 0 &&
      doneHistory[lastIndex].role === 'user' && doneHistory[lastIndex].text === message;
    const withoutEcho: ChatMessage[] = echoOfCurrent ? doneHistory.slice(0, lastIndex) : doneHistory;
    const latestHistory: ChatMessage[] = withoutEcho.slice(-20);
    const mappedHistory: AgentHistoryItem[] = [];
    for (let i: number = 0; i < latestHistory.length; i++) {
      const item: ChatMessage = latestHistory[i];
      mappedHistory.push({ role: item.role, text: item.text });
    }

    const request: AgentRequest = {
      message: message,
      image: image,
      history: mappedHistory
    };
    return request;
  }

  static ensureChatSessionId(): string {
    const current: string = (appState.chatSessionId || '').trim();
    if (current.length > 0 && current.length <= 128) {
      appState.chatSessionId = current;
      return current;
    }
    const created: string = `chat-${Date.now()}-${Math.random().toString(36).slice(2, 14)}`;
    appState.chatSessionId = created;
    return created;
  }

  static buildRequestBody(message: string, image: string, history: AgentHistoryItem[], document?: ChatFile): string {
    const sessionId: string = AgentBridge.ensureChatSessionId();
    const userDataObj: Record<string, Object> = {};
    userDataObj['courses'] = appState.courses;
    userDataObj['homeworkDDLs'] = appState.homeworkDDLs;
    userDataObj['isDataImported'] = appState.isDataImported;
    const userDataStr: string = JSON.stringify(userDataObj);

    const parts: string[] = [];
    parts.push('"message":' + JSON.stringify(message));
    parts.push('"image":' + JSON.stringify(image));
    parts.push('"history":' + JSON.stringify(history));
    parts.push('"user_data":' + userDataStr);
    parts.push('"userId":' + JSON.stringify(appState.currentUser.userId));
    parts.push('"sessionId":' + JSON.stringify(sessionId));
    if (document !== undefined) parts.push('"document":' + JSON.stringify(document));
    parts.push('"coordinateLearning":true');
    return '{' + parts.join(',') + '}';
  }

  static async callAgent(
    message: string,
    image: string | undefined,
    history: ChatMessage[],
    onProgress?: (event: ChatProgress) => void,
    document?: ChatFile
  ): Promise<AgentResponse> {
    const request: AgentRequest = AgentBridge.buildRequest(message, image, history);
    const imageStr: string = image ?? '';
    const apiConfig: ApiClientConfig = AgentApiClient.getConfig();

    if (apiConfig.useFixture) {
      if (document !== undefined) return { reply: `已读取《${document.fileName}》的正文。离线演示无法生成文件问答，请连接服务后继续提问。\n正文片段：${document.text.slice(0, 300)}`, intent: 'unknown', llmUsed: false };
      return AgentBridge.createDemoResponse(message, image);
    }

    const httpRequestInstance: http.HttpRequest = http.createHttp();
    let streamDeadline: number = -1;
    try {
      const requestBody: string = AgentBridge.buildRequestBody(request.message, imageStr, request.history, document);

      const header: Record<string, string> = {
        'Accept': onProgress !== undefined ? 'text/event-stream' : 'application/json',
        'Content-Type': 'application/json',
        'X-API-Contract-Version': API_CONTRACT_VERSION
      };
      const token: string = AuthStore.getToken();
      if (token.length > 0) {
        header['Authorization'] = `Bearer ${token}`;
      }
      const readTimeoutMs: number = Math.max(apiConfig.timeoutMs,
        imageStr.length > 0 ? ApiDefaults.VISION_READ_TIMEOUT_MS :
          onProgress !== undefined ? ApiDefaults.CHAT_STREAM_READ_TIMEOUT_MS : CHAT_MIN_READ_TIMEOUT_MS);
      const httpRequest: http.HttpRequestOptions = AgentApiClient.prepareBackendRequest(apiConfig.baseUrl, {
        method: http.RequestMethod.POST,
        header: header,
        extraData: requestBody,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: apiConfig.timeoutMs,
        readTimeout: readTimeoutMs
      });
      if (onProgress !== undefined) {
        const parser: ChatEventParser = new ChatEventParser(onProgress);
        const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
        let streamError: string = '';
        const bodyEnded: Promise<void> = new Promise<void>((resolve) => {
          httpRequestInstance.on('dataEnd', () => resolve());
        });
        httpRequestInstance.on('dataReceive', (bytes: ArrayBuffer) => {
          if (streamError.length > 0) return;
          try {
            parser.feed(decoder.decodeToString(new Uint8Array(bytes), { stream: true }));
          } catch (error) {
            streamError = 'INVALID_RESPONSE::服务返回了无法解析的进度数据';
          }
        });
        const completed: Promise<number> = httpRequestInstance.requestInStream(
          apiConfig.baseUrl + '/api/agent/chat', httpRequest).then(async (status: number): Promise<number> => {
          await bodyEnded;
          return status;
        });
        const deadline: Promise<number> = new Promise<number>((resolve, reject) => {
          streamDeadline = setTimeout(() => reject(new Error(
            'HTTP_ERROR::等待回复超时，尚未收到完整结果，请查看会话记录后再重试')),
            readTimeoutMs + apiConfig.timeoutMs);
        });
        const status: number = await Promise.race([completed, deadline]);
        if (streamError.length > 0) throw new Error(streamError);
        parser.feed(decoder.decodeToString(new Uint8Array(0)));
        try {
          return AgentBridge.parseResponse(parser.finish(status));
        } catch (error) {
          const detail: string = error instanceof Error ? error.message : '';
          if (AgentBridge.errorCodeOf(detail).length > 0) throw new Error(detail);
          throw AgentBridge.taggedError(CODE_INVALID_RESPONSE, '服务返回的最终结果不符合接口约定');
        }
      }
      const httpResponse: http.HttpResponse =
        await httpRequestInstance.request(apiConfig.baseUrl + '/api/agent/chat', httpRequest);

      if (httpResponse.responseCode >= 200 && httpResponse.responseCode < 300) {
        const resultStr: string = (httpResponse.result as string).trim();
        if (resultStr.length === 0) {
          throw AgentBridge.taggedError(CODE_EMPTY_RESPONSE, '服务未返回可解析的数据。');
        }
        try {
          const data: Record<string, Object> = JSON.parse(resultStr) as Record<string, Object>;
          return AgentBridge.parseResponse(data);
        } catch (parseError) {
          const parseDetail: string = parseError instanceof Error ? parseError.message : '';
          const contractDetail: string = parseDetail.length > 0 ? parseDetail : '响应内容无法解析';
          throw AgentBridge.taggedError(CODE_INVALID_RESPONSE, `服务响应不符合接口约定：${contractDetail}`);
        }
      }
      const serverFailure = AgentApiClient.parseServerError(httpResponse.result as string, httpResponse.responseCode);
      throw AgentBridge.taggedError(CODE_HTTP_ERROR, `服务请求失败：${serverFailure.error.message}`);
    } catch (err) {
      const detail: string = err instanceof Error ? err.message : '';
      const code: string = AgentBridge.errorCodeOf(detail);
      const reason: string = AgentBridge.errorTextOf(detail);
      if (code === CODE_INVALID_RESPONSE) {
        throw new Error(`${reason}（这不是网络问题，重试不会好转，请检查服务端返回结构）`);
      }
      if (code === CODE_EMPTY_RESPONSE) {
        throw new Error(`${reason}（这不是网络问题，请检查服务端是否真的返回了 JSON）`);
      }
      if (code.length > 0) {
        throw new Error(reason);
      }
      throw new Error('请求超时或连不上后端服务。请确认「接口环境」里的服务地址可访问；'
        + '使用真实大模型时生成较慢，也可能需要重试一次。');
    } finally {
      if (streamDeadline !== -1) clearTimeout(streamDeadline);
      httpRequestInstance.destroy();
    }
  }

  private static taggedError(code: string, message: string): Error {
    return new Error(`${code}${CODE_SEPARATOR}${message}`);
  }

  private static errorCodeOf(detail: string): string {
    const separator: number = detail.indexOf(CODE_SEPARATOR);
    return separator > 0 ? detail.substring(0, separator) : '';
  }

  private static errorTextOf(detail: string): string {
    const separator: number = detail.indexOf(CODE_SEPARATOR);
    return separator > 0 ? detail.substring(separator + CODE_SEPARATOR.length) : detail;
  }

  static parseResponse(data: Record<string, Object>): AgentResponse {
    const reply: string = AgentBridge.requiredString(data, 'reply');
    const intent: string = AgentBridge.normalizeIntent(
      AgentBridge.requiredString(data, 'intent'));
    const cardObj: Object | undefined = data['card'] as Object | undefined;
    const rawLlmUsed: Object | undefined = data['llmUsed'] as Object | undefined;

    let card: ChatCard | undefined = undefined;
    if (cardObj !== undefined && cardObj !== null) {
      if (typeof cardObj !== 'object' || Array.isArray(cardObj)) {
        throw new Error('card must be an object.');
      }
      card = AgentBridge.parseCard(cardObj as Record<string, Object>);
    }

    let llmUsed: boolean | undefined = undefined;
    if (rawLlmUsed !== undefined && rawLlmUsed !== null) {
      if (typeof rawLlmUsed !== 'boolean') {
        throw new Error('llmUsed must be a boolean.');
      }
      llmUsed = rawLlmUsed as boolean;
    }

    const wrongAnalysis: WrongAnalysis | undefined = AgentBridge.parseWrongAnalysis(data['wrongAnalysis']);

    const profileUpdates: ChatProfileUpdates | undefined = AgentBridge.parseProfileUpdates(data);
    const learningContext: LearningContext | undefined = AgentBridge.parseLearningContext(data['learningContext']);

    return { reply: reply, intent: intent, card: card, llmUsed: llmUsed,
      profileUpdates: profileUpdates, wrongAnalysis: wrongAnalysis, learningContext: learningContext,
      attachmentStatus: data['attachmentReceipt'] !== undefined && typeof data['attachmentReceipt'] === 'object'
        ? AgentBridge.stringField(data['attachmentReceipt'] as Record<string, Object>, 'message') : undefined };
  }

  private static parseWrongAnalysis(raw: Object | undefined, includeQuestions: boolean = true): WrongAnalysis | undefined {
    if (raw === undefined || raw === null || typeof raw !== 'object' || Array.isArray(raw)) return undefined;
    const record: Record<string, Object> = raw as Record<string, Object>;
    const questions: WrongAnalysis[] = [];
    const rawQuestions: Object | undefined = record['questions'];
    if (includeQuestions && Array.isArray(rawQuestions)) {
      (rawQuestions as Object[]).forEach((item: Object) => {
        const question: WrongAnalysis | undefined = AgentBridge.parseWrongAnalysis(item, false);
        if (question !== undefined) questions.push(question);
      });
    }
    if (questions.length === 0 && AgentBridge.stringField(record, 'questionText').length === 0
      && AgentBridge.stringField(record, 'knowledgePoint').length === 0
      && AgentBridge.stringField(record, 'recognitionStatus').length === 0
      && AgentBridge.stringField(record, 'wrongType').length === 0) return undefined;
    return { courseName: AgentBridge.stringField(record, 'courseName'), knowledgePoint: AgentBridge.stringField(record, 'knowledgePoint'),
      answer: AgentBridge.stringField(record, 'answer') || AgentBridge.stringField(record, 'correctAnswer'),
      explanation: AgentBridge.stringField(record, 'explanation') || AgentBridge.stringField(record, 'solution'),
      reason: AgentBridge.stringField(record, 'reason'),
      wrongType: AgentBridge.stringField(record, 'wrongType'),
      diagnosisId: AgentBridge.stringField(record, 'diagnosisId'),
      questionText: AgentBridge.stringField(record, 'questionText'),
      questionNumber: AgentBridge.stringField(record, 'questionNumber'),
      reply: AgentBridge.stringField(record, 'reply'),
      recognitionStatus: AgentBridge.stringField(record, 'recognitionStatus'),
      complete: record['complete'] === true,
      questionCount: typeof record['questionCount'] === 'number' ? record['questionCount'] as number : questions.length,
      questions: includeQuestions && Array.isArray(rawQuestions) ? questions : undefined };
  }

  private static parseLearningContext(raw: Object | undefined): LearningContext | undefined {
    if (raw === undefined || !ApiResponseValidator.isLearningContext(raw)) return undefined;
    return raw as LearningContext;
  }

  private static parseProfileUpdates(data: Record<string, Object>): ChatProfileUpdates | undefined {
    const raw: Object | undefined = data['profileUpdates'] as Object | undefined;
    if (raw === undefined || raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
      return undefined;
    }
    const record: Record<string, Object> = raw as Record<string, Object>;
    const result: ChatProfileUpdates = {};

    const rawCourses: Object | undefined = record['course'] as Object | undefined;
    if (Array.isArray(rawCourses)) {
      const courses: ChatCourseUpdate[] = [];
      for (let index: number = 0; index < rawCourses.length; index++) {
        const rawCourse: Object = rawCourses[index] as Object;
        if (rawCourse === null || typeof rawCourse !== 'object' || Array.isArray(rawCourse)) continue;
        const courseRecord: Record<string, Object> = rawCourse as Record<string, Object>;
        const course: ChatCourseUpdate = {};
        course.courseId = AgentBridge.optionalString(courseRecord, 'courseId');
        course.courseName = AgentBridge.optionalString(courseRecord, 'courseName');
        course.priority = AgentBridge.optionalString(courseRecord, 'priority');

        const rawExam: Object | undefined = courseRecord['exam'] as Object | undefined;
        if (rawExam !== undefined && rawExam !== null && typeof rawExam === 'object' && !Array.isArray(rawExam)) {
          const exam: ChatExamUpdate = { date: AgentBridge.optionalString(rawExam as Record<string, Object>, 'date') };
          course.exam = exam;
        }
        const rawRecent: Object | undefined = courseRecord['recentStatus'] as Object | undefined;
        if (rawRecent !== undefined && rawRecent !== null && typeof rawRecent === 'object' && !Array.isArray(rawRecent)) {
          const recentRecord: Record<string, Object> = rawRecent as Record<string, Object>;
          const recent: ChatRecentStatusUpdate = {
            studyHours: AgentBridge.optionalNumber(recentRecord, 'studyHours'),
            status: AgentBridge.optionalString(recentRecord, 'status')
          };
          course.recentStatus = recent;
        }
        const rawTasks: Object | undefined = courseRecord['tasks'] as Object | undefined;
        if (Array.isArray(rawTasks)) {
          const tasks: ChatTaskUpdate[] = [];
          for (let taskIndex: number = 0; taskIndex < rawTasks.length; taskIndex++) {
            const rawTask: Object = rawTasks[taskIndex] as Object;
            if (rawTask === null || typeof rawTask !== 'object' || Array.isArray(rawTask)) continue;
            const taskRecord: Record<string, Object> = rawTask as Record<string, Object>;
            const task: ChatTaskUpdate = {
              taskname: AgentBridge.optionalString(taskRecord, 'taskname'),
              taskType: AgentBridge.optionalString(taskRecord, 'taskType'),
              deadline: AgentBridge.optionalString(taskRecord, 'deadline'),
              taskStatus: AgentBridge.optionalString(taskRecord, 'taskStatus'),
              estimatedMinutes: AgentBridge.optionalNumber(taskRecord, 'estimatedMinutes')
            };
            if ((task.taskname ?? '').length > 0) tasks.push(task);
          }
          course.tasks = tasks;
        }
        if ((course.courseId ?? '').length > 0 || (course.courseName ?? '').length > 0) courses.push(course);
      }
      result.course = courses;
    }

    const rawUser: Object | undefined = record['user'] as Object | undefined;
    if (rawUser !== undefined && rawUser !== null && typeof rawUser === 'object' && !Array.isArray(rawUser)) {
      const userRecord: Record<string, Object> = rawUser as Record<string, Object>;
      const user: ChatUserUpdate = {};
      const rawBasic: Object | undefined = userRecord['basicInfo'] as Object | undefined;
      if (rawBasic !== undefined && rawBasic !== null && typeof rawBasic === 'object' && !Array.isArray(rawBasic)) {
        const basicRecord: Record<string, Object> = rawBasic as Record<string, Object>;
        const basic: ChatBasicInfoUpdate = {
          name: AgentBridge.optionalString(basicRecord, 'name'),
          grade: AgentBridge.optionalString(basicRecord, 'grade'),
          major: AgentBridge.optionalString(basicRecord, 'major')
        };
        user.basicInfo = basic;
      }
      const rawGoal: Object | undefined = userRecord['learningGoal'] as Object | undefined;
      if (rawGoal !== undefined && rawGoal !== null && typeof rawGoal === 'object' && !Array.isArray(rawGoal)) {
        const goalRecord: Record<string, Object> = rawGoal as Record<string, Object>;
        const goal: ChatLearningGoalUpdate = {
          course: AgentBridge.optionalString(goalRecord, 'course'),
          goal: AgentBridge.optionalString(goalRecord, 'goal')
        };
        user.learningGoal = goal;
      }
      const rawTime: Object | undefined = userRecord['time'] as Object | undefined;
      if (rawTime !== undefined && rawTime !== null && typeof rawTime === 'object' && !Array.isArray(rawTime)) {
        const timeRecord: Record<string, Object> = rawTime as Record<string, Object>;
        const time: ChatTimeUpdate = { freeTime: AgentBridge.optionalStringArray(timeRecord, 'freeTime') };
        user.time = time;
      }
      const rawKnowledge: Object | undefined = userRecord['knowledge'] as Object | undefined;
      if (rawKnowledge !== undefined && rawKnowledge !== null && typeof rawKnowledge === 'object'
        && !Array.isArray(rawKnowledge)) {
        const knowledgeRecord: Record<string, Object> = rawKnowledge as Record<string, Object>;
        const knowledge: ChatKnowledgeUpdate = {
          weakness: AgentBridge.optionalStringArray(knowledgeRecord, 'weakness'),
          strength: AgentBridge.optionalStringArray(knowledgeRecord, 'strength')
        };
        user.knowledge = knowledge;
      }
      result.user = user;
    }
    return result.course !== undefined || result.user !== undefined ? result : undefined;
  }

  private static optionalString(data: Record<string, Object>, key: string): string | undefined {
    const value: Object | undefined = data[key] as Object | undefined;
    return typeof value === 'string' ? value as string : undefined;
  }

  private static optionalNumber(data: Record<string, Object>, key: string): number | undefined {
    const value: Object | undefined = data[key] as Object | undefined;
    return typeof value === 'number' && Number.isFinite(value as number) ? value as number : undefined;
  }

  private static optionalStringArray(data: Record<string, Object>, key: string): string[] | undefined {
    const value: Object | undefined = data[key] as Object | undefined;
    if (!Array.isArray(value)) return undefined;
    const result: string[] = [];
    for (let index: number = 0; index < value.length; index++) {
      if (typeof value[index] === 'string' && (value[index] as string).trim().length > 0) {
        result.push((value[index] as string).trim());
      }
    }
    return result;
  }

  static parseCard(cardObj: Record<string, Object>): ChatCard {
    const rawCardType: string = AgentBridge.requiredString(cardObj, 'type');
    const cardType: ChatCardType = AgentBridge.normalizeCardType(rawCardType);
    const title: string = AgentBridge.stringField(cardObj, 'title');
    const summary: string = AgentBridge.stringField(cardObj, 'summary');
    const rawTargetPage: string = AgentBridge.requiredString(cardObj, 'targetPage');
    const targetPage: string = AgentBridge.safeTargetPage(cardType, rawTargetPage);
    const dataMap: Map<string, string> = new Map<string, string>();

    const backendActionLabel: string = AgentBridge.stringField(cardObj, 'actionLabel');
    const actionLabel: string = backendActionLabel.length > 0 ? backendActionLabel : AgentBridge.getActionLabel(cardType);
    const action: ChatAction = { label: actionLabel, targetPage: targetPage };
    const actions: ChatAction[] = [action];

    return { type: cardType, title: title, summary: summary, targetPage: targetPage, data: dataMap, actions: actions };
  }

  private static requiredString(data: Record<string, Object>, key: string): string {
    const value: Object | undefined = data[key] as Object | undefined;
    if (typeof value !== 'string' || (value as string).trim().length === 0) {
      throw new Error(`${key} must be a non-empty string.`);
    }
    return value as string;
  }

  private static stringField(data: Record<string, Object>, key: string): string {
    const value: Object | undefined = data[key] as Object | undefined;
    if (value === undefined || value === null) {
      return '';
    }
    if (typeof value !== 'string') {
      throw new Error(`${key} must be a string.`);
    }
    return value as string;
  }

  private static normalizeIntent(intent: string): ChatIntent {
    if (intent === 'query_tasks' || intent === 'analyze_weakness' ||
      intent === 'get_suggestion' || intent === 'match_partner' ||
      intent === 'analyze_wrong' || intent === 'update_profile' ||
      intent === 'free_chat' || intent === 'unknown') {
      return intent as ChatIntent;
    }
    return 'unknown';
  }

  private static normalizeCardType(cardType: string): ChatCardType {
    if (cardType === 'analyze_weakness') return 'weakness';
    if (cardType === 'match_partner') return 'partner';
    if (cardType === 'query_tasks') return 'tasks';
    if (cardType === 'analyze_wrong') return 'wrong';
    if (cardType === 'get_suggestion' || cardType === 'update_profile') return 'suggestion';
    if (cardType === 'weakness' || cardType === 'partner' || cardType === 'tasks' ||
      cardType === 'wrong' || cardType === 'suggestion') {
      return cardType as ChatCardType;
    }
    return 'suggestion';
  }

  private static safeTargetPage(cardType: ChatCardType, targetPage: string): string {
    const safePages: string[] = [
      'pages/Index', 'pages/StudyPlan', 'pages/WrongQuestion', 'pages/StudyTags',
      'pages/ExercisePractice', 'pages/AgentTrace', 'pages/PartnerMatch', 'pages/StudyPlan',
      'pages/ReviewSummary', 'pages/FocusSetup'
    ];
    if (safePages.indexOf(targetPage) >= 0) {
      return targetPage;
    }
    if (cardType === 'weakness') return 'pages/StudyTags';
    if (cardType === 'profile') return 'pages/StudyTags';
    if (cardType === 'partner') return 'pages/PartnerMatch';
    if (cardType === 'wrong') return 'pages/WrongQuestion';
    if (cardType === 'tasks') return 'pages/StudyPlan';
    return 'pages/StudyPlan';
  }

  static getActionLabel(cardType: string): string {
    if (cardType === 'weakness') { return '查看学情画像'; }
    if (cardType === 'profile') { return '查看更新后的画像'; }
    if (cardType === 'partner') { return '查看学习搭子'; }
    if (cardType === 'tasks') { return '查看今日任务'; }
    if (cardType === 'wrong') { return '查看错题诊断'; }
    return '查看今日学习建议';
  }

  static createDemoResponse(message: string, image: string | undefined): AgentResponse {
    const intent: ChatIntent = AgentBridge.matchIntentLocal(message);

    if (image !== undefined && image.length > 0) {
      return {
        reply: '图片已收到。你可以进入错题分析页，查看识别出的知识点、错误类型和补强建议。',
        intent: 'analyze_wrong',
        card: AgentBridge.createLocalCard('wrong', '错题分析', '基于题目内容识别知识点和错误原因。', 'pages/WrongQuestion'),
        llmUsed: false
      };
    }

    const replyMap: Map<ChatIntent, string> = new Map<ChatIntent, string>();
    replyMap.set('query_tasks', '我已按当前课程与作业 DDL 整理出今日任务，可以打开学习计划查看优先级。');
    replyMap.set('analyze_weakness', '我已读取当前学情画像，你可以查看薄弱知识点、掌握度和学习证据。');
    replyMap.set('get_suggestion', '我已按课程紧迫度、近期复习状态与薄弱点算好今日学习建议，先从最高优先级任务开始。');
    replyMap.set('match_partner', '我已按课程、目标、知识互补与空闲时间完成学习搭子匹配，可以查看匹配因子明细。');
    replyMap.set('analyze_wrong', '请上传或选择一道错题，我会展示知识点、错误原因和补强建议。');
    replyMap.set('update_profile', '离线演示下画像由诊断练习自动更新：去「练习智能体」做一组专项题，掌握度会随之变化。');
    replyMap.set('free_chat', '你可以问我今日学习建议、学情画像、今日任务或学习搭子，也可以上传错题。');
    replyMap.set('unknown', '你可以问我今日学习建议、学情画像、今日任务或学习搭子，也可以上传错题。');

    const defaultReply: string = '你可以问我今日学习建议、学情画像、今日任务或学习搭子。';
    const foundReply: string | undefined = replyMap.get(intent);

    return {
      reply: foundReply !== undefined ? foundReply : defaultReply,
      intent: intent,
      card: AgentBridge.createLocalCardForIntent(intent),
      llmUsed: false
    };
  }

  static createLocalCardForIntent(intent: ChatIntent): ChatCard | undefined {
    if (intent === 'get_suggestion') {
      return AgentBridge.createLocalCard('suggestion', '今日学习建议',
        '按课程紧迫度、近期复习状态与薄弱点算出的下一步动作。', 'pages/StudyPlan');
    }
    if (intent === 'analyze_wrong') {
      return AgentBridge.createLocalCard('wrong', '错题诊断',
        '上传或选择一道错题，获取错误原因和补强建议。', 'pages/WrongQuestion');
    }
    if (intent === 'analyze_weakness') {
      return AgentBridge.createLocalCard('weakness', '学情画像',
        '查看当前薄弱知识点、掌握度和学习证据。', 'pages/StudyTags');
    }
    if (intent === 'match_partner') {
      return AgentBridge.createLocalCard('partner', '学习搭子',
        '查看基于课程、目标和时间的匹配结果。', 'pages/PartnerMatch');
    }
    if (intent === 'query_tasks') {
      return AgentBridge.createLocalCard('tasks', '今日任务',
        '查看近期学习任务和优先级安排。', 'pages/StudyPlan');
    }
    if (intent === 'update_profile') {
      return AgentBridge.createLocalCard('profile', '学习画像已更新',
        '你说明的情况已按**真实练习记录**核对后写入学习档案；画像与后续推荐已按新数据重算。',
        'pages/StudyTags');
    }
    if (intent === 'free_chat' || intent === 'unknown') {
      return AgentBridge.createLocalCard('suggestion', '继续提问',
        '可以问我今日学习建议、学情画像、今日任务或学习搭子，也可以上传错题。', 'pages/ChatMain');
    }
    return undefined;
  }

  static createLocalCard(type: ChatCardType, title: string, summary: string, targetPage: string): ChatCard {
    const action: ChatAction = { label: AgentBridge.getActionLabel(type), targetPage: targetPage };
    return { type: type, title: title, summary: summary, targetPage: targetPage, data: new Map<string, string>(), actions: [action] };
  }
}
