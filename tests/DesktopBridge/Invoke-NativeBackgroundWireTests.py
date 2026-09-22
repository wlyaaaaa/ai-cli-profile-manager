"""Real installed Codex + bridge, isolated deterministic Responses endpoints.

No credentials, real models, private configuration or executable model tools.
The strict parent endpoint rejects split call/result pairs and orphan outputs.
This is native transport integration, not user Desktop/model E2E.
"""
from __future__ import annotations
import argparse, hashlib, json, os, queue, re, shutil, stat, subprocess, tempfile, threading, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def text_of(item):
    content=item.get('content',[])
    return content if isinstance(content,str) else '\n'.join(x.get('text','') for x in content if isinstance(x,dict))


def child_snapshots(items):
    snapshots=[]
    for x in items:
        if x.get('type')=='function_call_output':
            try:s=json.loads(x.get('output',''))
            except (ValueError,TypeError):continue
            if isinstance(s,dict):
                if s.get('thread_id'):snapshots.append(s)
                snapshots.extend(s.get('children',[]))
        elif x.get('type')=='message' and '<aicli_background_event>' in text_of(x):
            for line in text_of(x).splitlines():
                try:s=json.loads(line)
                except ValueError:continue
                if isinstance(s,dict) and s.get('thread_id'):snapshots.append(s)
    return snapshots


def run_case(bridge:Path,engine:Path,model:str,expect_rejection:bool,protected_contract:bool=False,protected_model:str="gpt-6-astra"):
    work=Path(tempfile.mkdtemp(prefix='native-child-wire-'));home=work/'home';home.mkdir()
    nonce=uuid.uuid4().hex;provider='aicli_'+model.replace('.','_').replace('-','_')
    if model=='deepseek-flash':provider='aicli_deepseek_flash'
    requests=[];errors=[];turns=[];child_ids=set();sessions=set();strict_rejections=[];lock=threading.Lock()
    result={'parent_model':model,'engine_sha256':hashlib.sha256(engine.read_bytes()).hexdigest(),
        'bridge_sha256':hashlib.sha256(bridge.read_bytes()).hexdigest(),
        'bridge_files_sha256':{name:hashlib.sha256((bridge.parent/name).read_bytes()).hexdigest() for name in
            ('AiCli.CodexDesktopBridge.exe','AiCli.CodexDesktopBridge.dll','AiCli.CodexDesktopBridge.deps.json','AiCli.CodexDesktopBridge.runtimeconfig.json')},
        'live_models':False,'desktop_e2e':False,
        'fixture_only':True,'credential_access':False,'private_config_access':False,'protected_contract':protected_contract,'protected_model':protected_model if protected_contract else None}
    done=threading.Event()
    def function(name,args):
        return {'id':str(uuid.uuid4()),'type':'function_call','call_id':'call_nonce_'+uuid.uuid4().hex,
            'name':name,'arguments':json.dumps(args),'status':'completed'}
    def final(text):
        return {'id':'msg_'+uuid.uuid4().hex,'type':'message','role':'assistant','status':'completed',
                'content':[{'type':'output_text','text':text,'annotations':[]}]}
    def validate_parent(items):
        pending=set()
        for x in items:
            kind=x.get('type')
            if kind=='function_call':pending.add(x['call_id'])
            elif kind=='function_call_output':
                cid=x.get('call_id')
                if not cid or cid not in pending:return 'orphan tool output or missing call_id'
                pending.remove(cid)
            elif pending and kind=='message':return 'message splits function call and result'
        return 'missing tool result' if pending else None
    def parent_reply(data):
        items=data.get('input',[]);failure=validate_parent(items)
        if failure:
            strict_rejections.append(failure);return None
        phase_index=-1;phase=''
        for i,x in enumerate(items):
            text=text_of(x)
            if x.get('type')=='message' and text.startswith('PHASE_'):
                phase_index=i;phase=text.split()[0]
        phase_items=items[phase_index+1:];snapshots=child_snapshots(phase_items)
        if protected_contract:
            calls=[x for x in phase_items if x.get('type')=='function_call' and x.get('name')=='openai_child']
            args={'agent_type':'gpt6_sol_high_protected_judgment' if protected_model=='gpt-6-sol' else 'gpt6_astra_high_protected_judgment','model':protected_model,'reasoning_effort':'high',
                  'task_name':'astra_high_native_contract','message':'PROTECTED:'+nonce}
            outputs=[json.loads(x['output']) for x in phase_items if x.get('type')=='function_call_output']
            if not calls:
                args['wait_ms']=30000  # Reproduce a caller using the old, broader schema.
                return function('openai_child',args)
            if len(calls)==1:
                assert len(outputs)==1 and outputs[0].get('error')=='OPENAI_CHILD_PROTECTED_ARGUMENTS_INVALID',outputs
                assert outputs[0].get('child_created') is False and 'retry_action' in outputs[0]
                assert not any(r['path']=='/child/responses' for r in requests)
                return function('openai_child',args)
            assert len(calls)==2 and len(outputs)==2,outputs
            complete=outputs[-1]
            assert complete.get('final_text')=='JUDGMENT:'+nonce,complete
            assert complete.get('model')==protected_model and complete.get('reasoning_effort')=='high' and complete.get('persistent') is True,complete
            assert complete.get('transcript_path') and complete.get('host_event',{}).get('turn_id')==complete.get('turn_id'),complete
            child_ids.add(complete['thread_id']);sessions.add(complete['session_id']);turns.append(complete['turn_id'])
            result['protected_evidence_returned']=True
            return final('PARENT_PROTECTED_PASS')
        all_snapshots=child_snapshots(items)
        for snap in all_snapshots:
            child_ids.add(snap['thread_id'])
            if snap.get('session_id'):sessions.add(snap['session_id'])
        handle=next((s['thread_id'] for s in reversed(all_snapshots) if s.get('session_id')),None)
        calls=[x for x in phase_items if x.get('type')=='function_call' and x.get('name')=='openai_child']
        if not calls:
            messages={'PHASE_REMEMBER':'REMEMBER:'+nonce,'PHASE_RECALL':'RECALL',
                      'PHASE_ASK':'ASK:Which fixture option?','PHASE_PROGRESS':'PROGRESS:nonce progress'}
            args={'agent_type':'openai_child','model':'gpt-5.6-luna','reasoning_effort':'high',
                  'task_name':'luna_high_native_wire','message':messages[phase],'wait_ms':0}
            if handle:args['thread_id']=handle
            return function('openai_child',args)
        # A question may arrive as an automatic event before or after tool return.
        question=next((s for s in reversed(snapshots) if s.get('event')=='question' or s.get('pending_reply_ids')),None)
        replied=any('reply_to' in json.loads(x['arguments']) for x in calls)
        if phase=='PHASE_ASK' and question and not replied:
            return function('openai_child',{'agent_type':'openai_child','model':'gpt-5.6-luna',
                'reasoning_effort':'high','task_name':'luna_high_native_wire','message':'OPTION_B',
                'thread_id':question['thread_id'],'reply_to':question.get('reply_to') or question['pending_reply_ids'][0],'wait_ms':0})
        complete=next((s for s in reversed(snapshots) if s.get('state')=='completed' and s.get('final_text')),None)
        if complete:
            expected={'PHASE_REMEMBER':'REMEMBERED','PHASE_RECALL':nonce,'PHASE_ASK':'ANSWER:OPTION_B','PHASE_PROGRESS':'PROGRESS_SENT'}[phase]
            if complete['final_text']!=expected:raise AssertionError(('wrong child result',phase,complete['final_text']))
            if complete['turn_id'] not in turns:turns.append(complete['turn_id'])
            return final('PARENT_'+phase[6:]+'_PASS')
        if not handle:raise AssertionError('Native child start did not return a handle')
        latest_version=next((s['version'] for s in reversed(snapshots) if s.get('thread_id')==handle and 'version' in s),-1)
        return function('openai_child_control',{'action':'wait','thread_id':handle,'after_version':latest_version,'timeout_ms':1000})
    def child_reply(data):
        items=data.get('input',[])
        if protected_contract:
            assert data['model']==protected_model and data.get('reasoning',{}).get('effort')=='high',data.get('reasoning')
            assert any(text_of(x)=='PROTECTED:'+nonce for x in items),items
            return final('JUDGMENT:'+nonce)
        incoming=[(i,x.get('output','')) for i,x in enumerate(items) if x.get('type')=='function_call_output' and x.get('name')=='openai_parent' and not x.get('call_id')]
        if not incoming:raise AssertionError('Child did not receive the parent via native toolOutput')
        index,message=incoming[-1];following=items[index+1:]
        if message.startswith('REMEMBER:'):
            # An actual progress callback forces asynchronous parent delivery before completion.
            callbacks=[x for x in following if x.get('type')=='function_call_output' and x.get('call_id')]
            if not callbacks:return function('openai_parent',{'message':'nonce initial progress','request_reply':False})
            if not json.loads(callbacks[-1]['output']).get('delivered'):raise AssertionError('Progress not delivered')
            return final('REMEMBERED')
        if message=='RECALL':
            stored=[x.split(':',1)[1] for _,x in incoming if x.startswith('REMEMBER:')]
            if len(stored)!=1:raise AssertionError('Child history lacks exactly one original nonce')
            return final(stored[0])
        if message.startswith('ASK:'):
            callbacks=[x for x in following if x.get('type')=='function_call_output' and x.get('call_id')]
            if not callbacks:return function('openai_parent',{'message':message[4:],'request_reply':True})
            payload=json.loads(callbacks[-1]['output']);assert payload['provenance']=='owning_parent_agent_not_user'
            return final('ANSWER:'+payload['reply'])
        if message.startswith('PROGRESS:'):
            callbacks=[x for x in following if x.get('type')=='function_call_output' and x.get('call_id')]
            if not callbacks:return function('openai_parent',{'message':message[9:],'request_reply':False})
            assert json.loads(callbacks[-1]['output'])['delivered'] is True
            return final('PROGRESS_SENT')
        raise AssertionError('Unexpected child task')
    class Handler(BaseHTTPRequestHandler):
        def log_message(self,*args):pass
        def do_POST(self):
            try:
                assert self.path in ('/parent/responses','/child/responses'),self.path
                data=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                assert self.headers.get('Authorization') in (None,'Bearer fixture-not-a-real-key'),'Unexpected credential in an isolated fixture'
                with lock:
                    requests.append({'path':self.path,'body':data})
                    if len(requests)>60:raise AssertionError('Fixture exceeded bounded request count')
                    item=parent_reply(data) if self.path.startswith('/parent/') else child_reply(data)
                if item is None:
                    self.send_response(400);self.send_header('Content-Type','application/json');self.end_headers()
                    self.wfile.write(json.dumps({'error':{'message':strict_rejections[-1],'code':'strict_fixture_rejected'}}).encode());return
                response={'id':'resp_'+uuid.uuid4().hex,'object':'response','status':'completed','model':data['model'],
                    'output':[item],'usage':{'input_tokens':10,'output_tokens':10,'total_tokens':20}}
                self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
                events=[('response.created',{'response':{**response,'status':'in_progress','output':[]}}),
                    ('response.output_item.added',{'output_index':0,'item':item}),('response.output_item.done',{'output_index':0,'item':item}),
                    ('response.completed',{'response':response})]
                for kind,value in events:
                    self.wfile.write(('event: '+kind+'\ndata: '+json.dumps({'type':kind,**value})+'\n\n').encode());self.wfile.flush()
            except (BrokenPipeError,ConnectionResetError):pass
            except Exception as exc:
                errors.append(repr(exc));done.set()
                try:self.send_error(500,'Fixture assertion failed')
                except OSError:pass
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler);server.daemon_threads=True
    threading.Thread(target=server.serve_forever,daemon=True).start()
    config='''model="gpt-5.6-luna"
model_provider="openai"
approval_policy="never"
sandbox_mode="danger-full-access"
project_doc_max_bytes=0
web_search="disabled"
openai_base_url="http://127.0.0.1:PORT/child"
cli_auth_credentials_store="file"
[features]
plugins=false
'''.replace('PORT',str(server.server_port));(home/'config.toml').write_text(config,encoding='utf-8')
    # Official built-in auth uses an isolated, explicitly non-secret test value.
    # No real credential store or user login is read or modified.
    (home/'auth.json').write_text(json.dumps({'OPENAI_API_KEY':'fixture-not-a-real-key'}),encoding='utf-8')
    catalog={'slug':model,'display_name':model,'description':'Isolated deterministic protocol fixture',
        'base_instructions':'Use only the registered collaboration tools for this nonce test.',
        'context_window':1048576,'effective_context_window_percent':95,'default_reasoning_level':'high',
        'supported_reasoning_levels':[{'effort':'high','description':'high'}],
        'shell_type':'shell_command','visibility':'list','minimal_client_version':'0.144.0','supported_in_api':True,
        'priority':1,'availability_nux':None,'upgrade':None,'supports_reasoning_summaries':True,
        'support_verbosity':True,'default_verbosity':'low','apply_patch_tool_type':'freeform',
        'web_search_tool_type':'text','input_modalities':['text'],'supports_image_detail_original':False,
        'truncation_policy':{'mode':'tokens','limit':10000},'supports_parallel_tool_calls':True,
        'experimental_supported_tools':[],'include_skills_usage_instructions':False,
        'include_apps_usage_instructions':False,'include_plugin_usage_instructions':False,
        'prefer_websockets':False,'use_responses_lite':False,'tool_mode':None,'multi_agent_version':'v2',
        'default_reasoning_summary':'none','reasoning_summary_format':'experimental','supports_search_tool':False}
    plan={'schemaVersion':1,'codexHome':str(home),'upstreamFileName':str(engine),'upstreamPrefixArgs':[],'upstreamModels':[{**catalog,'slug':m,'display_name':m+' fixture'} for m in ('gpt-5.6-luna','gpt-6-astra','gpt-6-sol')],
       'models':[{'profileId':'fixture-'+model,'model':model,'providerId':provider,'routeProviderId':provider,
         'kind':'cloud','provider':{'name':'Isolated strict parent fixture','base_url':'http://127.0.0.1:'+str(server.server_port)+'/parent',
           'wire_api':'responses','requires_openai_auth':False,'request_max_retries':0,'stream_max_retries':0},
         'catalogModel':catalog,'catalogPath':str(home/'catalog.json'),'contextWindow':1048576,'defaultEffort':'high'}]}
    planpath=work/'plan.json';planpath.write_text(json.dumps(plan),encoding='utf-8')
    env={k:v for k,v in os.environ.items() if k.upper() in ('SYSTEMROOT','WINDIR','COMSPEC','PATH','PATHEXT','SYSTEMDRIVE','OS','PROCESSOR_ARCHITECTURE','NUMBER_OF_PROCESSORS')}
    env.update({'CODEX_HOME':str(home),'CODEX_SQLITE_HOME':str(home),'TEMP':str(work),'TMP':str(work),'TMPDIR':str(work),
       'USERPROFILE':str(work),'APPDATA':str(work/'app'),'LOCALAPPDATA':str(work/'local'),'AICLI_DESKTOP_PLAN_FILE':str(planpath),
       'NO_PROXY':'127.0.0.1,localhost','no_proxy':'127.0.0.1,localhost','HTTP_PROXY':'','HTTPS_PROXY':'','ALL_PROXY':'','http_proxy':'','https_proxy':'','all_proxy':''})
    proc=None;notifications=[];stderr=[];phases=[];q=queue.Queue();started=time.monotonic()
    try:
        proc=subprocess.Popen([str(bridge),'app-server'],cwd=work,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,text=True,encoding='utf-8',creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        def pump():
            for line in proc.stdout:
                try:q.put(json.loads(line))
                except ValueError:errors.append('Non-JSON bridge stdout')
        threading.Thread(target=pump,daemon=True).start()
        def errpump():
            for line in proc.stderr:stderr.append(line)
        threading.Thread(target=errpump,daemon=True).start()
        def rpc(method,params):
            rid=uuid.uuid4().hex;proc.stdin.write(json.dumps({'jsonrpc':'2.0','id':rid,'method':method,'params':params})+'\n');proc.stdin.flush()
            deadline=time.monotonic()+12
            while time.monotonic()<deadline:
                m=q.get(timeout=max(.1,deadline-time.monotonic()))
                if m.get('id')==rid:
                    if 'error' in m:raise RuntimeError((method,m['error']))
                    return m['result']
                notifications.append(m)
            raise TimeoutError(method)
        rpc('initialize',{'clientInfo':{'name':'aicli_isolated_native_background_test','version':'1'},'capabilities':{'experimentalApi':True}})
        proc.stdin.write('{"jsonrpc":"2.0","method":"initialized"}\n');proc.stdin.flush()
        parent=rpc('thread/start',{'cwd':str(work),'model':model,'historyMode':'legacy','ephemeral':False,
           'approvalPolicy':'never','sandbox':'danger-full-access'})['thread']['id']
        for phase in (('PROTECTED',) if protected_contract else ('REMEMBER','RECALL','ASK','PROGRESS')):
            start=rpc('turn/start',{'threadId':parent,'input':[{'type':'text','text':'PHASE_'+phase+' '+(nonce if phase=='REMEMBER' else 'Continue the same child.')}]})
            wanted='PARENT_'+phase+'_PASS';deadline=time.monotonic()+25;matched=False
            while time.monotonic()<deadline and not errors:
                if strict_rejections:break
                for m in notifications:
                    p=m.get('params',{})
                    if m.get('method')=='item/completed' and p.get('threadId')==parent and p.get('item',{}).get('text')==wanted:matched=True
                if matched:break
                try:notifications.append(q.get(timeout=.2))
                except queue.Empty:pass
            if strict_rejections and expect_rejection:break
            assert matched,(phase,errors,strict_rejections,stderr[-4:])
            # Wait for the actual parent's last turn to stop before the next real fixture input.
            deadline=time.monotonic()+6
            while time.monotonic()<deadline:
                state=rpc('thread/read',{'threadId':parent,'includeTurns':False})
                if state['thread']['status']['type']!='active':break
                time.sleep(.03)
            phases.append(phase)
        if expect_rejection:
            assert strict_rejections,'Old release did not reproduce the strict protocol rejection'
        else:
            assert not errors and not strict_rejections
            assert phases==(['PROTECTED'] if protected_contract else ['REMEMBER','RECALL','ASK','PROGRESS'])
            assert len(child_ids)==len(sessions)==1 and len(turns)==(1 if protected_contract else 4),(child_ids,sessions,turns)
            if not protected_contract:
                assert any('OPTION_B' in json.dumps(r['body']) for r in requests if r['path']=='/child/responses')
            visible=rpc('thread/list',{})['data']
            assert child_ids.isdisjoint({x['id'] for x in visible}),(child_ids,[(x['id'],x.get('model'),x.get('source')) for x in visible])
        machine_records=0;human_records=0
        for file in (home/'sessions').rglob('*.jsonl'):
            for line in file.open(encoding='utf-8'):
                row=json.loads(line);p=row.get('payload',{})
                if row.get('type')!='response_item' or p.get('type')!='message':continue
                text=text_of(p);kinds=p.get('internal_chat_message_metadata_passthrough',{}).get('content_item_kinds',[])
                if text.startswith('<aicli_background_event>'):
                    assert not any(k.startswith('user.') for k in kinds),kinds
                    machine_records+=1
                if text.startswith('PHASE_') and 'user.text' in kinds:human_records+=1
        if not expect_rejection and not protected_contract:assert machine_records>=3 and human_records==4,(machine_records,human_records)
        if protected_contract:assert human_records==1 and machine_records==0,(machine_records,human_records)
        result.update({'pass':True,'positive_old_rejection_control':expect_rejection,'phases':phases,'requests':len(requests),
          'strict_rejections':strict_rejections,'same_child_thread':len(child_ids)==1,'same_child_session':len(sessions)==1,
          'distinct_child_completed_turns':len(turns),'machine_context_records':machine_records,'genuine_fixture_user_records':human_records})
    except Exception as exc:
        import traceback
        result.update({'pass':False,'error':repr(exc),'traceback':traceback.format_exc(),'fixture_errors':errors,'strict_rejections':strict_rejections,'stderr_tail':stderr[-8:]})
    finally:
        if proc is not None:
            if proc.poll() is None:
                # The exact fixture process tree may own native background helpers.
                # Close the owned tree before its parent exits; never stop by name.
                subprocess.run(['taskkill','/PID',str(proc.pid),'/T','/F'],capture_output=True,timeout=10,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
                proc.wait(timeout=5)
            result['owned_process_stopped']=proc.poll() is not None
        server.shutdown();server.server_close();result['seconds']=round(time.monotonic()-started,3)
        def remove_readonly(function,path,exc):
            if not isinstance(exc,PermissionError):raise exc
            target=Path(path)
            if not target.resolve().is_relative_to(work.resolve()):raise exc
            target.chmod(target.stat().st_mode | stat.S_IWRITE)
            function(path)
        if result.get('pass'):
            try:shutil.rmtree(work,onexc=remove_readonly)
            except OSError as exc:
                result.update({'pass':False,'checks_passed_but_cleanup_failed':str(exc),'failure_workspace':str(work)})
        else:
            (work/'request-debug.json').write_text(json.dumps(requests,indent=2),encoding='utf-8');result['failure_workspace']=str(work)
    return result


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--bridge',type=Path,required=True);parser.add_argument('--engine',type=Path,required=True)
    parser.add_argument('--parent',choices=['deepseek-flash','glm-5.3-flash'],default='deepseek-flash');parser.add_argument('--expect-rejection',action='store_true');parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--protected-contract',action='store_true')
    parser.add_argument('--protected-model',choices=['gpt-6-sol','gpt-6-astra'],default='gpt-6-astra')
    args=parser.parse_args();result=run_case(args.bridge.resolve(),args.engine.resolve(),args.parent,args.expect_rejection,args.protected_contract,args.protected_model)
    args.output.write_text(json.dumps(result,indent=2),encoding='utf-8');print(json.dumps(result));return 0 if result.get('pass') else 1

if __name__=='__main__':raise SystemExit(main())
