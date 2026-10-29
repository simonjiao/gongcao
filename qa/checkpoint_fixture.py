"""Offline SDK substitute: preserve a partial edit, then prove the fresh session inherits it."""

WORKER = r"""
import json, pathlib, sys, uuid
request = json.loads(sys.stdin.readline())
data = request['context']
sample = pathlib.Path('/workspace/sample.txt')
conclusion = 'ready'
if data['role'] == 'developer':
    assert pathlib.Path('/workspace/.git').read_bytes() == b''
    assert data['source']['sha']
    if sample.read_text() == 'original\n':
        sample.write_text('partial work\n')
        conclusion = 'blocked'
    else:
        assert sample.read_text() == 'partial work\n', 'Prior changes were lost'
        sample.write_text('partial work\ncompleted after retry\n')
print(json.dumps({'kind':'thread','data':{'thread_id':str(uuid.uuid4())}}))
print(json.dumps({'kind':'result','data':{
    'conclusion':conclusion,
    'summary':'Missing release packages' if conclusion=='blocked' else 'Ready',
    'basis':['PASS: document checks; NOT_RUN: package verification'],
    'target_sha':data['target_sha'],
    'next_steps':['Supply original/r1 packages and Release metadata']}}))
"""
