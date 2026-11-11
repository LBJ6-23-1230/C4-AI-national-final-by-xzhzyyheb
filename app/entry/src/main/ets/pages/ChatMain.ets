import { pasteboard } from '@kit.BasicServicesKit';
import { UserAvatar } from '../components/UserAvatar';
import { ChatComposer } from '../components/ChatComposer';
import { ChatMessageAction } from '../components/ChatMessageActions';
import { ChatFile } from '../api/StudyTaskModels';
import { picker, fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { UiTheme } from '../utils/UiTheme';
import { AppBottomBar } from '../components/AppBottomBar';
import { PartnerInboxButton } from '../components/PartnerInboxButton';
import { TodayPanel } from '../components/TodayPanel';
import { PageHeader } from '../components/PageHeader';
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

const INTENT_CHIPS: IntentChip[] = [
  { intent: 'get_suggestion', label: '今日学习建议', prompt: '今天我应该先学什么？' },
  { intent: 'analyze_wrong', label: '错题诊断', prompt: '帮我诊断这道错题' },
  { intent: 'analyze_weakness', label: '学情画像', prompt: '帮我看看我的薄弱知识点' },
  { intent: 'match_partner', label: '学习搭子', prompt: '帮我匹配一个学习搭子' },
  { intent: 'query_tasks', label: '今日任务', prompt: '今天有哪些任务要交？' },
  { intent: 'update_profile', label: '更新学习画像', prompt: '我要更新学习画像：我的学习目标或掌握情况有变化' },
];

interface DiagnosisEdit { id: string; point: string; }

@Entry
@Component
struct ChatMain {
  @State todayRevision: number = 0;
  @State messages: ChatMessage[] = [];
  @State inputText: string = '';
  @State menuMessageId: string = '';
  @State pendingFileName: string = '';
  @State pendingFileTruncated: boolean = false;
  @State pendingFileText: string = '';
  @State fileBusy: boolean = false;
  private fileRevision: number = 0;
  @State pendingImage: string = '';
  @State previewImage: string = '';
  @State previewNotice: string = '';
  private imageRequestVersion: number = 0;
  @State selectedIntent: string = 'get_suggestion';
  @State showFunctionWorkspace: boolean = false;
  @State activeTab: number = 0;
  @State isSending: boolean = false;
  @State workflowTitle: string = '';
  @State workflowDetail: string = '';
  @State workflowStateVersion: number = 0;
  @State isWorkflowLoading: boolean = false;
  @State workflowMessage: string = '';
  @State isListening: boolean = false;
  @State voiceMode: boolean = false;
  @State voiceReady: boolean = false;
  @State voicePressing: boolean = false;
  @State isVoiceStarting: boolean = false;
  @State isVoiceFinalizing: boolean = false;
  @State voiceMessage: string = '';
  @State showHistory: boolean = false;
  @State showLearningFunctions: boolean = false;
  @State historyLoading: boolean = false;
  @State historySessions: ChatHistorySession[] = [];
  @State welcomeNotice: string = '';
  @State diagnosisEditedId: string = '';
  @State diagnosisEditedPoint: string = '';
  @State goalHistory: LearningContext[] = [];
  @State diagnosisEdits: DiagnosisEdit[] = [];
  @State bookSelectedIds: string[] = [];
  @State bookSavedIds: string[] = [];
  @State bookSavingIds: string[] = [];
  @State diagnosisNoticeId: string = '';
  @State diagnosisNotice: string = '';
  @State startingDiagnosisId: string = '';
  private diagnosisKey(message: ChatMessage, question: WrongAnalysis): string { return question.diagnosisId || message.id; }
  private diagnosisPoint(message: ChatMessage, question: WrongAnalysis): string {
    const edit: DiagnosisEdit | undefined = this.diagnosisEdits.find((entry: DiagnosisEdit) => entry.id === this.diagnosisKey(message, question));
    return edit ? edit.point : (question.knowledgePoint || '');
  }
  private async saveDiagnosisToBook(message: ChatMessage, question: WrongAnalysis): Promise<void> {
    const key: string = this.diagnosisKey(message, question);
    if (this.bookSavedIds.indexOf(key) >= 0 || this.bookSavingIds.indexOf(key) >= 0 || this.bookSelectedIds.indexOf(key) < 0) return;
    if (!question.questionText?.trim()) { this.diagnosisNoticeId = key; this.diagnosisNotice = '题干识别不完整，请补拍清晰题目后再加入。'; return; }
    const owner: string = appState.currentUser.userId;
    this.bookSavingIds = this.bookSavingIds.concat([key]);
    const result = await AgentApiClient.saveScannedQuestion({ stem: question.questionText || '', courseName: question.courseName || '',
      knowledgePointName: this.diagnosisPoint(message, question), explanation: question.reply || message.wrongAnalysis?.reply || '' });
    if (!this.isPageActive || owner !== appState.currentUser.userId) return;
    this.bookSavingIds = this.bookSavingIds.filter((id: string) => id !== key);
    this.diagnosisNoticeId = key;
    if (result.ok) { this.bookSavedIds = this.bookSavedIds.concat([key]); this.diagnosisNotice = '已加入错题本，按题目内容自动分类。'; }
    else this.diagnosisNotice = '加入失败：' + (result as ApiFailure).error.message;
  }
  @Builder
  DiagnosisQuestion(message: ChatMessage, question: WrongAnalysis, index: number) {
    Column({ space: 10 }) {
      Text(`第${question.questionNumber || (index + 1).toString()}题`).fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink)
      if (question.courseName) { Text(`建议科目：${question.courseName} · 保存后可在错题本调整`).fontSize(12).fontColor(UiTheme.secondary).width('100%') }
      if (question.questionText) { Text(question.questionText).fontSize(14).fontColor(UiTheme.secondary).maxLines(4).width('100%') }
      TextInput({ text: this.diagnosisPoint(message, question), placeholder: '核对知识点' }).height(38).fontSize(13)
        .onChange((value: string) => {
          const key: string = this.diagnosisKey(message, question);
          this.diagnosisEdits = this.diagnosisEdits.filter((entry: DiagnosisEdit) => entry.id !== key).concat([{ id: key, point: value }]);
        })
      Row({ space: 8 }) {
        Checkbox().select(this.bookSelectedIds.indexOf(this.diagnosisKey(message, question)) >= 0)
          .enabled(this.bookSavedIds.indexOf(this.diagnosisKey(message, question)) < 0)
          .onChange((selected: boolean) => {
            const key: string = this.diagnosisKey(message, question);
            this.bookSelectedIds = selected ? this.bookSelectedIds.concat([key]) : this.bookSelectedIds.filter((id: string) => id !== key);
          })
        Text(this.bookSavedIds.indexOf(this.diagnosisKey(message, question)) >= 0 ? '已加入错题本' : '加入错题本（可选）').fontSize(13).fontColor(UiTheme.secondary)
      }.width('100%')
      Row({ space: 12 }) {
        Button(this.startingDiagnosisId === this.diagnosisKey(message, question) && this.isGoalLoading ? '准备中…' : '开始练习', { type: ButtonType.Normal })
          .height(36).fontSize(13).backgroundColor(UiTheme.accent).fontColor(UiTheme.surface).borderRadius(8).enabled(!this.isGoalLoading && !!question.diagnosisId && !!this.diagnosisPoint(message, question).trim())
          .onClick(() => this.confirmDiagnosis(message, question))
        if (this.bookSelectedIds.indexOf(this.diagnosisKey(message, question)) >= 0 && this.bookSavedIds.indexOf(this.diagnosisKey(message, question)) < 0) {
          Text(this.bookSavingIds.indexOf(this.diagnosisKey(message, question)) >= 0 ? '加入中…' : '确认加入').fontSize(13).fontColor(UiTheme.accent)
            .onClick(() => this.saveDiagnosisToBook(message, question))
        }
      }.width('100%')
      if (this.diagnosisNoticeId === this.diagnosisKey(message, question)) { Text(this.diagnosisNotice).fontSize(12).fontColor(UiTheme.secondary).width('100%') }
    }.width('100%').padding(12).backgroundColor(UiTheme.subtle).borderRadius(8).alignItems(HorizontalAlign.Start)
  }
  @State inboxRefreshVersion: number = 0;
  @State showGoalHistory: boolean = false;
  @State showGoalTechnical: boolean = false;
  @State learningContext: LearningContext | null = null;
  @State showLearningGoalCard: boolean = false;
  @State showGoalSummary: boolean = false;
  @State goalMessage: string = '';
  @State isGoalLoading: boolean = false;
  private goalRequestVersion: number = 0;
  private chatRequestVersion: number = 0;
  private pendingChatOwner: string = '';
  private historyRequestVersion: number = 0;
  @StorageLink('identityReady') identityReady: boolean = false;
  private messageScroller: Scroller = new Scroller();
  private workflowViewModel: WorkflowViewModel = new WorkflowViewModel();
  private workflowRequestVersion: number = 0;
  private isPageActive: boolean = false;
  private hasShownOnce: boolean = false;
  private voiceInputService: VoiceInputService = new VoiceInputService();
  private inputController: TextInputController = new TextInputController();
  private voiceRequestVersion: number = 0;
  private voiceTurnStarted: boolean = false;
  private voiceDraft: string = '';

  aboutToAppear(): void {
    this.isPageActive = true;
    this.welcomeNotice = appState.loginNotice;
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
    this.cancelVoiceInput();
    void this.voiceInputService.dispose();
  }

  onPageShow(): void {
    this.todayRevision++;
    this.inboxRefreshVersion++;
    this.isPageActive = true;
    if (!this.hasShownOnce) {
      this.hasShownOnce = true;
      return;
    }
    this.scrollToLatestMessage();
    void this.refreshLearningContext();
    void this.refreshWorkflowStatus();
  }

  onPageHide(): void {
    this.closeImagePreview();
    this.cancelVoiceInput();
    this.isPageActive = false;
    this.goalRequestVersion++;
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

  @Builder
  IdentityLoading() {
    Column({ space: 16 }) {
      Text('知学 Mate').fontSize(24).fontWeight(FontWeight.Bold).fontColor(UiTheme.accent)
      LoadingProgress().width(36).height(36).color(UiTheme.accent)
      Text('正在恢复登录状态…').fontSize(13).fontColor(UiTheme.secondary)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(UiTheme.surface)
  }

  onBackPress(): boolean {
    if (this.previewImage.length > 0) { this.closeImagePreview(); return true; }
    if (this.showHistory) { this.showHistory = false; return true; }
    if (this.showGoalHistory) { this.showGoalHistory = false; return true; }
    if (this.showFunctionWorkspace) { this.showFunctionWorkspace = false; return true; }
    return false;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (!this.identityReady) {
        this.IdentityLoading()
      } else {
        Column() {
          this.Header()
          FocusRecoveryCard()
          if (this.showFunctionWorkspace) { this.FunctionWorkspace() } else { this.MessageList() }
          this.InputBar()
          this.TabBar()
        }
        .width('100%')
        .height('100%')
        .backgroundColor(UiTheme.surface)
        if (this.showGoalHistory) {
          Column() {
            PageHeader({ title: '学习目标记录', detail: '当前对话', onBack: () => this.showGoalHistory = false })
            Scroll() {
              Column({ space: 12 }) {
                Text('查看当前对话中建立的学习任务及完成状态，点击一项可恢复任务或查看结果。专注时长请到“我的”查看。').fontSize(13).fontColor(UiTheme.secondary).lineHeight(20).width('100%')
                if (!this.goalHistory.length) { Text('还没有学习任务记录').fontSize(14).fontColor(UiTheme.muted).padding(20) }
                ForEach(this.goalHistory, (goal: LearningContext) => {
                  Row() {
                    Column({ space: 6 }) {
                      Text(goal.knowledgePointName || '待确认的练习').fontSize(16).fontColor(UiTheme.ink)
                      Text(goal.status === 'completed' ? '本次练习已完成 · 查看记录' : goal.status === 'ended' ? '已结束' : '学习进行中')
                        .fontSize(12).fontColor(UiTheme.muted)
                    }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                    Text('›').fontSize(22).fontColor(UiTheme.muted)
                  }.width('100%').padding(18).backgroundColor(UiTheme.surface).borderRadius(8)
                    .onClick(() => { this.showGoalHistory = false; void this.changeGoal('select', goal.goalId); })
                }, (goal: LearningContext) => goal.goalId)
              }.width('100%').constraintSize({ maxWidth: UiTheme.contentWidth }).padding(16).alignItems(HorizontalAlign.Start)
            }.align(Alignment.Top).layoutWeight(1).width('100%')
          }.width('100%').height('100%').backgroundColor(UiTheme.canvas)
        }
        if (this.showHistory) {
          Row() {}
            .width('100%').height('100%').backgroundColor('#66000000')
            .onClick(() => this.showHistory = false)
          this.HistoryDrawer()
        }
        if (this.previewImage.length > 0) {
          Column({ space: 12 }) {
            Row() {
              Text(this.previewNotice).fontSize(13).fontColor(UiTheme.surface).layoutWeight(1)
              Button('关闭').onClick(() => this.closeImagePreview())
            }.width('100%').padding(16)
            Image(this.previewImage).width('100%').layoutWeight(1).objectFit(ImageFit.Contain)
          }.width('100%').height('100%').backgroundColor('#F2111827')
        }
      }
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.showLearningGoalCard, this.GoalDetails(), {
      height: SheetSize.FIT_CONTENT, title: { title: '当前目标详情' }, showClose: true, dragBar: true,
      backgroundColor: UiTheme.surface
    })
  }

  @Builder
  private GoalDetails() {
    if (this.learningContext !== null) { this.LearningGoalCard(this.learningContext) }
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
        found.turns.unshift(record);
        found.title = record.userInput;
        found.startedAt = record.timestamp;
      }
    }
    return sessions;
  }

  private restoreHistory(session: ChatHistorySession): void {
    this.chatRequestVersion++;
    this.goalRequestVersion++;
    this.isSending = false;
    this.isGoalLoading = false;
    this.inputText = '';
    this.pendingImage = '';
    this.pendingFileName = ''; this.pendingFileText = ''; this.pendingFileTruncated = false; this.fileRevision++; this.fileBusy = false;
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
        Text('历史会话').fontSize(19).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink)
        Blank()
        Text('关闭').fontSize(14).fontColor(UiTheme.accent).onClick(() => this.showHistory = false)
      }.width('100%').padding({ left: 18, right: 18, top: 20, bottom: 14 })
      if (this.historyLoading) {
        LoadingProgress().width(34).height(34).margin({ top: 48 })
      } else if (this.historySessions.length === 0) {
        Text('暂无历史会话').fontSize(14).fontColor(UiTheme.secondary).margin({ top: 48 })
      } else {
        List({ space: 8 }) {
          ForEach(this.historySessions, (session: ChatHistorySession) => {
            ListItem() {
              Column({ space: 5 }) {
                Text(session.title).fontSize(15).fontWeight(FontWeight.Medium)
                  .fontColor(UiTheme.ink).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                Text(session.turns[session.turns.length - 1].botResponse)
                  .fontSize(12).fontColor(UiTheme.secondary).maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                Row() {
                  Text(`${session.turns.length} 轮对话`).fontSize(12).fontColor(UiTheme.accent)
                  Blank()
                  Text(session.updatedAt.length >= 16
                    ? session.updatedAt.substring(0, 16).replace('T', ' ') : '')
                    .fontSize(11).fontColor(UiTheme.muted)
                }.width('100%')
              }.width('100%').alignItems(HorizontalAlign.Start).padding(13)
                .backgroundColor(UiTheme.surface).border({ width: { bottom: 1 }, color: UiTheme.line })
                .onClick(() => this.restoreHistory(session))
            }
          }, (session: ChatHistorySession) => session.sessionId)
        }.layoutWeight(1).width('100%').padding({ left: 14, right: 14, bottom: 20 })
      }
    }.width('100%').height('100%').backgroundColor(UiTheme.surface)

  }

  @Builder
  private TabBar() {
    AppBottomBar({ selected: this.activeTab, onSelect: (index: number) => this.switchTab(index) })
  }

  @Builder
  private TabItem(icon: Resource, selectedIcon: Resource, label: string, index: number) {
    Column({ space: 6 }) {
      Image(this.activeTab === index ? selectedIcon : icon)
        .width(22).height(22).objectFit(ImageFit.Contain)
      Text(label).fontSize(12)
        .fontWeight(this.activeTab === index ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.activeTab === index ? UiTheme.accent : UiTheme.secondary)
    }
    .layoutWeight(1).height(62).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    .accessibilityText(label)
    .backgroundColor(this.activeTab === index ? UiTheme.tint : UiTheme.surface).borderRadius(8)
    .onClick(() => this.switchTab(index))
  }

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
        Text(this.isWorkflowLoading ? '···' : 'AI').fontSize(11).fontWeight(FontWeight.Bold).fontColor(UiTheme.surface)
      }.width(28).height(28).borderRadius(8).justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center).backgroundColor(this.workflowMessage.length > 0 ? '#B45309' : UiTheme.accent)
      Column({ space: 2 }) {
        Text(this.workflowTitle.length > 0 ? this.workflowTitle : 'Agent 状态暂时无法同步')
          .fontSize(12).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink)
        Text(this.workflowMessage.length > 0 ? this.workflowMessage : this.workflowDetail)
          .fontSize(11).fontColor(UiTheme.secondary).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      if (this.workflowMessage.length > 0) {
        Text('重试').fontSize(12).fontWeight(FontWeight.Bold).fontColor('#B45309')
          .onClick(() => this.refreshWorkflowStatus())
      } else {
        Text(this.workflowStateVersion > 0 ? `v${this.workflowStateVersion} ›` : '查看 ›')
          .fontSize(12).fontWeight(FontWeight.Bold).fontColor(UiTheme.accent)
          .onClick(() => router.pushUrl({ url: 'pages/AgentTrace' }))
      }
    }.width('100%').padding({ left: 16, right: 16, top: 9, bottom: 9 })
      .backgroundColor(this.workflowMessage.length > 0 ? '#FFFBEB' : UiTheme.tint)
  }

  @Builder
  private Header() {
    Row({ space: 2 }) {
      Button({ type: ButtonType.Normal }) {
        Column({ space: 1 }) {
          Image($r('app.media.ui_history')).width(20).height(20)
          Text('历史').fontSize(10).fontColor(UiTheme.secondary)
        }
      }.width(40).height(44).backgroundColor(UiTheme.surface).borderRadius(8)
        .accessibilityText('历史会话').onClick(() => this.openHistory())
      Button({ type: ButtonType.Normal }) {
        Column({ space: 1 }) {
          Image($r('app.media.ui_compose')).width(20).height(20)
          Text('新对话').fontSize(10).fontColor(UiTheme.secondary)
        }
      }.width(40).height(44).backgroundColor(UiTheme.surface).borderRadius(8)
        .accessibilityText('新对话').onClick(() => this.resetChat())
      Text(this.showFunctionWorkspace ? this.functionLabel() : '知学 Mate').fontSize(18).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink)
        .layoutWeight(1).textAlign(TextAlign.Center)
      PartnerInboxButton({ refreshVersion: this.inboxRefreshVersion })
      }.width('100%').constraintSize({ minHeight: 56, maxWidth: UiTheme.conversationWidth })
        .padding({ left: 12, right: 12 }).backgroundColor(UiTheme.surface)
      .bindSheet($$this.showLearningFunctions, this.IntentBar(), { height: SheetSize.FIT_CONTENT, title: { title: '添加内容与学习功能' }, showClose: true, dragBar: true, backgroundColor: UiTheme.surface })
  }

  @Builder
  private IntentBar() {
    Column() {
      Button('添加图片', { type: ButtonType.Normal }).width('100%').height(48).fontSize(16).fontColor(UiTheme.ink).backgroundColor(UiTheme.surface)
        .onClick(() => { this.showLearningFunctions = false; void this.pickImage(); })
      Button('添加文件', { type: ButtonType.Normal }).width('100%').height(48).fontSize(16).fontColor(UiTheme.ink).backgroundColor(UiTheme.surface)
        .onClick(() => { this.showLearningFunctions = false; void this.pickDocument(); })
      Divider().color(UiTheme.line)
      Text('学习功能').fontSize(12).fontColor(UiTheme.secondary).width('100%').padding({ top: 12, bottom: 4 })
      ForEach(INTENT_CHIPS, (item: IntentChip) => {
        Button(item.label, { type: ButtonType.Normal }).width('100%').height(52)
          .fontSize(16).fontColor(UiTheme.ink).backgroundColor(UiTheme.surface)
          .borderRadius(0).align(Alignment.Start)
          .border({ width: { bottom: 1 }, color: UiTheme.line })
          .onClick(() => { this.showLearningFunctions = false; this.chooseIntent(item); })
      }, (item: IntentChip) => item.intent)
    }.width('100%').padding({ left: 20, right: 20, bottom: 24 })
  }

  private chooseIntent(item: IntentChip): void {
    this.voiceMessage = '';
    this.showGoalSummary = false;
    this.selectedIntent = item.intent;
    this.inputText = item.prompt;
    this.showFunctionWorkspace = true;
  }

  private functionLabel(): string {
    return INTENT_CHIPS.find((item: IntentChip) => item.intent === this.selectedIntent)?.label || '学习功能';
  }

  private functionHint(): string {
    switch (this.selectedIntent) {
      case 'analyze_wrong': return '上传清晰的题目图片，核对题干后查看答案、解题步骤和补强建议。';
      case 'analyze_weakness': return '按课程查看练习表现、薄弱知识点和掌握变化，再选择下一步练习。';
      case 'match_partner': return '根据课程、目标和空闲时间寻找搭子，查看已有关系与协同安排。';
      case 'query_tasks': return '查看今天安排的任务、预计时长和待处理作业。';
      case 'update_profile': return '在下方说明课程、目标或学习情况的变化，确认后再更新画像。';
      default: return '结合已有课程、待办和练习记录，获取今天可以执行的学习建议。';
    }
  }

  private functionActionLabel(): string {
    switch (this.selectedIntent) {
      case 'analyze_wrong': return '上传错题并诊断';
      case 'analyze_weakness': return '查看学情画像';
      case 'match_partner': return '查看学习搭子';
      case 'query_tasks': return '查看今日任务';
      case 'update_profile': return '开始更新对话';
      default: return '获取今日学习建议';
    }
  }

  private openFunction(): void {
    let target: string = '';
    if (this.selectedIntent === 'analyze_wrong') target = 'pages/WrongQuestion';
    else if (this.selectedIntent === 'analyze_weakness') target = 'pages/StudyTags';
    else if (this.selectedIntent === 'match_partner') target = 'pages/PartnerMatch';
    else if (this.selectedIntent === 'query_tasks') target = 'pages/StudyPlan';
    if (target) { router.pushUrl({ url: target }); return; }
    void this.sendMessage();
  }

  @Builder
  private FunctionWorkspace() {
    Scroll() {
      Column({ space: 18 }) {
        Row() {
          Text('当前学习功能').fontSize(12).fontColor(UiTheme.secondary).layoutWeight(1)
          Text('更换功能 ›').fontSize(13).fontColor(UiTheme.accent).height(44).padding({ top: 13 })
            .onClick(() => this.showLearningFunctions = true)
        }.width('100%')
        Text(this.functionLabel()).fontSize(24).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).width('100%')
        Text(this.functionHint()).fontSize(15).lineHeight(24).fontColor(UiTheme.secondary).width('100%')
        if (this.selectedIntent === 'analyze_wrong') {
          Text('选择题目 → 核对识别 → 查看解析').fontSize(13).fontColor(UiTheme.secondary).width('100%')
        }
        Button(this.functionActionLabel(), { type: ButtonType.Normal }).width('100%').height(46).fontSize(15)
          .backgroundColor(UiTheme.accent).fontColor('#FFFFFF').borderRadius(8).enabled(!this.isSending)
          .onClick(() => this.openFunction())
        Text('返回对话 ›').fontSize(14).fontColor(UiTheme.secondary).height(44).padding({ top: 12 })
          .onClick(() => this.showFunctionWorkspace = false)
      }.width('100%').constraintSize({ maxWidth: UiTheme.contentWidth }).padding(20).alignItems(HorizontalAlign.Start)
    }.width('100%').layoutWeight(1).align(Alignment.Top).scrollBar(BarState.Off)
  }

  @Builder
  private MessageList() {
    List({ space: 4, scroller: this.messageScroller }) {
      if (this.messages.length === 0) {
        ListItem() { this.WelcomeBlock() }
      }
      ForEach(this.messages, (item: ChatMessage) => {
        ListItem() { this.MessageBubble(item) }
      }, (item: ChatMessage) => item.id)
      if (this.learningContext !== null && this.showGoalSummary) {
        ListItem() {
          Row({ space: 8 }) {
            Text(`当前目标：${this.learningContext.knowledgePointName || '待选择知识点'}`)
              .fontSize(13).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).layoutWeight(1)
            Text('详情 ›').fontSize(13).fontColor(UiTheme.accent)
          }.width('100%').constraintSize({ minHeight: 44 }).padding(12)
            .backgroundColor(UiTheme.subtle).borderRadius(8)
            .onClick(() => this.showLearningGoalCard = true)
        }.padding({ left: 20, right: 20, top: 8, bottom: 12 })
      }
    }.layoutWeight(1).width('100%').constraintSize({ maxWidth: UiTheme.conversationWidth }).padding({ top: 8, bottom: 8 }).backgroundColor(UiTheme.surface)
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
    this.startingDiagnosisId = editId;
    this.diagnosisNoticeId = editId;
    this.diagnosisNotice = '正在为这道题准备练习…';
    if (this.isGoalLoading) return;
    const owner: string = appState.currentUser.userId;
    const chatId: string = appState.chatSessionId;
    this.isGoalLoading = true;
    const version: number = ++this.goalRequestVersion;
    const result = await AgentApiClient.manageChatGoal(chatId, { action: 'start', diagnosisId: question?.diagnosisId,
      knowledgePoint: question ? this.diagnosisPoint(message, question) : '' });
    if (owner !== appState.currentUser.userId || chatId !== appState.chatSessionId || version !== this.goalRequestVersion) return;
    this.isGoalLoading = false;
    if (result.ok) {
      this.showGoalSummary = true; this.learningContext = result.data.learningContext ?? null;
      this.showLearningGoalCard = false; this.goalMessage = ''; void this.loadGoalHistory();
      if (this.learningContext !== null) {
        await this.continueLearningGoal(this.learningContext);
        if (this.isPageActive) { this.diagnosisNoticeId = editId; this.diagnosisNotice = this.goalMessage || '练习已准备，可在下方任务卡继续。'; this.messageScroller.scrollEdge(Edge.Bottom); }
      }
    } else { this.goalMessage = (result as ApiFailure).error.message; this.diagnosisNotice = this.goalMessage; }
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
    if (failure.error.statusCode === 404) {
      this.learningContext = null;
      this.showLearningGoalCard = false;
      this.showGoalSummary = false;
      this.goalMessage = '';
      return;
    }
    if (this.learningContext !== null) {
      this.goalMessage = `目标状态刷新失败：${failure.error.message}（上方显示的是上一次读取到的目标）`;
    }
  }

  private isLearningIntent(intent: string): boolean {
    return intent === 'get_suggestion' || intent === 'analyze_weakness' || intent === 'analyze_wrong';
  }

  private roleLabel(role: string): string {
    if (role === 'secretary' || role === 'clarify' || role === 'finish') return '流程编排';
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
      router.pushUrl({ url: target, params: { initialTab: 'import' } });
    } else if (target === 'pages/StudyPlan' || target === 'pages/StudyTags') {
      router.pushUrl({ url: target });
    }
  }

  @Builder
  private LearningGoalCard(context: LearningContext) {
    Column({ space: 16 }) {
      Row() {
        Text('进度状态').fontSize(14).fontColor(UiTheme.secondary).width(84)
        Text(context.status === 'completed' ? '已完成' : context.status === 'ended' ? '已结束' : '进行中')
          .fontSize(14).fontColor(UiTheme.accent).layoutWeight(1)
      }.width('100%')
      Divider().color(UiTheme.line)
      Row({ space: 12 }) {
        Text('目标').fontSize(14).fontColor(UiTheme.secondary).width(72)
        Text(context.goal || context.knowledgePointName || '待确认学习目标').fontSize(14)
          .fontColor(UiTheme.ink).lineHeight(22).layoutWeight(1)
      }.width('100%').alignItems(VerticalAlign.Top)
      Divider().color(UiTheme.line)
      Row({ space: 12 }) {
        Text('测评状态').fontSize(14).fontColor(UiTheme.secondary).width(72)
        Text(context.assessmentStatus === 'assessed' ? `已测评 ${context.assessedQuestionCount} 道题` : '尚未提交测评')
          .fontSize(14).fontColor(UiTheme.ink).layoutWeight(1)
      }.width('100%')
      Divider().color(UiTheme.line)
      Row({ space: 12 }) {
        Text('下一步').fontSize(14).fontColor(UiTheme.secondary).width(72)
        Text(context.nextAction || '继续当前学习任务').fontSize(14).fontColor(UiTheme.ink).lineHeight(22).layoutWeight(1)
      }.width('100%').alignItems(VerticalAlign.Top)
      if (context.waitingFor === 'knowledge_points' || context.waitingFor === 'available_time' || context.status === 'tool_failed') {
        Text(context.waitingFor === 'knowledge_points' ? '请导入资料并确认知识点。' : context.waitingFor === 'available_time' ? '请先设置可用学习时间。' : '练习准备失败，可重试。')
          .fontSize(13).fontColor(UiTheme.secondary).width('100%')
      }
      if (this.goalMessage.length > 0) Text(this.goalMessage).fontSize(13).fontColor(UiTheme.danger).width('100%')
      Button(this.isGoalLoading ? '正在继续…' : context.action.label || '继续学习', { type: ButtonType.Normal })
        .width('100%').height(46).fontSize(15).fontColor(UiTheme.surface).backgroundColor(UiTheme.accent).borderRadius(8)
        .enabled(!this.isGoalLoading && context.status !== 'ended' && !context.needsConfirmation)
        .onClick(() => this.continueLearningGoal(context))
      if (context.status !== 'completed' && context.status !== 'ended') {
        Button('结束本次任务', { type: ButtonType.Normal }).width('100%').height(44)
          .fontSize(14).fontColor(UiTheme.secondary).backgroundColor(UiTheme.subtle).borderRadius(8)
          .onClick(() => { void this.changeGoal('end', context.goalId); })
      }
      Button(this.showGoalTechnical ? '收起进度详情' : '进度详情', { type: ButtonType.Normal })
        .width('100%').height(44).fontSize(14).fontColor(UiTheme.ink).backgroundColor(UiTheme.surface)
        .onClick(() => this.showGoalTechnical = !this.showGoalTechnical)
      if (this.showGoalTechnical) {
        Text(context.sourceMode === 'materials' ? '题目来源：上传资料，可在练习中查看原文。' : '题目来源：通用知识练习。')
          .fontSize(13).fontColor(UiTheme.secondary).width('100%')
        Text(context.assessmentStatus === 'assessed' ? `已保存 ${context.assessedQuestionCount} 道题的测评记录。` : '提交测评后可查看结果，未提交不判断掌握情况。')
          .fontSize(13).fontColor(UiTheme.secondary).width('100%')
      }
    }.width('100%').padding({ left: 20, right: 20, top: 8, bottom: 24 })
  }

  private greetingText(): string {
    const hour: number = new Date().getHours();
    if (hour < 6) return '夜深了';
    if (hour < 12) return '早上好';
    if (hour < 18) return '下午好';
    return '晚上好';
  }

  @Builder
  private WelcomeBlock() {
    Column({ space: 12 }) {
      Text(`${this.greetingText()}${appState.authNickname ? '，' + appState.authNickname : ''}`)
        .fontSize(13).fontColor(UiTheme.secondary).width('100%')
      Text('今天，先完成一件事。').fontSize(23).fontWeight(FontWeight.Medium)
        .fontColor(UiTheme.ink).width('100%').margin({ bottom: 12 })
      TodayPanel({ revision: this.todayRevision })
      if (this.welcomeNotice.length > 0) {
        Text(this.welcomeNotice).fontSize(13).lineHeight(20).fontColor(UiTheme.secondary)
          .width('100%').padding(12).backgroundColor(UiTheme.tint).borderRadius(8)
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
      .padding({ left: 20, right: 20, top: 16, bottom: 20 })
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

  private async copyChatMessage(text: string): Promise<void> {
    this.menuMessageId = '';
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text));
      this.getUIContext().getPromptAction().showToast({ message: '已复制' });
    } catch (_) {
      this.getUIContext().getPromptAction().showToast({ message: '复制失败，请重试' });
    }
  }

  @Builder
  private MessageActions(message: ChatMessage) {
    Row() {
      if (message.text) {
        ChatMessageAction({ icon: $r('sys.symbol.rectangle_on_rectangle'), label: '复制', onAction: () => { void this.copyChatMessage(message.text); } })
      }
      if (message.role === 'user' && message.text && !this.inputText) {
        ChatMessageAction({ icon: $r('sys.symbol.square_and_pencil'), label: '编辑', onAction: () => {
          this.menuMessageId = '';
          if (this.inputText) return;
          this.cancelVoiceInput();
          this.inputText = message.text;
        } })
      }
      if (message.image) {
        ChatMessageAction({ icon: $r('sys.symbol.picture'), label: '查看', onAction: () => {
          this.menuMessageId = '';
          void this.openImagePreview(message);
        } })
      }
    }.padding(4)
  }

  @Builder
  private MessageBubble(message: ChatMessage) {
    Row({ space: 10 }) {
      if (message.role === 'user') {
        Blank()
      }

      Column({ space: 8 }) {
        Column({ space: 8 }) {
          if (message.image !== undefined && message.image.length > 0) {
            Image(message.image)
              .width(112)
              .height(84)
              .objectFit(ImageFit.Cover)
              .borderRadius(8)
              .backgroundColor(UiTheme.line)
              .onClick(() => { void this.openImagePreview(message); })
          }

          if (message.status === 'sending') {
            Row({ space: 5 }) {
              Text('').width(6).height(6).borderRadius(3).backgroundColor('#8E99A8')
              Text('').width(6).height(6).borderRadius(3).backgroundColor('#B3BBC6')
              Text('').width(6).height(6).borderRadius(3).backgroundColor('#D0D6DE')
            }
            .padding({ left: 14, right: 14, top: 12, bottom: 12 })
            .backgroundColor(UiTheme.surface)
            .borderRadius(8)
          } else {
            Text(message.text)
              .fontSize(15)
              .lineHeight(22)
              .fontColor(message.role === 'user' ? UiTheme.surface : '#1F2933')
              .padding({ left: 14, right: 14, top: 11, bottom: 11 })
              .backgroundColor(message.role === 'user' ? UiTheme.accent : UiTheme.surface)
              .borderRadius(8)
          }
        }.alignItems(message.role === 'user' ? HorizontalAlign.End : HorizontalAlign.Start)
          .gesture(LongPressGesture().onAction(() => {
            if (message.status !== 'sending' && (message.text || message.image)) this.menuMessageId = message.id;
          }))
          .bindPopup(this.menuMessageId === message.id, {
            builder: this.MessageActions(message), placement: Placement.Top, enableArrow: true,
            popupColor: '#353535', backgroundBlurStyle: BlurStyle.NONE, autoCancel: true,
            onStateChange: (event) => { if (!event.isVisible && this.menuMessageId === message.id) this.menuMessageId = ''; }
          })

        if (message.role === 'agent' && message.status === 'done' && message.sourceLabel !== undefined) {
          Text(message.sourceLabel)
            .fontSize(11)
            .fontColor(UiTheme.accent)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .backgroundColor(UiTheme.surface)
            .borderRadius(8)
        }

        if (message.attachmentStatus !== undefined) Text(message.attachmentStatus).fontSize(12).fontColor(UiTheme.secondary)
        if (message.wrongAnalysis?.questions !== undefined && message.wrongAnalysis.questions.length > 1) {
          Text('只识别分析，不会自动加入错题本。可逐题选择收藏或开始练习。').fontSize(12).fontColor(UiTheme.muted)
          ForEach(message.wrongAnalysis.questions, (question: WrongAnalysis, index: number) => {
            this.DiagnosisQuestion(message, question, index)
          }, (question: WrongAnalysis, index: number) => question.diagnosisId || `${message.id}-${index}`)
        } else if (message.wrongAnalysis?.questionText) {
          this.DiagnosisQuestion(message, message.wrongAnalysis, 0)
        }
        if (message.card !== undefined) {
          this.CardView(message.card)
        }
      }
      .alignItems(message.role === 'user' ? HorizontalAlign.End : HorizontalAlign.Start)
      .width('78%')

      if (message.role === 'user') {
        UserAvatar({ nickname: appState.authNickname || '我', source: appState.authAvatar, diameter: 36 })
      } else {
        Blank()
      }
    }
    .width('100%').alignItems(VerticalAlign.Top)
    .justifyContent(message.role === 'user' ? FlexAlign.End : FlexAlign.Start)
    .padding({ left: 16, right: 16, top: 5, bottom: 5 })
  }

  @Builder
  private CardView(card: ChatCard) {
    Column({ space: 6 }) {
      Row() {
        Text(this.getCardLabel(card))
          .fontSize(12)
          .fontColor(UiTheme.accent)
          .fontWeight(FontWeight.Medium)
        Blank()
        Text('查看 ›')
          .fontSize(12)
          .fontColor(UiTheme.secondary)
      }
      .width('100%')

      Text(card.title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(UiTheme.ink)
        .maxLines(1)
      Text(card.summary)
        .fontSize(13)
        .fontColor(UiTheme.secondary)
        .lineHeight(18)
        .maxLines(2)

      if (card.actions !== undefined && card.actions.length > 0) {
        Row({ space: 8 }) {
          ForEach(card.actions, (action: ChatAction) => {
            Button(action.label)
              .fontSize(12)
              .fontColor(UiTheme.accent)
              .backgroundColor(UiTheme.surface)
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
    .backgroundColor(UiTheme.subtle)
    .border({ width: 1, color: UiTheme.line })
    .borderRadius(8)
    .onClick(() => {
      if (card.actions !== undefined && card.actions.length > 0) {
        this.openAction(card.actions[0]);
      } else if (card.targetPage.length > 0) {
        router.pushUrl({ url: card.targetPage });
      }
    })
  }

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
            .fontSize(11).fontColor(this.isListening ? UiTheme.danger : UiTheme.accent)
          Text(this.voiceMessage).fontSize(12).fontColor(UiTheme.secondary).layoutWeight(1)
        }.width('100%').padding({ left: 10, right: 10, top: 7, bottom: 7 })
          .backgroundColor(this.isListening ? '#FEF2F2' : UiTheme.tint).borderRadius(8)
      }
      if (this.pendingFileName) {
        Row({ space: 8 }) {
          Text(this.pendingFileName).fontSize(13).fontColor(UiTheme.ink).layoutWeight(1).maxLines(2)
          Button('移除文件', { type: ButtonType.Normal }).height(44).fontSize(12).fontColor(UiTheme.secondary).backgroundColor(UiTheme.surface)
            .onClick(() => { this.pendingFileName = ''; this.pendingFileText = ''; this.pendingFileTruncated = false; })
        }.width('100%').padding(10).backgroundColor(UiTheme.subtle).borderRadius(8)
      }
      if (this.pendingImage.length > 0) {
        Row({ space: 10 }) {
          Image(this.pendingImage)
            .width(54)
            .height(54)
            .objectFit(ImageFit.Cover)
            .borderRadius(8)
            .backgroundColor(UiTheme.line)
          Text('已添加图片')
            .fontSize(13)
            .fontColor(UiTheme.secondary)
          Blank()
          Button('移除')
            .fontSize(12)
            .fontColor(UiTheme.secondary)
            .backgroundColor(UiTheme.subtle)
            .height(30)
            .borderRadius(8)
            .onClick(() => this.pendingImage = '')
        }
        .width('100%')
      }

      ChatComposer({
        draft: this.inputText, placeholder: '问学习建议、错题、计划或搭子', maxLength: 0,
        toolsLabel: '添加图片、文件或选择学习功能', busy: this.isSending || this.fileBusy,
        canSend: this.canSend(), voiceMode: this.voiceMode, voiceReady: this.voiceReady,
        voicePressing: this.voicePressing, voiceTurnStarted: this.voiceTurnStarted,
        startingVoice: this.isVoiceStarting, listening: this.isListening, inputController: this.inputController,
        onDraftChange: (value: string) => {
          if (this.isVoiceFinalizing && value !== this.inputText) {
            this.cancelVoiceInput();
            this.voiceMessage = '已保留文字，可修改后发送。';
          }
          this.inputText = value;
        },
        onVoiceToggle: () => { void this.toggleVoiceMode(); },
        onVoiceDown: () => { this.voicePressing = true; },
        onVoiceStart: () => { void this.startVoiceInput(); },
        onVoiceEnd: (cancelled: boolean) => { void this.endVoiceHold(cancelled); },
        onImage: () => { void this.pickImage(); },
        onTools: () => { this.showLearningFunctions = true; },
        onSend: () => { void this.sendMessage(); }
      })
    }
    .width('100%')
    .constraintSize({ maxWidth: UiTheme.conversationWidth })
    .padding({ left: 14, right: 14, top: 10, bottom: 14 })
    .backgroundColor(UiTheme.surface)
  }

  private canSend(): boolean {
    return !this.isSending && !this.fileBusy && !this.isVoiceStarting && !this.isListening && !this.isVoiceFinalizing &&
      (this.inputText.trim().length > 0 || this.pendingImage.length > 0 || this.pendingFileText.length > 0);
  }

  private resetChat(): void {
    this.cancelVoiceInput();
    this.goalRequestVersion++;
    this.chatRequestVersion++;
    this.learningContext = null;
    this.showLearningGoalCard = false;
    this.showGoalSummary = false;
    this.goalMessage = '';
    this.isGoalLoading = false;
    this.messages = [];
    this.inputText = '';
    this.pendingImage = '';
    this.pendingFileName = ''; this.pendingFileText = ''; this.pendingFileTruncated = false; this.fileRevision++; this.fileBusy = false;
    this.selectedIntent = 'get_suggestion';
    this.showFunctionWorkspace = false;
    this.isSending = false;
    appState.hasActiveChat = false;
    appState.chatMessages = '';
    appState.chatSessionId = '';
  }

  private async toggleVoiceMode(): Promise<void> {
    if (this.voiceMode) {
      this.cancelVoiceInput();
      return;
    }
    this.cancelVoiceInput();
    this.voiceMode = true;
    this.voiceReady = false;
    this.inputController.stopEditing();
    this.voiceMessage = '正在准备麦克风…';
    const revision: number = this.voiceRequestVersion;
    const owner: string = appState.currentUser.userId;
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const permissions: Permissions[] = ['ohos.permission.MICROPHONE'];
    try {
      const result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, permissions);
      if (!this.isCurrentVoiceRequest(revision, owner) || !this.voiceMode) return;
      if (result.authResults.length === 0 || result.authResults[0] !== 0) {
        this.voiceMode = false;
        this.voiceMessage = '麦克风权限未开启，可在系统设置中允许后重试。';
        return;
      }
      this.voiceReady = true;
      this.voiceMessage = '按住说话，松开后可修改文字再发送。';
    } catch (error) {
      if (!this.isCurrentVoiceRequest(revision, owner)) return;
      this.voiceMode = false;
      this.voiceMessage = '无法申请麦克风权限，请在系统设置中检查权限。';
    }
  }

  private isCurrentVoiceRequest(revision: number, owner: string): boolean {
    return this.isPageActive && revision === this.voiceRequestVersion && owner === appState.currentUser.userId;
  }

  private async startVoiceInput(): Promise<void> {
    if (!this.isPageActive || !this.voiceMode || !this.voiceReady || !this.voicePressing ||
      this.isSending || this.fileBusy || this.isVoiceStarting || this.isListening || this.isVoiceFinalizing) return;
    const revision: number = ++this.voiceRequestVersion;
    const owner: string = appState.currentUser.userId;
    this.voiceTurnStarted = true;
    this.voiceDraft = this.inputText;
    this.isVoiceStarting = true;
    this.voiceMessage = '正在打开麦克风，请保持按住…';
    const callbacks: VoiceInputCallbacks = new VoiceInputCallbacks(
      (listening: boolean): void => {
        if (!this.isCurrentVoiceRequest(revision, owner)) return;
        this.isListening = listening;
        this.isVoiceStarting = false;
        if (listening) this.voiceMessage = '正在聆听，松开后可编辑识别文字。';
      },
      (text: string, isFinal: boolean): void => {
        if (!this.isCurrentVoiceRequest(revision, owner)) return;
        this.inputText = this.voiceDraft + text;
        this.voiceMessage = this.voicePressing ? '正在识别，松开后可修改。' : '正在整理识别结果，可直接修改文字。';
      },
      (message: string): void => {
        if (!this.isCurrentVoiceRequest(revision, owner)) return;
        this.isListening = false;
        this.isVoiceStarting = false;
        this.isVoiceFinalizing = false;
        if (!this.voicePressing) this.voiceMode = false;
        this.voiceMessage = message;
      },
      (): void => {
        if (!this.isCurrentVoiceRequest(revision, owner)) return;
        this.isListening = false;
        this.isVoiceStarting = false;
        this.isVoiceFinalizing = false;
        if (!this.voicePressing) this.voiceMode = false;
        this.voiceMessage = this.inputText === this.voiceDraft ? '未识别到语音，请重新按住说话。' : '已转换为文字，可修改后发送。';
      }
    );
    await this.voiceInputService.start(callbacks);
  }

  private async endVoiceHold(cancelled: boolean): Promise<void> {
    this.voicePressing = false;
    if (!this.voiceTurnStarted) return;
    this.voiceTurnStarted = false;
    if (cancelled) {
      const draft: string = this.voiceDraft;
      this.cancelVoiceInput();
      this.inputText = draft;
      this.voiceMessage = '已取消本次语音输入。';
      return;
    }
    this.voiceMode = false;
    if (!this.isListening && !this.isVoiceStarting) return;
    this.isVoiceFinalizing = true;
    this.voiceMessage = '正在整理识别结果，可直接修改文字。';
    await this.voiceInputService.stop(true);
  }

  private cancelVoiceInput(): void {
    this.voiceRequestVersion++;
    this.voiceMode = false;
    this.voiceReady = false;
    this.voicePressing = false;
    this.voiceTurnStarted = false;
    this.isVoiceStarting = false;
    this.isVoiceFinalizing = false;
    this.isListening = false;
    void this.voiceInputService.stop(false);
  }

  private async pickDocument(): Promise<void> {
    if (this.isSending || this.fileBusy) return;
    const owner: string = appState.currentUser.userId;
    const session: string = appState.chatSessionId;
    const revision: number = ++this.fileRevision;
    this.fileBusy = true; this.voiceMessage = '请选择 PDF、Word、PPT、TXT 或 Markdown 文件，最大8MB。';
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const uris: string[] = await documentPicker.select();
      if (!uris.length) return;
      const uri: string = uris[0];
      const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      let encoded: string = '';
      try {
        const size: number = fileIo.statSync(file.fd).size;
        if (size <= 0 || size > 8 * 1024 * 1024) { this.voiceMessage = '请选择非空且不超过8MB的文件。'; return; }
        const buffer: ArrayBuffer = new ArrayBuffer(size);
        if (fileIo.readSync(file.fd, buffer) !== size) { this.voiceMessage = '文件读取不完整，请重新选择。'; return; }
        encoded = new util.Base64Helper().encodeToStringSync(new Uint8Array(buffer));
      } finally { fileIo.closeSync(file); }
      if (owner !== appState.currentUser.userId || session !== appState.chatSessionId || revision !== this.fileRevision) return;
      this.voiceMessage = '正在读取文件内容…';
      const result = await AgentApiClient.readChatFile({ fileName: decodeURIComponent(uri.split('/').pop() || '学习资料.txt'), contentBase64: encoded });
      if (!this.isPageActive || owner !== appState.currentUser.userId || session !== appState.chatSessionId || revision !== this.fileRevision) return;
      if (result.ok) { this.pendingFileName = result.data.fileName; this.pendingFileText = result.data.text; this.pendingFileTruncated = result.data.truncated;
        this.voiceMessage = result.data.truncated ? '文件已添加，本次对话使用前12000字；长文可导入知识库。' : '文件已添加，发送后可结合文件提问。'; }
      else this.voiceMessage = (result as ApiFailure).error.message;
    } catch (error) {
      if (owner === appState.currentUser.userId && revision === this.fileRevision) this.voiceMessage = '文件选择或读取失败，请重试。';
    } finally { if (revision === this.fileRevision) this.fileBusy = false; }
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
    this.isSending = true;
    this.showFunctionWorkspace = false;
    const owner: string = appState.currentUser.userId;
    const requestVersion: number = ++this.chatRequestVersion;
    this.pendingChatOwner = owner;

    if (appState.chatSessionId.length === 0) {
      appState.chatSessionId = `chat-${Date.now()}`;
    }
    const chatId: string = appState.chatSessionId;

    const fileName: string = this.pendingFileName;
    const fileText: string = this.pendingFileText;
    const fileTruncated: boolean = this.pendingFileTruncated;
    const questionText: string = this.inputText.trim() || (fileText ? '请总结这份文件的学习重点' : '请分析这张图片');
    const text: string = questionText + (fileName ? `\n附件：${fileName}` : '');
    const document: ChatFile | undefined = fileText ? { fileName: fileName, text: fileText, truncated: fileTruncated } : undefined;
    this.showLearningGoalCard = false;
    this.showGoalSummary = false;
    const bubbleImage: string | undefined = this.pendingImage.length > 0 ? this.pendingImage : undefined;
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
      status: 'sending',
      progressText: imageForAgent ? '正在上传图片，识别结果会在这里显示…' : '正在发送…'
    };

    const historyBeforeSend: ChatMessage[] = this.messages;
    this.messages = [...this.messages, userMessage, loadingMessage];
    this.inputText = '';
    this.pendingImage = '';
    this.pendingFileName = ''; this.pendingFileText = ''; this.pendingFileTruncated = false; this.fileRevision++; this.fileBusy = false;
    this.isSending = true;
    this.scrollToLatestMessage();

    try {
      const response = await AgentBridge.callAgent(questionText, imageForAgent, historyBeforeSend, (progress) => {
        if (requestVersion !== this.chatRequestVersion || owner !== appState.currentUser.userId ||
          chatId !== appState.chatSessionId) return;
        this.messages = this.messages.map((item: ChatMessage): ChatMessage => item.id === loadingMessage.id ? {
          id: item.id, role: item.role, text: progress.reply || item.text,
          time: item.time, status: 'sending', progressText: progress.message
        } : item);
      }, document);
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
      this.pendingImage = bubbleImage ?? '';
      this.pendingFileName = fileName; this.pendingFileText = fileText; this.pendingFileTruncated = fileTruncated;
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
