"""Portable stdio lifecycle regression tests; fixtures never contact real models."""
from __future__ import annotations
import argparse
import concurrent.futures
import json
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path


class Client:
    def __init__(self, bridge: Path, root: Path, fixture: Path):
        home = root / 'home'
        home.mkdir(exist_ok=True)
        models = []
        for model, provider in [('glm-5.3-flash', 'aicli_glm_5_3_flash'), ('deepseek-flash', 'aicli_deepseek_flash')]:
            models.append({'profileId': 'codex-' + model.replace('.', '-'), 'model': model,
                'providerId': provider, 'routeProviderId': provider, 'kind': 'cloud',
                'provider': {'name': model, 'base_url': 'https://fixture.invalid/v1', 'wire_api': 'responses', 'requires_openai_auth': False},
                'catalogModel': {'slug': model, 'display_name': model, 'description': 'Offline protocol fixture',
                    'base_instructions': 'Isolated protocol fixture only.', 'context_window': 1048576,
                    'effective_context_window_percent': 95, 'default_reasoning_level': 'max',
                    'supported_reasoning_levels': [{'effort': 'max', 'description': 'max'}]},
                'catalogPath': str(home / 'catalog.json'), 'contextWindow': 1048576, 'defaultEffort': 'max'})
        plan = {'schemaVersion': 1, 'codexHome': str(home), 'upstreamFileName': sys.executable,
            'upstreamPrefixArgs': ['-u', str(fixture)], 'models': models}
        plan_path = root / 'plan.json'
        plan_path.write_text(json.dumps(plan), encoding='utf-8')
        env = os.environ.copy()
        env.update({'AICLI_DESKTOP_PLAN_FILE': str(plan_path), 'AICLI_CHILD_FIXTURE_STATE': str(root / 'official-fixture-history.json'),
            'CODEX_HOME': str(home), 'CODEX_SQLITE_HOME': str(home), 'TEMP': str(root), 'TMP': str(root), 'TMPDIR': str(root)})
        self.pending = {}
        self.notifications = []
        self.lock = threading.Lock()
        self.stderr = open(root / ('stderr-' + uuid.uuid4().hex + '.txt'), 'w', encoding='utf-8')
        self.p = subprocess.Popen([str(bridge), 'app-server', '--stdio'], cwd=root, env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr, text=True, encoding='utf-8',
            creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        for line in self.p.stdout:
            try:
                item = json.loads(line)
            except ValueError:
                continue
            with self.lock:
                target = self.pending.get(item.get('id'))
                if target is None:
                    self.notifications.append(item)
                else:
                    target.put(item)

    def request(self, method, params=None, timeout=12):
        rid = uuid.uuid4().hex
        q = queue.Queue()
        with self.lock:
            self.pending[rid] = q
            self.p.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': rid, 'method': method, 'params': params or {}}) + '\n')
            self.p.stdin.flush()
        try:
            result = q.get(timeout=timeout)
            if 'error' in result:
                raise AssertionError((method, result))
            return result['result']
        finally:
            with self.lock:
                self.pending.pop(rid, None)

    def dispatch(self, parent, tool, args, **extra):
        result = self.request('test/dispatch', {'thread_id': parent, 'tool': tool, 'arguments': args, **extra})
        return result.get('success'), json.loads(result['contentItems'][0]['text'])

    def close(self):
        if self.p.poll() is None:
            self.p.stdin.close()
            try:
                self.p.wait(timeout=8)
            except subprocess.TimeoutExpired:
                subprocess.run(['taskkill', '/PID', str(self.p.pid), '/T', '/F'], capture_output=True,
                    creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0), timeout=10)
                self.p.wait(timeout=5)
        self.reader.join(timeout=3)
        self.stderr.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bridge', required=True, type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    fixture = Path(__file__).parent / 'transport-fixtures' / 'background_fake.py'
    if not fixture.exists():
        fixture = Path(__file__).parent / 'background_fake.py'
    root = Path(tempfile.mkdtemp(prefix='background-child-'))
    tests = []
    c = None

    def check(name, predicate):
        if not predicate:
            raise AssertionError(name)
        tests.append(name)
        print('PASS', name, flush=True)

    def tool(parent, text, handle=None, **kwargs):
        spec = {'agent_type': 'openai_child', 'model': 'gpt-5.6-luna', 'reasoning_effort': 'high',
            'task_name': 'luna_high_collaboration', 'message': text, 'wait_ms': 100}
        if handle:
            spec['thread_id'] = handle
        spec.update(kwargs)
        return c.dispatch(parent, 'openai_child', spec)

    def control(parent, handle, action='status', **kw):
        return c.dispatch(parent, 'openai_child_control', {'action': action, 'thread_id': handle, **kw})

    def terminal(parent, handle):
        for _ in range(10):
            ok, s = control(parent, handle, 'wait', timeout_ms=1000)
            if ok and s['state'] not in ('running', 'stopping', 'waiting_for_parent'):
                return s
        raise AssertionError('Child did not reach terminal state')

    try:
        c = Client(args.bridge.resolve(), root, fixture)
        parent_result = c.request('thread/start', {'model': 'glm-5.3-flash', 'cwd': str(root), 'config': {}})
        parent = parent_result['thread']['id']
        check('parent control tools registered', {'openai_child', 'openai_child_control'} <= {x['name'] for x in parent_result['thread']['tools']})
        nonce = uuid.uuid4().hex
        ok, first = tool(parent, 'REMEMBER:' + nonce)
        check('first child completes with explicit provider and effort', ok and first['final_text'] == 'REMEMBERED' and first['model_provider'] == 'openai' and first['reasoning_effort'] == 'high' and first['persistent'])
        child, session, first_turn = first['thread_id'], first['session_id'], first['turn_id']
        ok, second = tool(parent, 'RECALL', child)
        check('same-session follow-up retains context', ok and second['final_text'] == nonce and second['thread_id'] == child and second['session_id'] == session and second['turn_id'] != first_turn)
        start = time.monotonic()
        ok, active = tool(parent, 'WAIT', child)
        check('background start does not block parent work', ok and active['state'] == 'running' and time.monotonic() - start < 3)
        ok, updated = tool(parent, 'UPDATE:new instruction', child)
        check('mid-turn parent update stays on active turn', ok and updated['final_text'] == 'UPDATED:new instruction' and updated['turn_id'] == active['turn_id'])
        ok, question = tool(parent, 'ASK:Which branch?', child)
        check('child can suspend for parent question', ok and question['state'] == 'waiting_for_parent' and len(question['pending_reply_ids']) == 1)
        # The child signals a pending question before the asynchronous parent
        # injection completes. Observe delivery, not the earlier pending state.
        delivery_deadline = time.monotonic() + 5
        while True:
            evt_state = c.request('test/state')
            question_events = [e for e in evt_state['events'] if e['context_event'].get('event') == 'question']
            if question_events or time.monotonic() >= delivery_deadline:
                break
            time.sleep(.02)
        check('question auto-delivered as native machine context, never fake human input', bool(question_events) and question_events[-1]['thread_id'] == parent and question_events[-1]['context_event']['provenance'] == 'background_agent_not_user_authorization' and all('internal_chat_message_metadata_passthrough' not in x for x in question_events[-1]['items']))
        ok, answered = tool(parent, 'feature/collaboration', child, reply_to=question['pending_reply_ids'][0])
        answer = terminal(parent, child)
        check('parent reply resumes the same blocked child', ok and answer['final_text'] == 'ANSWER:feature/collaboration' and answer['turn_id'] == question['turn_id'])
        ok, progress = tool(parent, 'PROGRESS:Tested one component', child)
        progress = terminal(parent, child)
        events = c.request('test/state')['events']
        check('child progress arrives as real tool exchange', ok and any(e['context_event'].get('event') == 'progress' for e in events))
        _, delivered = control(parent, child)
        check('active-turn delivery does not retry EmptyInput or lose messages', delivered['parent_wake'] == 'existing_active_turn' and delivered['parent_delivery'] == 'delivered')
        c.request('test/finish-parent', {'thread_id': parent})
        ok, q = tool(parent, 'ASK:Idle wake?', child)
        _, status = control(parent, child)
        check('idle parent is woken after confirmed native context injection', ok and status['parent_wake'] == 'idle_turn_started')
        tool(parent, 'yes', child, reply_to=q['pending_reply_ids'][0]); terminal(parent, child)
        before_events = len(c.request('test/state')['events'])
        c.request('test/reject-next-injection')
        tool(parent, 'PROGRESS:must not replay injection', child); failed_delivery = terminal(parent, child)
        failure_events = [e['context_event'] for e in c.request('test/state')['events'][before_events:]]
        check('rejected injection fails visibly without replay or standalone output fallback', failed_delivery['state'] == 'failed' and not any(e.get('event') == 'progress' and e.get('message') == 'must not replay injection' for e in failure_events))
        c.request('test/reject-next-wake')
        tool(parent, 'PROGRESS:injected but wake fails', child); failed_wake = terminal(parent, child)
        _, failed_wake_state = control(parent, child)
        failure_events = [e['context_event'] for e in c.request('test/state')['events'][before_events:]]
        progress_events = [e for e in failure_events if e.get('event') == 'progress' and e.get('message') == 'injected but wake fails']
        failure_terminals = [e for e in failure_events if e.get('event') == 'turn_terminal' and e.get('turn_id') == failed_wake['turn_id']]
        check('wake failure is distinguished from injection and not retried', failed_wake['state'] == 'failed' and len(progress_events) == 1 and (failed_wake_state['parent_delivery'] == 'injected_wake_unconfirmed' or any(e.get('parent_delivery') == 'injected_wake_unconfirmed' for e in failure_terminals)))
        c.request('test/malformed-next-wake')
        tool(parent, 'PROGRESS:malformed wake success', child); malformed_wake = terminal(parent, child)
        events = [e['context_event'] for e in c.request('test/state')['events']]
        malformed_notice = [e for e in events if e.get('event') == 'turn_terminal' and e.get('turn_id') == malformed_wake['turn_id']]
        _, malformed_status = control(parent, child)
        check('wake success without actual turn identity is not reported delivered', malformed_wake['state'] == 'failed' and (malformed_status['parent_delivery'] == 'injected_wake_unconfirmed' or any(e.get('parent_delivery') == 'injected_wake_unconfirmed' for e in malformed_notice)))
        other = c.request('thread/start', {'model': 'deepseek-flash', 'cwd': str(root), 'config': {}})['thread']['id']
        ok, rejected = control(other, child)
        check('other parent cannot inspect child', not ok and rejected['error'] == 'OPENAI_CHILD_NOT_OWNED_BY_PARENT')
        ok, rejected = tool(other, 'RECALL', child)
        check('other parent cannot send to child', not ok and rejected['error'] == 'OPENAI_CHILD_NOT_OWNED_BY_PARENT')
        count = c.request('test/state')['counts'].get('thread/start', 0)
        ok, rejected = tool(parent, 'RECALL', child, reasoning_effort='max')
        check('continuation cannot silently change model effort', not ok and rejected['error'] == 'OPENAI_CHILD_CONTINUATION_IDENTITY_MISMATCH')
        ok, rejected = tool(parent, 'RECALL', 'unknown-child-id')
        check('unknown continuation never creates a replacement', not ok and c.request('test/state')['counts']['thread/start'] == count)
        ok, active = tool(parent, 'WAIT', child)
        ok, stopped = control(parent, child, 'stop')
        check('stop uses real interrupt and confirms terminal', ok and stopped['state'] == 'interrupted' and stopped['final_text'] is None)
        ok, after_stop = tool(parent, 'RECALL', child)
        check('stopped child can continue without losing context', ok and after_stop['final_text'] == nonce and after_stop['session_id'] == session)
        previous_turn = after_stop['turn_id']
        ok, active = tool(parent, 'WAIT', child)
        c.request('test/late-terminal', {'thread_id': child, 'turn_id': previous_turn})
        ok, current = control(parent, child)
        check('late old terminal cannot complete a newer turn', ok and current['state'] == 'running' and current['turn_id'] == active['turn_id'])
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            waiter = pool.submit(control, parent, child, 'wait', after_version=current['version'], timeout_ms=2000)
            time.sleep(0.1)
            tool(parent, 'UPDATE:wake waiter', child)
            wok, wstate = waiter.result(timeout=5)
        check('waiting parent wakes on real child change', wok and wstate['state'] == 'completed')
        ok, active = tool(parent, 'WAIT', child)
        ok, raced = tool(parent, 'RACE_FOLLOWUP', child)
        check('new native turn after a concurrent completion is adopted without resend', ok and raced['state'] == 'completed' and raced['turn_id'] != active['turn_id'] and raced['final_text'] == 'NEW_TURN_DONE')
        for callback in ('item/tool/requestUserInput', 'mcpServer/elicitation/request'):
            result = c.request('test/interactive-request', {'thread_id': child, 'method': callback})
            check('hidden callback receives explicit denial: ' + callback, result.get('code') == -32000 and 'not automatically approved' in result['message'])
        native = c.request('thread/start', {'model': 'gpt-5.6-luna', 'modelProvider': 'openai', 'cwd': str(root)})['thread']['id']
        visible = c.request('thread/list')['data']
        check('background children do not become independent UI tasks', child not in {x['id'] for x in visible})
        check('unrelated native OpenAI tasks remain visible', native in {x['id'] for x in visible})
        ok, second_child = tool(other, 'REMEMBER:deepseek context')
        check('DeepSeek root has its correctly owned OpenAI child', ok and second_child['thread_id'] != child)
        links = list((root / 'home/aicli-background-children').glob('*.json'))
        metadata = [json.loads(x.read_text()) for x in links]
        check('recovery ledger contains only identity metadata', len(metadata) == 2 and all(set(x) == {'schema_version', 'parent_id', 'thread_id', 'session_id', 'model', 'effort', 'task_name', 'cwd', 'permission_identity'} for x in metadata) and nonce not in ''.join(x.read_text() for x in links))
        check('hidden child notifications not leaked', not any((x.get('params', {}).get('threadId') == child or x.get('params', {}).get('thread', {}).get('id') == child) for x in c.notifications))
        c.close()
        c = Client(args.bridge.resolve(), root, fixture)
        parent_resume = c.request('thread/resume', {'threadId': parent, 'model': 'glm-5.3-flash', 'config': {}})
        check('actual parent resumes across bridge restart', parent_resume['thread']['id'] == parent)
        # A pre-upgrade native root has no persisted v2 tool schema marker.
        legacy_id = c.request('test/create-legacy-parent', {'cwd': str(root)})['thread_id']
        c.request('thread/resume', {'threadId': legacy_id, 'model': 'glm-5.3-flash', 'config': {}})
        ok, legacy = c.dispatch(legacy_id, 'openai_child', {'agent_type': 'openai_child', 'model': 'gpt-5.6-luna', 'reasoning_effort': 'high', 'task_name': 'luna_high_legacy', 'message': 'Legacy reply'})
        check('pre-upgrade parent retains synchronous one-shot behavior', ok and legacy['persistent'] is False and legacy['final_text'] == 'CHILD_OK')
        ok, listing = c.dispatch(parent, 'openai_child_control', {'action': 'list'})
        check('parent recovers exact handles after restart', ok and [x['thread_id'] for x in listing['children']] == [child])
        before = c.request('test/state')['counts']['thread/start']
        ok, resumed = tool(parent, 'RECALL', child)
        check('exact child and history resume across bridge restart', ok and resumed['thread_id'] == child and resumed['session_id'] == session and resumed['final_text'] == nonce and c.request('test/state')['counts']['thread/start'] == before)
        ok, failed = tool(parent, 'FAIL', child)
        check('failed terminal is not reported completed', ok and failed['state'] == 'failed' and failed['final_text'] is None)
        ok, empty = tool(parent, 'MISSINGFINAL', child)
        check('missing final answer is explicitly exposed', ok and empty['state'] == 'completed_without_answer' and empty['final_text'] is None)
        ok, active = tool(parent, 'WAIT', child)
        c.request('thread/unsubscribe', {'threadId': parent})
        ok, still_running = control(parent, child)
        check('closing a UI subscription does not cancel delegated work', ok and still_running['state'] == 'running')
        rejected_interrupt = False
        try:
            c.request('turn/interrupt', {'threadId': parent, 'turnId': 'invalid-root-turn'})
        except AssertionError:
            rejected_interrupt = True
        ok, still_running = control(parent, child)
        check('rejected parent interruption cannot cancel children', rejected_interrupt and ok and still_running['state'] == 'running')
        c.request('turn/interrupt', {'threadId': parent, 'turnId': 'parent-turn'})
        stopped = terminal(parent, child)
        check('stopping parent interrupts outstanding children', stopped['state'] == 'interrupted')
        c.request('test/tamper-model', {'thread_id': child})
        c.close()
        c = Client(args.bridge.resolve(), root, fixture)
        c.request('thread/resume', {'threadId': parent, 'model': 'glm-5.3-flash', 'config': {}})
        before = c.request('test/state')['counts']['thread/start']
        ok, mismatch = tool(parent, 'RECALL', child)
        check('recovery identity drift fails closed without replacement', not ok and mismatch['error'] == 'OPENAI_CHILD_RESUME_IDENTITY_MISMATCH' and c.request('test/state')['counts']['thread/start'] == before)
        c.request('thread/resume', {'threadId': other, 'model': 'deepseek-flash', 'config': {}})
        c.request('test/permission-drift', {'thread_id': second_child['thread_id']})
        ok, permission_drift = tool(other, 'RECALL', second_child['thread_id'])
        check('effective permission profile drift is detected on exact resume', not ok and permission_drift['error'] == 'OPENAI_CHILD_PERMISSION_IDENTITY_CHANGED')
        cancel_parent = c.request('thread/start', {'model': 'glm-5.3-flash', 'cwd': str(root), 'config': {}})['thread']['id']
        c.request('test/hold-next-child-start')
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            creating = pool.submit(tool, cancel_parent, 'WAIT', wait_ms=0)
            deadline = time.monotonic() + 5
            while c.request('test/state')['held_count'] == 0 and time.monotonic() < deadline:
                time.sleep(0.01)
            check('creation cancellation test reached actual in-flight boundary', c.request('test/state')['held_count'] == 1)
            before_turns = c.request('test/state')['counts']['turn/start']
            c.request('turn/interrupt', {'threadId': cancel_parent, 'turnId': 'parent-turn'})
            c.request('test/release-held')
            ok, cancelled = creating.result(timeout=6)
        check('parent stop during child creation prevents the child first turn', not ok and cancelled['error'] == 'OPENAI_CHILD_PARENT_STOPPED' and c.request('test/state')['counts']['turn/start'] == before_turns)
        ok, cancelled_again = tool(cancel_parent, 'WAIT')
        check('a stopped parent cannot dispatch from a stale tool call', not ok and cancelled_again['error'] == 'OPENAI_CHILD_PARENT_STOPPED')
        c.request('turn/start', {'threadId': cancel_parent, 'input': [{'type': 'text', 'text': 'resume work'}]})
        ok, allowed = tool(cancel_parent, 'RECALL')
        check('a new accepted parent turn can delegate again', ok and allowed['state'] == 'completed')
        for override, expected in (
            ({'top': {'reasoningEffort': 'max'}}, 'OPENAI_CHILD_EFFORT_READBACK_MISMATCH'),
            ({'top': {'reasoningEffort': None}, 'thread': {'reasoningEffort': None}}, 'OPENAI_CHILD_EFFORT_READBACK_MISMATCH'),
            ({'top': {'approvalPolicy': 'on-request'}}, 'OPENAI_CHILD_PERMISSION_READBACK_MISMATCH'),
            ({'top': {'sandbox': {'type': 'readOnly'}}}, 'OPENAI_CHILD_PERMISSION_READBACK_MISMATCH')):
            c.request('test/next-child-override', override)
            before_turns = c.request('test/state')['counts']['turn/start']
            ok, mismatch = tool(cancel_parent, 'WAIT', wait_ms=0)
            check('effective startup identity rejects ' + json.dumps(override), not ok and mismatch['error'] == expected and c.request('test/state')['counts']['turn/start'] == before_turns)
        slot_parent = c.request('thread/start', {'model': 'glm-5.3-flash', 'cwd': str(root), 'config': {}})['thread']['id']
        live_children = []
        for number in range(10):
            ok, running_child = tool(slot_parent, 'WAIT', wait_ms=0)
            check('parent slot admission ' + str(number + 1), ok and running_child['state'] == 'running')
            live_children.append(running_child['thread_id'])
        count_before_rejection = c.request('test/state')['counts']['thread/start']
        ok, overflow = tool(slot_parent, 'WAIT', wait_ms=0)
        check('eleventh active background child is refused before creation', not ok and overflow['error'] == 'OPENAI_CHILD_PARENT_SLOTS_FULL' and c.request('test/state')['counts']['thread/start'] == count_before_rejection)
        ok, update_at_capacity = tool(slot_parent, 'UPDATE:existing child reply', live_children[0])
        check('an admitted active child can still receive messages at capacity', ok and update_at_capacity['final_text'] == 'UPDATED:existing child reply')
        ok, reclaimed = tool(slot_parent, 'WAIT', wait_ms=0)
        check('terminal turn frees the parent execution slot', ok and reclaimed['state'] == 'running')
        c.request('turn/interrupt', {'threadId': slot_parent, 'turnId': 'parent-turn'})
        c.close()
        corrupt = next((root / 'home/aicli-background-children').glob('*.json'))
        corrupt.write_text('{broken json', encoding='utf-8')
        c = Client(args.bridge.resolve(), root, fixture)
        ordinary = c.request('thread/start', {'model': 'deepseek-flash', 'cwd': str(root), 'config': {}})['thread']['id']
        ok, unavailable = c.dispatch(ordinary, 'openai_child_control', {'action': 'list'})
        check('damaged child metadata leaves ordinary Codex usable but exposes recovery failure', not ok and unavailable['error'] == 'OPENAI_CHILD_RECOVERY_UNAVAILABLE')
        result = {'pass': True, 'tests_passed': len(tests), 'tests': tests, 'live_models': False, 'desktop_e2e': False}
    except Exception as exc:
        result = {'pass': False, 'tests_passed': len(tests), 'tests': tests, 'error': repr(exc), 'workspace': str(root), 'live_models': False, 'desktop_e2e': False}
        print(json.dumps(result), file=sys.stderr)
    finally:
        if c:
            c.close()
    if args.output:
        args.output.write_text(json.dumps(result, indent=2), encoding='utf-8')
    if result['pass']:
        shutil.rmtree(root)
    print(json.dumps(result), flush=True)
    return 0 if result['pass'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
