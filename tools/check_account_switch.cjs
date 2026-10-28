// Run the production auth client with controlled API responses.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2] || 'typescript');
let session = null;
const store = {getSession: () => session, save(user, token, expiresAt) { session = {...user, token, expiresAt}; }, clear() {session=null;} };
const alice = {userId:'alice', nickname:'Alice', grade:''};
const bob = {userId:'bob', nickname:'Bob', grade:''};
let pending;
const api = {getConfig:()=>({useFixture:false}), authRegister: async request => {
  assert.equal(request.password, 'secret123');
  if(request.phone === '13900000001') return {ok:false,error:{message:'手机号已注册',statusCode:409}};
  return {ok:true,data:{user:bob,token:'bob-token',expiresAt:'2030'}};
}, authMe:()=>new Promise(resolve=>{pending=resolve;})};
const code = ts.transpileModule(fs.readFileSync('app/entry/src/main/ets/api/AuthClient.ets','utf8'), {compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;
const moduleMock = {exports:{}};
vm.runInNewContext(code,{exports:moduleMock.exports,module:moduleMock,require(name){
 if(name==='./AuthStore') return {AuthStore:store};
 if(name==='./AgentApiClient') return {AgentApiClient:api};
 if(name==='./AuthModels') return {NICKNAME_MIN_LENGTH:1,NICKNAME_MAX_LENGTH:32,VERIFICATION_CODE_MESSAGES:{}};
 return {};
}});
const auth = moduleMock.exports.AuthClient;
(async()=>{
 store.save(alice,'alice-token','2030');
 const denied = await auth.register('Bob','13900000001','','secret123');
 assert.equal(denied.ok,false);
 assert.equal(session.userId,'alice');
 const restore = auth.restore();
 const registered = await auth.register('Bob','13900000002','','secret123');
 assert.equal(registered.user.userId,'bob');
 assert.equal(registered.createdAccount,true);
 pending({ok:true,data:{user:alice}});
 assert.equal((await restore).ok,false);
 assert.equal(session.userId,'bob');
 assert.equal(session.token,'bob-token');
 api.authLogin = async () => ({ok:true,data:{accounts:[alice,bob],selectionToken:'choice'}});
 const offered = await auth.loginByPhone('13900000002','secret123');
 assert.equal(offered.ok,false,'choice must not count as an authenticated login');
 assert.equal(offered.accounts.length,2);
 assert.equal(session.userId,'bob','offering choices must not replace session');
 api.authSelectAccount = async request => {
   assert.equal(request.accountId,'alice');
   assert.equal(request.selectionToken,'choice');
   return {ok:true,data:{user:alice,token:'new-alice-token',expiresAt:'2030'}};
 };
 const selected = await auth.selectAccount(offered.selectionToken,'alice','secret123');
 assert.equal(selected.ok,true);
 assert.equal(session.userId,'alice');
 assert.equal(session.token,'new-alice-token');
 console.log('PASS registration, stale restore isolation, choice without session, selected account session');
})().catch(error=>{console.error(error);process.exitCode=1;});

