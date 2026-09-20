"""Actual compiled bridge + installed Python policy, with synthetic official RPC.

All user messages, thread records, permissions and upstream responses are fixtures.
No model endpoint, account or existing user's Codex home is accessed.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone


def module_at(name, path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--bridge',type=Path,required=True)
    parser.add_argument('--runtime',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    runtime=args.runtime.resolve()
    base=Path(__file__).parent
    lifecycle=module_at('synthetic_child_client',base/'Invoke-BackgroundChildTests.py')
    upstream=base/'transport-fixtures'/'background_fake.py'
    if not upstream.exists():upstream=base/'background_fake.py'
    root=Path(tempfile.mkdtemp(prefix='scoped-child-permission-'))
    home=root/'home';home.mkdir()
    local=root/'local';local.mkdir()
    original={name:os.environ.get(name) for name in ('CODEX_HOME','LOCALAPPDATA','TEMP','TMP','TMPDIR')}
    os.environ.update(CODEX_HOME=str(home),LOCALAPPDATA=str(local),TEMP=str(root),TMP=str(root),TMPDIR=str(root))
    tests=[];client=None
    def check(label, condition, detail=None):
        if not condition:raise AssertionError((label,detail))
        tests.append(label);print('PASS '+label,flush=True)
    try:
        raw=runtime.read_bytes();sha=hashlib.sha256(raw).hexdigest()
        installed=home/'managed-hooks'/'native-economy'/'runtimes'/sha/'codex_native_economy_runtime.py'
        installed.parent.mkdir(parents=True);installed.write_bytes(raw)
        manifest=installed.parents[2]/'active-runtime.json'
        manifest.write_text(json.dumps({'schema':'agents.codex-native-economy-runtime-manifest.v1',
            'active_runtime_path':str(installed),'active_runtime_sha256':sha,
            'bridge_sha256':'a'*64,'compatible_expected_script_sha256':[],'installed_at_utc':datetime.now(timezone.utc).isoformat()}))
        (home/'models_cache.json').write_text(json.dumps({'models':[
            {'slug':model,'supported_reasoning_levels':[{'effort':level} for level in ['low','high','max']]}
            for model in ['gpt-5.6-luna','gpt-5.6-sol']]}))
        sessions=home/'sessions';sessions.mkdir()
        policy=module_at('scoped_fixture_policy',runtime)
        bindings=local/'Codex'/'native-economy-gate'/'thread-bindings'
        client=lifecycle.Client(args.bridge.resolve(),root,upstream)
        client.request('initialize',{'clientInfo':{'name':'scoped-permission-fixture','version':'1'}})
        parent=client.request('thread/start',{'model':'glm-5.3-flash','cwd':str(root),'config':{}})['thread']['id']
        quote='Synthetic fixture: allow the requested OpenAI subtask only.'
        transcript=sessions/f'rollout-{parent}.jsonl'
        records=[{'type':'session_meta','payload':{'id':parent,'session_id':parent,'parent_thread_id':None}},
            {'type':'response_item','payload':{'type':'message','role':'user','id':'msg_fixturepermission0001',
                'content':[{'type':'input_text','text':quote}],
                'internal_chat_message_metadata_passthrough':{'content_item_kinds':['user.text']}}},
            {'type':'turn_context','payload':{'turn_id':'fixture-root-turn','model':'glm-5.3-flash','effort':'max'}}]
        transcript.write_text(''.join(json.dumps(record)+'\n' for record in records),encoding='utf-8')
        grant_sequence=0
        def grant(*,scope='task',mode='exact',expiry=None):
            nonlocal grant_sequence
            grant_sequence+=1
            source_id=f'msg_fixturegrant{grant_sequence:08d}'
            source_quote=f'Synthetic new user permission {grant_sequence}: {scope}, Luna {mode} High, expiry={expiry}.'
            with transcript.open('a',encoding='utf-8') as out:
                out.write(json.dumps({'type':'response_item','payload':{'type':'message','role':'user','id':source_id,
                    'content':[{'type':'input_text','text':source_quote}],
                    'internal_chat_message_metadata_passthrough':{'content_item_kinds':['user.text']}}})+'\n')
            current=policy.load_routing_consent(bindings,parent)
            return policy._write_routing_consent({'mode':'SetRouting','models':{'gpt-5.6-luna':'high'},
                'user_quote':source_quote,'source_message_id':source_id,'routing_scope':scope,'task_name':'luna_high_collaboration' if scope=='task' else '',
                'effort_mode':mode,'expires_at_utc':expiry,'expected_sha256':current['binding_sha256'] if current else ''},
                binding_root=bindings,thread_id=parent,transcript=transcript)
        def tool(message,child=None,**kwargs):
            value={'agent_type':'openai_child','model':'gpt-5.6-luna','reasoning_effort':'high',
                'task_name':'luna_high_collaboration','message':message,'wait_ms':100}
            if child:value['thread_id']=child
            value.update(kwargs)
            return client.dispatch(parent,'openai_child',value)
        def control(child,action='status'):
            return client.dispatch(parent,'openai_child_control',{'action':action,'thread_id':child})
        count=client.request('test/state')['counts']['thread/start']
        ok,result=tool('RECALL')
        check('no permission blocks before native child creation',not ok and 'AUTHORIZATION_DENIED' in result['error']
              and client.request('test/state')['counts']['thread/start']==count,result)
        grant()
        for change in ({'reasoning_effort':'low'},{'reasoning_effort':'max'},
                       {'model':'gpt-5.6-sol'},{'task_name':'another_task'}):
            ok,result=tool('RECALL',**change)
            check('exact permission rejects '+str(change),not ok and 'AUTHORIZATION_DENIED' in result['error'],result)
        ok,first=tool('REMEMBER:scope-keeps-history')
        check('authorized child actually consumes its first task',ok and first['final_text']=='REMEMBERED',first)
        child=first['thread_id'];session=first['session_id']
        check('fixture exercises different real thread and session identifiers',child!=session)
        ok,again=tool('RECALL',child)
        check('same scoped child continues with intact history',ok and again['final_text']=='scope-keeps-history'
              and again['thread_id']==child and again['session_id']==session,again)
        count=client.request('test/state')['counts']['thread/start']
        ok,second=tool('RECALL')
        check('once-task permission cannot create a second child',not ok and 'AUTHORIZATION_DENIED' in second['error']
              and client.request('test/state')['counts']['thread/start']==count,second)
        ok,question=tool('ASK:Which branch?',child)
        check('authorized child can ask parent',ok and question['state']=='waiting_for_parent',question)
        ok,answer=tool('allowed branch',child,reply_to=question['pending_reply_ids'][0])
        check('parent answer resumes the exact child',ok and answer['thread_id']==child and answer['session_id']==session,answer)
        ok,active=tool('WAIT',child)
        check('authorized task can run while parent continues',ok and active['state']=='running',active)
        current=policy.load_routing_consent(bindings,parent)
        policy._write_routing_consent({'mode':'RemoveRouting','expected_sha256':current['binding_sha256']},
            binding_root=bindings,thread_id=parent,transcript=transcript)
        deadline=time.monotonic()+12
        while True:
            ok,stopped=control(child)
            if stopped.get('state') in ('interrupted','stop_unconfirmed') or time.monotonic()>deadline:break
            time.sleep(.1)
        check('revocation interrupts an in-flight native turn without a new parent prompt',ok and stopped['state']=='interrupted',stopped)
        ok,blocked=tool('RECALL',child)
        check('revocation denies new execution on the old child',not ok and 'AUTHORIZATION_DENIED' in blocked['error'],blocked)
        ok,status=control(child)
        check('existing status remains accessible after delegation revoke',ok and status['session_id']==session,status)
        ok,status=control(child,'stop')
        check('stopping own child does not require a new delegation grant',ok,status)
        grant(scope='conversation')
        ok,new=tool('RECALL')
        check('an explicit conversation grant permits a different subtask child',ok and new['thread_id']!=child,new)
        # Expiry is observed by the bridge's bounded timer, not a user-operated test.
        grant(scope='conversation',expiry=(datetime.now(timezone.utc)+timedelta(seconds=7)).isoformat())
        ok,active=tool('WAIT',new['thread_id'])
        check('not-yet-expired grant is usable',ok and active['state']=='running',active)
        deadline=time.monotonic()+12
        while True:
            ok,expired=control(new['thread_id'])
            if expired.get('state') in ('interrupted','stop_unconfirmed') or time.monotonic()>deadline:break
            time.sleep(.15)
        check('expiry interrupts the exact running child',ok and expired['state']=='interrupted',expired)
        grant(scope='conversation')
        manifest.rename(manifest.with_suffix('.unavailable'))
        ok,missing=tool('RECALL')
        check('removing an observed policy cannot fall back to an unmanaged route',not ok and 'AUTHORIZATION_UNAVAILABLE' in missing['error'],missing)
        result={'pass':True,'tests_passed':len(tests),'tests':tests,'compiled_bridge':True,
            'real_policy_runtime':True,'live_models':False,'desktop_e2e':False}
    except Exception as exc:
        result={'pass':False,'tests_passed':len(tests),'tests':tests,'error':repr(exc),
            'workspace':str(root),'live_models':False,'desktop_e2e':False}
    finally:
        if client:client.close()
        for key,value in original.items():
            if value is None:os.environ.pop(key,None)
            else:os.environ[key]=value
    args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(result,ensure_ascii=False),flush=True)
    if result['pass']:shutil.rmtree(root)
    return 0 if result['pass'] else 1


if __name__=='__main__':raise SystemExit(main())
