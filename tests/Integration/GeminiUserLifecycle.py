"""Explicit Windows user lifecycle test. Uses local bearer only; invokes no model.
Run with --allow-stop-idle-bridge in the ordinary logged-in user session.
The local bridge refuses shutdown when a real model request is active.
"""
from __future__ import annotations
import argparse, ctypes, hashlib, json, os, re, subprocess, time, urllib.request
from pathlib import Path


def main() -> int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--pwsh',type=Path,required=True)
    parser.add_argument('--allow-stop-idle-bridge',action='store_true',required=True)
    args=parser.parse_args()
    if os.name!='nt' or ctypes.windll.shell32.IsUserAnAdmin():
        raise RuntimeError('ordinary_windows_user_required')
    root=args.root.resolve()
    if root.exists() and any(root.iterdir()):raise RuntimeError('empty_test_root_required')
    root.mkdir(parents=True,exist_ok=True)
    discover=subprocess.run([str(args.pwsh),'-NoLogo','-NoProfile','-NonInteractive','-Command',
        "(Get-Module -ListAvailable AiCliProfileManager | Sort-Object Version -Descending | Select-Object -First 1).ModuleBase"],
        stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=15,creationflags=subprocess.CREATE_NO_WINDOW)
    module_root=discover.stdout.decode('utf-8-sig').strip()
    if discover.returncode or not module_root:raise RuntimeError('installed_module_not_found')
    helper=Path(module_root)/'Support'/'GetDesktopGeminiToken.ps1'
    if not helper.is_file() or not args.pwsh.is_file():raise RuntimeError('dependency_missing')
    base=Path(os.environ['LOCALAPPDATA'])/'AiCliProfileManager'/'gemini'
    deployment=json.loads((base/'deployment.json').read_text(encoding='utf-8-sig'))
    fingerprint=hashlib.sha256((base/'deployment.json').read_bytes()).hexdigest()
    env=os.environ.copy()
    for key in ('TEMP','TMP','TMPDIR'):env[key]=str(root)
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    result={'schema':'aicli.gemini-user-lifecycle.v1','pass':False,'release':deployment['releaseId'],'phases':[],'model_requests':0,'installed_module':module_root}
    def session(pid):
        value=ctypes.c_uint()
        if not ctypes.windll.kernel32.ProcessIdToSessionId(pid,ctypes.byref(value)):raise RuntimeError('session_query_failed')
        return value.value
    expected_session=session(os.getpid())
    def control(token,operation='health'):
        request=urllib.request.Request('http://127.0.0.1:'+str(deployment['port'])+'/'+operation,
            headers={'Authorization':'Bearer '+token},method='GET' if operation=='health' else 'POST')
        with opener.open(request,timeout=5) as response:return json.load(response)
    def invoke(label):
        clock=time.monotonic()
        process=subprocess.Popen([str(args.pwsh),'-NoLogo','-NoProfile','-NonInteractive','-File',str(helper)],
            stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,creationflags=subprocess.CREATE_NO_WINDOW)
        try:stdout,stderr=process.communicate(timeout=20)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)
            # Do not close/join a pipe whose reader is still held by descendants.
            # Report the regression instead of hanging inside the test harness.
            raise RuntimeError('auth_helper_did_not_return_eof')
        token=stdout.decode('utf-8-sig').strip()
        if process.returncode or not re.fullmatch('[a-f0-9]{64}',token):raise RuntimeError('auth_helper_failed')
        health=control(token)
        if health.get('component')!='aicli.gemini-responses' or session(health['pid'])!=expected_session:
            raise RuntimeError('bridge_session_or_identity_mismatch')
        result['phases'].append({'label':label,'seconds':round(time.monotonic()-clock,2),'pid':health['pid'],'ordinary_session':True,'eof_received':True})
        return token,health['pid']
    try:
        token,_=invoke('initial')
        if not control(token,'shutdown').get('stopping'):raise RuntimeError('idle_shutdown_refused')
        time.sleep(2)
        for i in range(2):
            token,pid=invoke('cold_'+str(i))
            time.sleep(2)
            token,pid_again=invoke('reuse_'+str(i))
            if pid!=pid_again:raise RuntimeError('duplicate_bridge_start')
            if i==0:
                if not control(token,'shutdown').get('stopping'):raise RuntimeError('idle_shutdown_refused')
                time.sleep(2)
        result['pass']=fingerprint==hashlib.sha256((base/'deployment.json').read_bytes()).hexdigest()
        if not result['pass']:raise RuntimeError('deployment_changed_during_test')
    except Exception as error:
        result['error']=str(error) if re.fullmatch('[a-z_]{1,100}',str(error)) else type(error).__name__
    finally:
        token=None
        (root/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(result,ensure_ascii=False))
    return 0 if result['pass'] else 1

if __name__=='__main__':raise SystemExit(main())