import sys

from gongcao.sandbox import Sandbox


def install_worker(monkeypatch, source):
    original = Sandbox.argv

    def argv(self, *payload):
        if payload[1:3] == ("-m", "gongcao.worker"):
            payload = (sys.executable, "-c", source)
        return original(self, *payload)

    monkeypatch.setattr(Sandbox, "argv", argv)


SUCCESS = """
import json,sys,pathlib
request = json.loads(sys.stdin.readline())
if request['writable']:
    pathlib.Path('/workspace/sample.txt').write_text('changed in worktree\\n')
print(json.dumps({'kind':'thread','data':{'thread_id':request['context']['role']+'-thread'}}))
print(json.dumps({'kind':'result','data':{
    'conclusion':'ready','summary':'Inspected the assigned revision',
    'basis':['sample.txt was inspected'],'target_sha':request['context']['target_sha'],
    'next_steps':['Run validation']}}))
"""


WORKER = """
import json, pathlib, sys, uuid
from gongcao.plan import propose
data = json.loads(sys.stdin.readline())['context']
role = data['role']
sample = pathlib.Path('/workspace/sample.txt')
if role == 'developer':
    sample.write_text('complete\\n' if data['confirmed_findings'] else 'incomplete\\n')
conclusion = 'revise' if role == 'reviewer' and sample.read_text() == 'incomplete\\n' else 'ready'
plan = propose(data) if role=='analyst' else []
for item in plan:
    if item['category']=='e2e':
        item.update(required=False,reason='Offline protocol fixture; real E2E is not claimed')
print(json.dumps({'kind':'thread','data':{'thread_id':str(uuid.uuid4())}}))
print(json.dumps({'kind':'result','data':{
    'conclusion':conclusion,'summary':'Inspected the exact worktree',
    'basis':['sample.txt must be complete'],'target_sha':data['target_sha'],
    'next_steps':['Fix incomplete output' if conclusion=='revise' else 'Check controller gates'],
    'validation_plan':plan}}))
"""
