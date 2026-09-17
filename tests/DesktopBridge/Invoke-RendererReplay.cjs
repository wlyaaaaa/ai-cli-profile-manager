'use strict';
const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('assert'),cp=require('child_process'),rl=require('readline');
if(process.argv[2]==='--fake'){
 const input=rl.createInterface({input:process.stdin});
 input.on('line',line=>{const r=JSON.parse(line);if(r.method==='thread/start')process.stdout.write(JSON.stringify({id:r.id,result:{model:'deepseek-flash',modelProvider:'aicli_deepseek_flash',thread:{id:'deep-thread',modelProvider:'aicli_deepseek_flash'}}})+'\n');else if(r.method==='test/replay'){for(const e of r.params.events)process.stdout.write(JSON.stringify(e)+'\n');process.stdout.write(JSON.stringify({id:r.id,result:{ok:true}})+'\n');}});return;
}

// Runs the installed Desktop's actual projection and grouping functions against a real
// bridge executable. Unrelated artifact/Markdown adapters are stubbed. This is deliberately
// a projection regression, NOT DOM or visual acceptance. No vendor source is redistributed.
// Usage: node Invoke-RendererReplay.cjs <bridge.exe> <current-app.asar>
const os=require('os'),crypto=require('crypto');
assert(process.argv[2]&&process.argv[3],'Provide bridge.exe and the current installed app.asar.');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'aicli-renderer-replay-'));
process.on('exit',()=>fs.rmSync(root,{recursive:true,force:true}));
function asset(prefix){
 const fd=fs.openSync(process.argv[3],'r');
 try{
  const size=Buffer.alloc(8);fs.readSync(fd,size,0,8,0);
  const n=size.readUInt32LE(4);assert(n>8&&n<64*1024*1024,'Invalid ASAR header size');
  const header=Buffer.alloc(n);fs.readSync(fd,header,0,n,8);
  const manifest=JSON.parse(header.subarray(8,8+header.readUInt32LE(4)).toString('utf8'));
  const matches=[];
  function visit(node){for(const [name,entry]of Object.entries(node.files??{})){if(entry.files)visit(entry);else if(name.startsWith(prefix)&&name.endsWith('.js')&&entry.offset!=null)matches.push(entry);}}
  visit(manifest);assert.equal(matches.length,1,'Expected one installed '+prefix+' asset');
  const entry=matches[0];assert(entry.size<32*1024*1024,'Asset unexpectedly large');
  const bytes=Buffer.alloc(entry.size);assert.equal(fs.readSync(fd,bytes,0,bytes.length,8+n+Number(entry.offset)),bytes.length);
  return bytes.toString('utf8');
 }finally{fs.closeSync(fd);}
}
const source=asset('app-initial-');

assert(source.includes('function bO(e,t,n){let{assistantMessageStartedAtMsById:')&&source.includes('function w2n(e){for(let t=e.length-1;'),'Installed projection contract changed; review extraction before trusting this diagnostic.');
function fn(name){const a=source.indexOf('function '+name+'('); assert(a>=0,name+' missing');let b=source.indexOf('function ',a+10);let s=source.slice(a,b<0?undefined:b);const v=s.indexOf('var ');if(v>=0)s=s.slice(0,v);return s;}
const projection=vm.createContext({console,Set,Map,
 r7n:()=>({replyItemIds:new Set()}),v7n:()=>({}),u8n:()=>false,her:()=>null,xer:e=>e,H7n:()=>[],
 Wer:{default:(a,p)=>a.findLastIndex(p)},ZD:s=>({content:s,removed:false}),pcn:()=>null,Her:()=>null,b7n:()=>{},
 G7n:s=>({inProgress:'in_progress',completed:'complete',interrupted:'cancelled',failed:'failed'}[s]),
 Ner:({items})=>items,u7n:()=>false,x7n:()=>[],T2n:()=>false,
 J7n:e=>e,e9n:(e,done)=>({type:'unknown',cmd:e.cmd??'test',isFinished:done}),ng:e=>e
});
vm.runInContext(fn('w2n')+'\n'+fn('vO')+'\n'+fn('bO'),projection);
const splitSource=asset('split-items-into-render-groups-');
const split=vm.createContext({console,Set,Map,
 e:f=>{f();return ()=>{};},t:f=>({default:f}),n:()=>{},s:()=>{},c:()=>false,
 a:()=>((a,b)=>JSON.stringify(a)===JSON.stringify(b)),
 i:()=>((a,key)=>{const seen=new Set();return a.filter(x=>{const k=key(x);if(seen.has(k))return false;seen.add(k);return true;});}),
 o:()=>((a)=>a),r:()=>false,
 l:e=>e.type==='reasoning'?null:{item:e,grouping:['exec','mcp-tool-call'].includes(e.type)?'groupable':'standalone'}
});
vm.runInContext(splitSource.replace(/import\{[^}]*\}from"[^"]*";/g,'').replace(/export\{[^}]*\};/g,''),split);
function view(turn){const p=projection.bO(turn,[],{includeTurnDiff:false});const g=split.u(p.items,p.status,'latest');return {
 status:p.status,assistant:g.assistantItem?.content??null,
 reasoning:g.agentItems.filter(x=>x.type==='reasoning').map(x=>({id:x.sourceItemId,text:x.content,completed:x.completed})),
 agent:g.agentItems.filter(x=>x.type==='assistant-message').map(x=>({text:x.content,phase:x.phase})),
 active:g.agentItems.filter(x=>x.type==='reasoning'&&!x.completed).map(x=>x.sourceItemId)
};}
function apply(turn,event){const p=event.params??{},m=event.method;
 if(m==='item/started'||m==='item/completed'){const i=turn.items.findIndex(x=>x.id===p.item.id);const val=structuredClone(p.item);if(i<0)turn.items.push(val);else turn.items[i]=val;}
 else if(m==='item/reasoning/summaryTextDelta'){const item=turn.items.find(x=>x.id===p.itemId);assert(item,'delta target absent');item.summary??=[];while(item.summary.length<=p.summaryIndex)item.summary.push('');item.summary[p.summaryIndex]+=p.delta;}
 else if(m==='item/agentMessage/delta'){const item=turn.items.find(x=>x.id===p.itemId);assert(item,'message target absent');item.text=(item.text??'')+p.delta;}
 else if(m==='turn/completed'){turn.status=p.turn.status;}
 return view(turn);
}
async function collect(exe,scenario,publicSummary=false){
 const temp=path.join(root,'replay-home');fs.mkdirSync(temp,{recursive:true});
 const plan={schemaVersion:1,codexHome:temp,upstreamFileName:process.execPath,upstreamPrefixArgs:[__filename,'--fake'],models:[{profileId:'codex-deepseek-flash',model:'deepseek-flash',providerId:'aicli_deepseek_flash',routeProviderId:'aicli_deepseek_flash',kind:'cloud',provider:{name:'DeepSeek Flash',base_url:'https://api.deepseek.com/v1',wire_api:'responses',requires_openai_auth:false},contextWindow:1048576,catalogModel:{slug:'deepseek-flash',display_name:'DeepSeek Flash',context_window:1048576}}]};
 if(publicSummary)plan.models[0].catalogModel.base_instructions="# AICLI public progress summary v1";
 const pf=path.join(root,'replay-plan.json');fs.writeFileSync(pf,JSON.stringify(plan));
 const child=cp.spawn(exe,['app-server','--stdio'],{windowsHide:true,env:{...process.env,AICLI_DESKTOP_PLAN_FILE:pf,TEMP:root,TMP:root,TMPDIR:root},stdio:['pipe','pipe','pipe']});
 let err='';child.stderr.on('data',x=>err+=x);
 const lines=rl.createInterface({input:child.stdout});
 const result=[];const timeout=setTimeout(()=>{child.kill();},12000);
 child.stdin.write(JSON.stringify({id:'start',method:'thread/start',params:{model:'deepseek-flash',config:{}}})+'\n');
 try{for await(const line of lines){const e=JSON.parse(line);if(e.id==='start'){assert(!e.error,JSON.stringify(e.error));child.stdin.write(JSON.stringify(scenario?{id:'events',method:'test/replay',params:{events:scenario}}:{id:'events',method:'test/deepseek-events',params:{}})+'\n');}else if(e.id==='events'){break;}else result.push(e);}}
 finally{clearTimeout(timeout);child.stdin.end();child.kill();}
 assert(result.length>0,err);return result;
}

async function verifyPublicSummary(){
 const nt=(method,params)=>({method,params:{threadId:'deep-thread',turnId:'deep-turn',...params}});
 const items=[
 nt('item/started',{item:{type:'reasoning',id:'r',summary:[],content:[]}}),
 nt('item/reasoning/textDelta',{itemId:'r',contentIndex:0,delta:'RAW_PRIVATE_CANARY'}),
 nt('item/completed',{item:{type:'reasoning',id:'r',summary:[],content:['RAW_PRIVATE_CANARY']}}),
 nt('item/started',{item:{type:'agentMessage',id:'progress',phase:'commentary',text:''}}),
 nt('item/agentMessage/delta',{itemId:'progress',delta:'已经发现四个文件遗漏，需要核对备份目标。'}),
 nt('item/completed',{item:{type:'agentMessage',id:'progress',phase:'commentary',text:'已经发现四个文件遗漏，需要核对备份目标。'}}),
 nt('item/started',{item:{type:'commandExecution',id:'tool',command:'synthetic fixture',cwd:'',processId:null,status:'inProgress',commandActions:[],aggregatedOutput:'',exitCode:null,durationMs:null}}),
 nt('item/completed',{item:{type:'commandExecution',id:'tool',command:'synthetic fixture',cwd:'',processId:null,status:'completed',commandActions:[],aggregatedOutput:'synthetic',exitCode:0,durationMs:1}}),
 nt('item/started',{item:{type:'agentMessage',id:'final',phase:'final_answer',text:''}}),
 nt('item/agentMessage/delta',{itemId:'final',delta:'最终答案保留原样。'}),
 nt('item/completed',{item:{type:'agentMessage',id:'final',phase:'final_answer',text:'最终答案保留原样。'}}),
 {method:'turn/completed',params:{threadId:'deep-thread',turn:{id:'deep-turn',status:'completed'}}}];
 const events=await collect(process.argv[2],items,true);
 const turn={turnId:'deep-turn',status:'inProgress',params:{input:[],threadId:'deep-thread'},items:[]};
 const views=events.map(event=>({event:event.method,...apply(turn,event)}));
 const early=views.filter(v=>v.status==='in_progress'&&v.assistant);
 const summary=views.at(-1).reasoning.map(r=>r.text).join('');
 assert.equal(early.length,0,'Public summary progress must not flash in the final slot');
 assert(summary.includes('四个文件'),'Public summary text missing from actual renderer');
 assert(views.some(v=>v.reasoning.some(r=>r.text.includes('RAW_PRIVATE_CANARY'))),'Pre-existing transient live reasoning must remain visible while the turn is running');
 assert.equal(views.at(-1).assistant,'最终答案保留原样。','Public-summary mode must preserve final answer');
 assert.equal(views.at(-1).active.length,0,'Public-summary mode must not remain thinking');
 return {case:'public-summary',events:events.length,early_final_frames:0,transient_reasoning_visible:true,summary_visible:true,final_preserved:true};
}
(async()=>{
 const scenarios=[];
 const nt=(method,params)=>({method,params:{threadId:'deep-thread',turnId:'deep-turn',...params}});
 const rStart=()=>nt('item/started',{item:{type:'reasoning',id:'r',summary:[],content:[]}});
 const rDelta=()=>nt('item/reasoning/textDelta',{itemId:'r',contentIndex:0,delta:'Visible reasoning'});
 const rDone=(empty)=>nt('item/completed',{item:{type:'reasoning',id:'r',summary:[],content:empty?[]:['Visible reasoning']}});
 const mStart=(phase,prefilled)=>nt('item/started',{item:{type:'agentMessage',id:'m',phase,text:prefilled?'INITIAL ':''}});
 const mDelta=()=>nt('item/agentMessage/delta',{itemId:'m',delta:'FINAL'});
 const mDone=(phase,text='FINAL')=>nt('item/completed',{item:{type:'agentMessage',id:'m',phase,text}});
 const end=()=>({method:'turn/completed',params:{threadId:'deep-thread',turn:{id:'deep-turn',status:'completed'}}});
 for(const phase of [null,'commentary','final_answer']){
   for(const empty of [false,true])scenarios.push({name:'reason-then-output/'+phase+'/empty='+empty,events:[rStart(),rDelta(),rDone(empty),mStart(phase),mDelta(),mDone(phase),end()]});
   scenarios.push({name:'overlap/'+phase,events:[rStart(),rDelta(),mStart(phase),mDelta(),rDone(true),mDone(phase),end()]});
   scenarios.push({name:'completion-only/'+phase,events:[rStart(),rDelta(),rDone(false),mDone(phase),end()]});
   scenarios.push({name:'prefilled/'+phase,expected:'INITIAL FINAL',events:[rStart(),rDelta(),rDone(false),mStart(phase,true),mDelta(),mDone(phase,'INITIAL FINAL'),end()]});
 }
 let report=[];
 for(const scenario of scenarios){
   const events=await collect(process.argv[2],scenario.events),turn={turnId:'deep-turn',status:'inProgress',params:{input:[],threadId:'deep-thread'},items:[]};
   const views=[];for(const event of events)views.push({event:event.method,item:event.params?.item?.id??event.params?.itemId,...apply(turn,event)});
   const early=views.filter(v=>v.status==='in_progress'&&v.assistant);
   assert.equal(early.length,0,scenario.name+': prematurely promoted output');
   const output=views.filter(v=>v.status==='in_progress'&&v.agent.some(a=>a.text));
   assert(output.length>0,scenario.name+': output disappeared');
   assert(output.every(v=>v.reasoning.some(r=>r.text==='Visible reasoning')),scenario.name+': reasoning disappeared');
   assert.equal(views.at(-1).assistant,scenario.expected??'FINAL',scenario.name+': final missing');
   assert.equal(views.at(-1).active.length,0,scenario.name+': stuck thinking');
   report.push({case:scenario.name,events:events.length,early_final_frames:early.length,summary_visible:true,final_preserved:true});
 }
 report.push(await verifyPublicSummary());
 fs.writeFileSync(path.join(root,'renderer-matrix-result.json'),JSON.stringify(report,null,2));
 console.log(JSON.stringify({status:'pass',cases:report.length,projection_asset_sha256:crypto.createHash('sha256').update(source).digest('hex'),grouping_asset_sha256:crypto.createHash('sha256').update(splitSource).digest('hex'),early_final_frames:0,summary_loss_cases:0,final_loss_cases:0}));
})().catch(e=>{console.error(e.stack);process.exitCode=1;});
