const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.argv[2] || path.join(process.env.DEVECO_HOME || 'D:/DevEco/DevEco Studio',
  'tools/hvigor/hvigor/node_modules/typescript'));
const base = path.join(__dirname, '../app/entry/src/main/ets');
function load(filename) {
  const full = path.resolve(base, filename);
  const output = ts.transpileModule(fs.readFileSync(full, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  const module = { exports: {} };
  vm.runInNewContext(output, { exports: module.exports, module,
    require: name => load(path.relative(base, path.resolve(path.dirname(full), name + '.ets'))) });
  return module.exports;
}
const { AccountProfileSaver } = load('services/AccountProfileSaver.ets');
const { apiSuccess, apiFailure } = load('api/ApiResult.ets');
const request = { nickname: 'New name', avatar: 'new-avatar' };
const saved = apiSuccess({ user: { userId: 'owner', ...request } }, 'network');
const old = apiSuccess({ user: { userId: 'owner', nickname: 'Old name', avatar: '' } }, 'network');
const network = apiFailure('NETWORK_ERROR', 'timeout', true, 'network');
let tests = 0;
async function check(writes, readResult, expectedOk, expectedWrites, expectedReads, switchAfter = '') {
  let writeCount = 0, readCount = 0, active = true;
  const transport = {
    write: async () => { const result = writes[writeCount++]; if (switchAfter === 'write') active = false; return result; },
    read: async () => { readCount++; if (switchAfter === 'read') active = false; return readResult; },
    isCurrent: () => active
  };
  const result = await AccountProfileSaver.save(request, 'owner', transport);
  assert.equal(result.ok, expectedOk);
  assert.equal(writeCount, expectedWrites);
  assert.equal(readCount, expectedReads);
  tests++;
  return result;
}
(async () => {
  await check([saved], old, true, 1, 0);
  // Server committed, but the client lost the PUT response: do not repeat the write.
  await check([network], saved, true, 1, 1);
  // Server did not commit: recover with exactly one automatic idempotent retry.
  await check([network, saved], old, true, 2, 1);
  await check([network, saved], network, true, 2, 1);
  await check([network, network], network, false, 2, 1);
  await check([apiFailure('VALIDATION_ERROR', 'invalid', false, 'network', 400)], old, false, 1, 0);
  await check([network], apiFailure('UNAUTHORIZED', 'expired', false, 'network', 401), false, 1, 1);
  await check([network], old, false, 1, 0, 'write');
  await check([network], old, false, 1, 1, 'read');
  await check([apiSuccess({ user: { userId: 'other', ...request } }, 'network')], old, false, 1, 0);
  await check([apiFailure('HTTP_ERROR', 'busy', true, 'network', 503), saved], old, true, 2, 1);
  console.log(`Account profile save: ${tests} timeout, recovery, and account-isolation scenarios passed.`);
})().catch(error => { console.error(error); process.exitCode = 1; });
