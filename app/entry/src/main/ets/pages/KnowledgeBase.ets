import { AppBottomBar } from '../components/AppBottomBar';
import { UiTheme } from '../utils/UiTheme';
import { PageHeader } from '../components/PageHeader';
import router from '@ohos.router';
import { util } from '@kit.ArkTS';
import { fileIo, picker } from '@kit.CoreFileKit';
import { AgentApiClient } from '../api/AgentApiClient';
import {
  KnowledgeBase,
  KnowledgeBaseDetail,
  KnowledgeBaseListResponse,
  KnowledgeChunkHit,
  KnowledgeDocument,
  KnowledgeDocumentChunk,
  KnowledgeDocumentDetail,
  KnowledgePointEvidence,
  KnowledgeSearchResponse
} from '../api/ApiModels';
import { ApiFailure } from '../api/ApiResult';
import { ApiDefaults } from '../api/ApiDefaults';
import { AIFloatButton } from '../components/AIFloatButton';
import { appState } from '../data/AppState';

@Entry
@Component
struct KnowledgeBasePage {
  @State expandedPointsId: string = '';
  @State practiceDocId: string = '';
  @State practicePoint: string = '';
  @State editingPointsId: string = '';
  @State editedPoints: string = '';
  @State pointsSaving: boolean = false;
  @State isLoading: boolean = true;
  @State message: string = '';
  @State messageIsError: boolean = false;

  @State knowledgeBases: KnowledgeBase[] = [];
  @State selectedKbId: string = '';
  @State documents: KnowledgeDocument[] = [];
  @State activeTab: string = 'documents';

  @State createKbOpen: boolean = false;
  @State manageKbOpen: boolean = false;
  @State expandedDocumentId: string = '';
  @State newCourseName: string = '';
  @State isCreating: boolean = false;

  @State isUploading: boolean = false;
  @State uploadProgressText: string = '正在上传文件…';
  @State sampleText: string = '';
  @State sampleFileName: string = '';
  @State uploadResultVisible: boolean = false;

  @State deleteConfirmVisible: boolean = false;
  @State deleteTargetType: string = '';
  @State deleteTargetId: string = '';
  @State deleteTargetKbId: string = '';
  @State deleteTargetName: string = '';
  @State deleteTargetSummary: string = '';
  @State isDeleting: boolean = false;
  @State deleteProgressText: string = '正在删除…';

  @State searchQuery: string = '';
  @State isSearching: boolean = false;
  @State hits: KnowledgeChunkHit[] = [];
  @State retrievalMode: string = '';
  @State lastScanned: number = 0;

  @State detailVisible: boolean = false;
  @State detailDocumentId: string = '';
  @State detailFileName: string = '';
  @State detailKbLabel: string = '';
  @State detailEvidence: KnowledgePointEvidence[] = [];
  @State detailChunks: KnowledgeDocumentChunk[] = [];
  @State detailChunkTotal: number = 0;
  @State detailTruncated: boolean = false;
  @State detailLoading: boolean = false;
  @State detailError: string = '';
  @State detailStatus: string = '';
  @State detailStatusMessage: string = '';

  private isActive: boolean = true;
  private pageVersion: number = 0;
  private listRequestVersion: number = 0;
  private documentRequestVersion: number = 0;
  private searchRequestVersion: number = 0;
  private detailRequestVersion: number = 0;
  private pollVersion: number = 0;
  private pollingDocuments: string[] = [];
  private uploadHintTimer: number = -1;
  private deleteHintTimer: number = -1;

  private async revisePoints(doc: KnowledgeDocument, reparse: boolean): Promise<void> {
    if (this.pointsSaving) return;
    this.pointsSaving = true;
    const owner: string = appState.currentUser.userId;
    const version: number = this.pageVersion;
    const result = await AgentApiClient.reviseDocumentPoints(doc.documentId, {
      knowledgePoints: this.editedPoints.split(/[、,，;；\n]/).map((v: string): string => v.trim()).filter((v: string): boolean => v.length > 0),
      reparse: reparse, expectedParsedAt: doc.parsedAt ?? ''
    });
    this.pointsSaving = false;
    if (!this.isActive || owner !== appState.currentUser.userId || version !== this.pageVersion) return;
    if (result.ok) {
      this.editingPointsId = '';
      this.showMessage(reparse ? '已从原文重新提取，请核对并确认知识点。' : '知识点已去重并确认，画像已同步。', false);
      await this.loadKnowledgeBases();
    } else this.showMessage((result as ApiFailure).error.message, true);
  }

  aboutToAppear(): void {
    this.isActive = true;
    this.isUploading = false;
    this.isDeleting = false;
    this.deleteConfirmVisible = false;
    this.stopUploadHint();
    this.stopDeleteHint();
    this.loadKnowledgeBases();
  }

  onPageShow(): void {
    this.isActive = true;
    if (!this.isLoading) {
      this.loadKnowledgeBases();
    }
  }

  aboutToDisappear(): void {
    this.isActive = false;
    this.pageVersion++;
    this.pollVersion++;
    this.pollingDocuments = [];
    this.stopUploadHint();
    this.stopDeleteHint();
  }

  private currentUserId(): string {
    const id: string = appState.currentUser.userId;
    return id.length > 0 ? id : ApiDefaults.DEMO_USER_ID;
  }

  private showMessage(text: string, isError: boolean): void {
    this.message = text;
    this.messageIsError = isError;
  }

  private ownsRequest(owner: string, version: number): boolean {
    return this.isActive && owner === this.currentUserId() && version === this.pageVersion;
  }

  private selectKnowledgeBase(kbId: string): void {
    this.selectedKbId = kbId;
    this.documentRequestVersion++;
    this.searchRequestVersion++;
    this.detailRequestVersion++;
    this.pollVersion++;
    this.pollingDocuments = [];
    this.documents = [];
    this.hits = [];
    this.retrievalMode = '';
    this.lastScanned = 0;
    this.isSearching = false;
    this.detailVisible = false;
  }

  private async loadKnowledgeBases(): Promise<void> {
    const owner: string = this.currentUserId();
    const page: number = this.pageVersion;
    const version: number = ++this.listRequestVersion;
    this.isLoading = true;
    const result = await AgentApiClient.listKnowledgeBases(owner);
    if (!this.ownsRequest(owner, page) || version !== this.listRequestVersion) {
      return;
    }
    this.isLoading = false;
    if (!result.ok) {
      this.showMessage((result as ApiFailure).error.message, true);
      return;
    }
    const payload: KnowledgeBaseListResponse = result.data;
    this.knowledgeBases = payload.knowledgeBases;
    if (!this.knowledgeBases.some((kb: KnowledgeBase): boolean => kb.kbId === this.selectedKbId)) {
      this.selectKnowledgeBase(this.knowledgeBases.length > 0 ? this.knowledgeBases[0].kbId : '');
    }
    if (this.selectedKbId.length > 0) {
      await this.loadDocuments();
    }
  }

  private async loadDocuments(): Promise<void> {
    const owner: string = this.currentUserId();
    const page: number = this.pageVersion;
    const version: number = ++this.documentRequestVersion;
    const kbId: string = this.selectedKbId;
    if (this.selectedKbId.length === 0) {
      this.documents = [];
      return;
    }
    const result = await AgentApiClient.getKnowledgeBase(kbId);
    if (!this.ownsRequest(owner, page) || version !== this.documentRequestVersion || kbId !== this.selectedKbId) {
      return;
    }
    if (!result.ok) {
      this.showMessage((result as ApiFailure).error.message, true);
      return;
    }
    const detail = result.data;
    this.documents = detail.documents ?? [];
    this.documents.forEach((doc: KnowledgeDocument) => {
      if (doc.status === 'processing') void this.pollDocument(doc.documentId, owner, page);
    });
    const refreshed: KnowledgeBase[] = [];
    for (let index: number = 0; index < this.knowledgeBases.length; index++) {
      const item: KnowledgeBase = this.knowledgeBases[index];
      refreshed.push(item.kbId === detail.kbId ? {
        kbId: item.kbId,
        userId: item.userId,
        courseName: item.courseName,
        name: item.name,
        description: item.description,
        documentCount: detail.documentCount,
        chunkCount: detail.chunkCount,
        knowledgePoints: detail.knowledgePoints,
        createdAt: item.createdAt,
        updatedAt: detail.updatedAt
      } : item);
    }
    this.knowledgeBases = refreshed;
  }

  private async createKnowledgeBase(): Promise<void> {
    if (this.isCreating) {
      return;
    }
    if (this.newCourseName.trim().length === 0) {
      this.showMessage('请填写课程名称。', true);
      return;
    }
    const courseName: string = this.newCourseName.trim();
    const owner: string = this.currentUserId();
    const page: number = this.pageVersion;
    this.isCreating = true;
    const result = await AgentApiClient.createKnowledgeBase({
      courseName: courseName,
      name: `${courseName}知识库`,
      userId: owner
    });
    if (!this.ownsRequest(owner, page)) {
      return;
    }
    this.isCreating = false;
    if (!result.ok) {
      this.showMessage((result as ApiFailure).error.message, true);
      return;
    }
    this.selectKnowledgeBase(result.data.kbId);
    this.newCourseName = '';
    this.showMessage(`已创建知识库「${result.data.name}」。`, false);
    await this.loadKnowledgeBases();
  }

  private requestDeleteKnowledgeBase(kb: KnowledgeBase): void {
    if (this.isDeleting) return;
    this.deleteTargetType = 'knowledgeBase';
    this.deleteTargetId = kb.kbId;
    this.deleteTargetKbId = kb.kbId;
    this.deleteTargetName = kb.courseName;
    this.deleteTargetSummary = `将同时删除 ${kb.documentCount ?? 0} 份文档和 ` +
      `${kb.chunkCount ?? 0} 个检索片段。此操作不可撤销。`;
    this.deleteConfirmVisible = true;
  }

  private requestDeleteDocument(doc: KnowledgeDocument): void {
    if (this.isDeleting) return;
    this.deleteTargetType = 'document';
    this.deleteTargetId = doc.documentId;
    this.deleteTargetKbId = doc.kbId;
    this.deleteTargetName = doc.fileName;
    this.deleteTargetSummary = `将删除该文件及其 ${doc.chunkCount ?? 0} 个检索片段。此操作不可撤销。`;
    this.deleteConfirmVisible = true;
  }

  private cancelDelete(): void {
    if (this.isDeleting) return;
    this.deleteConfirmVisible = false;
  }

  private async confirmDelete(): Promise<void> {
    if (this.isDeleting || this.deleteTargetId.length === 0) return;
    const owner: string = this.currentUserId();
    const page: number = this.pageVersion;
    const targetType: string = this.deleteTargetType;
    const targetId: string = this.deleteTargetId;
    const targetKbId: string = this.deleteTargetKbId;
    this.isDeleting = true;
    this.startDeleteHint();
    const result = targetType === 'knowledgeBase'
      ? await AgentApiClient.deleteKnowledgeBase(targetId)
      : await AgentApiClient.deleteKnowledgeDocument(targetId);
    if (!this.ownsRequest(owner, page)) {
      return;
    }
    if (result.ok) {
      await this.finishDelete(targetType, targetId, false);
      return;
    }
    this.deleteProgressText = '正在确认服务端删除结果…';
    const deleted: boolean = await this.confirmDeleteResult(targetType, targetId, targetKbId);
    if (!this.ownsRequest(owner, page)) return;
    if (deleted) {
      await this.finishDelete(targetType, targetId, true);
      return;
    }
    this.isDeleting = false;
    this.stopDeleteHint();
    this.deleteConfirmVisible = false;
    this.showMessage(`删除未完成：${(result as ApiFailure).error.message}`, true);
  }

  private startDeleteHint(): void {
    this.stopDeleteHint();
    this.deleteProgressText = '正在删除…';
    this.deleteHintTimer = setTimeout(() => {
      this.deleteHintTimer = -1;
      if (this.isDeleting && this.isActive) {
        this.deleteProgressText = '内容较多，服务端正在批量删除，请稍候…';
      }
    }, 6000);
  }

  private stopDeleteHint(): void {
    if (this.deleteHintTimer >= 0) {
      clearTimeout(this.deleteHintTimer);
      this.deleteHintTimer = -1;
    }
  }

  private async confirmDeleteResult(targetType: string, targetId: string,
    targetKbId: string): Promise<boolean> {
    await this.waitFor(1200);
    if (targetType === 'knowledgeBase') {
      const listResult = await AgentApiClient.listKnowledgeBases(this.currentUserId());
      if (!listResult.ok) return false;
      const bases: KnowledgeBase[] = listResult.data.knowledgeBases;
      for (let index: number = 0; index < bases.length; index++) {
        if (bases[index].kbId === targetId) return false;
      }
      return true;
    }
    const detailResult = await AgentApiClient.getKnowledgeBase(targetKbId);
    if (!detailResult.ok) return false;
    const remaining: KnowledgeDocument[] = detailResult.data.documents ?? [];
    for (let index: number = 0; index < remaining.length; index++) {
      if (remaining[index].documentId === targetId) return false;
    }
    return true;
  }

  private async finishDelete(targetType: string, targetId: string,
    recoveredAfterTimeout: boolean): Promise<void> {
    this.pollVersion++;
    this.pollingDocuments = [];
    if (targetType === 'document') {
      this.documents = this.documents.filter((doc: KnowledgeDocument): boolean => doc.documentId !== targetId);
    }
    this.isDeleting = false;
    this.stopDeleteHint();
    this.deleteConfirmVisible = false;
    if (targetType === 'knowledgeBase' && this.selectedKbId === targetId) {
      this.selectKnowledgeBase('');
    }
    this.showMessage(`${recoveredAfterTimeout ? '后台处理已完成：' : ''}` +
      `${targetType === 'knowledgeBase' ? '知识库' : '文档'}已删除。`, false);
    await this.loadKnowledgeBases();
  }

  private encodeBase64(text: string): string {
    try {
      const encoder: util.TextEncoder = new util.TextEncoder();
      const bytes: Uint8Array = encoder.encodeInto(text);
      const helper: util.Base64Helper = new util.Base64Helper();
      return helper.encodeToStringSync(bytes);
    } catch (error) {
      return '';
    }
  }

  private async upload(fileName: string, content: string): Promise<void> {
    if (this.selectedKbId.length === 0) {
      this.showMessage('请先选择或创建一个知识库。', true);
      return;
    }
    if (this.isUploading) {
      return;
    }
    const encoded: string = this.encodeBase64(content);
    if (encoded.length === 0) {
      this.showMessage('内容编码失败，请重试。', true);
      return;
    }
    await this.uploadEncoded(fileName, encoded, content.length, 'text/plain');
  }

  private async uploadEncoded(fileName: string, encoded: string,
    sizeBytes: number, mimeType: string): Promise<void> {
    if (this.isUploading || this.selectedKbId.length === 0) return;
    const owner: string = this.currentUserId();
    const page: number = this.pageVersion;
    this.isUploading = true;
    this.startUploadHint();
    const uploadKbId: string = this.selectedKbId;
    const documentIdsBeforeUpload: string[] = [];
    for (let index: number = 0; index < this.documents.length; index++) {
      documentIdsBeforeUpload.push(this.documents[index].documentId);
    }
    const result = await AgentApiClient.uploadKnowledgeDocument(uploadKbId, {
      fileName: fileName,
      contentBase64: encoded,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      userId: owner
    });
    if (!this.ownsRequest(owner, page)) {
      return;
    }
    if (!result.ok) {
      const failure: ApiFailure = result as ApiFailure;
      if (failure.error.code === 'NETWORK_ERROR' && failure.error.recoverable) {
        this.uploadProgressText = '服务端仍在处理，正在自动确认…';
        this.showMessage('上传请求已发送，正在确认后台解析结果，请稍候…', false);
        const recovered: KnowledgeDocument | null = await this.confirmBackgroundUpload(
          uploadKbId, fileName, documentIdsBeforeUpload, owner, page);
        if (!this.ownsRequest(owner, page)) return;
        if (recovered !== null) {
          this.isUploading = false;
          this.stopUploadHint();
          await this.showUploadSuccess(recovered, true);
          return;
        }
      }
      this.isUploading = false;
      this.stopUploadHint();
      this.showMessage(failure.error.message, true);
      this.uploadResultVisible = true;
      return;
    }
    this.isUploading = false;
    this.stopUploadHint();
    await this.showUploadSuccess(result.data, false);
  }

  private startUploadHint(): void {
    this.stopUploadHint();
    this.uploadProgressText = '正在上传文件…';
    this.uploadHintTimer = setTimeout(() => {
      this.uploadHintTimer = -1;
      if (this.isUploading && this.isActive) {
        this.uploadProgressText = '文件较大，正在解析…';
        this.showMessage('文件较大，上传与解析需要一些时间，请勿重复操作。', false);
      }
    }, 6000);
  }

  private stopUploadHint(): void {
    if (this.uploadHintTimer >= 0) {
      clearTimeout(this.uploadHintTimer);
      this.uploadHintTimer = -1;
    }
  }

  private async waitFor(milliseconds: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => resolve(), milliseconds);
    });
  }

  private async confirmBackgroundUpload(kbId: string, fileName: string,
    documentIdsBeforeUpload: string[], owner: string, page: number): Promise<KnowledgeDocument | null> {
    for (let attempt: number = 0; attempt < 10; attempt++) {
      if (!this.ownsRequest(owner, page)) return null;
      if (attempt > 0) await this.waitFor(2000);
      if (!this.ownsRequest(owner, page)) return null;
      const detailResult = await AgentApiClient.getKnowledgeBase(kbId);
      if (!this.ownsRequest(owner, page)) return null;
      if (!detailResult.ok) continue;
      const detail: KnowledgeBaseDetail = detailResult.data;
      const latestDocuments: KnowledgeDocument[] = detail.documents ?? [];
      for (let index: number = 0; index < latestDocuments.length; index++) {
        const candidate: KnowledgeDocument = latestDocuments[index];
        if (candidate.fileName === fileName &&
          documentIdsBeforeUpload.indexOf(candidate.documentId) < 0) {
          return candidate;
        }
      }
    }
    return null;
  }

  private async showUploadSuccess(doc: KnowledgeDocument, recoveredAfterTimeout: boolean): Promise<void> {
    const owner: string = this.currentUserId();
    const page: number = this.pageVersion;
    if (doc.kbId === this.selectedKbId) {
      this.documentRequestVersion++;
      this.documents = [doc, ...this.documents.filter((item: KnowledgeDocument): boolean => item.documentId !== doc.documentId)];
    }
    if (doc.status === 'processing') {
      this.showMessage(`「${doc.fileName}」已上传，后台正在解析。处理完成后会自动刷新；离开页面不会中断处理。`, false);
      if (doc.kbId === this.selectedKbId) void this.pollDocument(doc.documentId, owner, page);
    } else if (doc.status === 'failed') {
      this.showMessage(`「${doc.fileName}」解析失败：${doc.statusMessage ?? '未知原因'}`, true);
    } else {
      this.showMessage(
        `${recoveredAfterTimeout ? '后台处理已完成：' : ''}「${doc.fileName}」已解析：` +
        `${doc.chunkCount ?? 0} 个片段、` +
        `${(doc.knowledgePoints ?? []).length} 个知识点。`, false);
    }
    this.uploadResultVisible = true;
    await this.loadKnowledgeBases();
    if (this.ownsRequest(owner, page) && this.selectedKbId === doc.kbId) this.activeTab = 'documents';
  }

  private async pollDocument(documentId: string, owner: string, page: number): Promise<void> {
    if (this.pollingDocuments.indexOf(documentId) >= 0) return;
    const version: number = this.pollVersion;
    const kbId: string = this.selectedKbId;
    this.pollingDocuments.push(documentId);
    try {
      for (let attempt: number = 0; attempt < 30; attempt++) {
        await this.waitFor(2000);
        if (!this.ownsRequest(owner, page) || version !== this.pollVersion || kbId !== this.selectedKbId) return;
        const result = await AgentApiClient.getKnowledgeDocument(documentId);
        if (!this.ownsRequest(owner, page) || version !== this.pollVersion || kbId !== this.selectedKbId) return;
        if (!result.ok) {
          const code: string = (result as ApiFailure).error.code;
          if (code === 'NOT_FOUND' || code === 'UNAUTHORIZED' || code === 'FORBIDDEN') return;
          continue;
        }
        if (result.data.status !== 'processing') {
          await this.showUploadSuccess(result.data, false);
          return;
        }
      }
      if (this.ownsRequest(owner, page) && version === this.pollVersion) this.showMessage('资料仍在后台处理，请稍后刷新资料列表查看结果。', false);
    } finally {
      if (version === this.pollVersion) {
        this.pollingDocuments = this.pollingDocuments.filter((id: string): boolean => id !== documentId);
      }
    }
  }

  private fileNameFromUri(uri: string): string {
    const clean: string = uri.indexOf('?') >= 0 ? uri.substring(0, uri.indexOf('?')) : uri;
    const slash: number = clean.lastIndexOf('/');
    const encodedName: string = slash >= 0 ? clean.substring(slash + 1) : clean;
    if (encodedName.length === 0) {
      return `课程资料_${Date.now()}.txt`;
    }
    try {
      return decodeURIComponent(encodedName);
    } catch (error) {
      return encodedName;
    }
  }

  private mimeTypeFor(fileName: string): string {
    const lower: string = fileName.toLowerCase();
    if (lower.endsWith('.pptx')) return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
    if (lower.endsWith('.ppt')) return 'application/vnd.ms-powerpoint';
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.docx')) {
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    }
    if (lower.endsWith('.json')) return 'application/json';
    if (lower.endsWith('.csv')) return 'text/csv';
    if (lower.endsWith('.md') || lower.endsWith('.markdown')) return 'text/markdown';
    return 'text/plain';
  }

  private async pickAndUploadDocument(): Promise<void> {
    if (this.isUploading) return;
    const owner: string = this.currentUserId();
    const page: number = this.pageVersion;
    const kbId: string = this.selectedKbId;
    if (this.selectedKbId.length === 0) {
      this.showMessage('请先选择或创建一个知识库。', true);
      return;
    }
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const result: string[] = await documentPicker.select();
      if (!this.ownsRequest(owner, page) || kbId !== this.selectedKbId) return;
      if (result.length === 0) return;
      const uri: string = result[0];
      const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      try {
        const stat: fileIo.Stat = fileIo.statSync(file.fd);
        if (stat.size <= 0) {
          this.showMessage('所选文件为空。', true);
          this.uploadResultVisible = true;
          return;
        }
        if (stat.size > 8 * 1024 * 1024) {
          this.showMessage('文件超过 8MB 上限，请压缩后重试。', true);
          this.uploadResultVisible = true;
          return;
        }
        const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
        const read: number = fileIo.readSync(file.fd, buffer);
        if (read !== stat.size) {
          this.showMessage('文件没有读取完整，请重新选择。', true);
          this.uploadResultVisible = true;
          return;
        }
        const helper: util.Base64Helper = new util.Base64Helper();
        const encoded: string = helper.encodeToStringSync(new Uint8Array(buffer));
        const fileName: string = this.fileNameFromUri(uri);
        await this.uploadEncoded(fileName, encoded, stat.size, this.mimeTypeFor(fileName));
      } finally {
        fileIo.closeSync(file);
      }
    } catch (error) {
      if (!this.ownsRequest(owner, page)) return;
      this.isUploading = false;
      this.stopUploadHint();
      this.showMessage('文件选择或读取失败，请重试。', true);
      this.uploadResultVisible = true;
    }
  }

  private async uploadSample(): Promise<void> {
    const sample: string =
      '# 第3章 树与二叉树\n\n' +
      '## 3.2 二叉树遍历\n\n' +
      '前序遍历的顺序是根-左-右。中序遍历的顺序是左-根-右。\n\n' +
      '## 3.2.3 后序遍历\n\n' +
      '后序遍历的顺序是左-右-根，因此根节点总是最后被访问。\n' +
      '常见错误：把后序遍历与中序遍历的访问时机混淆。\n\n' +
      '## 3.3 递归理解\n\n' +
      '递归理解的核心是终止条件与调用栈。递归理解不到位会导致遍历写错。\n' +
      '递归理解的练习建议从简单树开始。\n';
    await this.upload('二叉树复习讲义.md', sample);
  }

  private knowledgeBaseLabel(kbId: string): string {
    for (let i: number = 0; i < this.knowledgeBases.length; i++) {
      const kb: KnowledgeBase = this.knowledgeBases[i];
      if (kb.kbId !== kbId) {
        continue;
      }
      if (kb.courseName.length > 0 && kb.name.length > 0) {
        return `${kb.courseName} · ${kb.name}`;
      }
      if (kb.courseName.length > 0) {
        return kb.courseName;
      }
      if (kb.name.length > 0) {
        return kb.name;
      }
      return '归属未知';
    }
    return '归属未知';
  }

  private chunkSummary(): string {
    return this.detailTruncated ? '正文较长，当前仅展示部分内容' : '正文预览 · 按章节与页码阅读';
  }

  private readingSections(): KnowledgeDocumentChunk[] {
    const sections: KnowledgeDocumentChunk[] = [];
    for (let i: number = 0; i < this.detailChunks.length; i++) {
      const chunk: KnowledgeDocumentChunk = this.detailChunks[i];
      const previous: KnowledgeDocumentChunk | undefined = sections.length > 0 ? sections[sections.length - 1] : undefined;
      if (previous !== undefined && previous.headingPath === chunk.headingPath) {
        let overlap: number = Math.min(80, previous.text.length, chunk.text.length);
        while (overlap > 0 && previous.text.slice(-overlap) !== chunk.text.slice(0, overlap)) overlap--;
        previous.text += (overlap > 0 ? '' : '\n\n') + chunk.text.slice(overlap);
      } else {
        sections.push({ chunkId: chunk.chunkId, index: chunk.index, headingPath: chunk.headingPath,
          text: chunk.text, knowledgePoints: chunk.knowledgePoints });
      }
    }
    return sections;
  }

  private chunkTitle(chunk: KnowledgeDocumentChunk): string {
    return chunk.headingPath || '正文';
  }

  private emptyDetailText(): string {
    if (this.detailStatus === 'failed') {
      const reason: string = this.detailStatusMessage.length > 0
        ? this.detailStatusMessage : '后端未给出原因';
      return `这份文档解析失败，没有正文可显示：${reason}`;
    }
    return '这份文档没有可显示的正文片段。';
  }

  private async openDocumentDetail(doc: KnowledgeDocument): Promise<void> {
    this.detailVisible = true;
    this.detailDocumentId = doc.documentId;
    this.detailFileName = doc.fileName;
    this.detailKbLabel = this.knowledgeBaseLabel(doc.kbId);
    await this.fetchDocumentDetail(doc.documentId);
  }

  private async fetchDocumentDetail(documentId: string): Promise<void> {
    const owner: string = this.currentUserId();
    const page: number = this.pageVersion;
    const version: number = ++this.detailRequestVersion;
    this.detailChunks = [];
    this.detailEvidence = [];
    this.detailChunkTotal = 0;
    this.detailTruncated = false;
    this.detailError = '';
    this.detailStatus = '';
    this.detailStatusMessage = '';
    this.detailLoading = true;
    const result = await AgentApiClient.getKnowledgeDocument(documentId);
    if (!this.ownsRequest(owner, page) || version !== this.detailRequestVersion) {
      return;
    }
    if (!this.detailVisible || this.detailDocumentId !== documentId) {
      return;
    }
    this.detailLoading = false;
    if (!result.ok) {
      this.detailError = (result as ApiFailure).error.message;
      return;
    }
    const payload: KnowledgeDocumentDetail = result.data;
    this.detailChunks = payload.chunks;
    this.detailEvidence = payload.knowledgePointEvidence ?? [];
    this.detailChunkTotal = payload.chunkTotal;
    this.detailTruncated = payload.chunksTruncated;
    this.detailStatus = payload.status;
    this.detailStatusMessage = payload.statusMessage ?? '';
  }

  private closeDocumentDetail(): void {
    this.detailRequestVersion++;
    this.detailVisible = false;
  }

  onBackPress(): boolean {
    if (this.deleteConfirmVisible) { this.cancelDelete(); return true; }
    if (this.uploadResultVisible) { this.uploadResultVisible = false; return true; }
    if (this.detailVisible) { this.closeDocumentDetail(); return true; }
    if (this.activeTab !== 'documents') { this.activeTab = 'documents'; return true; }
    return false;
  }

  private async runSearch(): Promise<void> {
    if (this.selectedKbId.length === 0) {
      this.showMessage('请先选择知识库。', true);
      return;
    }
    if (this.searchQuery.trim().length === 0) {
      this.showMessage('请输入检索内容。', true);
      return;
    }
    if (this.isSearching) {
      return;
    }
    this.isSearching = true;
    const owner: string = this.currentUserId();
    const page: number = this.pageVersion;
    const kbId: string = this.selectedKbId;
    const query: string = this.searchQuery.trim();
    const version: number = ++this.searchRequestVersion;
    const result = await AgentApiClient.searchKnowledgeBase(kbId, {
      query: query,
      topK: 5
    });
    if (!this.ownsRequest(owner, page) || version !== this.searchRequestVersion || kbId !== this.selectedKbId) {
      return;
    }
    this.isSearching = false;
    if (query !== this.searchQuery.trim()) return;
    if (!result.ok) {
      this.showMessage((result as ApiFailure).error.message, true);
      return;
    }
    const payload: KnowledgeSearchResponse = result.data;
    this.hits = payload.hits;
    this.retrievalMode = payload.retrievalMode;
    this.lastScanned = payload.totalScanned;
    this.showMessage(this.hits.length > 0
      ? `命中 ${this.hits.length} 个片段（扫描 ${this.lastScanned} 个）。`
      : '没有命中。换个说法试试，或先上传更相关的资料。', this.hits.length === 0);
  }

  private allKnowledgePoints(): string[] {
    const points: string[] = [];
    for (let i: number = 0; i < this.documents.length; i++) {
      const list: string[] = this.documents[i].knowledgePoints ?? [];
      for (let j: number = 0; j < list.length; j++) {
        if (points.indexOf(list[j]) < 0) {
          points.push(list[j]);
        }
      }
    }
    return points;
  }

  private selectedKb(): KnowledgeBase | null {
    for (let i: number = 0; i < this.knowledgeBases.length; i++) {
      if (this.knowledgeBases[i].kbId === this.selectedKbId) {
        return this.knowledgeBases[i];
      }
    }
    return null;
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        this.TopBar()
        Scroll() {
          Column({ space: 14 }) {
            this.MessageBanner()
            this.KnowledgeBaseSection()
            if (this.selectedKbId.length > 0) {
              this.TabBar()
              if (this.activeTab === 'documents') {
                this.DocumentsSection()
              } else if (this.activeTab === 'upload') {
                this.UploadSection()
              } else if (this.activeTab === 'knowledge') {
                this.KnowledgeSection()
              } else {
                this.SearchSection()
              }
            }
            Blank().height(24)
          }
          .width('100%').constraintSize({ maxWidth: UiTheme.workspaceWidth }).padding({ left: 16, right: 16, bottom: 20 })
        }
        .width('100%').layoutWeight(1).scrollBar(BarState.Off).align(Alignment.Top)
        if (this.activeTab === 'documents') { AppBottomBar({ selected: 2 }) }
      }
      .width('100%').height('100%').backgroundColor(UiTheme.subtle)

      AIFloatButton()

      if (this.detailVisible) {
        this.DocumentDetailOverlay()
      }
      if (this.uploadResultVisible) {
        this.UploadResultOverlay()
      }
      if (this.deleteConfirmVisible) {
        this.DeleteConfirmOverlay()
      }
    }
    .width('100%').height('100%')
    .bindSheet($$this.createKbOpen, this.CreateKnowledgeBase(), { height: SheetSize.FIT_CONTENT, title: { title: '新建课程资料库' }, showClose: true, backgroundColor: UiTheme.surface })
  }

  @Builder
  TopBar() {
    PageHeader({ title: this.activeTab === 'upload' ? '上传资料' : this.activeTab === 'search' ? '检索与原文引用' : '我的知识库',
      assistant: true, onBack: () => { if (!this.onBackPress()) router.back(); } })
  }

  @Builder
  CreateKnowledgeBase() {
    Column({ space: 16 }) {
      Text('课程名称').fontSize(14).fontColor(UiTheme.ink).width('100%')
      TextInput({ text: this.newCourseName, placeholder: '例如：数据结构' }).height(44).fontSize(15)
        .backgroundColor(UiTheme.subtle).borderRadius(8).onChange((value: string) => this.newCourseName = value)
      Text('每门课程一个资料库，后续文件都归入该课程。').fontSize(12).fontColor(UiTheme.secondary).width('100%')
      if (this.message && this.messageIsError) { Text(this.message).fontSize(13).fontColor(UiTheme.danger).width('100%') }
      Button(this.isCreating ? '创建中…' : '创建资料库', { type: ButtonType.Normal }).height(46).width('100%')
        .fontSize(15).fontColor('#FFFFFF').backgroundColor(UiTheme.accent).borderRadius(8).enabled(!this.isCreating)
        .onClick(async () => { await this.createKnowledgeBase(); if (!this.messageIsError) this.createKbOpen = false; })
    }.width('100%').padding(20)
  }

  @Builder
  MessageBanner() {
    if (this.message.length > 0) {
      Text(this.message)
        .fontSize(13).lineHeight(20).width('100%').padding(12).borderRadius(8)
        .fontColor(this.messageIsError ? '#B91C1C' : '#166534')
        .backgroundColor(this.messageIsError ? '#FEF2F2' : '#F0FDF4')
    }
  }

  @Builder
  KnowledgeBaseSection() {
    Column({ space: 12 }) {
      Row() {
        Text('课程知识库').fontSize(17).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).layoutWeight(1)
        Text('新建课程资料库').fontSize(13).fontColor(UiTheme.accent).padding({ top: 12, bottom: 12 })
          .onClick(() => this.createKbOpen = true)
      }.width('100%')
      if (this.knowledgeBases.length > 0) {
        Row({ space: 10 }) {
          Text('课程').fontSize(13).fontColor(UiTheme.secondary)
          Select(this.knowledgeBases.map((kb: KnowledgeBase): SelectOption => { return { value: kb.courseName }; }))
            .value(this.selectedKb()?.courseName || '选择课程').layoutWeight(1).backgroundColor(UiTheme.surface)
            .onSelect((index: number) => { this.selectKnowledgeBase(this.knowledgeBases[index].kbId); void this.loadDocuments(); })
          Text('管理').fontSize(13).fontColor(UiTheme.secondary).padding({ top: 12, bottom: 12 })
            .onClick(() => this.manageKbOpen = !this.manageKbOpen)
        }.width('100%')
        if (this.selectedKb() !== null) {
          Row() {
            Column({ space: 5 }) {
              Text(this.selectedKb()!.courseName + '资料库').fontSize(15).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink)
              Text(`${this.selectedKb()!.documentCount ?? 0} 个文件 · ${this.allKnowledgePoints().length} 个知识点`)
                .fontSize(12).fontColor(UiTheme.secondary)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Text('···').fontSize(20).fontColor(UiTheme.secondary).padding(8)
              .bindMenu([{ value: '管理资料库', action: () => { this.manageKbOpen = true; } },
                { value: '删除资料库', action: () => { if (this.selectedKb() !== null) this.requestDeleteKnowledgeBase(this.selectedKb()!); } }])
          }.width('100%').padding(12).backgroundColor(UiTheme.subtle).borderRadius(8)
        }
        if (this.manageKbOpen) {
          ForEach(this.knowledgeBases, (kb: KnowledgeBase) => {
            Row({ space: 10 }) {
              Text(kb.courseName).fontSize(14).fontColor(UiTheme.ink).layoutWeight(1)
                .onClick(() => { this.selectKnowledgeBase(kb.kbId); void this.loadDocuments(); this.manageKbOpen = false; })
              Text('删除').fontSize(13).fontColor(UiTheme.danger).padding({ top: 12, bottom: 12 })
                .onClick(() => this.requestDeleteKnowledgeBase(kb))
            }.width('100%').border({ width: { bottom: 1 }, color: UiTheme.line })
          }, (kb: KnowledgeBase) => kb.kbId)
          Text('收起管理').fontSize(13).fontColor(UiTheme.secondary).onClick(() => this.manageKbOpen = false)
        }
      } else if (!this.isLoading) {
        Text('还没有课程资料库。先新建课程，再添加讲义、题库或笔记。').fontSize(14).fontColor(UiTheme.secondary).lineHeight(22).width('100%')
        Button('新建课程资料库', { type: ButtonType.Normal }).height(44).fontColor('#FFFFFF').backgroundColor(UiTheme.accent)
          .borderRadius(8).onClick(() => this.createKbOpen = true)
      }
    }.width('100%')
  }

  @Builder
  TabBar() {
    Row({ space: 8 }) {
      this.TabChip('documents', '文件')
      this.TabChip('upload', '上传')
      this.TabChip('knowledge', '知识点')
      this.TabChip('search', '检索')
    }
    .width('100%')
  }

  @Builder
  TabChip(key: string, label: string) {
    Text(label).fontSize(13).fontWeight(this.activeTab === key ? FontWeight.Medium : FontWeight.Regular)
      .fontColor(this.activeTab === key ? UiTheme.accent : UiTheme.secondary)
      .constraintSize({ minHeight: 44 }).layoutWeight(1).textAlign(TextAlign.Center).padding({ top: 12, bottom: 12 })
      .border({ width: { bottom: this.activeTab === key ? 2 : 1 }, color: this.activeTab === key ? UiTheme.accent : UiTheme.line })
      .onClick(() => this.activeTab = key)
  }

  @Builder
  DocumentsSection() {
    Column({ space: 10 }) {
      if (this.documents.length === 0) {
        Text('这个知识库还没有文件。切到「上传」添加讲义、题库或笔记。')
          .fontSize(13).fontColor(UiTheme.secondary).width('100%')
          .padding(12).backgroundColor(UiTheme.surface).borderRadius(8)
      }
      GridRow({
        columns: { xs: 1, sm: 2 }, gutter: { x: 20, y: 12 },
        breakpoints: { value: ['780vp'], reference: BreakpointsReference.ComponentSize }
      }) {
        ForEach(this.documents, (doc: KnowledgeDocument) => {
          GridCol() {
            Column({ space: 6 }) {
              Row({ space: 10 }) {
                Text(doc.fileName.split('.').pop()?.toUpperCase() || '文件').fontSize(10).fontColor(UiTheme.secondary)
                  .width(36).height(42).textAlign(TextAlign.Center).padding({ top: 14 }).border({ width: 1, color: UiTheme.line }).borderRadius(4)
                Column({ space: 4 }) {
                  Text(doc.fileName).fontSize(15).fontWeight(FontWeight.Medium).fontColor(UiTheme.ink).maxLines(2).width('100%')
                  Text(doc.status === 'ready' ? '处理完成' : doc.status === 'processing' ? '后台处理中' : '解析失败')
                    .fontSize(12).fontColor(doc.status === 'ready' ? UiTheme.success : doc.status === 'processing' ? UiTheme.secondary : UiTheme.danger)
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                Text('···').fontSize(20).fontColor(UiTheme.secondary).padding(8).bindMenu([
                  { value: '查看正文', action: () => { void this.openDocumentDetail(doc); } },
                  { value: '修改与确认知识点', action: () => { this.expandedDocumentId = doc.documentId; this.editingPointsId = doc.documentId; this.editedPoints = (doc.knowledgePoints ?? []).join('、'); } },
                  { value: '重新提取', action: () => { void this.revisePoints(doc, true); } },
                  { value: '删除', action: () => { this.requestDeleteDocument(doc); } }
                ])
              }.width('100%')
              Row({ space: 20 }) {
                Text('正文 ›').fontSize(13).fontColor(UiTheme.secondary).padding({ top: 10, bottom: 10 }).onClick(() => this.openDocumentDetail(doc))
                Text(this.expandedDocumentId === doc.documentId ? '收起知识点' : '修改确认知识点').fontSize(13).fontColor(UiTheme.secondary)
                  .padding({ top: 10, bottom: 10 }).onClick(() => this.expandedDocumentId = this.expandedDocumentId === doc.documentId ? '' : doc.documentId)
              }.width('100%')
              if (this.expandedDocumentId === doc.documentId) {
              Text(`所属知识库：${this.knowledgeBaseLabel(doc.kbId)}`)
                .fontSize(12).fontColor(UiTheme.secondary).width('100%')
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })

              if (doc.status === 'ready') {
                Text(`${doc.charCount ?? 0} 字 · ${doc.chunkCount ?? 0} 个片段`)
                  .fontSize(12).fontColor(UiTheme.secondary).width('100%')
              } else {
                Text(doc.statusMessage ?? '未知原因')
                  .fontSize(12).fontColor('#B91C1C').width('100%').lineHeight(18)
              }

              if (doc.status === 'ready') {
                Text(doc.tagsConfirmed ? '知识点已确认' : '知识点待核对；点击正文可查看原文依据').fontSize(12).fontColor(UiTheme.secondary)
                Row({ space: 8 }) {
                  Button('修改 / 确认知识点').fontSize(12).height(32).onClick(() => {
                    this.editingPointsId = doc.documentId;
                    this.editedPoints = (doc.knowledgePoints ?? []).join('、');
                  })
                  Button('重新提取').fontSize(12).height(32).enabled(!this.pointsSaving)
                    .onClick(() => { void this.revisePoints(doc, true); })
                }
                if (this.editingPointsId === doc.documentId) {
                  TextArea({ text: this.editedPoints, placeholder: '输入知识点，以逗号或顿号分隔；保存时去重' })
                    .onChange((v: string) => this.editedPoints = v)
                  Button(this.pointsSaving ? '保存中…' : '确认并同步画像').enabled(!this.pointsSaving)
                    .onClick(() => { void this.revisePoints(doc, false); })
                  Button('取消').onClick(() => this.editingPointsId = '')
                }
              }
              if (doc.status === 'ready' && !AgentApiClient.getConfig().useFixture) {
                Button('从此文件抽原题').fontSize(13).height(36)
                  .onClick(() => router.pushUrl({ url: 'pages/ExercisePractice', params: {
                    documentId: doc.documentId, sourceMode: 'document_bank'
                  } }))
              }
              if ((doc.knowledgePoints ?? []).length > 0) {
                Text(`候选知识点 ${(doc.knowledgePoints ?? []).length} 项：${(this.expandedPointsId === doc.documentId ? (doc.knowledgePoints ?? []) : (doc.knowledgePoints ?? []).slice(0, 3)).join('、')}`)
                  .fontSize(12).fontColor(UiTheme.accent).width('100%').lineHeight(18)
                if ((doc.knowledgePoints ?? []).length > 3) {
                  Text(this.expandedPointsId === doc.documentId ? '收起知识点 ↑' : '查看全部知识点 ↓').fontSize(12).fontColor(UiTheme.accent)
                    .onClick(() => this.expandedPointsId = this.expandedPointsId === doc.documentId ? '' : doc.documentId)
                }
                if (doc.status === 'ready') {
                  Button(doc.tagsConfirmed ? '选择知识点开始练习' : '核对知识点后开始练习').fontSize(13).height(36)
                    .onClick(() => {
                      if (!doc.tagsConfirmed) { this.editingPointsId = doc.documentId; this.editedPoints = (doc.knowledgePoints ?? []).join('、'); }
                      else { this.practiceDocId = doc.documentId; this.practicePoint = (doc.knowledgePoints ?? [])[0] ?? ''; }
                    })
                  if (this.practiceDocId === doc.documentId && doc.tagsConfirmed) {
                    Flex({ wrap: FlexWrap.Wrap }) {
                      ForEach(doc.knowledgePoints ?? [], (point: string) => {
                        Button(`${point === this.practicePoint ? ' ' : ''}${point}`).fontSize(12).height(30).margin(4)
                          .onClick(() => this.practicePoint = point)
                      }, (point: string) => point)
                    }
                    Button('依据本资料练习').fontSize(13).height(36).enabled(this.practicePoint.length > 0)
                      .onClick(() => router.pushUrl({ url: 'pages/ExercisePractice', params: {
                        knowledgePointId: this.practicePoint, kbId: doc.kbId, documentId: doc.documentId, sourceMode: 'materials'
                      } }))
                  }
                }
                Text(`资料解析结果：识别 ${(doc.knowledgePoints ?? []).length} 个知识点、` +
                  `提取 ${doc.chunkCount ?? 0} 个可检索片段` +
                  ((doc.errorPointCandidates ?? []).length > 0
                    ? `、发现 ${(doc.errorPointCandidates ?? []).length} 个易错点` : ''))
                  .fontSize(12).fontColor('#166534').width('100%').lineHeight(18)
              }
              }
            }
            .width('100%').padding({ top: 16, bottom: 12 }).backgroundColor(UiTheme.surface)
            .border({ width: { bottom: 1 }, color: UiTheme.line })
            .onClick(() => { this.openDocumentDetail(doc); })
          }
        }, (doc: KnowledgeDocument) => doc.documentId)
      }.width('100%').alignItems(ItemAlign.Start)
    }
    .width('100%')
  }

  @Builder
  DocumentDetailOverlay() {
    Column() {
      Column({ space: 10 }) {
        Row({ space: 10 }) {
          Column({ space: 3 }) {
            Text(this.detailFileName).fontSize(16).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink)
              .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(`所属知识库：${this.detailKbLabel}`)
              .fontSize(12).fontColor(UiTheme.secondary).width('100%')
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)

          Text('关闭').fontSize(13).fontColor(UiTheme.accent)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor(UiTheme.tint).borderRadius(8)
            .onClick(() => { this.closeDocumentDetail(); })
        }.width('100%')

        Text(this.chunkSummary())
          .fontSize(11).width('100%')
          .fontColor(this.detailTruncated ? '#B45309' : UiTheme.muted)

        Divider().color(UiTheme.line)

        if (this.detailLoading) {
          Row({ space: 8 }) {
            LoadingProgress().width(18).height(18).color(UiTheme.accent)
            Text('正在加载正文…').fontSize(13).fontColor(UiTheme.secondary)
          }
          .width('100%').padding({ top: 24, bottom: 24 })
          .justifyContent(FlexAlign.Center)
        } else if (this.detailError.length > 0) {
          Column({ space: 10 }) {
            Text('正文加载失败').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#B91C1C')
              .width('100%')
            Text(this.detailError).fontSize(12).fontColor('#B91C1C').width('100%').lineHeight(18)
            Button('重试').height(38).fontSize(13).fontColor(UiTheme.surface)
              .backgroundColor(UiTheme.accent).borderRadius(8)
              .onClick(() => { this.fetchDocumentDetail(this.detailDocumentId); })
          }
          .width('100%').padding({ top: 12 })
        } else if (this.detailChunks.length === 0) {
          Text(this.emptyDetailText()).fontSize(13).fontColor(UiTheme.secondary)
            .width('100%').lineHeight(20)
        } else {
          Scroll() {
            Column({ space: 12 }) {
              Text('知识点原文依据').fontSize(14).fontWeight(FontWeight.Bold).fontColor(UiTheme.ink)
              ForEach(this.detailEvidence, (item: KnowledgePointEvidence) => {
                Column({ space: 4 }) {
                  Text(`${item.name} · ${item.headingPath || '原文片段'}`).fontSize(13).fontColor(UiTheme.accent)
                  Text(item.excerpt || '此名称由用户修订，尚无可直接对应的原文短语。').fontSize(12).fontColor(UiTheme.secondary).lineHeight(18)
                }.width('100%').padding(10).backgroundColor(UiTheme.tint).borderRadius(8)
              }, (item: KnowledgePointEvidence) => item.name)
              ForEach(this.readingSections(), (chunk: KnowledgeDocumentChunk) => {
                Column({ space: 5 }) {
                  Text(this.chunkTitle(chunk))
                    .fontSize(11).fontColor('#166534').width('100%').lineHeight(17)
                  Text(chunk.text).fontSize(13).fontColor(UiTheme.secondary).width('100%').lineHeight(21)
                  if ((chunk.knowledgePoints ?? []).length > 0) {
                    Text(`标签：${(chunk.knowledgePoints ?? []).join('、')}`)
                      .fontSize(11).fontColor(UiTheme.secondary).width('100%')
                  }
                }
                .width('100%').padding({ top: 8, bottom: 12 })
              }, (chunk: KnowledgeDocumentChunk) => chunk.chunkId)
            }.width('100%')
          }
          .width('100%').layoutWeight(1).align(Alignment.TopStart).scrollBar(BarState.Auto)
        }
      }
      .width('92%').height('86%').constraintSize({ maxWidth: UiTheme.contentWidth }).padding(16)
      .backgroundColor(UiTheme.surface).borderRadius(8)
      .border({ width: 1, color: UiTheme.line })
    }
    .width('100%').height('100%')
    .backgroundColor('rgba(15, 23, 42, 0.45)')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  UploadResultOverlay() {
    Column() {
      Column({ space: 14 }) {
        Text(this.messageIsError ? '上传未完成' : '上传成功')
          .fontSize(18).fontWeight(FontWeight.Bold)
          .fontColor(this.messageIsError ? '#B91C1C' : '#166534')
        Text(this.message).fontSize(13).lineHeight(20).fontColor(UiTheme.secondary).width('100%')
        Button('知道了').width('100%').height(42).fontColor(UiTheme.surface)
          .backgroundColor(UiTheme.accent).borderRadius(8)
          .onClick(() => { this.uploadResultVisible = false; })
      }
      .width('84%').constraintSize({ maxWidth: UiTheme.dialogWidth }).padding(18).backgroundColor(UiTheme.surface).borderRadius(8)
      .border({ width: 1, color: UiTheme.line })
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center)
    .backgroundColor('rgba(15, 23, 42, 0.45)')
  }

  @Builder
  DeleteConfirmOverlay() {
    Column() {
      Column({ space: 14 }) {
        Text(this.isDeleting ? '正在删除' : `确认删除“${this.deleteTargetName}”？`)
          .fontSize(18).fontWeight(FontWeight.Bold)
          .fontColor(this.isDeleting ? '#B45309' : '#B91C1C')
        if (this.isDeleting) {
          LoadingProgress().width(28).height(28).color(UiTheme.accent)
          Text(this.deleteProgressText).fontSize(13).lineHeight(20).fontColor(UiTheme.secondary).width('100%')
          Text('请勿重复点击或退出页面。').fontSize(12).fontColor(UiTheme.muted).width('100%')
        } else {
          Text(this.deleteTargetSummary).fontSize(13).lineHeight(20).fontColor(UiTheme.secondary).width('100%')
          Row({ space: 10 }) {
            Button('取消').layoutWeight(1).height(42).fontColor(UiTheme.secondary)
              .backgroundColor(UiTheme.subtle).borderRadius(8)
              .onClick(() => { this.cancelDelete(); })
            Button('确定删除').layoutWeight(1).height(42).fontColor(UiTheme.surface)
              .backgroundColor(UiTheme.danger).borderRadius(8)
              .onClick(() => { this.confirmDelete(); })
          }.width('100%')
        }
      }
      .width('86%').constraintSize({ maxWidth: UiTheme.dialogWidth }).padding(18).backgroundColor(UiTheme.surface).borderRadius(8)
      .border({ width: 1, color: UiTheme.line })
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center)
    .backgroundColor('#66000000')
  }

  @Builder
  UploadSection() {
    Column({ space: 12 }) {
      Text('支持 TXT / Markdown / CSV / JSON / Word（DOCX）/ PDF / PPT / PPTX。纯图片需先做 OCR。')
        .fontSize(12).fontColor(UiTheme.secondary).width('100%').lineHeight(18)

      Button(this.isUploading ? this.uploadProgressText : '选择 Word / PDF / 文本文件')
        .width('100%').height(46).fontSize(14).fontColor(UiTheme.accent)
        .backgroundColor(UiTheme.tint).borderRadius(8)
        .border({ width: 1, color: '#BFDBFE' })
        .enabled(!this.isUploading)
        .onClick(() => { this.pickAndUploadDocument(); })

      TextArea({ placeholder: '把讲义 / 笔记内容粘贴到这里…', text: this.sampleText })
        .height(160).fontSize(13)
        .onChange((value: string) => { this.sampleText = value; })

      TextInput({ placeholder: '文件名，如「二叉树复习讲义.md」', text: this.sampleFileName })
        .height(44).fontSize(14)
        .onChange((value: string) => { this.sampleFileName = value; })

      Button(this.isUploading ? this.uploadProgressText : '上传并解析')
        .width('100%').height(46).fontSize(15).fontColor(UiTheme.surface)
        .backgroundColor(UiTheme.accent).borderRadius(8)
        .enabled(!this.isUploading)
        .onClick(() => {
          const name: string = this.sampleFileName.trim().length > 0
            ? this.sampleFileName.trim() : '我的讲义.md';
          this.upload(name, this.sampleText);
        })

      Button('使用示例讲义快速体验')
        .width('100%').height(44).fontSize(14).fontColor(UiTheme.accent)
        .backgroundColor(UiTheme.surface).borderRadius(8)
        .border({ width: 1, color: '#BFDBFE' })
        .enabled(!this.isUploading)
        .onClick(() => { this.uploadSample(); })
    }
    .width('100%').padding(12).borderRadius(8).backgroundColor(UiTheme.surface)
    .border({ width: 1, color: UiTheme.line })
  }

  @Builder
  KnowledgeSection() {
    Column({ space: 10 }) {
      Text('从你的资料中识别出的知识点').fontSize(14).fontWeight(FontWeight.Bold)
        .fontColor(UiTheme.ink).width('100%')

      if (this.allKnowledgePoints().length === 0) {
        Text('还没有识别到知识点。上传含标题层级的讲义效果最好。')
          .fontSize(13).fontColor(UiTheme.secondary).width('100%')
      } else {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.allKnowledgePoints(), (point: string) => {
            Text(point)
              .fontSize(12).fontColor(UiTheme.accent)
              .backgroundColor(UiTheme.tint)
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .borderRadius(8)
              .margin({ right: 8, bottom: 8 })
          }, (point: string) => point)
        }.width('100%')
      }

      if (this.gatherErrorPoints().length > 0) {
        Divider().color(UiTheme.line).margin({ top: 6, bottom: 6 })
        Text('常见易错点').fontSize(14).fontWeight(FontWeight.Bold)
          .fontColor(UiTheme.ink).width('100%')
        ForEach(this.gatherErrorPoints(), (item: string) => {
          Text(`· ${item}`).fontSize(12).fontColor('#B45309')
            .width('100%').lineHeight(18)
        }, (item: string) => item)
      }
    }
    .width('100%').padding(12).borderRadius(8).backgroundColor(UiTheme.surface)
    .border({ width: 1, color: UiTheme.line })
  }

  private gatherErrorPoints(): string[] {
    const items: string[] = [];
    for (let i: number = 0; i < this.documents.length; i++) {
      const list: string[] = this.documents[i].errorPointCandidates ?? [];
      for (let j: number = 0; j < list.length; j++) {
        if (items.indexOf(list[j]) < 0) {
          items.push(list[j]);
        }
      }
    }
    return items;
  }

  @Builder
  SearchSection() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        TextInput({ placeholder: '例如：后序遍历的顺序', text: this.searchQuery })
          .layoutWeight(1).height(44).fontSize(14)
          .onChange((value: string) => { this.searchQuery = value; })
          .onSubmit(() => { this.runSearch(); })
        Button(this.isSearching ? '检索中' : '检索')
          .height(44).fontSize(14).fontColor(UiTheme.surface)
          .backgroundColor(UiTheme.accent).borderRadius(8)
          .enabled(!this.isSearching)
          .onClick(() => { this.runSearch(); })
      }.width('100%')

      if (this.retrievalMode.length > 0) {
        Text(`检索方式：${this.retrievalMode} · 扫描 ${this.lastScanned} 个片段`)
          .fontSize(11).fontColor(UiTheme.muted).width('100%')
      }

      ForEach(this.hits, (hit: KnowledgeChunkHit) => {
        Column({ space: 6 }) {
          Row({ space: 8 }) {
            Text(hit.fileName ?? '未知文件').fontSize(12).fontWeight(FontWeight.Bold)
              .fontColor(UiTheme.accent).layoutWeight(1)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(hit.score.toFixed(2)).fontSize(12).fontColor(UiTheme.surface)
              .backgroundColor(UiTheme.accent)
              .padding({ left: 8, right: 8, top: 2, bottom: 2 }).borderRadius(8)
          }.width('100%')

          if ((hit.headingPath ?? '').length > 0) {
            Text(`§ ${hit.headingPath}`)
              .fontSize(12).fontColor('#166534').width('100%').lineHeight(18)
          }
          Text(hit.text).fontSize(13).fontColor(UiTheme.secondary)
            .width('100%').lineHeight(20).maxLines(6)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          if ((hit.knowledgePoints ?? []).length > 0) {
            Text(`标签：${(hit.knowledgePoints ?? []).join('、')}`)
              .fontSize(11).fontColor(UiTheme.secondary).width('100%')
          }
        }
        .width('100%').padding(12).borderRadius(8).backgroundColor(UiTheme.surface)
        .border({ width: 1, color: UiTheme.line })
      }, (hit: KnowledgeChunkHit) => hit.chunkId)
    }
    .width('100%')
  }
}
