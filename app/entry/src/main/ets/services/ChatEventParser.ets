/** Incremental SSE framing. No UI mutations or business actions before result. */
export interface ChatProgress {
  stage: string;
  message: string;
  reply: string;
}

export class ChatEventParser {
  private buffer: string = '';
  private terminal: boolean = false;
  private result: Record<string, Object> | null = null;
  private failure: string = '';
  private streamed: boolean = false;

  private progress?: (event: ChatProgress) => void;

  constructor(progress?: (event: ChatProgress) => void) {
    this.progress = progress;
  }

  feed(chunk: string): void {
    if (this.terminal) return;
    this.buffer += chunk;
    if (this.buffer.length > 8 * 1024 * 1024) throw new Error('INVALID_RESPONSE::响应内容过大');
    let end: number = this.buffer.indexOf('\n\n');
    while (end >= 0) {
      const frame: string = this.buffer.substring(0, end);
      this.buffer = this.buffer.substring(end + 2);
      if (frame.startsWith('event:') || frame.startsWith(':')) {
        this.streamed = true;
        this.consume(frame);
      } else {
        // Legacy JSON can contain whitespace; defer it intact until finish().
        this.buffer = frame + '\n\n' + this.buffer;
        break;
      }
      if (this.terminal) break;
      end = this.buffer.indexOf('\n\n');
    }
  }

  private consume(frame: string): void {
    let kind: string = '';
    let payload: string = '';
    const lines: string[] = frame.split('\n');
    for (let i: number = 0; i < lines.length; i++) {
      if (lines[i].startsWith('event:')) kind = lines[i].substring(6).trim();
      if (lines[i].startsWith('data:')) payload += lines[i].substring(5).trim();
    }
    if (payload.length === 0) return;
    const data: Record<string, Object> = JSON.parse(payload) as Record<string, Object>;
    if (kind === 'result') {
      this.result = data;
      this.terminal = true;
    } else if (kind === 'error') {
      const body: Record<string, Object> = data['body'] as Record<string, Object>;
      this.failure = body && typeof body['message'] === 'string' ? body['message'] as string : '服务处理失败';
      this.terminal = true;
    } else if (kind === 'progress' && this.progress !== undefined) {
      this.progress({ stage: typeof data['stage'] === 'string' ? data['stage'] as string : '',
        message: typeof data['message'] === 'string' ? data['message'] as string : '',
        reply: typeof data['reply'] === 'string' ? data['reply'] as string : '' });
    }
  }

  finish(status: number): Record<string, Object> {
    if (this.failure.length > 0) throw new Error('HTTP_ERROR::' + this.failure);
    if (this.result !== null && status >= 200 && status < 300) return this.result;
    if (this.streamed) throw new Error('HTTP_ERROR::连接已中断，尚未收到完整结果，请查看会话记录后再重试');
    const data: Record<string, Object> = JSON.parse(this.buffer) as Record<string, Object>;
    if (status < 200 || status >= 300) {
      throw new Error('HTTP_ERROR::' + (typeof data['message'] === 'string' ? data['message'] as string : '服务请求失败'));
    }
    return data;
  }
}
