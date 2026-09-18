"""Deterministic official app-server protocol fixture. Never calls a model/network."""
import json
import os
import sys
import uuid
from pathlib import Path

store = Path(os.environ['AICLI_CHILD_FIXTURE_STATE'])
state = json.loads(store.read_text()) if store.exists() else {'threads': {}, 'events': [], 'counts': {}}
threads = state['threads']
pending = {}
held = []
next_child_override = None
hold_next_child_start = False


def effective(t):
    return {'thread': t, 'model': t['model'], 'modelProvider': t['modelProvider'],
            'reasoningEffort': t.get('reasoningEffort'),
            'approvalPolicy': t.get('approvalPolicy', 'never'),
            'sandbox': t.get('sandbox', {'type': 'dangerFullAccess'}),
            'activePermissionProfile': t.get('activePermissionProfile')}



def write(data):
    print(json.dumps(data), flush=True)


def save():
    store.write_text(json.dumps(state), encoding='utf-8')


def reply(req, result):
    write({'jsonrpc': '2.0', 'id': req['id'], 'result': result})


def error(req, message):
    write({'jsonrpc': '2.0', 'id': req['id'], 'error': {'code': -32000, 'message': message}})


def event(method, params):
    write({'jsonrpc': '2.0', 'method': method, 'params': params})


def finish(t, text=None, status='completed', turn_id=None):
    turn = t['turns'][-1]
    if turn_id and turn_id != turn['id']:
        event('turn/completed', {'threadId': t['id'], 'turn': {'id': turn_id, 'status': status}})
        return
    if text is not None:
        item = {'id': str(uuid.uuid4()), 'type': 'agentMessage', 'phase': 'final_answer', 'text': text}
        turn['items'].append(item)
        event('item/completed', {'threadId': t['id'], 'turnId': turn['id'], 'item': item})
    turn['status'] = status
    t['status'] = {'type': 'idle'}
    save()
    event('turn/completed', {'threadId': t['id'], 'turn': turn})


def ask(t, message, wait, finish_reply=True):
    cid = 'msg-' + str(uuid.uuid4())
    sid = 'child-call-' + str(uuid.uuid4())
    pending[sid] = {'child': t['id'], 'finish_reply': finish_reply}
    event_params = {'threadId': t['id'], 'turnId': t['turns'][-1]['id'], 'callId': cid,
                    'tool': 'openai_parent', 'arguments': {'message': message, 'request_reply': wait}}
    write({'jsonrpc': '2.0', 'id': sid, 'method': 'item/tool/call', 'params': event_params})


for line in sys.stdin:
    req = json.loads(line)
    method = req.get('method')
    args = req.get('params', {})
    if not method:
        operation = pending.pop(req.get('id'), None)
        if not operation:
            continue
        if 'client_id' in operation:
            reply({'id': operation['client_id']}, req.get('result', req.get('error')))
        else:
            data = req.get('result', {})
            payload = json.loads(data.get('contentItems', [{}])[0].get('text', '{}'))
            t = threads[operation['child']]
            if operation['finish_reply'] and t['status']['type'] == 'active':
                if data.get('success'):
                    finish(t, 'ANSWER:' + payload.get('reply', 'PROGRESS_SENT'))
                else:
                    finish(t, 'PARENT_ERROR:' + payload.get('error', 'unknown'), 'failed')
        continue
    state['counts'][method] = state['counts'].get(method, 0) + 1
    if method == 'initialize':
        reply(req, {'userAgent': 'isolated-fixture'})
    elif method == 'initialized':
        pass
    elif method == 'thread/start':
        tid = str(uuid.uuid4())
        t = {'id': tid, 'sessionId': str(uuid.uuid4()), 'model': args.get('model'),
             'modelProvider': args.get('modelProvider', 'openai'),
             'cwd': args.get('cwd') or str(Path.cwd()), 'reasoningEffort': args.get('config', {}).get('model_reasoning_effort'),
             'ephemeral': args.get('ephemeral', False), 'threadSource': args.get('threadSource'),
             'status': {'type': 'idle'}, 'turns': [], 'tools': args.get('dynamicTools', [])}
        threads[tid] = t
        save()
        event('thread/started', {'thread': t})
        result = effective(t)
        if str(t.get('threadSource', '')).startswith('aicli.background-child.'):
            if next_child_override is not None:
                result.update(next_child_override.get('top', {}))
                t.update(next_child_override.get('thread', {}))
                next_child_override = None
            if hold_next_child_start:
                held.append((req, result))
                hold_next_child_start = False
                continue
        reply(req, result)
    elif method in ('thread/resume', 'thread/read'):
        t = threads.get(args['threadId'])
        if not t:
            error(req, 'Exact thread does not exist')
            continue
        if method == 'thread/resume':
            t['status'] = {'type': 'idle'}
            if args.get('config', {}).get('model_reasoning_effort'):
                t['reasoningEffort'] = args['config']['model_reasoning_effort']
        save()
        reply(req, effective(t))
    elif method == 'turn/start':
        t = threads.get(args['threadId'])
        if not t:
            error(req, 'Unknown target thread')
            continue
        message = args.get('toolOutput', {}).get('output', '')
        if not message:
            message = ' '.join(x.get('text', '') for x in args.get('input', []))
        racing_followup = message == 'RACE_FOLLOWUP' and t['status']['type'] == 'active'
        if racing_followup:
            finish(t, 'OLD_TURN_DONE')
        running = t['status']['type'] == 'active'
        if not running:
            turn = {'id': str(uuid.uuid4()), 'status': 'inProgress', 'items': []}
            t['turns'].append(turn)
            t['status'] = {'type': 'active'}
        else:
            turn = t['turns'][-1]
        if args.get('effort'):
            t['reasoningEffort'] = args['effort']
        if args.get('toolOutput'):
            turn['items'].append({'type': 'functionCallOutput', 'id': str(uuid.uuid4()), **args['toolOutput']})
        if not racing_followup:
            reply(req, {'turn': turn})
        if not running:
            event('turn/started', {'threadId': t['id'], 'turn': turn})
        if t['modelProvider'] != 'openai':
            if args.get('toolOutput'):
                state['events'].append({'thread_id': t['id'], 'input': args.get('input'), 'toolOutput': args['toolOutput']})
            save()
            continue
        if racing_followup:
            finish(t, 'NEW_TURN_DONE')
            reply(req, {'turn': turn})
        elif message.startswith('REMEMBER:'):
            t['memory'] = message.split(':', 1)[1]
            finish(t, 'REMEMBERED')
        elif message == 'RECALL':
            finish(t, t.get('memory', 'MEMORY_MISSING'))
        elif message.startswith('ASK:'):
            ask(t, message[4:], True)
        elif message.startswith('PROGRESS:'):
            ask(t, message[9:], False)
        elif message.startswith('UPDATE:'):
            finish(t, 'UPDATED:' + message[7:])
        elif message == 'FAIL':
            finish(t, None, 'failed')
        elif message == 'MISSINGFINAL':
            finish(t)
        elif message == 'WAIT':
            save()
        else:
            finish(t, 'CHILD_OK')
    elif method == 'turn/interrupt':
        t = threads.get(args['threadId'])
        if args.get('turnId') == 'invalid-root-turn':
            error(req, 'Stale root turn ID')
            continue
        reply(req, {})
        if t and t['turns'] and t['status']['type'] == 'active':
            finish(t, None, 'interrupted')
    elif method in ('thread/list', 'thread/search'):
        reply(req, {'data': list(threads.values()), 'nextCursor': None})
    elif method == 'thread/loaded/list':
        reply(req, {'data': list(threads)})
    elif method in ('thread/unsubscribe', 'thread/name/set'):
        reply(req, {})
    elif method == 'test/dispatch':
        sid = 'server-' + str(uuid.uuid4())
        pending[sid] = {'client_id': req['id']}
        write({'jsonrpc': '2.0', 'id': sid, 'method': 'item/tool/call', 'params': {
            'threadId': args['thread_id'], 'turnId': args.get('turn_id', 'parent-turn'),
            'callId': args.get('call_id', 'call-' + str(uuid.uuid4())),
            'tool': args['tool'], 'arguments': args['arguments']}})
    elif method == 'test/create-legacy-parent':
        tid = str(uuid.uuid4())
        threads[tid] = {'id': tid, 'sessionId': tid, 'model': 'glm-5.3-flash', 'modelProvider': 'aicli_glm_5_3_flash', 'cwd': args['cwd'], 'reasoningEffort': 'max', 'status': {'type': 'idle'}, 'turns': [], 'tools': []}
        save()
        reply(req, {'thread_id': tid})
    elif method == 'test/state':
        reply(req, {**state, 'held_count': len(held)})
    elif method == 'test/hold-next-child-start':
        hold_next_child_start = True
        reply(req, {})
    elif method == 'test/release-held':
        for original, result in held:
            reply(original, result)
        held.clear()
        reply(req, {})
    elif method == 'test/next-child-override':
        next_child_override = args
        reply(req, {})
    elif method == 'test/permission-drift':
        threads[args['thread_id']]['activePermissionProfile'] = {'id': 'changed-effective-profile'}
        save()
        reply(req, {})
    elif method == 'test/interactive-request':
        rid = 'interactive-' + str(uuid.uuid4())
        pending[rid] = {'client_id': req['id']}
        write({'jsonrpc': '2.0', 'id': rid, 'method': args['method'], 'params': {
            'threadId': args['thread_id'], 'turnId': args.get('turn_id', ''), 'questions': []}})
    elif method == 'test/late-terminal':
        finish(threads[args['thread_id']], turn_id=args['turn_id'])
        reply(req, {})
    elif method == 'test/tamper-model':
        threads[args['thread_id']]['model'] = 'not-the-requested-model'
        save()
        reply(req, {})
    else:
        if 'id' in req:
            reply(req, {})
    save()
