import { http } from '@kit.NetworkKit';
import { AgentApiClient } from '../api/AgentApiClient';

export interface ConnectionDiagnostic {
  available: boolean;
  message: string;
  latencyMs: number;
}

export class ConnectionDiagnostics {
  static async check(): Promise<ConnectionDiagnostic> {
    const config = AgentApiClient.getConfig();
    if (config.useFixture) return { available: false, message: '请先切换到真实后端。', latencyMs: 0 };
    const request = http.createHttp();
    const started: number = Date.now();
    try {
      const response = await request.request(config.baseUrl.replace(/\/+$/, '') + '/ready',
        AgentApiClient.prepareBackendRequest(config.baseUrl, {
          method: http.RequestMethod.GET, connectTimeout: 5000, readTimeout: 5000,
          expectDataType: http.HttpDataType.STRING
        }));
      const latency: number = Math.max(0, Date.now() - started);
      if (response.responseCode === 200) {
        return { available: true, message: `后端与数据库已就绪 · ${latency} 毫秒`, latencyMs: latency };
      }
      return { available: false, message: response.responseCode === 503 ?
        '已连上后端，数据库或依赖尚未就绪（HTTP 503）。' :
        `已连上后端，就绪检查未通过（HTTP ${response.responseCode}）。`, latencyMs: latency };
    } catch (_) {
      return { available: false, message: '无法连接后端，请核对两端地址、电脑服务与网络。',
        latencyMs: Math.max(0, Date.now() - started) };
    } finally { request.destroy(); }
  }
}
