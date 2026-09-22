"""Isolated native Codex regression. Fake model by default; --live is explicit.
Only a client-owned nonce tool can pass the test server's dispatch filter.
Existing user Codex configuration/history and personal data are not loaded.
"""
from __future__ import annotations
import argparse, hashlib, json, os, queue, re, secrets, subprocess, threading, time
from pathlib import Path
from typing import Any

PROVIDER="aicli_gemini_v2_test"
TOKEN="t"*48 # Synthetic loopback fixture token, not a user credential.
class TestFailure(RuntimeError):pass

def main()->int:
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ("root","codex","test-dll","settings","catalog","pwsh","dotnet"):
        parser.add_argument("--"+name,required=True,type=Path)
    parser.add_argument("--live",action="store_true")
    parser.add_argument("--skip-compaction",action="store_true")
    parser.add_argument("--auto-compact",action="store_true",help="Fixture-only: lower the native threshold after the first successful turn.")
    args=parser.parse_args();root=args.root.resolve()
    if args.live:
        # Use the same checked-in lifecycle as normal installation, before
        # creating test files, invoking Codex or starting a consumer model.
        state_path=Path(__file__).resolve().parents[2]/"src"/"AiCliProfileManager"/"Support"/"GeminiIntegrationState.json"
        state=json.loads(state_path.read_text(encoding="utf-8-sig"))
        if state.get("schema")!="aicli.gemini-integration-state.v1" or state.get("state")!="experimental":
            raise TestFailure("gemini_integration_frozen")
    if args.auto_compact and args.live:raise TestFailure("automatic_compaction_fixture_only")
    if root.exists() and any(root.iterdir()):raise TestFailure("test_root_must_be_empty")
    root.mkdir(parents=True,exist_ok=True)
    for path in (args.codex,args.test_dll,args.settings,args.catalog,args.pwsh,args.dotnet):
        if not path.is_file():raise TestFailure("required_dependency_missing:"+path.name)
    config=json.loads(args.settings.read_text(encoding="utf-8-sig"))
    model_set=json.loads(Path(config["ModelCatalogPath"]).read_text(encoding="utf-8-sig"))
    model=model_set["defaultModel"];definition=next(m for m in model_set["models"] if m["menuModel"]==model)
    config.update(RuntimeDirectory=str(root/"backend"),Port=0,IdleSeconds=900,MaxSessions=1,TurnTimeoutSeconds=150)
    settings=root/"server-settings.json";settings.write_text(json.dumps(config),encoding="utf-8")
    home=root/"codex-home";home.mkdir()
    env={k:v for k,v in os.environ.items() if not re.match(r"^(OPENAI|ANTHROPIC|CODEX|AICLI|GEMINI|GOOGLE|VERTEX|GCLOUD|CLOUDSDK|DEEPSEEK|DASHSCOPE|ZHIPU|GLM|QWEN|AGENTS)(_|$)",k)}
    for key in ("TEMP","TMP","TMPDIR"):env[key]=str(root)
    env["NO_PROXY"]="127.0.0.1,localhost,::1"
    events=[];phases=[];diagnostics=[];children=[];tool_calls=set()
    codex=None;server=None;thread_id=None;turn_id=None;rid=0;q=queue.Queue()
    nonce="native-fixture-"+secrets.token_hex(16)
    deadline_seconds=330 if args.live else 30
    flags=subprocess.CREATE_NO_WINDOW if os.name=="nt" else 0
    def log(value):print(json.dumps(value,ensure_ascii=False),flush=True)
    def drain_error(process):
        for line in process.stderr:
            labels=re.findall(r"google_[a-z_]+|antigravity_[a-z_]+|fixture_[a-z_]+|unsupported_[a-z_]+|structured_[a-z_]+|model_[a-z_]+|public_summary_[a-z_]+|schema_[a-z_]+|unknown_tool|compaction_[a-z_]+",line)
            if len(diagnostics)<150:diagnostics.extend(labels)
    def launch(command,environment,cwd):
        p=subprocess.Popen(command,cwd=cwd,env=environment,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding="utf-8",errors="replace",creationflags=flags)
        children.append(p);threading.Thread(target=drain_error,args=(p,),daemon=True).start();return p
    def send(value):
        codex.stdin.write(json.dumps(value,ensure_ascii=False)+"\n");codex.stdin.flush()
    def receive(timeout=30):
        try:event=q.get(timeout=timeout)
        except queue.Empty as e:raise TimeoutError("native_event_timeout") from e
        if event is None:raise TestFailure("native_process_closed")
        events.append(event)
        if event.get("method")=="item/tool/call":
            p=event.get("params",{});cid=p.get("callId")
            if p.get("threadId")!=thread_id or (turn_id is not None and p.get("turnId")!=turn_id) or p.get("tool")!="read_nonce" or p.get("arguments")!={} or not cid or cid in tool_calls:
                raise TestFailure("unexpected_native_tool_request")
            tool_calls.add(cid);send({"id":event["id"],"result":{"success":True,"contentItems":[{"type":"inputText","text":nonce}]}})
        elif "id" in event and "method" in event:
            send({"id":event["id"],"error":{"code":-32601,"message":"Only the isolated nonce is available."}})
            raise TestFailure("unexpected_native_server_request")
        return event
    def call(method,params,timeout=30):
        nonlocal rid
        rid+=1;current=rid;send({"id":current,"method":method,"params":params});until=time.monotonic()+timeout
        while time.monotonic()<until:
            e=receive(max(.01,until-time.monotonic()))
            if e.get("id")==current and "method" not in e:
                if "error" in e:raise TestFailure("rpc_rejected:"+method+":"+str(e["error"].get("code")))
                return e["result"]
        raise TimeoutError("native_rpc_timeout:"+method)
    def start_codex():
        nonlocal codex,q
        q=queue.Queue();ce=env.copy();ce.update(CODEX_HOME=str(home),CODEX_SQLITE_HOME=str(home),AICLI_TEST_BRIDGE_TOKEN=TOKEN)
        codex=launch([str(args.codex),"app-server"],ce,root)
        def reader(p,destination):
            for line in p.stdout:
                try:destination.put(json.loads(line))
                except ValueError:continue
            destination.put(None)
        threading.Thread(target=reader,args=(codex,q),daemon=True).start()
        call("initialize",{"clientInfo":{"name":"aicli-gemini-v2-regression","title":"Isolated Gemini V2 regression","version":"2.0"},"capabilities":{"experimentalApi":True}})
        send({"method":"initialized","params":{}})
    def terminal(first,target):
        until=time.monotonic()+deadline_seconds
        def find():return next((e["params"]["turn"] for e in events[first:] if e.get("method")=="turn/completed" and (target is None or e.get("params",{}).get("turn",{}).get("id")==target)),None)
        result=find()
        while result is None and time.monotonic()<until:
            receive(max(.01,until-time.monotonic()));result=find()
        if result is None:raise TimeoutError("native_turn_terminal")
        if result.get("status")!="completed":
            markers=re.findall(r"google_[a-z_]+|antigravity_[a-z_]+|fixture_[a-z_]+|unsupported_[a-z_]+|structured_[a-z_]+|model_[a-z_]+|public_summary_[a-z_]+|schema_[a-z_]+|unknown_tool",json.dumps(result.get("error",{})))
            raise TestFailure("native_turn_failed:"+",".join(markers))
        return result
    def turn(text,phase):
        nonlocal turn_id
        before=len(events);clock=time.monotonic();turn_id=None
        log({"phase":phase,"status":"started","backend":"live" if args.live else "deterministic"})
        started=call("turn/start",{"threadId":thread_id,"input":[{"type":"text","text":text}],"effort":definition["defaultEffort"],"summary":"detailed"})
        turn_id=started["turn"]["id"];terminal(before,turn_id);subset=events[before:]
        text="".join(e.get("params",{}).get("delta","") for e in subset if e.get("method")=="item/agentMessage/delta")
        if not text:text="".join(e.get("params",{}).get("item",{}).get("text","") for e in subset if e.get("method")=="item/completed" and e.get("params",{}).get("item",{}).get("type")=="agentMessage")
        row={"phase":phase,"status":"completed","seconds":round(time.monotonic()-clock,2),"summary_events":sum(e.get("method")=="item/reasoning/summaryTextDelta" for e in subset),"item_types":sorted({e.get("params",{}).get("item",{}).get("type","") for e in subset if e.get("method")=="item/completed"})}
        phases.append(row);log(row);turn_id=None;return text
    failure=None;pass_test=False
    try:
        server_root=root/"test-server";server_root.mkdir()
        mode="--serve-native-live" if args.live else "--serve-native-fixture"
        server=launch([str(args.dotnet),str(args.test_dll),str(server_root),str(args.pwsh),mode,str(settings)],env,root)
        ready_queue=queue.Queue()
        def server_stdout():
            for line in server.stdout:
                try:ready_queue.put(json.loads(line))
                except ValueError:continue
            ready_queue.put(None)
        threading.Thread(target=server_stdout,daemon=True).start();ready=ready_queue.get(timeout=15)
        if not ready or ready.get("component")!="aicli-gemini-native-test":raise TestFailure("test_server_identity_invalid")
        url=ready["addresses"][0]
        config_lines=["model_provider = "+json.dumps(PROVIDER),"model = "+json.dumps(model),"model_reasoning_effort = "+json.dumps(definition["defaultEffort"]),
            'model_reasoning_summary = "detailed"',"model_catalog_json = "+json.dumps(str(args.catalog.resolve())),"model_context_window = "+str(definition["contextWindow"]),
            "model_auto_compact_token_limit = "+str(definition["contextWindow"]*90//100),'web_search = "disabled"','approval_policy = "never"','sandbox_mode = "danger-full-access"',
            "[model_providers."+PROVIDER+"]",'name = "Isolated Gemini V2 native fixture"',"base_url = "+json.dumps(url+"/v1"),'wire_api = "responses"','env_key = "AICLI_TEST_BRIDGE_TOKEN"',
            'requires_openai_auth = false','request_max_retries = 0','stream_max_retries = 0','stream_read_timeout_ms = 240000','supports_websockets = false']
        (home/"config.toml").write_text("\n".join(config_lines)+"\n",encoding="utf-8")
        start_codex()
        spec={"type":"function","name":"read_nonce","description":"Return the isolated test nonce only. No file, shell, external search or personal data.","inputSchema":{"type":"object","properties":{},"additionalProperties":False},"deferLoading":False}
        result=call("thread/start",{"cwd":str(root),"approvalPolicy":"never","permissions":":danger-full-access","runtimeWorkspaceRoots":[str(root)],"ephemeral":False,"model":model,"modelProvider":PROVIDER,"dynamicTools":[spec]})
        thread_id=result["thread"]["id"]
        if result.get("modelProvider")!=PROVIDER or result.get("model")!=model:raise TestFailure("native_provider_model_identity_mismatch")
        answer=turn("这是隔离测试。先用一句中文说明要验证工具输出，再调用 read_nonce，然后原样报告工具返回的随机字符串。不要调用其他工具。","native_tool_roundtrip")
        if nonce not in answer or len(tool_calls)!=1 or phases[-1]["summary_events"]==0:raise TestFailure("native_tool_result_or_summary_missing")
        if not args.skip_compaction and not args.auto_compact:
            begin=len(events);clock=time.monotonic();call("thread/compact/start",{"threadId":thread_id});terminal(begin,None)
            compact_events=[e for e in events[begin:] if e.get("method")=="item/completed" and e.get("params",{}).get("item",{}).get("type")=="contextCompaction"]
            if not compact_events:raise TestFailure("native_compaction_item_missing")
            row={"phase":"native_compaction","status":"completed","seconds":round(time.monotonic()-clock,2),"native_compaction_items":len(compact_events)};phases.append(row);log(row)
        if args.auto_compact:
            # Change only this synthetic thread's native threshold, never the
            # user's configuration or the production provider's 90% default.
            # A loaded native thread may retain its original configuration.
            # Change the isolated file and restart before exact resume, then
            # check the effective config instead of assuming an override stuck.
            codex.stdin.close();codex.wait(timeout=15)
            old_config=(home/"config.toml").read_text(encoding="utf-8")
            new_config=re.sub(r"(?m)^model_auto_compact_token_limit = \d+$","model_auto_compact_token_limit = 80",old_config)
            if new_config==old_config:raise TestFailure("fixture_limit_setting_not_found")
            (home/"config.toml").write_text(new_config,encoding="utf-8")
            start_codex()
            observed=call("config/read",{"includeLayers":False})
            if observed.get("config",{}).get("model_auto_compact_token_limit")!=80:raise TestFailure("fixture_limit_not_effective")
            refreshed=call("thread/resume",{"threadId":thread_id,"cwd":str(root),"approvalPolicy":"never","permissions":":danger-full-access","model":model,"modelProvider":PROVIDER})
            if refreshed["thread"]["id"]!=thread_id:raise TestFailure("automatic_compaction_thread_changed")
        before_followup=len(events)
        answer=turn("继续同一会话。不要调用任何工具，原样重复刚才 read_nonce 实际返回的随机字符串。","automatic_compaction_followup" if args.auto_compact else "after_compaction" if not args.skip_compaction else "same_thread_followup")
        if args.auto_compact:
            auto_events=[e for e in events[before_followup:] if e.get("method")=="item/completed" and e.get("params",{}).get("item",{}).get("type")=="contextCompaction"]
            if not auto_events:raise TestFailure("native_auto_compaction_not_observed")
            log({"phase":"automatic_compaction","native_items":len(auto_events),"test_threshold":80})
        if nonce not in answer or len(tool_calls)!=1:raise TestFailure("effective_context_not_preserved")
        history=call("thread/read",{"threadId":thread_id,"includeTurns":True})
        if history["thread"]["id"]!=thread_id or nonce not in json.dumps(history,ensure_ascii=False):raise TestFailure("native_history_not_preserved")
        old=codex;old.stdin.close();old.wait(timeout=15)
        start_codex()
        resumed=call("thread/resume",{"threadId":thread_id,"cwd":str(root),"approvalPolicy":"never","permissions":":danger-full-access","model":model,"modelProvider":PROVIDER})
        if resumed["thread"]["id"]!=thread_id or resumed.get("modelProvider")!=PROVIDER:raise TestFailure("exact_resume_identity_mismatch")
        answer=turn("不要调用工具。请原样重复此前同一会话里的随机字符串。","fresh_process_exact_resume")
        if nonce not in answer or len(tool_calls)!=1:raise TestFailure("resume_memory_not_preserved")
        pass_test=True
    except Exception as e:
        failure={"type":type(e).__name__,"message":str(e)[:500]}
    finally:
        cleanup_errors=[]
        for p in reversed(children):
            if p.poll() is None:
                try:
                    if p.stdin:p.stdin.close()
                    p.wait(timeout=15)
                except (subprocess.TimeoutExpired,OSError):
                    try:
                        # Only exact children created above, never user's apps.
                        if os.name=="nt":subprocess.run(["taskkill","/PID",str(p.pid),"/T","/F"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,creationflags=flags,timeout=10)
                        else:p.kill()
                        p.wait(timeout=10)
                    except (OSError,subprocess.TimeoutExpired):cleanup_errors.append(p.pid)
        report={"pass":pass_test and not cleanup_errors,"test_level":"native-codex/live-fresh-gemini" if args.live else "native-codex/deterministic-model-fixture",
            "model":model,"native_thread_id":thread_id,"exact_tool_calls":len(tool_calls),"phases":phases,"failure":failure,"cleanup_errors":cleanup_errors,
            "native_executable_sha256":hashlib.sha256(args.codex.read_bytes()).hexdigest(),"manual_desktop_e2e":"not_performed"}
        (root/"result.json").write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding="utf-8")
        metadata=[{"method":e.get("method"),"rpc_id":e.get("id"),"item_type":e.get("params",{}).get("item",{}).get("type"),"turn_status":e.get("params",{}).get("turn",{}).get("status")} for e in events]
        (root/"event-metadata.json").write_text(json.dumps(metadata),encoding="utf-8")
        (root/"diagnostic-markers.json").write_text(json.dumps(sorted(set(diagnostics))),encoding="utf-8")
        log(report)
    return 0 if pass_test and not cleanup_errors else 1

if __name__=="__main__":raise SystemExit(main())
