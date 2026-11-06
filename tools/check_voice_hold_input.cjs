/* Exercise the real ArkTS speech lifecycle and chat hold handlers with deferred native APIs.
 * This verifies ordering and draft ownership; speech quality still needs a physical microphone.
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2] || 'typescript');
const root = 'app/entry/src/main/ets/';
const read = file => fs.readFileSync(root + file, 'utf8').replace(/\r\n/g, '\n');
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
};
const tick = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
let checks = 0;
const check = (value, label) => { assert(value, label); checks++; };
function compile(context, source) {
  const result = ts.transpileModule(source, { reportDiagnostics: true,
    compilerOptions: { target: ts.ScriptTarget.ES2020 } });
  assert.equal(result.diagnostics.length, 0);
  vm.runInContext(result.outputText, context);
}
function speechHarness() {
  const timers = new Map();
  let timerId = 0;
  const capturers = [];
  const engines = [];
  const options = { engineWait: null, capturerWait: null, startWait: null, onlineFails: false };
  function engine() {
    const value = { busy: false, writes: [], starts: [], finishes: [], cancels: [], shutdowns: 0,
      setListener(listener) { this.listener = listener; },
      isBusy() { return this.busy; },
      startListening(params) { this.starts.push(params); this.busy = true; this.session = params.sessionId; },
      writeAudio(id, bytes) { this.writes.push({id, bytes: [...bytes]}); },
      finish(id) { this.finishes.push(id); },
      cancel(id) { this.cancels.push(id); this.busy = false; },
      shutdown() { this.shutdowns++; this.busy = false; },
      result(text, isFinal = false, isLast = false, id = this.session) {
        this.listener.onResult(id, {result: text, isFinal, isLast});
      }
    };
    engines.push(value); return value;
  }
  function capturer() {
    const value = { state: 0, starts: 0, stops: 0, releases: 0,
      on(name, listener) { this.listener = listener; },
      off() { this.listener = null; },
      async start() { this.starts++; if (options.startWait) await options.startWait.promise; this.state = 1; },
      async stop() { this.stops++; this.state = 0; },
      async release() { this.releases++; this.state = 2; }
    };
    capturers.push(value); return value;
  }
  const createModes = [];
  const context = vm.createContext({ console, Uint8Array, ArrayBuffer,
    setTimeout(fn, ms) { const id = ++timerId; timers.set(id, {fn, ms}); return id; },
    clearTimeout(id) { timers.delete(id); },
    speechRecognizer: { async createEngine(params) {
      createModes.push(params.online);
      if (params.online === 0 && options.onlineFails) throw new Error('online unavailable');
      return options.engineWait ? options.engineWait.promise : engine();
    } },
    audio: { AudioSamplingRate: {SAMPLE_RATE_16000: 16000}, AudioChannel: {CHANNEL_1: 1},
      AudioSampleFormat: {SAMPLE_FORMAT_S16LE: 1}, AudioEncodingType: {ENCODING_TYPE_RAW: 1},
      SourceType: {SOURCE_TYPE_VOICE_RECOGNITION: 1}, AudioState: {STATE_RUNNING: 1},
      async createAudioCapturer() { return options.capturerWait ? options.capturerWait.promise : capturer(); }
    }
  });
  compile(context, read('services/VoiceInputService.ets').replace(/^import[^\n]*\n/gm, '').replace(/export /g, '') +
    '\nglobalThis.Service = VoiceInputService; globalThis.Callbacks = VoiceInputCallbacks;');
  const service = new context.Service();
  const events = { states: [], texts: [], errors: [], complete: 0 };
  const callbacks = () => new context.Callbacks(
    state => events.states.push(state), (text, final) => events.texts.push({text, final}),
    error => events.errors.push(error), () => events.complete++);
  return { context, service, events, callbacks, options, engines, capturers, engine, capturer, timers, createModes };
}
function pageHarness(harness) {
  const appState = {currentUser: {userId: 'alice'}};
  const permissions = deferred();
  const context = harness.context;
  context.appState = appState;
  context.abilityAccessCtrl = {createAtManager: () => ({requestPermissionsFromUser: () => permissions.promise})};
  const source = read('pages/ChatMain.ets');
  const a = source.indexOf('  private async toggleVoiceMode(');
  const b = source.indexOf('  private async pickDocument(', a);
  compile(context, 'class ChatHarness {' + source.slice(a, b) +
    '} globalThis.ChatHarness = ChatHarness;');
  const page = new context.ChatHarness();
  Object.assign(page, {isPageActive: true, voiceMode: true, voiceReady: true, voicePressing: true,
    voiceTurnStarted: false, voiceRequestVersion: 1, voiceDraft: '', inputText: '原有草稿：',
    isSending: false, fileBusy: false, isVoiceStarting: false, isVoiceFinalizing: false, isListening: false,
    voiceInputService: harness.service, voiceMessage: '', inputController: {stopEditing() {}},
    getUIContext: () => ({getHostContext: () => ({})})});
  return {page, appState, permissions};
}
(async () => {
  let h = speechHarness();
  await h.service.start(h.callbacks());
  const e = h.engines[0], c = h.capturers[0];
  e.result('你好');
  e.result('你好。', true);
  e.result('第二句');
  check(h.events.texts.at(-1).text === '你好。第二句', 'sentence finalization retains earlier speech');
  check(h.events.complete === 0 && h.service.isListening(), 'sentence final is not a finished turn');
  const first = new Uint8Array(420).fill(1), second = new Uint8Array(300).fill(2);
  c.listener(first.buffer); c.listener(second.buffer);
  check(e.writes.length === 1 && e.writes[0].bytes.length === 640, 'PCM frames join callback remainders');
  check(e.writes[0].bytes[419] === 1 && e.writes[0].bytes[420] === 2, 'PCM sample order survives framing');
  await h.service.stop(true);
  check(e.finishes.length === 1 && c.releases === 1, 'release microphone before requesting final text');
  check(e.writes.length === 2 && e.writes[1].bytes[79] === 2 && e.writes[1].bytes[80] === 0,
    'last partial PCM frame is preserved with silence padding');
  e.result('第二句。', true, true);
  check(h.events.texts.at(-1).text === '你好。第二句。' && h.events.complete === 1, 'last sentence finalizes exactly once');
  e.listener.onComplete(e.session, 'done');
  check(h.events.complete === 1 && h.timers.size === 0, 'duplicate completion does not replay callbacks');
  const texts = h.events.texts.length;
  e.result('过期文本', true, true);
  check(h.events.texts.length === texts, 'late native recognition results are ignored');

  h = speechHarness();
  h.options.engineWait = deferred();
  const starting = h.service.start(h.callbacks());
  await h.service.stop(true);
  const lateEngine = h.engine(); h.options.engineWait.resolve(lateEngine);
  await starting;
  check(lateEngine.shutdowns === 1 && h.capturers.length === 0, 'release while initializing never opens microphone');
  check(h.events.complete === 1 && !h.events.states.includes(true), 'early release completes without starting');

  h = speechHarness(); h.options.capturerWait = deferred();
  const creating = h.service.start(h.callbacks()); await tick();
  await h.service.dispose();
  const lateCapturer = h.capturer(); h.options.capturerWait.resolve(lateCapturer); await creating;
  check(lateCapturer.starts === 0 && lateCapturer.releases === 1, 'leaving during microphone creation releases late handle');

  h = speechHarness(); h.options.startWait = deferred();
  const nativeStarting = h.service.start(h.callbacks()); await tick();
  const stopping = h.service.stop(true);
  h.options.startWait.resolve(); await Promise.all([nativeStarting, stopping]);
  check(h.capturers[0].stops === 1 && h.capturers[0].releases === 1,
    'release during native start still stops the microphone after start settles');
  check(!h.events.states.includes(true) && h.events.complete === 1,
    'a canceled native start never reports listening');

  h = speechHarness(); await h.service.start(h.callbacks());
  h.engines[0].listener.onComplete(h.engines[0].session, 'silence'); await tick();
  check(h.capturers[0].releases === 1 && !h.service.isListening(), 'native completion releases microphone without button release');

  h = speechHarness(); await h.service.start(h.callbacks()); await h.service.stop(true);
  const finalWait = [...h.timers.values()].find(timer => timer.ms === 5000); finalWait.fn();
  check(h.events.complete === 1 && h.timers.size === 0, 'missing native completion has a bounded final-result wait');

  h = speechHarness(); h.options.onlineFails = true; await h.service.start(h.callbacks());
  check(h.createModes.join(',') === '0,1' && h.service.isListening(), 'offline fallback remains available');

  h = speechHarness(); let {page, appState} = pageHarness(h);
  await page.startVoiceInput(); h.engines[0].result('今天复习树');
  check(page.inputText === '原有草稿：今天复习树' && page.voiceMode, 'hold shows incremental text and preserves existing draft');
  await page.endVoiceHold(false);
  check(!page.voiceMode && page.isVoiceFinalizing && !page.isListening, 'release changes back to editable input while finalizing');
  h.engines[0].result('今天复习树。', true, true);
  check(!page.isVoiceFinalizing && page.inputText === '原有草稿：今天复习树。', 'final speech remains a manually sendable draft');

  h = speechHarness(); ({page} = pageHarness(h)); await page.startVoiceInput();
  h.engines[0].result('不需要的语音'); await page.endVoiceHold(true);
  check(page.inputText === '原有草稿：' && h.engines[0].cancels.length === 1, 'cancel restores the draft before this hold');
  h.engines[0].result('迟到结果', true, true);
  check(page.inputText === '原有草稿：', 'canceled hold cannot overwrite draft');

  h = speechHarness(); ({page, appState} = pageHarness(h)); await page.startVoiceInput();
  appState.currentUser.userId = 'bob'; h.engines[0].result('甲用户语音');
  check(page.inputText === '原有草稿：', 'account change rejects earlier speech callbacks');
  page.cancelVoiceInput();

  h = speechHarness(); const permissionPage = pageHarness(h); page = permissionPage.page;
  page.voiceMode = false;
  const preparing = page.toggleVoiceMode(); page.cancelVoiceInput();
  permissionPage.permissions.resolve({authResults: [0]}); await preparing;
  check(!page.voiceMode && !page.voiceReady, 'late permission result does not reopen voice mode');
  console.log(`PASS ${checks} speech lifecycle and hold-input checks`);
})().catch(error => { console.error(error); process.exitCode = 1; });
