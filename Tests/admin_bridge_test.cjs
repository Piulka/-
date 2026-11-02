const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../ChromeOTPBridge/admin.js'), 'utf8');
const origin = 'https://test08-podval.int.indels.dev';
async function scenario(operation, options = {}) {
  const calls = [];
  let door = options.current || 'enabled', other = 'unchanged';
  const field = () => ({value:door, type:'select-one', getAttribute:()=> 'door_to_door'});
  const block = {
    getAttribute:()=> '42',
    querySelector:s => s === '[data-name="door_to_door"]' ? field() : s.includes('order_type_city_id') ? {value:'73'} : s.includes('YII_CSRF_TOKEN') ? {value:'fake-csrf-test'} : null,
    querySelectorAll:()=> [field(), {value:other,type:'text',getAttribute:()=> 'other_field'}],
  };
  const document = {
    querySelector:s => s === '#City_name' ? {value:options.cityName || 'Калуга'} : s === '#orderCitySettingsTypes' ? {options:[{value:'73',textContent:'Courier'}]} : s === '#order-type-setting-block-73' ? block : s === '#reason' || s === '#cleargo' ? {} : null,
  };
  const context = vm.createContext({
    location:{origin:options.origin || origin,pathname:'/podval/city/update',search:'?id=590'},
    AbortSignal:{timeout:()=>undefined}, FormData, URLSearchParams,
    DOMParser:class {parseFromString(){return document;}},
    fetch:async (url, request)=>{
      calls.push({url,request});
      assert.equal(request.credentials,'same-origin');assert.equal(request.redirect,'manual');
      assert.ok(url.startsWith(origin+'/podval/'));
      let text='form; {"X-CSRF-TOKEN":"'+'test-csrf-placeholder-only'.repeat(2)+'"}';
      if(url.endsWith('/gocache/cache')) {
        assert.equal(request.headers['X-CSRF-TOKEN'],'test-csrf-placeholder-only'.repeat(2));
        assert.equal(request.headers['X-Requested-With'],'XMLHttpRequest');
      }
      if(url.includes('/ordertypecitysettings/update')) {
        const data=JSON.parse(request.body.get('data'));
        assert.deepEqual(Object.keys(data).sort(),['door_to_door','order_type_city_id']);
        assert.equal(data.order_type_city_id,'73');
        assert.equal(request.body.get('YII_CSRF_TOKEN'),'fake-csrf-test');
        door= options.verifyFail ? door : data.door_to_door;
        if(options.sideEffect) other='changed';
        text=JSON.stringify({status:200});
      }else if(url.endsWith('/gocache/cache')) {
        assert.equal(request.method,'POST');
        if(options.goFail) throw Error('private server details');
      }else if(url.endsWith('/stat/clearcache'))text=options.phpFail ? 'unknown server output' : 'Yii cache cleared';
      const status=options.auth ? 403 : options.redirect ? 302 : 200;
      return {status,ok:status===200,text:async()=>text};
    },
  });
  vm.runInContext(source,context);
  const result=await context.ZhmakeeAdmin.run({operation,stand:options.stand || '08',city:options.city ?? 590,created:Date.now()/1000-(options.stale?10:0),value:options.value || 'disabled',expected:options.expected || 'enabled'});
  assert.ok(!JSON.stringify(result).includes('fake-csrf'));
  assert.ok(!JSON.stringify(result).includes('private server'));
  return {result,calls,door};
}
module.exports=(async()=>{
  let r=await scenario('admin_read');assert.equal(r.result.code,'admin_loaded');assert.equal(r.calls.length,1);
  r=await scenario('admin_door');assert.equal(r.result.ok,true);assert.equal(r.result.door,'disabled');assert.equal(r.result.saved,true);assert.equal(r.result.go,false);assert.equal(r.result.php,false);
  assert.equal(r.calls.some(x=>x.url.includes('/gocache/') || x.url.includes('/stat/clearcache')),false);
  assert.equal(r.calls.filter(x=>x.url.includes('/ordertypecitysettings/update')).length,1);
  r=await scenario('admin_cache');assert.equal(r.result.ok,true);assert.equal(r.calls.filter(x=>x.url.includes('/ordertypecitysettings/update')).length,0);
  for(const options of [{stand:'09'},{city:591},{stale:true},{value:'other'},{origin:'https://test09-podval.int.indels.dev'}]) {
    r=await scenario('admin_door',options);assert.equal(r.result.ok,false);assert.equal(r.calls.length,0);
  }
  r=await scenario('admin_door',{current:'disabled'});assert.equal(r.result.code,'admin_conflict');assert.equal(r.calls.length,1);
  r=await scenario('admin_door',{cityName:'Москва'});assert.equal(r.result.code,'admin_page_changed');assert.equal(r.calls.length,1);
  r=await scenario('admin_door',{redirect:true});assert.equal(r.result.code,'admin_auth_required');assert.equal(r.calls.length,1);
  r=await scenario('admin_door',{auth:true});assert.equal(r.result.code,'admin_auth_required');assert.equal(r.calls.length,1);
  for(const options of [{verifyFail:true},{sideEffect:true}]) {
    r=await scenario('admin_door',options);assert.equal(r.result.code,'admin_unverified');assert.equal(r.calls.some(x=>x.url.includes('gocache')),false);
  }
  r=await scenario('admin_cache',{goFail:true});assert.equal(r.result.code,'admin_unverified');assert.equal(r.result.saved,false);assert.equal(r.result.go,false);
  r=await scenario('admin_cache',{phpFail:true});assert.equal(r.result.code,'admin_partial');assert.equal(r.result.go,true);assert.equal(r.result.php,false);
  console.log('Admin scope, partial field update, stale-state conflicts, verification and partial cache results: passed');
})();
