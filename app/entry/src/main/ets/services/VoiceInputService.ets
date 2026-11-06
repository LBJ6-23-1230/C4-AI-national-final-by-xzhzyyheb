import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { speechRecognizer } from '@kit.CoreSpeechKit';

export class VoiceInputCallbacks {
  onStateChange: (listening: boolean) => void;
  onText: (text: string, isFinal: boolean) => void;
  onError: (message: string) => void;
  onComplete: () => void;

  constructor(
    onStateChange: (listening: boolean) => void,
    onText: (text: string, isFinal: boolean) => void,
    onError: (message: string) => void,
    onComplete: () => void = (): void => {}
  ) {
    this.onStateChange = onStateChange;
    this.onText = onText;
    this.onError = onError;
    this.onComplete = onComplete;
  }
}

/**
 * Single-page speech-to-text controller.
 *
 * CoreSpeechKit accepts PCM frames rather than opening the microphone itself, so this service
 * keeps the recognizer and AudioCapturer lifecycles together. The engine is reused between turns
 * and released only when the chat page disappears.
 */
export class VoiceInputService {
  private engine: speechRecognizer.SpeechRecognitionEngine | null = null;
  private capturer: audio.AudioCapturer | null = null;
  private captureStart: Promise<void> | null = null;
  private callbacks: VoiceInputCallbacks | null = null;
  private sessionId: string = '';
  private listening: boolean = false;
  private starting: boolean = false;
  private finishing: boolean = false;
  private revision: number = 0;
  private finalizedText: string = '';
  private pendingPcm: Uint8Array = new Uint8Array(0);
  private finishTimer: number = -1;

  isListening(): boolean {
    return this.listening;
  }

  async start(callbacks: VoiceInputCallbacks): Promise<void> {
    if (this.listening || this.starting || this.finishing) return;
    const revision: number = ++this.revision;
    this.starting = true;
    this.callbacks = callbacks;
    this.finalizedText = '';
    this.pendingPcm = new Uint8Array(0);
    try {
      const engine: speechRecognizer.SpeechRecognitionEngine | null = await this.ensureEngine(revision);
      if (revision !== this.revision || engine === null) return;
      if (engine.isBusy()) {
        this.starting = false;
        this.callbacks = null;
        callbacks.onError('语音识别正在处理上一段内容，请稍后再试。');
        return;
      }

      this.sessionId = `zhixue-voice-${Date.now()}-${revision}`;
      const capturer: audio.AudioCapturer = await audio.createAudioCapturer({
        streamInfo: {
          samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
          channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
        },
        capturerInfo: {
          source: audio.SourceType.SOURCE_TYPE_VOICE_RECOGNITION,
          capturerFlags: 0
        }
      });
      // A finger may already have lifted while the engine or microphone was opening.
      if (revision !== this.revision) {
        await this.releaseCapturer(capturer);
        return;
      }
      this.capturer = capturer;

      engine.startListening({
        sessionId: this.sessionId,
        audioInfo: {
          audioType: 'pcm',
          sampleRate: 16000,
          soundChannel: 1,
          sampleBit: 16
        }
      });
      this.listening = true;
      capturer.on('readData', (buffer: ArrayBuffer) => {
        if (revision === this.revision) this.writePcm(buffer);
      });
      const captureStart: Promise<void> = capturer.start();
      this.captureStart = captureStart;
      await captureStart;
      if (this.capturer === capturer) this.captureStart = null;
      if (revision !== this.revision || !this.listening) return;
      this.starting = false;
      callbacks.onStateChange(true);
      this.finishTimer = setTimeout(() => { void this.stop(true); }, 60000);
    } catch (error) {
      if (revision !== this.revision) return;
      await this.stop(false);
      callbacks.onError(this.readableError(error));
    }
  }

  async stop(requestFinalResult: boolean = true): Promise<void> {
    const activeSession: string = this.sessionId;
    const callbacks: VoiceInputCallbacks | null = this.callbacks;
    // Cancellation invalidates pending engine/capturer promises before awaiting cleanup.
    if (!requestFinalResult || this.starting) {
      this.revision++;
      this.starting = false;
      this.finishing = false;
      this.listening = false;
      this.clearFinishTimer();
      this.callbacks = null;
      this.sessionId = '';
      this.pendingPcm = new Uint8Array(0);
      if (activeSession.length > 0 && this.engine !== null) {
        try { this.engine.cancel(activeSession); } catch (error) {}
      }
      callbacks?.onStateChange(false);
      if (requestFinalResult) callbacks?.onComplete();
      await this.stopCapture();
      return;
    }
    if (!this.listening || this.finishing) return;
    const revision: number = this.revision;
    if (this.pendingPcm.length > 0 && this.engine !== null) {
      try {
        const tail: Uint8Array = new Uint8Array(640);
        tail.set(this.pendingPcm);
        this.engine.writeAudio(activeSession, tail);
      } catch (error) {}
    }
    this.listening = false;
    this.finishing = true;
    this.clearFinishTimer();
    callbacks?.onStateChange(false);
    await this.stopCapture();
    if (revision !== this.revision || this.sessionId !== activeSession) return;
    if (activeSession.length > 0 && this.engine !== null) {
      try {
        // A recognizer that never returns its final callback must not lock the draft.
        this.finishTimer = setTimeout(() => {
          if (revision === this.revision) this.completeSession();
        }, 5000);
        this.engine.finish(activeSession);
      } catch (error) {
        await this.stop(false);
        callbacks?.onError(this.readableError(error));
      }
    }
  }

  async dispose(): Promise<void> {
    await this.stop(false);
    if (this.engine !== null) {
      this.engine.shutdown();
      this.engine = null;
    }
    this.callbacks = null;
    this.sessionId = '';
  }

  private async ensureEngine(revision: number): Promise<speechRecognizer.SpeechRecognitionEngine | null> {
    if (this.engine !== null) return this.engine;
    let engine: speechRecognizer.SpeechRecognitionEngine;
    let onlineFailure: string = '';
    try {
      engine = await this.createEngine(0);
    } catch (error) {
      // Core Speech 的在线资源并非所有真机/系统版本都可用。
      // 在线引擎初始化失败时自动回退到端侧离线引擎，避免把“真机”误判成不支持。
      onlineFailure = this.errorDetail(error);
      try {
        engine = await this.createEngine(1);
      } catch (offlineError) {
        throw new Error(`在线语音引擎启动失败（${onlineFailure}）；离线语音引擎也启动失败（${this.errorDetail(offlineError)}）`);
      }
    }
    if (revision !== this.revision) {
      engine.shutdown();
      return null;
    }
    engine.setListener({
      onStart: (sessionId: string, eventMessage: string): void => {
        if (sessionId !== this.sessionId) return;
      },
      onEvent: (sessionId: string, eventCode: number, eventMessage: string): void => {
        if (sessionId !== this.sessionId) return;
      },
      onResult: (sessionId: string, result: speechRecognizer.SpeechRecognitionResult): void => {
        if (sessionId !== this.sessionId) return;
        const text: string = result.result.trim();
        if (text.length > 0) {
          // isFinal closes one sentence; isLast closes the whole recognition turn.
          const transcript: string = this.finalizedText + text;
          if (result.isFinal) this.finalizedText = transcript;
          this.callbacks?.onText(transcript, result.isLast);
        }
        if (result.isLast) this.completeSession();
      },
      onComplete: (sessionId: string, eventMessage: string): void => {
        if (sessionId !== this.sessionId) return;
        this.completeSession();
      },
      onError: (sessionId: string, errorCode: number, errorMessage: string): void => {
        if (sessionId !== this.sessionId) return;
        const callbacks: VoiceInputCallbacks | null = this.callbacks;
        void this.stop(false);
        callbacks?.onError(this.recognitionError(errorCode, errorMessage));
      }
    });
    this.engine = engine;
    return engine;
  }

  /** online: 0 = 在线识别，1 = 离线识别（字段命名与取值语义相反）。 */
  private async createEngine(online: number): Promise<speechRecognizer.SpeechRecognitionEngine> {
    return speechRecognizer.createEngine({
      language: 'zh-CN',
      online: online
    });
  }

  private writePcm(buffer: ArrayBuffer): void {
    if (!this.listening || this.engine === null || this.sessionId.length === 0) return;
    const chunk: Uint8Array = new Uint8Array(buffer);
    const bytes: Uint8Array = new Uint8Array(this.pendingPcm.length + chunk.length);
    bytes.set(this.pendingPcm);
    bytes.set(chunk, this.pendingPcm.length);
    let offset: number = 0;
    try {
      while (bytes.length - offset >= 640) {
        const frameSize: number = bytes.length - offset >= 1280 ? 1280 : 640;
        this.engine.writeAudio(this.sessionId, bytes.slice(offset, offset + frameSize));
        offset += frameSize;
      }
      this.pendingPcm = bytes.slice(offset);
    } catch (error) {
      const callbacks: VoiceInputCallbacks | null = this.callbacks;
      void this.stop(false);
      callbacks?.onError(this.readableError(error));
    }
  }

  private completeSession(): void {
    const callbacks: VoiceInputCallbacks | null = this.callbacks;
    const sessionId: string = this.sessionId;
    this.revision++;
    this.sessionId = '';
    this.callbacks = null;
    this.listening = false;
    this.starting = false;
    this.finishing = false;
    this.clearFinishTimer();
    if (sessionId.length > 0 && this.engine !== null) {
      try { this.engine.cancel(sessionId); } catch (error) {}
    }
    void this.stopCapture();
    callbacks?.onStateChange(false);
    callbacks?.onComplete();
  }

  private async stopCapture(): Promise<void> {
    const activeCapturer: audio.AudioCapturer | null = this.capturer;
    const captureStart: Promise<void> | null = this.captureStart;
    this.capturer = null;
    this.captureStart = null;
    if (activeCapturer === null) return;
    // A pending native start may succeed after release. Wait for that same handle,
    // then stop it, without touching a newer turn's microphone.
    if (captureStart !== null) {
      try { await captureStart; } catch (error) {}
    }
    await this.releaseCapturer(activeCapturer);
  }

  private async releaseCapturer(activeCapturer: audio.AudioCapturer): Promise<void> {
    try {
      activeCapturer.off('readData');
      if (activeCapturer.state === audio.AudioState.STATE_RUNNING) {
        await activeCapturer.stop();
      }
      await activeCapturer.release();
    } catch (error) {
      // Cleanup is best effort; the next recognition turn creates a fresh capturer.
    }
  }

  private clearFinishTimer(): void {
    if (this.finishTimer >= 0) {
      clearTimeout(this.finishTimer);
      this.finishTimer = -1;
    }
  }

  private recognitionError(code: number, detail: string): string {
    if (code === 1002200012) return '没有麦克风权限，请在系统设置中允许后重试。';
    if (code === 1002200006) return '语音识别服务正忙，请稍后重试。';
    if (code === 1002200001 || code === 1002200009) return '当前设备暂不支持语音识别，请使用真机或直接输入文字。';
    return detail.length > 0 ? `语音识别失败：${detail}` : '语音识别失败，请稍后重试。';
  }

  private readableError(error: Object): string {
    const detail: string = this.errorDetail(error);
    if (detail.includes('201') || detail.includes('1002200012')) {
      return '没有麦克风权限，请在系统设置中允许后重试。';
    }
    return `语音识别启动失败：${detail}`;
  }

  /** BusinessError 的 code/message 默认不可枚举，JSON.stringify 会把它变成空对象。 */
  private errorDetail(error: Object): string {
    const typed: BusinessError = error as BusinessError;
    const code: number = typed.code;
    const message: string = typed.message;
    if (code !== undefined && message !== undefined && message.length > 0) {
      return `${code}: ${message}`;
    }
    if (message !== undefined && message.length > 0) {
      return message;
    }
    return String(error);
  }
}
