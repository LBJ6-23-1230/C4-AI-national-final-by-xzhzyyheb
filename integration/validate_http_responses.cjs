/* Consume actual HTTP responses with the same guard used by the ArkTS app. */
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[3] || 'D:/DevEco/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/bin/ark/build-win/legacy_api8/node_modules/typescript');
const moduleValue = { exports: {} };
const source = ts.transpileModule(fs.readFileSync('app/entry/src/main/ets/api/ApiResponseValidator.ets','utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;
vm.runInNewContext(source, { exports: moduleValue.exports, module: moduleValue });
const validator = moduleValue.exports.ApiResponseValidator;
const records = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
let failed = 0;
for (const row of records.filter(r => r.frontend)) {
  if (!validator.isValid(row.method, row.path, row.body)) { console.log('FAIL '+row.method+' '+row.path); failed++; }
}
console.log(`ArkTS validator: ${records.filter(r=>r.frontend).length} actual HTTP responses, ${failed} failed`);
process.exitCode = failed ? 1 : 0;
