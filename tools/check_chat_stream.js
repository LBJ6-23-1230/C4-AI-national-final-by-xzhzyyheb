/* Execute the real ETS parser/bridge with fragmented HTTP and delayed dataEnd. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2] || 'typescript');
const root = path.resolve(__dirname, '../app/entry/src/main/ets/services');
function compile(name, requireFn) {
  const module = { exports: {} };
  const code = ts.transpileModule(fs.readFileSync(path.join(root, name + '.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  vm.runInThisContext(`(function(require,module,exports,setTimeout){${code}\n})`)(requireFn, module, module.exports,
    (fn, delay) => setTimeout(fn, delay >= 150000 ? 100 : delay));
  return module.exports;
}
const parserModule = compile('ChatEventParser', () => ({}));
const { ChatEventParser } = parserModule;
const answer = { reply: '递归需要练习🙂', intent: 'analyze_weakness', card: null, llmUsed: true };
const event = (kind, data) => `event: ${kind}\ndata: ${JSON.stringify(data)}\n\n`;
const progress = { stage: 'analysis', message: '正在分析', reply: '' };
const wire = event('progress', progress) + ': keep-alive\n\n' + event('result', answer);
for (let size = 1; size <= wire.length; size++) {
  const updates = [];
  const parser = new ChatEventParser(data => updates.push(data));
  for (let i = 0; i < wire.length; i += size) parser.feed(wire.slice(i, i + size));
  assert.deepEqual(parser.finish(200), answer);
  assert.deepEqual(updates, [progress]);
}
const partial = new ChatEventParser();
partial.feed(event('progress', progress));
assert.throws(() => partial.finish(200), /尚未收到完整结果/);
const error = new ChatEventParser();
error.feed(event('error', { status: 403, body: { message: '权限不足' } }));
assert.throws(() => error.finish(200), /权限不足/);
const legacy = new ChatEventParser();
legacy.feed(JSON.stringify(answer));
assert.deepEqual(legacy.finish(200), answer);

let mode = 'sse', destroyed = 0, requests = 0;
const http = {
  RequestMethod: { POST: 'POST' }, HttpDataType: { STRING: 'STRING' },
  createHttp() {
    const listeners = {};
    return {
      on(type, callback) { listeners[type] = callback; },
      destroy() { destroyed++; },
      async requestInStream(url, options) {
        requests++;
        assert.equal(options.header.Accept, 'text/event-stream');
        assert.equal(options.header.Authorization, 'Bearer session-token');
        assert.equal(JSON.parse(options.extraData).userId, 'owner');
        if (mode === 'noend') return 200;
        const bytes = Buffer.from(mode === 'legacy' ? JSON.stringify(answer) :
          mode === 'truncated' ? event('progress', progress) : wire);
        // Return the status before body completion to exercise the dataEnd gate.
        setTimeout(() => {
          for (let i = 0; i < bytes.length; i++) {
            const chunk = Uint8Array.from([bytes[i]]);
            listeners.dataReceive(chunk.buffer);
          }
          listeners.dataEnd();
        }, 1);
        return 200;
      }
    };
  }
};
const { AgentBridge } = compile('AgentBridge', spec => {
  if (spec === './ChatEventParser') return parserModule;
  if (spec === '@kit.NetworkKit') return { http };
  if (spec === '@kit.ArkTS') return { util: { TextDecoder: { create() {
    const decoder = new TextDecoder();
    return { decodeToString: (bytes, options) => decoder.decode(bytes, options) };
  } } } };
  if (spec.endsWith('/AppState')) return { appState: { currentUser: { userId: 'owner' }, chatSessionId: 'chat', courses: [], homeworkDDLs: [] } };
  if (spec.endsWith('/AuthStore')) return { AuthStore: { getToken: () => 'session-token' } };
  if (spec.endsWith('/ApiDefaults')) return { ApiDefaults: { LLM_BOUND_READ_TIMEOUT_MS: 40000, CHAT_STREAM_READ_TIMEOUT_MS: 150000 } };
  if (spec.endsWith('/AgentApiClient')) return { AgentApiClient: { getConfig: () => ({ baseUrl: 'http://test', timeoutMs: 8000, useFixture: false }) } };
  return {};
});
(async () => {
  for (const current of ['sse', 'legacy', 'truncated', 'noend']) {
    mode = current;
    const updates = [];
    const promise = AgentBridge.callAgent('分析学情', undefined, [], data => updates.push(data));
    if (current === 'truncated' || current === 'noend') await assert.rejects(promise, /尚未收到完整结果/);
    else assert.equal((await promise).reply, answer.reply);
    assert.equal(updates.length, current === 'legacy' || current === 'noend' ? 0 : 1);
  }
  assert.equal(requests, 4, 'must not retry an accepted POST');
  assert.equal(destroyed, 4, 'all requests must release the network handle');
  console.log(`PASS: ${wire.length} packet splits, Unicode, progress, errors, legacy JSON, dataEnd ordering and handle cleanup`);
})().catch(error => { console.error(error); process.exitCode = 1; });
