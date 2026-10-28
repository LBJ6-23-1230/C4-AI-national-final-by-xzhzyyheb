import router from '@ohos.router';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { appState } from '../data/AppState';
import { ChatAction, ChatCard, ChatHandoff, ChatHistoryRecord, ChatHistorySession, ChatMessage, IntentChip, WrongAnalysis } from '../models/ChatModels';
import { AgentBridge } from '../services/AgentBridge';
import { ImageEncoder } from '../utils/ImageEncoder';
import { ClientCache } from '../cache/ClientCache';
import { WorkflowResponse, WorkflowStatusResponse } from '../api/ApiModels';
import { WorkflowViewModel } from '../viewmodels/WorkflowViewModel';
import { ApiDisplayFormatter } from '../utils/ApiDisplayFormatter';
import { VoiceInputCallbacks, VoiceInputService } from '../services/VoiceInputService';
import { FocusRecoveryCard } from '../components/FocusRecoveryCard';
import { AgentApiClient } from '../api/AgentApiClient';
import { LearningContext, LearningHandoff } from '../api/ApiModels';
import { ApiFailure } from '../api/ApiResult';

/**
 * 对话页顶部的六个意图快捷按钮。
 *
 * ⚠️ 三条纪律（改动前务必读完）：
 *
 * 1. **`intent` 不能改** —— 这六个值是前后端契约（`api-contract-v0.3`）里
 *    意图识别的枚举，后端 `chat_llm.INTENT_CARDS` 与 `KNOWN_INTENTS`
 *    都按这六个键取值。改 key 会直接打断意图路由。
 *
 * 2. **`label` 必须等于用户点下去之后真正会看到的页面/卡片名字**。
 *    原来写的是"今日建议 / 薄弱诊断 / 查任务 / 更新信息"这类**内部叫法**，
 *    而落地页标题是"今日学习建议 / 学情画像 / Agent 学习计划"——
 *    按钮说什么、点进去看到什么，两边对不上，用户会怀疑点错了。
 *    现在一律以页面标题为准。
 *
 * 3. **一个按钮只能落到一个页面**。原实现在离线 Fixture 下把
 *    `get_suggestion` 与 `query_tasks` 合并成同一张"学习计划"卡，
 *    导致两个不同按钮点出同一个结果（见 `AgentBridge.createLocalCardForIntent`）。
 */
const INTENT_CHIPS: IntentChip[] = [
  { intent: 'get_suggestion', label: '今日学习建议', prompt: '今天我应该先学什么？' },
  { intent: 'analyze_wrong', label: '错题诊断', prompt: '帮我诊断这道错题' },
  { intent: 'analyze_weakness', label: '学情画像', prompt: '帮我看看我的薄弱知识点' },
  { intent: 'match_partner', label: '学习搭子', prompt: '帮我匹配一个学习搭子' },
  { intent: 'query_tasks', label: '今日任务', prompt: '今天有哪些任务要交？' },
  // ⚠️ 标签必须体现"改"这个动作，不能只叫「学习画像」。
  // 实测反馈：「学习画像和学情画像有什么区别？点开之后跳转的界面是一样的」
  // —— 两个 chip 一个叫「学情画像」一个叫「学习画像」，名字几乎同义、
  // 又都落到同一个页面，用户无法分辨。它们的**动作**其实是不同的：
  // 学情画像 = **看**掌握度；这一个 = **改**画像（说出你掌握了什么，系统再去核对）。
  { intent: 'update_profile', label: '更新学习画像', prompt: '我要更新学习画像：我的学习目标或掌握情况有变化' },
];

@Entry
@Component
struct ChatMain {
  @State messages: ChatMessage[] = [];
  @State inputText: string = '';
  @State pendingImage: string = '';
  @State previewImage: string = '';
  @State previewNotice: string = '';
  private imageRequestVersion: number = 0;
  @State selectedIntent: string = 'get_suggestion';
  /** 当前标签：对话页自身固定为 0，仅用于驱动底部标签栏高亮。 */
  @State activeTab: number = 0;
  @State isSending: boolean = false;
  @State workflowTitle: string = '';
  @State workflowDetail: string = '';
  @State workflowStateVersion: number = 0;
  @State isWorkflowLoading: boolean = false;
  @State workflowMessage: string = '';
  @State isListening: boolean = false;
  @State voiceMessage: string = '';
  @State showHistory: boolean = false;
  @State historyLoading: boolean = false;
  @State historySessions: ChatHistorySession[] = [];
  /**
   * 注册 / 建号成功后要如实告知用户的那句话（没有则为空串）。
   *
   * 登录页跳转是 `router.replaceUrl`，注册结果说明留在那边没人看得到；
   * 所以由 `appState.loginNotice` 带过来，落在首屏欢迎区 ——
   * 用户得知道自己这次建号到底"带了什么数据进来"。
   */
  @State welcomeNotice: string = '';
  @State diagnosisEditedId: string = '';
  @State diagnosisEditedPoint: string = '';
  @State goalHistory: LearningContext[] = [];
  @State showGoalHistory: boolean = false;
  @State showGoalTechnical: boolean = false;
  @State learningContext: LearningContext | null = null;
  /**
   * 目标卡只属于触发它的那一轮学习对话，不是整场聊天的常驻页脚。
   * 普通问答发出时先隐藏；只有本轮学习类回复确实返回 learningContext 才重新显示。
   */
  @State showLearningGoalCard: boolean = false;
  @State showGoalSummary: boolean = false;
  @State goalMessage: string = '';
  @State isGoalLoading: boolean = false;
  private goalRequestVersion: number = 0;
  private chatRequestVersion: number = 0;
  private pendingChatOwner: string = '';
  private historyRequestVersion: number = 0;
  /**
   * 身份是否已判定完成。默认 false —— 冷启动时先显示**启动加载态**，
   * 由 `EntryAbility.restoreIdentity()` 结束时翻成 true。
   *
   * 为什么不能直接渲染：冷启动顺序是「applyLogout → 加载对话页 → 异步恢复登录态」，
   * 未登录时这一帧会以**游客身份**显示会话内容，看着像"已经用游客进去了"。
   * 详见 `AppState.markIdentityPending()`。
   */
  @StorageLink('identityReady') identityReady: boolean = false;
  private messageScroller: Scroller = new Scroller();
  private workflowViewModel: WorkflowViewModel = new WorkflowViewModel();
  private workflowRequestVersion: number = 0;
  private isPageActive: boolean = false;
  /** 首帧的 `onPageShow` 与 `aboutToAppear` 是同一次进入，不重复请求。 */
  private hasShownOnce: boolean = false;
  private voiceInputService: VoiceInputService = new VoiceInputService();

  aboutToAppear(): void {
    this.isPageActive = true;
    // 与 `pendingChatPrompt` 同一套取值方式：直接读 appState 的当前值。
    // **取完不清空** —— 用户在几个标签页之间来回切时，这句说明应当还在。
    // 它只在换身份（登录 / 退出）时由 `AppState.resetAccountScopedState()` 清掉。
    this.welcomeNotice = appState.loginNotice;
    // 恢复之前的对话；**没有历史时保持为空**，由 WelcomeBlock 呈现"纯对话界面"。
    //
    // ⚠️ 修正来源：原实现在无历史时种入一条 WELCOME_MESSAGE 气泡，
    // 结果 `messages.length === 0` 永远不成立，欢迎引导（问候语 + 输入框）
    // 从来没显示过，首屏看起来就是"一条机器人寒暄"，不是想要的对话界面。
    if (appState.hasActiveChat && appState.chatMessages.length > 0) {
      try {
        const saved: ChatMessage[] = JSON.parse(appState.chatMessages) as ChatMessage[];
        this.messages = saved;
      } catch (e) {
        this.messages = [];
      }
    } else {
      this.messages = [];
    }
    // 从其他页面跳回时预填 prompt
    if (appState.pendingChatPrompt.length > 0) {
      this.inputText = appState.pendingChatPrompt;
      appState.pendingChatPrompt = '';
    }
    this.appendTaskHandoff();
    this.scrollToLatestMessage();
    this.refreshWorkflowStatus();
    this.refreshLearningContext();
  }

  aboutToDisappear(): void {
    this.closeImagePreview();
    this.historyRequestVersion++;
    // A destroyed page cannot consume the response. Persist a retryable message
    // rather than an endless sending placeholder, only for the original owner.
    if (this.isSending && this.pendingChatOwner === appState.currentUser.userId) {
      this.messages = this.messages.map((item: ChatMessage): ChatMessage => item.status === 'sending'
        ? { id: item.id, role: item.role, text: '本次对话已离开，可在历史记录查看回复或重新发送。',
          time: item.time, status: 'error' } : item);
      this.saveMessages();
    }
    this.isPageActive = false;
    this.goalRequestVersion++;
    this.chatRequestVersion++;
    this.isSending = false;
    this.isGoalLoading = false;
    this.workflowRequestVersion++;
    this.isWorkflowLoading = false;
    this.isListening = false;
    void this.voiceInputService.dispose();
  }

  /**
   * 从练习页 / 导入页 / 计划页返回时刷新目标与工作流状态。
   *
   * 原实现只读 `aboutToAppear`，而 `router.pushUrl` 打开的页返回**不会**重入它 ——
   * 用户在导入页补完课程、或在练习页交完卷回到对话，目标卡仍停在
   * "等待补充知识点 / 等待作答"，看起来像操作没生效，只能手工再点一次。
   */
  onPageShow(): void {
    this.isPageActive = true;
    if (!this.hasShownOnce) {
      this.hasShownOnce = true;
      return;
    }
    this.scrollToLatestMessage();
    // 返回时可能同时带回"目标已交卷"与"计划已重排"，两处都要重新读。
    void this.refreshLearningContext();
    void this.refreshWorkflowStatus();
  }

  onPageHide(): void {
    this.closeImagePreview();
    this.isPageActive = false;
    this.goalRequestVersion++;
    // Keep a same-session chat request alive while a pushed page covers it.
    this.isGoalLoading = false;
    this.workflowRequestVersion++;
    this.isWorkflowLoading = false;
  }

  private scrollToLatestMessage(): void {
    setTimeout(() => {
      if (this.isPageActive) this.messageScroller.scrollEdge(Edge.Bottom);
    }, 100);
  }

  private saveMessages(): void {
    appState.chatMessages = JSON.stringify(this.messages);
    appState.hasActiveChat = this.messages.length > 1;
  }

  /**
   * 启动加载态：**身份判定完成前**显示，不渲染任何会话内容。
   *
   * 保留「先加载对话页、避免白屏」这个原设计，只把那一帧的内容
   * 从"游客身份的会话"换成"正在启动"。见 `AppState.markIdentityPending()`。
   */
  @Builder
  IdentityLoading() {
    Column({ space: 16 }) {
      Text('知学 Mate').fontSize(24).fontWeight(FontWeight.Bold).fontColor('#2563EB')
      LoadingProgress().width(36).height(36).color('#2563EB')
      Text('正在恢复登录状态…').fontSize(13).fontColor('#667085')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#F3F6FA')
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (!this.identityReady) {
        this.IdentityLoading()
      } else {
        Column() {
          this.Header()
          FocusRecoveryCard()
          if (this.workflowTitle.length > 0 || this.workflowMessage.length > 0) {
            this.WorkflowStatusBar()
          }
          this.IntentBar()
          this.MessageList()
          this.InputBar()
          this.TabBar()
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#F3F6FA')
        if (this.showHistory) {
          Row() {}
            .width('100%').height('100%').backgroundColor('#66000000')
            .onClick(() => this.showHistory = false)
          this.HistoryDrawer()
        }
        if (this.previewImage.length > 0) {
          Column({ space: 12 }) {
            Row() {
              Text(this.previewNotice).fontSize(13).fontColor('#FFFFFF').layoutWeight(1)
              Button('关闭').onClick(() => this.closeImagePreview())
            }.width('100%').padding(16)
            Image(this.previewImage).width('100%').layoutWeight(1).objectFit(ImageFit.Contain)
          }.width('100%').height('100%').backgroundColor('#F2111827')
        }
      }
    }
    .width('100%')
    .height('100%')
  }

  private async openHistory(): Promise<void> {
    const owner: string = appState.currentUser.userId;
    const version: number = ++this.historyRequestVersion;
    this.showHistory = true;
    this.historyLoading = true;
    const records: ChatHistoryRecord[] = await AgentBridge.loadHistory();
    if (owner !== appState.currentUser.userId || version !== this.historyRequestVersion) return;
    this.historySessions = this.groupHistorySessions(records);
    this.historyLoading = false;
  }

  /** 服务端按新到旧返回轮次；这里把相同 sessionId 合为一场完整对话。 */
  private groupHistorySessions(records: ChatHistoryRecord[]): ChatHistorySession[] {
    const sessions: ChatHistorySession[] = [];
    for (let index: number = 0; index < records.length; index++) {
      const record: ChatHistoryRecord = records[index];
      let found: ChatHistorySession | null = null;
      for (let sessionIndex: number = 0; sessionIndex < sessions.length; sessionIndex++) {
        if (sessions[sessionIndex].sessionId === record.sessionId) {
          found = sessions[sessionIndex];
          break;
        }
      }
      if (found === null) {
        sessions.push({
          sessionId: record.sessionId,
          title: record.userInput,
          startedAt: record.timestamp,
          updatedAt: record.timestamp,
          turns: [record]
        });
      } else {
        // records 是新到旧，向头部插入后 turns 恢复为正常阅读顺序（旧到新）。
        found.turns.unshift(record);
        found.title = record.userInput;
        found.startedAt = record.timestamp;
      }
    }
    return sessions;
  }

  /** 点击历史卡片时恢复整场对话，不再只恢复被点击的单轮问答。 */
  private restoreHistory(session: ChatHistorySession): void {
    this.chatRequestVersion++;
    this.goalRequestVersion++;
    this.isSending = false;
    this.isGoalLoading = false;
    this.inputText = '';
    this.pendingImage = '';
    const restored: ChatMessage[] = [];
    for (let index: number = 0; index < session.turns.length; index++) {
      const record: ChatHistoryRecord = session.turns[index];
      const time: string = record.timestamp.length >= 16
        ? record.timestamp.substring(11, 16) : this.formatTime();
      restored.push({ id: `history-user-${index}-${record.timestamp}`, role: 'user',
        text: record.userInput, image: record.image, imageFileId: record.imageFileId,
        time: time, status: 'done' });
      restored.push({ id: `history-agent-${index}-${record.timestamp}`, role: 'agent',
        text: record.botResponse, time: time, status: 'done' });
    }
    this.messages = restored;
    appState.chatSessionId = session.sessionId;
    this.learningContext = null;
    this.refreshLearningContext();
    this.saveMessages();
    this.showHistory = false;
    this.scrollToLatestMessage();
  }

  @Builder
  private HistoryDrawer() {
    Column() {
      Row() {
        Text('历史会话').fontSize(19).fontWeight(FontWeight.Bold).fontColor('#111827')
        Blank()
        Text('关闭').fontSize(14).fontColor('#2563EB').onClick(() => this.showHistory = false)
      }.width('100%').padding({ left: 18, right: 18, top: 20, bottom: 14 })
      if (this.historyLoading) {
        LoadingProgress().width(34).height(34).margin({ top: 48 })
      } else if (this.historySessions.length === 0) {
        Text('暂无历史会话').fontSize(14).fontColor('#667085').margin({ top: 48 })
      } else {
        List({ space: 8 }) {
          ForEach(this.historySessions, (session: ChatHistorySession) => {
            ListItem() {
              Column({ space: 5 }) {
                Text(session.title).fontSize(15).fontWeight(FontWeight.Medium)
                  .fontColor('#1F2937').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                Text(session.turns[session.turns.length - 1].botResponse)
                  .fontSize(12).fontColor('#667085').maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                Row() {
                  Text(`${session.turns.length} 轮对话`).fontSize(12).fontColor('#2563EB')
                  Blank()
                  Text(session.updatedAt.length >= 16
                    ? session.updatedAt.substring(0, 16).replace('T', ' ') : '')
                    .fontSize(11).fontColor('#98A2B3')
                }.width('100%')
              }.width('100%').alignItems(HorizontalAlign.Start).padding(13)
                .backgroundColor('#F8FAFC').borderRadius(10)
                .onClick(() => this.restoreHistory(session))
            }
          }, (session: ChatHistorySession) => session.sessionId)
        }.layoutWeight(1).width('100%').padding({ left: 14, right: 14, bottom: 20 })
      }
    }.width('82%').height('100%').backgroundColor('#FFFFFF')
      .shadow({ radius: 16, color: '#33000000', offsetX: 4, offsetY: 0 })
  }

  /**
   * 底部标签栏（与「我的智能体」页保持一致的四标签语义）。
   *
   * ⚠️ 必须无参，高亮在内部读 `this.activeTab`——原因见 Index.ets 的同名注释：
   * ArkTS 的 `@Builder` 参数按值传递，把状态当参数传会导致高亮不刷新。
   */
  @Builder
  private TabBar() {
    Row({ space: 4 }) {
      this.TabItem($r('app.media.nav_chat'), $r('app.media.nav_chat_selected'), '对话', 0)
      this.TabItem($r('app.media.nav_agent'), $r('app.media.nav_agent_selected'), '智能体', 1)
      this.TabItem($r('app.media.nav_study'), $r('app.media.nav_study_selected'), '学习', 2)
      this.TabItem($r('app.media.nav_profile'), $r('app.media.nav_profile_selected'), '我的', 3)
    }
    .width('100%').padding({ left: 12, right: 12, top: 8, bottom: 10 })
    .backgroundColor('#FFFFFF').border({ width: { top: 1 }, color: '#EAECF0' })
  }

  @Builder
  private TabItem(icon: Resource, selectedIcon: Resource, label: string, index: number) {
    Column({ space: 6 }) {
      Image(this.activeTab === index ? selectedIcon : icon)
        .width(22).height(22).objectFit(ImageFit.Contain)
      Text(label).fontSize(12)
        .fontWeight(this.activeTab === index ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.activeTab === index ? '#2563EB' : '#667085')
    }
    .layoutWeight(1).height(62).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    .accessibilityText(label)
    .backgroundColor(this.activeTab === index ? '#EFF6FF' : '#FFFFFF').borderRadius(12)
    .onClick(() => this.switchTab(index))
  }

  /**
   * 标签切换。对话页自身是 0 号标签，其余三个跳转到工作台页。
   *
   * 用 `replaceUrl` 而不是 `pushUrl`：标签是**同级导航**，
   * 若用 pushUrl 会让页面栈随每次切换不断增长（用户在标签间来回点几次就退不出去了）。
   *
   * 「智能体」与「学习」都在 `pages/Index` 里（同一页的不同标签），
   * 用路由参数 `initialTab` 指定落地标签；`Index.aboutToAppear` 会读取它。
   */
  private switchTab(index: number): void {
    if (index === 0) {
      return;
    }
    if (index === 1) {
      router.replaceUrl({ url: 'pages/Index', params: { initialTab: 1 } });
      return;
    }
    if (index === 2) {
      router.replaceUrl({ url: 'pages/Index', params: { initialTab: 2 } });
      return;
    }
    router.replaceUrl({ url: 'pages/Index', params: { initialTab: 3 } });
  }

  private syncWorkflowSummary(status: WorkflowStatusResponse | null): void {
    const workflow: WorkflowResponse | null = ClientCache.getWorkflow();
    if (workflow === null) {
      this.workflowTitle = '';
      this.workflowDetail = '';
      this.workflowStateVersion = 0;
      return;
    }
    if (status !== null) {
      this.workflowTitle = `${ApiDisplayFormatter.agent(status.currentAgent)} · ${ApiDisplayFormatter.workflowStatus(status.status)}`;
      this.workflowDetail = status.finalAction !== null ? status.finalAction : `正在推进：${workflow.nextAction}`;
      this.workflowStateVersion = status.stateVersion;
      return;
    }
    this.workflowTitle = `Agent 会话 · ${ApiDisplayFormatter.workflowStatus(workflow.status)}`;
    // 翻译内部步骤名（实测卡片上出现过「下一步：diagnose」）——
    // 中文句子原样通过，见 `ApiDisplayFormatter.nextAction`。
    this.workflowDetail = `下一步：${ApiDisplayFormatter.nextAction(workflow.nextAction)}`;
    this.workflowStateVersion = 0;
  }

  private async refreshWorkflowStatus(): Promise<void> {
    const owner: string = appState.currentUser.userId;
    const workflow: WorkflowResponse | null = ClientCache.getWorkflow();
    this.syncWorkflowSummary(ClientCache.getWorkflowStatus());
    if (workflow === null || this.isWorkflowLoading) {
      return;
    }
    this.isWorkflowLoading = true;
    this.workflowMessage = '';
    const requestVersion: number = ++this.workflowRequestVersion;
    const status: WorkflowStatusResponse | null = await this.workflowViewModel.refreshStatus(true);
    if (!this.isPageActive || requestVersion !== this.workflowRequestVersion || owner !== appState.currentUser.userId) {
      return;
    }
    this.isWorkflowLoading = false;
    if (status === null) {
      this.workflowMessage = this.workflowViewModel.getErrorMessage();
      return;
    }
    this.syncWorkflowSummary(status);
  }

  @Builder
  private WorkflowStatusBar() {
    Row({ space: 10 }) {
      Column() {
        Text(this.isWorkflowLoading ? '···' : 'AI').fontSize(11).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
      }.width(28).height(28).borderRadius(14).justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center).backgroundColor(this.workflowMessage.length > 0 ? '#B45309' : '#2563EB')
      Column({ space: 2 }) {
        Text(this.workflowTitle.length > 0 ? this.workflowTitle : 'Agent 状态暂时无法同步')
          .fontSize(12).fontWeight(FontWeight.Bold).fontColor('#1F2937')
        Text(this.workflowMessage.length > 0 ? this.workflowMessage : this.workflowDetail)
          .fontSize(11).fontColor('#667085').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      if (this.workflowMessage.length > 0) {
        Text('重试').fontSize(12).fontWeight(FontWeight.Bold).fontColor('#B45309')
          .onClick(() => this.refreshWorkflowStatus())
      } else {
        Text(this.workflowStateVersion > 0 ? `v${this.workflowStateVersion} ›` : '查看 ›')
          .fontSize(12).fontWeight(FontWeight.Bold).fontColor('#2563EB')
          .onClick(() => router.pushUrl({ url: 'pages/AgentTrace' }))
      }
    }.width('100%').padding({ left: 16, right: 16, top: 9, bottom: 9 })
      .backgroundColor(this.workflowMessage.length > 0 ? '#FFFBEB' : '#EFF6FF')
  }

  @Builder
  private Header() {
    Row() {
      Button('☰')
        .fontSize(20).fontColor('#334155').backgroundColor('#F1F5F9')
        .width(38).height(38).borderRadius(10).margin({ right: 10 })
        .onClick(() => this.openHistory())
      Column({ space: 4 }) {
        Text('知学 Mate')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')
        Row({ space: 6 }) {
          Text('').width(7).height(7).borderRadius(4).backgroundColor('#3B82F6')
          Text('在线 · AI学习助手')
            .fontSize(12)
            .fontColor('#64748B')
        }
      }
      .alignItems(HorizontalAlign.Start)
      Blank()
      Row({ space: 8 }) {
        Button('目标').fontSize(13).height(34).onClick(() => { this.showGoalHistory = !this.showGoalHistory; void this.loadGoalHistory(); })
        Button('新对话')
          .fontSize(13)
          .fontColor('#2563EB')
          .backgroundColor('#EAF2FF')
          .borderRadius(8)
          .height(34)
          .onClick(() => this.resetChat())
      }
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 18, bottom: 12 })
    .backgroundColor('#FFFFFF')
    .shadow({ radius: 6, color: '#08000000', offsetX: 0, offsetY: 2 })
  }

  @Builder
  private IntentBar() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(INTENT_CHIPS, (item: IntentChip) => {
          Button(item.label)
            .fontSize(13)
            .fontColor(this.selectedIntent === item.intent ? '#FFFFFF' : '#334155')
            .backgroundColor(this.selectedIntent === item.intent ? '#2563EB' : '#FFFFFF')
            .border({ width: 1, color: this.selectedIntent === item.intent ? '#2563EB' : '#E2E8F0' })
            .borderRadius(8)
            .height(34)
            .padding({ left: 14, right: 14 })
            .onClick(() => { this.chooseIntent(item); })
        }, (item: IntentChip) => item.intent)
      }
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .backgroundColor('#FFFFFF')
  }

  private chooseIntent(item: IntentChip): void {
    this.voiceMessage = '';
    this.showGoalSummary = false;
    this.selectedIntent = item.intent;
    this.inputText = item.prompt;
    // 错题诊断沿用文字对话入口，图片由用户点击输入栏的相机按钮主动选择。
  }

  @Builder
  private MessageList() {
    List({ space: 2, scroller: this.messageScroller }) {
      // 消息为空时展示欢迎引导：对齐参考设计「问候语 + 一句话价值 + 输入框」的首屏。
      // 用 ListItem 承载是为了能跟着列表一起滚动，不与既有 List 结构冲突。
      if (this.messages.length === 0) {
        ListItem() {
          this.WelcomeBlock()
        }
      }
      ForEach(this.messages, (item: ChatMessage) => {
        ListItem() {
          this.MessageBubble(item)
        }
      }, (item: ChatMessage) => item.id)
      if (this.learningContext !== null && this.showGoalSummary) {
        ListItem() {
          if (this.showLearningGoalCard) this.LearningGoalCard(this.learningContext)
          else {
            Row({ space: 8 }) {
              Text(`当前目标：${this.learningContext.knowledgePointName || '待选择知识点'} · ${this.learningContext.status === 'ended' ? '已结束' : this.learningContext.status === 'completed' ? '测评流程已完成' : '学习进行中'}`)
                .fontSize(13).fontColor('#2563EB').layoutWeight(1)
              Button('展开').height(30).fontSize(12).onClick(() => this.showLearningGoalCard = true)
            }.width('94%').padding(12).backgroundColor('#EFF6FF').borderRadius(12).margin({ left: 12, bottom: 8 })
          }
        }
      }
      if (this.showGoalHistory) {
        ListItem() {
          Column({ space: 8 }) {
            Text('本会话学习目标历史').fontSize(16).fontWeight(FontWeight.Bold)
            if (this.goalHistory.length === 0) Text('尚无已确认的学习目标').fontSize(13)
            ForEach(this.goalHistory, (goal: LearningContext) => {
              Button(`${goal.needsConfirmation ? '旧目标待重新确认' : (goal.knowledgePointName || '待补充')} · ${goal.status === 'ended' ? '已结束' : goal.status === 'completed' ? '已完成测评' : '查看目标'}`)
                .fontSize(12).onClick(() => { void this.changeGoal('select', goal.goalId); })
            }, (goal: LearningContext) => goal.goalId)
          }.width('94%').padding(14).backgroundColor('#FFFFFF').borderRadius(12)
        }
      }
    }
    .layoutWeight(1)
    .padding({ top: 8, bottom: 8 })
    .backgroundColor('#F3F6FA')
  }

  private async loadGoalHistory(): Promise<void> {
    const owner: string = appState.currentUser.userId;
    const chatId: string = appState.chatSessionId;
    const result = await AgentApiClient.getChatGoalHistory(chatId);
    if (owner === appState.currentUser.userId && chatId === appState.chatSessionId && result.ok) this.goalHistory = result.data.goals;
  }
  private async changeGoal(action: string, goalId: string): Promise<void> {
    if (this.isGoalLoading) return;
    this.isGoalLoading = true;
    const version: number = ++this.goalRequestVersion;
    const owner: string = appState.currentUser.userId;
    const chatId: string = appState.chatSessionId;
    const result = await AgentApiClient.manageChatGoal(chatId, { action: action, goalId: goalId });
    if (owner !== appState.currentUser.userId || chatId !== appState.chatSessionId || version !== this.goalRequestVersion) return;
    this.isGoalLoading = false;
    if (result.ok) { this.showGoalSummary = true; this.learningContext = result.data.learningContext ?? null; this.showLearningGoalCard = false; void this.loadGoalHistory(); }
    else this.goalMessage = (result as ApiFailure).error.message;
  }
  private async confirmDiagnosis(message: ChatMessage, selected?: WrongAnalysis): Promise<void> {
    const question: WrongAnalysis | undefined = selected ?? message.wrongAnalysis;
    const editId: string = selected !== undefined ? (selected.diagnosisId || message.id) : message.id;
    if (this.isGoalLoading) return;
    const owner: string = appState.currentUser.userId;
    const chatId: string = appState.chatSessionId;
    this.isGoalLoading = true;
    const version: number = ++this.goalRequestVersion;
    const result = await AgentApiClient.manageChatGoal(chatId, { action: 'start', diagnosisId: question?.diagnosisId,
      knowledgePoint: this.diagnosisEditedId === editId ? this.diagnosisEditedPoint : question?.knowledgePoint });
    if (owner !== appState.currentUser.userId || chatId !== appState.chatSessionId || version !== this.goalRequestVersion) return;
    this.isGoalLoading = false;
    if (result.ok) { this.showGoalSummary = true; this.learningContext = result.data.learningContext ?? null; this.showLearningGoalCard = true; this.goalMessage = ''; void this.loadGoalHistory(); }
    else this.goalMessage = (result as ApiFailure).error.message;
  }

  private async refreshLearningContext(): Promise<void> {
    const chatId: string = appState.chatSessionId;
    const owner: string = appState.currentUser.userId;
    const version: number = ++this.goalRequestVersion;
    if (chatId.length === 0 || AgentApiClient.getConfig().useFixture) {
      this.learningContext = null;
      return;
    }
    const response = await AgentApiClient.getChatLearningContext(chatId);
    if (!this.isPageActive || version !== this.goalRequestVersion || owner !== appState.currentUser.userId ||
      chatId !== appState.chatSessionId) return;
    if (response.ok) {
      this.learningContext = response.data;
      this.showGoalSummary = false;
      return;
    }
    const failure: ApiFailure = response as ApiFailure;
    // 404 = 这个聊天还没有学习目标（含"会话存在但没有协调状态"的旧会话）。
    // 这是正常状态，清掉卡片即可；**不能**当成错误去吓用户。
    if (failure.error.statusCode === 404) {
      this.learningContext = null;
      this.showLearningGoalCard = false;
      this.showGoalSummary = false;
      this.goalMessage = '';
      return;
    }
    // 其他失败：卡片里若还挂着上一次的目标，必须说清它是旧数据。
    // 原实现在这里静默 return —— 断网后目标卡一直显示过期的"下一步"，
    // 用户点下去只会拿到另一个错误。
    if (this.learningContext !== null) {
      this.goalMessage = `目标状态刷新失败：${failure.error.message}（上方显示的是上一次读取到的目标）`;
    }
  }

  /**
   * 这几个意图在**当前后端**下必然带 learningContext（至少会建立一个等待补充
   * 知识点的目标）。只有它们缺字段时，才值得提示"版本可能不一致"；
   * 普通问候、闲聊、搭子匹配本来就没有目标，不该打扰用户。
   */
  private isLearningIntent(intent: string): boolean {
    return intent === 'get_suggestion' || intent === 'analyze_weakness' || intent === 'analyze_wrong';
  }

  private roleLabel(role: string): string {
    if (role === 'secretary' || role === 'clarify' || role === 'finish') return '学习秘书';
    if (role === 'diagnosis') return '学情诊断';
    if (role === 'exercise') return '练习';
    if (role === 'assessment') return '评估';
    if (role === 'planner') return '规划';
    return role;
  }

  private async continueLearningGoal(context: LearningContext): Promise<void> {
    if (this.isGoalLoading) return;
    const owner: string = appState.currentUser.userId;
    const chatId: string = appState.chatSessionId;
    const version: number = ++this.goalRequestVersion;
    this.isGoalLoading = true;
    this.goalMessage = '';
    const response = await AgentApiClient.runWorkflow(context.sessionId, { expectedStateVersion: context.stateVersion });
    if (!this.isPageActive || version !== this.goalRequestVersion || owner !== appState.currentUser.userId ||
      chatId !== appState.chatSessionId) return;
    this.isGoalLoading = false;
    if (!response.ok) {
      this.goalMessage = (response as ApiFailure).error.message;
      this.refreshLearningContext();
      return;
    }
    const updated: LearningContext | undefined = response.data.learningContext;
    if (updated === undefined) {
      this.goalMessage = '服务未返回本目标上下文，请刷新后继续。';
      return;
    }
    this.showGoalSummary = true;
    this.learningContext = updated;
    if (updated.status === 'tool_failed') {
      this.goalMessage = updated.nextAction;
      return;
    }
    const target: string = updated.action.targetPage;
    if (target === 'pages/ExercisePractice') {
      router.pushUrl({ url: target, params: { goalId: updated.goalId, goalStateVersion: updated.stateVersion,
        knowledgePointId: updated.knowledgePointId, sourceMode: updated.sourceMode, kbId: updated.kbId } });
    } else if (target === 'pages/CourseImport') {
      // 空画像账号的「补充课程与知识点」必须落到**真正能补上知识点**的导入页：
      // 课程导入会经服务端写入 mastery 并生成计划（见 app/api/profile.py）。
      // 旧实现跳的是只读的 pages/StudyTags，用户点进去仍然空无一物。
      router.pushUrl({ url: target, params: { initialTab: 'import' } });
    } else if (target === 'pages/StudyPlan' || target === 'pages/StudyTags') {
      router.pushUrl({ url: target });
    }
  }

  @Builder
  private LearningGoalCard(context: LearningContext) {
    Column({ space: 10 }) {
      Row() {
        Text('练习与测评').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#1D4ED8').layoutWeight(1)
        Button('收起').fontSize(12).height(28).fontColor('#2563EB')
          .backgroundColor('#EFF6FF').borderRadius(8)
          .onClick(() => { this.showLearningGoalCard = false; })
      }.width('100%')
      Button('结束当前目标').fontSize(12).height(30).onClick(() => { void this.changeGoal('end', context.goalId); })
      Text(context.knowledgePointName.length > 0 ? `练习内容：${context.knowledgePointName}` : '请先选择要练习的知识点')
        .fontSize(15).fontWeight(FontWeight.Medium).fontColor('#1F2937').width('100%')
      Text(context.status === 'ended' ? '你已结束这项练习，历史记录仍可查看。' :
        context.status === 'completed' ? '本次测评已完成，可查看结果和后续安排。' :
        context.waitingFor === 'knowledge_points' ? '还没有可用题目。请导入包含知识正文的资料，并确认知识点。' :
        context.waitingFor === 'available_time' ? '请先设置可用学习时间，再安排练习。' :
        context.status === 'tool_failed' ? '这次未能准备好练习，请重试。' : '下一步：打开练习，作答并提交后查看解析和测评结果。')
        .fontSize(13).fontColor('#475467').lineHeight(20).width('100%')
      if (context.knowledgePointName.length > 0 && context.waitingFor !== 'knowledge_points') {
        Text(context.sourceMode === 'materials' ? '题目依据：相关上传资料，可在练习中查看原文。' : '题目依据：通用知识题库或模型生成题。')
          .fontSize(12).fontColor('#64748B').width('100%')
      }
      Button(this.showGoalTechnical ? '收起进度详情 ↑' : '查看进度详情 ↓').fontSize(12).height(30)
        .onClick(() => this.showGoalTechnical = !this.showGoalTechnical)
      if (this.showGoalTechnical) {
        Text(context.assessmentStatus === 'assessed' ? `已保存 ${context.assessedQuestionCount} 道题的测评记录。` : '尚未提交测评，暂不能据此判断掌握情况。')
          .fontSize(12).fontColor('#64748B').width('100%')
        Text(context.nextAction).fontSize(12).fontColor('#64748B').lineHeight(18).width('100%')
      }
      if (this.goalMessage.length > 0) Text(this.goalMessage).fontSize(12).fontColor('#B42318')
      Button(this.isGoalLoading ? '正在继续…' : context.action.label).width('100%').height(40)
        .enabled(!this.isGoalLoading && context.status !== 'ended' && !context.needsConfirmation).onClick(() => this.continueLearningGoal(context))
      if (this.showGoalTechnical) {
      Row({ space: 8 }) {
        Button('查看调度轨迹').fontSize(12).height(32)
          .onClick(() => router.pushUrl({ url: 'pages/AgentTrace', params: { traceId: context.traceId } }))
        if (context.assessmentTraceId.length > 0) {
          Button('评估与重排轨迹').fontSize(12).height(32)
            .onClick(() => router.pushUrl({ url: 'pages/AgentTrace', params: { traceId: context.assessmentTraceId } }))
        }
      }
      }
    }.width('92%').padding(16).backgroundColor('#FFFFFF').borderRadius(14)
      .border({ width: 1, color: '#BFDBFE' }).margin({ left: 16, top: 10, bottom: 14 })
  }

  /** 按当前时间给出问候语（早上好 / 下午好 / 晚上好）。 */
  private greetingText(): string {
    const hour: number = new Date().getHours();
    if (hour < 6) return '夜深了';
    if (hour < 12) return '早上好';
    if (hour < 18) return '下午好';
    return '晚上好';
  }

  /**
   * 首次进入的欢迎区。
   *
   * 参考设计的首屏是「大号问候 + 一句话说明产品做什么 + 输入框」，
   * 这套结构比一上来就弹一排功能按钮更清楚：先让人知道**能对它说什么**。
   *
   * ⚠️ 第二段文案**刻意只说能力、不断言已知**。
   *
   * 原文案是「我**已经读取**你的课程、考试倒计时与错题记录」——
   * 而事实是：课程 / DDL 必须由用户自己导入（见 `appState.courses` 的默认值注释
   * 「演示课程只能由显式'恢复演示数据'动作加载」），错题也要用户自己上传或做过练习才有。
   * 于是刚注册的账号一进门就被系统告知"我读过你的记录了"，
   * 正是用户反馈的「会给用户一种虚假的感觉」。
   * 改成"可以读取你上传的…"既保住了"能对它说什么"的引导作用，又不撒谎。
   */
  @Builder
  private WelcomeBlock() {
    Column({ space: 10 }) {
      Text('ZHI XUE MATE  ·  LEARNING AGENT')
        .fontSize(10).fontWeight(FontWeight.Bold).fontColor('#94A3B8')
        .letterSpacing(1.5).width('100%')
      Text(`${this.greetingText()}，`)
        .fontSize(26).fontWeight(FontWeight.Bold).fontColor('#0F172A').width('100%')
      Text('从今天最该做的一件事开始。')
        .fontSize(26).fontWeight(FontWeight.Bold).fontColor('#0F172A').width('100%')
      Divider().color('#CBD5E1').width(160).margin({ top: 6, bottom: 2 })
      // 注册 / 建号结果说明：由后端事实生成（见 AuthClient.registerMessage），
      // 在登录页上来不及展示，落到这里才算"用户真的被告知了"。
      if (this.welcomeNotice.length > 0) {
        Text(this.welcomeNotice)
          .fontSize(12).lineHeight(19).width('100%')
          .fontColor('#334155')
          .padding(12).backgroundColor('#EFF6FF').borderRadius(10)
          .border({ width: 1, color: '#BFDBFE' })
      }
      Text('我可以读取你上传的课程、考试倒计时与错题记录。你可以直接说想做什么，')
        .fontSize(13).fontColor('#64748B').lineHeight(20).width('100%')
      Text('也可以点下面的能力，或去「智能体」页看看我全部会做的事。')
        .fontSize(13).fontColor('#64748B').lineHeight(20).width('100%')
    }
    .width('100%').alignItems(HorizontalAlign.Start)
    .padding({ left: 20, right: 20, top: 28, bottom: 18 })
  }

  private closeImagePreview(): void {
    this.imageRequestVersion++;
    this.previewImage = '';
    this.previewNotice = '';
  }

  private async openImagePreview(message: ChatMessage): Promise<void> {
    const version: number = ++this.imageRequestVersion;
    const owner: string = appState.currentUser.userId;
    this.previewImage = message.image ?? '';
    this.previewNotice = '';
    const fileId: string = message.imageFileId ?? '';
    if (fileId.length === 0) return;
    this.previewNotice = '正在加载原图…';
    const original: string = await AgentBridge.loadChatImage(fileId);
    if (!this.isPageActive || owner !== appState.currentUser.userId || version !== this.imageRequestVersion) return;
    if (original.length > 0) this.previewImage = original;
    this.previewNotice = original.length > 0 ? '' : '原图暂时无法加载，当前显示缩略图';
  }

  @Builder
  private MessageBubble(message: ChatMessage) {
    Row() {
      if (message.role === 'user') {
        Blank()
      }

      Column({ space: 8 }) {
        if (message.image !== undefined && message.image.length > 0) {
          Image(message.image)
            .width(112)
            .height(84)
            .objectFit(ImageFit.Cover)
            .borderRadius(8)
            .backgroundColor('#E2E8F0')
            .onClick(() => { void this.openImagePreview(message); })
        }

        if (message.status === 'sending') {
          Row({ space: 5 }) {
            Text('').width(6).height(6).borderRadius(3).backgroundColor('#8E99A8')
            Text('').width(6).height(6).borderRadius(3).backgroundColor('#B3BBC6')
            Text('').width(6).height(6).borderRadius(3).backgroundColor('#D0D6DE')
          }
          .padding({ left: 14, right: 14, top: 12, bottom: 12 })
          .backgroundColor('#FFFFFF')
          .borderRadius(8)
        } else {
          Text(message.text)
            .fontSize(15)
            .lineHeight(22)
            .fontColor(message.role === 'user' ? '#FFFFFF' : '#1F2933')
            .padding({ left: 14, right: 14, top: 11, bottom: 11 })
            .backgroundColor(message.role === 'user' ? '#2563EB' : '#FFFFFF')
            .borderRadius(8)
        }

        if (message.role === 'agent' && message.status === 'done' &&
          (message.sourceLabel !== undefined || message.llmUsed !== undefined)) {
          Text(message.sourceLabel ?? (message.llmUsed ? '大模型生成' : '本地规则兜底'))
            .fontSize(11)
            .fontColor(message.sourceLabel !== undefined || message.llmUsed ? '#2563EB' : '#B45309')
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .backgroundColor(message.sourceLabel !== undefined || message.llmUsed ? '#EAF2FF' : '#FFF7ED')
            .borderRadius(10)
        }

        if (message.attachmentStatus !== undefined) Text(message.attachmentStatus).fontSize(12).fontColor('#64748B')
        if (message.wrongAnalysis?.questions !== undefined && message.wrongAnalysis.questions.length > 1) {
          ForEach(message.wrongAnalysis.questions, (question: WrongAnalysis, index: number) => {
            if (question.diagnosisId && question.knowledgePoint) {
              Text(`第${question.questionNumber || (index + 1).toString()}题 · ${question.knowledgePoint}`)
                .fontSize(13).fontWeight(FontWeight.Bold).fontColor('#2563EB')
              TextInput({ text: this.diagnosisEditedId === question.diagnosisId ? this.diagnosisEditedPoint : (question.knowledgePoint ?? ''), placeholder: '核对或修改本题知识点' })
                .onChange((v: string) => { this.diagnosisEditedId = question.diagnosisId ?? message.id; this.diagnosisEditedPoint = v; })
              Button('确认本题，建立学习目标').fontSize(12).height(36).enabled(!this.isGoalLoading)
                .onClick(() => { void this.confirmDiagnosis(message, question); })
            }
          }, (question: WrongAnalysis, index: number) => index.toString())
        } else if (message.wrongAnalysis?.questionText) {
          Text('识别题干（请核对）').fontSize(13).fontWeight(FontWeight.Bold).fontColor('#2563EB')
          Text(message.wrongAnalysis.questionText).fontSize(13).fontColor('#475467').lineHeight(20)
          TextInput({ text: this.diagnosisEditedId === message.id ? this.diagnosisEditedPoint : (message.wrongAnalysis.knowledgePoint ?? ''), placeholder: '核对或修改知识点' })
            .onChange((v: string) => { this.diagnosisEditedId = message.id; this.diagnosisEditedPoint = v; })
          Button('确认题干无误，建立本题学习目标').fontSize(12).height(36).enabled(!this.isGoalLoading)
            .onClick(() => { void this.confirmDiagnosis(message); })
          if (this.learningContext !== null) Text('新题将建立独立目标；原目标保留在“目标”历史中。').fontSize(11).fontColor('#64748B')
        }
        if (message.card !== undefined) {
          this.CardView(message.card)
        }
      }
      .alignItems(message.role === 'user' ? HorizontalAlign.End : HorizontalAlign.Start)
      .width('78%')

      if (message.role !== 'user') {
        Blank()
      }
    }
    .width('100%')
    .justifyContent(message.role === 'user' ? FlexAlign.End : FlexAlign.Start)
    .padding({ left: 16, right: 16, top: 5, bottom: 5 })
  }

  @Builder
  private CardView(card: ChatCard) {
    Column({ space: 6 }) {
      Row() {
        Text(this.getCardLabel(card))
          .fontSize(12)
          .fontColor('#2563EB')
          .fontWeight(FontWeight.Medium)
        Blank()
        Text('查看 ›')
          .fontSize(12)
          .fontColor('#64748B')
      }
      .width('100%')

      Text(card.title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor('#111827')
        .maxLines(1)
      Text(card.summary)
        .fontSize(13)
        .fontColor('#64748B')
        .lineHeight(18)
        .maxLines(2)

      if (card.actions !== undefined && card.actions.length > 0) {
        Row({ space: 8 }) {
          ForEach(card.actions, (action: ChatAction) => {
            Button(action.label)
              .fontSize(12)
              .fontColor('#2563EB')
              .backgroundColor('#EAF2FF')
              .height(30)
              .borderRadius(8)
              .padding({ left: 10, right: 10 })
              .onClick(() => this.openAction(action))
          }, (action: ChatAction) => action.label + action.targetPage)
        }
        .width('100%')
      }
    }
    .width(226)
    .padding(12)
    .backgroundColor('#F8FAFC')
    .border({ width: 1, color: '#E2E8F0' })
    .borderRadius(8)
    .onClick(() => {
      // 点击卡片本身也跳转
      if (card.actions !== undefined && card.actions.length > 0) {
        this.openAction(card.actions[0]);
      } else if (card.targetPage.length > 0) {
        router.pushUrl({ url: card.targetPage });
      }
    })
  }

  /**
   * 卡片类型 → 卡片上的名称标签。
   *
   * ⚠️ 这里的文案必须与下面 `INTENT_CHIPS` 的 `label` **同一套口径**，
   * 否则会出现"按钮写学情画像、点进去卡片写薄弱诊断"的错位。
   * 统一规则：一律用页面标题（今日学习建议 / 学情画像 / 学习搭子 / 今日任务 / 错题诊断）。
   */
  private getCardLabel(card: ChatCard): string {
    if (card.type === 'weakness') {
      return '学情画像';
    }
    if (card.type === 'partner') {
      return '学习搭子';
    }
    if (card.type === 'tasks') {
      return '今日任务';
    }
    if (card.type === 'wrong') {
      return '错题诊断';
    }
    return '今日学习建议';
  }

  private openAction(action: ChatAction): void {
    appState.startChatTask(this.taskContextFor(action.targetPage));
    router.pushUrl({ url: action.targetPage });
  }

  private taskContextFor(targetPage: string): string {
    if (targetPage === 'pages/WrongQuestion') {
      return '诊断并安排错题复习';
    }
    if (targetPage === 'pages/PartnerMatch') {
      return '选择合适的学习搭子';
    }
    if (targetPage === 'pages/StudyPlan') {
      return '查看课程任务与专项计划';
    }
    if (targetPage === 'pages/FocusSetup') {
      return '开始本次专注';
    }
    return '确认今天的学习任务';
  }

  private appendTaskHandoff(): void {
    const handoff: ChatHandoff | null = appState.consumeChatHandoff();
    if (handoff === null) {
      return;
    }
    const action: ChatAction = {
      label: handoff.actionLabel,
      targetPage: handoff.targetPage
    };
    const data: Map<string, string> = new Map<string, string>();
    data.set('source', 'task_handoff');
    const card: ChatCard = {
      type: 'suggestion',
      title: handoff.nextPrompt,
      summary: '继续完成下一步，或直接在对话里调整安排。',
      targetPage: handoff.targetPage,
      data: data,
      actions: [action]
    };
    const message: ChatMessage = {
      id: `handoff-${Date.now()}`,
      role: 'agent',
      text: handoff.summary,
      card: card,
      time: this.formatTime(),
      status: 'done'
    };
    this.messages = this.messages.concat([message]);
    this.saveMessages();
    this.scrollToLatestMessage();
  }

  @Builder
  private InputBar() {
    Column({ space: 8 }) {
      if (this.voiceMessage.length > 0) {
        Row({ space: 8 }) {
          Text(this.isListening ? '●' : 'i')
            .fontSize(11).fontColor(this.isListening ? '#DC2626' : '#2563EB')
          Text(this.voiceMessage).fontSize(12).fontColor('#475569').layoutWeight(1)
          if (this.isListening) {
            Text('完成').fontSize(12).fontWeight(FontWeight.Bold).fontColor('#DC2626')
              .onClick(() => { void this.stopVoiceInput(); })
          }
        }.width('100%').padding({ left: 10, right: 10, top: 7, bottom: 7 })
          .backgroundColor(this.isListening ? '#FEF2F2' : '#EFF6FF').borderRadius(8)
      }
      if (this.pendingImage.length > 0) {
        Row({ space: 10 }) {
          Image(this.pendingImage)
            .width(54)
            .height(54)
            .objectFit(ImageFit.Cover)
            .borderRadius(8)
            .backgroundColor('#E2E8F0')
          Text('已添加图片')
            .fontSize(13)
            .fontColor('#475569')
          Blank()
          Button('移除')
            .fontSize(12)
            .fontColor('#64748B')
            .backgroundColor('#F1F5F9')
            .height(30)
            .borderRadius(8)
            .onClick(() => this.pendingImage = '')
        }
        .width('100%')
      }

      Row({ space: 8 }) {
        // 语音输入按钮。
        // ⚠️ 图标必须用系统 Symbol 字体（`sys.symbol.*`），不要用 emoji：
        //   原先写的是 `Button(this.isListening ? '■' : '🎤')`，
        //   emoji 字形取决于系统 emoji 字体，在不同设备/版本上大小、基线、
        //   配色都不一致，且在部分精简镜像里根本不渲染。
        //   Symbol 由 HM Symbol 字体提供，可随 fontSize / fontColor 精确控制。
        //   符号名取自本机 SDK 资源表
        //   `sdk/default/openharmony/toolchains/id_defined.json`（type == "symbol"），
        //   已核实 `mic` / `stop_circle_fill` / `camera` 均存在。
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          SymbolGlyph(this.isListening
            ? $r('sys.symbol.stop_circle_fill')
            : $r('sys.symbol.mic'))
            .fontSize(20)
            .fontColor([this.isListening ? '#FFFFFF' : '#2563EB'])
        }
        .backgroundColor(this.isListening ? '#DC2626' : '#EAF2FF')
        .width(40)
        .height(40)
        .borderRadius(8)
        .enabled(!this.isSending)
        .onClick(() => { void this.toggleVoiceInput(); })
        // 拍照上传按钮。语义是"拍照识别错题"，因此用相机图标而非相册/图片图标。
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.camera'))
            .fontSize(20)
            .fontColor(['#2563EB'])
        }
        .backgroundColor('#EAF2FF')
        .width(40)
        .height(40)
        .borderRadius(8)
        .enabled(!this.isSending)
        .onClick(() => this.pickImage())
        TextInput({ placeholder: '问学习建议、错题、计划或搭子', text: this.inputText })
          .height(40)
          .layoutWeight(1)
          .fontSize(14)
          .placeholderColor('#94A3B8')
          .fontColor('#111827')
          .backgroundColor('#F8FAFC')
          .borderRadius(8)
          .onChange((value: string) => this.inputText = value)
        Button('发送')
          .fontSize(14)
          .fontColor('#FFFFFF')
          .backgroundColor(this.canSend() ? '#2563EB' : '#CBD5E1')
          .height(40)
          .borderRadius(8)
          .enabled(this.canSend())
          .onClick(() => this.sendMessage())
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 14 })
    .backgroundColor('#FFFFFF')
  }

  private canSend(): boolean {
    return !this.isSending && (this.inputText.trim().length > 0 || this.pendingImage.length > 0);
  }

  private resetChat(): void {
    this.goalRequestVersion++;
    this.chatRequestVersion++;
    this.learningContext = null;
    this.showLearningGoalCard = false;
    this.showGoalSummary = false;
    this.goalMessage = '';
    this.isGoalLoading = false;
    // 原缺陷：这里写成 `this.messages = [WELCOME_MESSAGE]`，数组长度变成 1，
    // 而欢迎引导块只在 `messages.length === 0` 时渲染（见 MessageList），
    // 于是点「新对话」后首屏再也回不到"无消息"的初始态，欢迎块不再出现。
    // 现在与 aboutToAppear 的无历史分支保持一致，都用空数组；
    // 下面 appState.hasActiveChat / appState.chatMessages 的清理逻辑保持不变。
    this.messages = [];
    this.inputText = '';
    this.pendingImage = '';
    this.selectedIntent = 'get_suggestion';
    this.isSending = false;
    appState.hasActiveChat = false;
    appState.chatMessages = '';
    appState.chatSessionId = '';
  }

  private async toggleVoiceInput(): Promise<void> {
    if (this.isListening) {
      await this.stopVoiceInput();
      return;
    }
    await this.startVoiceInput();
  }

  private async startVoiceInput(): Promise<void> {
    this.voiceMessage = '';
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const permissions: Permissions[] = ['ohos.permission.MICROPHONE'];
    try {
      const result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, permissions);
      if (result.authResults.length === 0 || result.authResults[0] !== 0) {
        this.voiceMessage = '麦克风权限未开启，可在系统设置中允许后重试。';
        return;
      }
    } catch (error) {
      this.voiceMessage = '无法申请麦克风权限，请在系统设置中检查权限。';
      return;
    }

    const callbacks: VoiceInputCallbacks = new VoiceInputCallbacks(
      (listening: boolean): void => {
        this.isListening = listening;
        if (listening) this.voiceMessage = '正在聆听，点击红色停止按钮后生成文字。';
      },
      (text: string, isFinal: boolean): void => {
        this.inputText = text;
        this.voiceMessage = isFinal ? '已转换为文字，可修改后发送。' : '正在识别…';
      },
      (message: string): void => {
        this.isListening = false;
        this.voiceMessage = message;
      }
    );
    await this.voiceInputService.start(callbacks);
  }

  private async stopVoiceInput(): Promise<void> {
    this.voiceMessage = '正在整理识别结果…';
    await this.voiceInputService.stop(true);
  }

  private async pickImage(): Promise<void> {
    try {
      const photoPicker = new photoAccessHelper.PhotoViewPicker();
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      const result = await photoPicker.select(options);
      if (result.photoUris.length > 0) {
        const uri: string = result.photoUris[0];
        this.pendingImage = uri;
        appState.addWrongQuestionImage(uri, `chat_${Date.now()}.jpg`);
      }
    } catch (error) {
      const imageErrorMessage: ChatMessage = {
        id: `image-error-${Date.now()}`,
        role: 'agent',
        text: '图片选择暂时没有成功，你可以先发文字，我会保留图片入口等后续联调。',
        time: this.formatTime(),
        status: 'done'
      };
      this.messages = [...this.messages, imageErrorMessage];
    }
  }

  private async sendMessage(): Promise<void> {
    if (!this.canSend()) {
      return;
    }
    // 先占位：下面读图是 await，期间用户再点一次会重入
    this.isSending = true;
    const owner: string = appState.currentUser.userId;
    const requestVersion: number = ++this.chatRequestVersion;
    this.pendingChatOwner = owner;

    // 一场对话只生成一次 id。页面跳转、返回和连续追问都沿用；
    // 只有 resetChat（用户明确点「新对话」）才会清空并在下一次发送时换新 id。
    if (appState.chatSessionId.length === 0) {
      appState.chatSessionId = `chat-${Date.now()}`;
    }
    const chatId: string = appState.chatSessionId;

    const text: string = this.inputText.trim().length > 0 ? this.inputText.trim() : '请分析这张图片';
    // 新问题开始时不把上一轮目标卡继续钉在消息底部；若本轮仍是学习协作，
    // 服务端回复中的 learningContext 会在下面重新触发显示。
    this.showLearningGoalCard = false;
    this.showGoalSummary = false;
    // 气泡里显示的是**相册 URI**（`Image` 组件要 URI）。
    const bubbleImage: string | undefined = this.pendingImage.length > 0 ? this.pendingImage : undefined;
    // ⚠️ 发给后端的必须是 **base64**，不是 URI。
    // 后端按 base64 拼 `data:{mime};base64,{...}`（见 chat_llm._call_llm_with_image），
    // 而相册选择器给的是 `file://media/Photo/...` —— 直接把 URI 发过去，
    // 模型**看不到图片**，而且后端 `b64decode(validate=False)` 不报错，最难查。
    let imageForAgent: string | undefined = undefined;
    if (this.pendingImage.length > 0) {
      const encoded: string = await ImageEncoder.toBase64(this.pendingImage);
      if (requestVersion !== this.chatRequestVersion || owner !== appState.currentUser.userId ||
        chatId !== appState.chatSessionId) return;
      if (encoded.length === 0) {
        this.isSending = false;
        this.messages = [...this.messages, {
          id: `agent-error-${Date.now()}`,
          role: 'agent',
          text: ImageEncoder.describeFailure(),
          time: this.formatTime(),
          status: 'error'
        }];
        this.scrollToLatestMessage();
        return;
      }
      imageForAgent = encoded;
    }
    if (requestVersion !== this.chatRequestVersion || owner !== appState.currentUser.userId ||
      chatId !== appState.chatSessionId) return;
    const userMessage: ChatMessage = {
      id: `user-${Date.now()}`,
      role: 'user',
      text: text,
      image: bubbleImage,
      time: this.formatTime(),
      status: 'done'
    };
    const loadingMessage: ChatMessage = {
      id: `agent-loading-${Date.now()}`,
      role: 'agent',
      text: '',
      time: this.formatTime(),
      status: 'sending'
    };

    // 原缺陷：调用 callAgent 时直接把 this.messages 递过去，而它**已经含本条 userMessage**
    //（buildRequest 只过滤 status === 'sending' 的占位消息，拦不住它），
    // 于是同一条输入在请求体里出现两次：`message` 字段一份、`history` 末项一份，
    // 模型每轮都会看到重复问题。这里先取"发送前"的历史快照，本条消息只由 `message` 承载。
    const historyBeforeSend: ChatMessage[] = this.messages;
    this.messages = [...this.messages, userMessage, loadingMessage];
    this.inputText = '';
    this.pendingImage = '';
    this.isSending = true;
    this.scrollToLatestMessage();

    try {
      const response = await AgentBridge.callAgent(text, imageForAgent, historyBeforeSend, (progress) => {
        if (requestVersion !== this.chatRequestVersion || owner !== appState.currentUser.userId ||
          chatId !== appState.chatSessionId) return;
        this.messages = this.messages.map((item: ChatMessage): ChatMessage => item.id === loadingMessage.id ? {
          id: item.id, role: item.role, text: progress.reply || item.text,
          time: item.time, status: 'sending', progressText: progress.message
        } : item);
      });
      if (requestVersion !== this.chatRequestVersion || owner !== appState.currentUser.userId ||
        chatId !== appState.chatSessionId) return;
      this.showGoalSummary = response.learningContext !== undefined;
      if (response.intent === 'analyze_wrong') this.learningContext = null;
      if (response.learningContext !== undefined && response.intent !== 'analyze_wrong') {
        this.goalRequestVersion++;
        this.isGoalLoading = false;
        this.learningContext = response.learningContext;
      }
      this.showLearningGoalCard = false;
      this.messages = this.messages.filter((item: ChatMessage) => item.id !== loadingMessage.id);
      this.voiceMessage = '';
      let replyText: string = response.reply;
      if (response.profileUpdates !== undefined) {
        const applied: string[] = appState.applyChatProfileUpdates(response.profileUpdates);
        if (applied.length > 0) {
          replyText += `\n\n已在对话中完成：${applied.join('、')}。`;
        }
      }
      const agentMessage: ChatMessage = {
        id: `agent-${Date.now()}`,
        role: 'agent',
        text: replyText,
        wrongAnalysis: response.wrongAnalysis,
        attachmentStatus: response.attachmentStatus,
        card: response.learningContext !== undefined || response.intent === 'analyze_wrong' ? undefined : response.card,
        llmUsed: response.llmUsed,
        sourceLabel: response.profileUpdates !== undefined ? '系统已执行' : undefined,
        time: this.formatTime(),
        status: 'done'
      };
      this.messages = [...this.messages, agentMessage];
      this.saveMessages();
      this.scrollToLatestMessage();
    } catch (error) {
      if (requestVersion !== this.chatRequestVersion || owner !== appState.currentUser.userId ||
        chatId !== appState.chatSessionId) return;
      this.messages = this.messages.filter((item: ChatMessage) => item.id !== loadingMessage.id);
      const errorMessage: ChatMessage = {
        id: `agent-error-${Date.now()}`,
        role: 'agent',
        text: error instanceof Error ? error.message : '这次没有连上 Agent，请检查数据源后重试。',
        time: this.formatTime(),
        status: 'error'
      };
      this.messages = [...this.messages, errorMessage];
      this.inputText = text;
      // 失败时把图片还给输入框让用户重试 —— 还的是**相册 URI**（气泡/预览要 URI）
      this.pendingImage = bubbleImage ?? '';
      this.saveMessages();
      this.scrollToLatestMessage();
    }
    this.isSending = false;
  }

  private formatTime(): string {
    const now = new Date();
    const hour: number = now.getHours();
    const minute: number = now.getMinutes();
    const minuteText: string = minute < 10 ? `0${minute}` : `${minute}`;
    return `${hour}:${minuteText}`;
  }
}
