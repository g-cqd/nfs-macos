"""Focused behavior checks; fixtures contain no game or account data."""
import importlib.util
import json
from pathlib import Path
import tempfile

path = Path(__file__).with_name('collect-dxvk-markers.py')
spec = importlib.util.spec_from_file_location('dxvk_markers', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

GOOD = b'info:  D3D11CoreCreateDevice: Using feature level D3D_FEATURE_LEVEL_11_0'
OBSERVE = b'observing_pid=1988 hex=07c4 parent_pid=520'


def test_marker_allowlist():
    messages = {
        b'warn: D3D11CoreCreateDevice: Adapter is not a DXVK adapter': 'foreign_adapter',
        b'err:   D3D11CoreCreateDevice: Requested feature level not supported': 'unsupported_feature_level',
        b'err:   D3D11CoreCreateDevice: Failed to create D3D11 device': 'device_creation_failed',
        b'warn: D3D11CreateDevice: Unsupported driver type': 'unsupported_driver',
        b'err:   D3D11CreateDevice: Failed to create a DXGI factory': 'factory_creation_failed',
        b'err:   D3D11CreateDevice: No default adapter available': 'no_adapter',
        b'err:   D3D11CreateDevice: Failed to query DXGI factory from DXGI adapter': 'factory_query_failed',
        b'err:   D3D11CreateDevice: Failed to create swap chain': 'swapchain_creation_failed',
        b'err:   D3D11On12CreateDevice: Not implemented': 'd3d11on12_unimplemented',
    }
    for line, marker in messages.items():
        assert module.parse_marker(line) == {'marker': marker}
    for level in ('9_3', '10_0', '11_1', '12_0'):
        for word, marker in [('Probing', 'feature_probe'), ('Using feature level', 'feature_selected')]:
            line = f'info:  D3D11CoreCreateDevice: {word} D3D_FEATURE_LEVEL_{level}'.encode()
            assert module.parse_marker(line) == {'marker': marker, 'feature_level': level}


def test_secret_and_malformed_rejection():
    for line in [GOOD+b' token=PRIVATE', b'PRIVATE '+GOOD, GOOD+b'\x00', GOOD+b'\nPRIVATE',
                 GOOD.replace(b'11_0', b'111_0'), GOOD.replace(b'info', b'err'),
                 b'info:  D3D11CreateDevice: private account payload', b'\xff'+GOOD]:
        assert module.parse_marker(line) is None


def test_lines_bound_fragmentation_and_recovery():
    lines = module.Lines(128)
    assert lines.feed(GOOD[:20]) == []
    assert lines.feed(GOOD[20:]+b'\r\n') == [GOOD]
    assert lines.feed(b'x'*129) == []
    assert lines.feed(b'PRIVATE\n'+GOOD+b'\n') == [GOOD]
    assert lines.dropped == 1
    assert lines.feed(b'partial') == []
    lines.reset()
    assert lines.feed(GOOD+b'\n') == [GOOD]


def test_file_tail_detects_replacement_and_rewrites():
    with tempfile.TemporaryDirectory() as folder:
        p = Path(folder)/'NFS16_d3d11.log'
        tail = module.Tail(p)
        assert tail.poll()[2] == b''
        p.write_bytes(GOOD+b'\n')
        generation, reason, data = tail.poll()
        assert (generation, reason, data) == (1, 'created', GOOD+b'\n')
        with p.open('ab') as f: f.write(b'noise\n')
        assert tail.poll()[2] == b'noise\n'
        p.write_bytes(b'new\n')
        assert tail.poll() == (2, 'truncated', b'new\n')
        p.write_bytes(b'changed prefix and longer content\n')
        assert tail.poll() == (3, 'rewritten', b'changed prefix and longer content\n')
        q=Path(folder)/'replacement'; q.write_bytes(GOOD+b'\n'); q.replace(p)
        assert tail.poll() == (4, 'replaced', GOOD+b'\n')


def test_preexisting_log_is_not_attributed_to_new_run():
    with tempfile.TemporaryDirectory() as folder:
        p=Path(folder)/'NFS16_d3d11.log'; p.write_bytes(GOOD+b'\n')
        tail=module.Tail(p, skip_existing=True)
        assert tail.poll()[2] == b''
        with p.open('ab') as f: f.write(GOOD+b'\n')
        assert tail.poll()[2] == GOOD+b'\n'


def test_symlinks_and_nonregular_files_rejected():
    with tempfile.TemporaryDirectory() as folder:
        p=Path(folder)/'NFS16_d3d11.log'; private=Path(folder)/'private'; private.write_bytes(b'PRIVATE')
        p.symlink_to(private)
        try: module.Tail(p).poll()
        except module.InputError: pass
        else: raise AssertionError('symlink accepted')
        p.unlink(); p.mkdir()
        try: module.Tail(p).poll()
        except module.InputError: pass
        else: raise AssertionError('directory accepted')


def test_lifecycle_bootstrap_full_exit_and_ambiguity():
    state=module.Lifecycle()
    state.feed(b'observing_pid=464 hex=01d0 parent_pid=0')
    assert state.context(464)['stage']=='unclassified'
    state.feed(b'pid=464 exit_code=0x000186aa elapsed_observation_ms=959')
    state.feed(OBSERVE)
    assert state.context(1988)=={'stage':'full','windows_pid':1988}
    assert state.context(999)['stage']=='ambiguous'
    state.feed(b'pid=1988 exit_code=0xfffffffa elapsed_observation_ms=27969')
    assert state.first_full_exit == {'windows_pid':1988,'exit_code':4294967290,'observation_ms':27969}
    state.feed(b'observing_pid=2916 hex=0b64 parent_pid=1988')
    assert state.context(2916)['stage']=='successor'
    state.feed(b'multiple_game_processes=2; observation_stopped')
    assert state.context(2916)['stage']=='ambiguous'


def test_pid_map_and_writer_identity_are_not_guessed():
    state=module.Lifecycle()
    state.feed(OBSERVE)
    mappings=module.PidMap()
    mappings.feed(b'windows_pid=1988 native_pid=49563')
    assert mappings.lookup(49563)==1988
    mappings.feed(b'windows_pid=2916 native_pid=49563')
    assert mappings.lookup(49563) is None
    mappings.feed(b'windows_pid=1988 native_pid=123 PRIVATE')
    assert mappings.lookup(123) is None
    assert module.parse_writers(b'p100\nf4\nar\np200\nf5\naw\np300\nf6\nau\n') == {200,300}
    assert module.parse_writers(b'p99999999999999999999\nf5\naw\n') is None


def test_output_count_and_size_caps():
    with tempfile.TemporaryDirectory() as folder:
        p=Path(folder)/'output.jsonl'
        with module.Output(p, max_records=2, max_bytes=1024) as out:
            assert out.emit({'marker':'a'})
            assert out.emit({'marker':'b'})
            assert not out.emit({'marker':'c'})
            out.finish({'reason':'record_limit'})
        records=[json.loads(x) for x in p.read_bytes().splitlines()]
        assert len(records)==3 and records[-1]['reason']=='record_limit'
        assert p.stat().st_size<=1024
        try:
            with module.Output(p): pass
        except FileExistsError: pass
        else: raise AssertionError('existing output overwritten')


def test_collector_deadline_filters_noise_and_preserves_before_overwrite():
    with tempfile.TemporaryDirectory() as folder:
        root=Path(folder); log=root/'NFS16_d3d11.log'; life=root/'test.lifecycle.log'; maps=root/'pids.txt'; out=root/'result.jsonl'
        class Clock:
            value=0.0
            def __call__(self): return self.value
            def pause(self, seconds):
                self.value += seconds
                if self.value==0.5:
                    life.write_bytes(b'observing_pid=464 hex=01d0 parent_pid=0\npid=464 exit_code=0x000186aa elapsed_observation_ms=959\n'+OBSERVE+b'\n')
                    maps.write_bytes(b'windows_pid=1988 native_pid=49563\n')
                    log.write_bytes(b'PRIVATE\n'+GOOD+b'\n')
                elif self.value==1.0:
                    log.write_bytes(b'err:   D3D11CreateDevice: No default adapter available\n')
        clock=Clock()
        module.collect(root,life,maps,out,seconds=1.5,clock=clock,pause=clock.pause,writer_probe=lambda *_:{49563})
        data=out.read_bytes(); records=[json.loads(x) for x in data.splitlines()]
        markers=[x for x in records if x.get('kind')=='marker']
        assert [x['marker'] for x in markers]==['feature_selected','no_adapter']
        assert markers[0]['lifecycle_stage']=='full' and markers[0]['observed_writer_pid']==49563
        assert markers[0]['attribution']=='ambiguous_file_poll'
        assert b'PRIVATE' not in data
        assert records[-1]['reason']=='deadline' and records[-1]['coverage_complete'] is False
        assert clock.value==1.5


def test_output_cannot_alias_any_input():
    with tempfile.TemporaryDirectory() as folder:
        root=Path(folder); life=root/'test.lifecycle.log'; maps=root/'pids.txt'
        for output in [root/'NFS16_d3d11.log', life, maps]:
            try: module.collect(root,life,maps,output,seconds=0)
            except module.InputError: pass
            else: raise AssertionError('input path accepted as output')
            assert not output.exists()


def test_input_limit_stops_noise_and_records_no_payload():
    with tempfile.TemporaryDirectory() as folder:
        root=Path(folder); log=root/'NFS16_d3d11.log'
        class Clock:
            value=0.0
            def __call__(self): return self.value
            def pause(self, seconds):
                self.value += seconds
                if self.value==0.5:
                    log.write_bytes(b'x'*(module.INPUT_LIMIT+1))
        clock=Clock(); out=root/'out.jsonl'
        module.collect(root,root/'test.lifecycle.log',None,out,clock=clock,pause=clock.pause,writer_probe=lambda *_:None)
        records=[json.loads(x) for x in out.read_bytes().splitlines()]
        assert len(records)==1 and records[0]['reason']=='input_limit'
        assert records[0]['input_bytes']==module.INPUT_LIMIT and records[0]['markers']==0


def test_output_byte_limit_and_private_permissions():
    import stat
    with tempfile.TemporaryDirectory() as folder:
        out=Path(folder)/'out.jsonl'
        with module.Output(out, max_bytes=1024) as sink:
            assert not sink.emit({'marker':'x'*513})
            sink.finish({'reason':'output_limit'})
        assert out.stat().st_size <= 1024
        assert stat.S_IMODE(out.stat().st_mode)==0o600


def test_lsof_identifies_owned_writer_and_skips_readers():
    import os
    with tempfile.TemporaryDirectory() as folder:
        p=Path(folder)/'NFS16_d3d11.log'; p.write_bytes(b'')
        with p.open('rb'):
            assert module.writer_pids(p,2)==set()
        with p.open('ab'):
            assert module.writer_pids(p,2)=={os.getpid()}


def test_observer_replacement_and_stale_inputs_stop_collection():
    with tempfile.TemporaryDirectory() as folder:
        root=Path(folder); life=root/'test.lifecycle.log'; life.write_bytes(OBSERVE+b'\n')
        try: module.collect(root,life,None,root/'stale.jsonl',seconds=0)
        except module.InputError: pass
        else: raise AssertionError('stale observer accepted')
        life.unlink()
        class Clock:
            value=0.0
            def __call__(self): return self.value
            def pause(self,seconds):
                self.value+=seconds
                if self.value==0.5: life.write_bytes(OBSERVE+b'\n')
                elif self.value==1.0:
                    replacement=root/'new'; replacement.write_bytes(b''); replacement.replace(life)
        clock=Clock(); out=root/'replace.jsonl'
        module.collect(root,life,None,out,seconds=2,clock=clock,pause=clock.pause)
        summary=json.loads(out.read_bytes().splitlines()[-1])
        assert summary['reason']=='observer_input_replaced'


def test_expired_probe_does_not_emit_after_deadline():
    with tempfile.TemporaryDirectory() as folder:
        root=Path(folder); out=root/'out.jsonl'
        class Clock:
            value=0.0
            def __call__(self): return self.value
            def pause(self,seconds):
                self.value+=seconds
                (root/'NFS16_d3d11.log').write_bytes(GOOD+b'\n')
            def probe(self, path, timeout):
                self.value+=timeout
                return {49563}
        clock=Clock()
        module.collect(root,root/'test.lifecycle.log',None,out,seconds=1.5,clock=clock,pause=clock.pause,writer_probe=clock.probe)
        records=[json.loads(x) for x in out.read_bytes().splitlines()]
        assert len(records)==1 and records[0]['markers']==0 and records[0]['reason']=='deadline'


def test_corrupted_observer_cannot_confirm_full_exit():
    state=module.Lifecycle()
    state.feed(b'unknown observer failure PRIVATE')
    state.feed(b'observing_pid=464 hex=01d0 parent_pid=0')
    state.feed(b'pid=464 exit_code=0x000186aa elapsed_observation_ms=959')
    state.feed(OBSERVE)
    state.feed(b'pid=1988 exit_code=0xfffffffa elapsed_observation_ms=27969')
    assert state.first_full_exit is None


def test_dropped_or_late_corruption_invalidates_collected_exit():
    valid=(b'observing_pid=464 hex=01d0 parent_pid=0\n'
           b'pid=464 exit_code=0x000186aa elapsed_observation_ms=959\n'
           +OBSERVE+b'\n'
           b'pid=1988 exit_code=0xfffffffa elapsed_observation_ms=27969\n')
    cases={'oversized_before_sequence':b'x'*4097+b'\n'+valid,
           'invalid_after_exit':valid+b'unknown observer failure PRIVATE\n'}
    failures=[]
    for name,payload in cases.items():
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); life=root/'test.lifecycle.log'; out=root/'out.jsonl'
            class Clock:
                value=0.0
                def __call__(self): return self.value
                def pause(self,seconds):
                    self.value+=seconds
                    if self.value==0.5: life.write_bytes(payload)
            clock=Clock()
            module.collect(root,life,None,out,seconds=1,clock=clock,pause=clock.pause)
            data=out.read_bytes(); summary=json.loads(data.splitlines()[-1])
            if not (summary['observer_ambiguous'] is True
                    and summary['first_full_exit'] is None
                    and summary['reason']=='deadline'
                    and b'PRIVATE' not in data):
                failures.append(name)
    assert not failures, failures


def test_writer_cleanup_timeout_closes_pipe_and_records_failure():
    import io
    import subprocess
    from unittest import mock

    class Process:
        def __init__(self):
            self.stdout, self.killed = io.BytesIO(), False
            self.wait_timeouts = []
        def poll(self): return None
        def kill(self): self.killed = True
        def wait(self, timeout):
            self.wait_timeouts.append(timeout)
            raise subprocess.TimeoutExpired('PRIVATE command path', timeout)

    class Selector:
        def __enter__(self): return self
        def __exit__(self, *_): pass
        def register(self, *_): pass

    with tempfile.TemporaryDirectory() as folder:
        root=Path(folder); out=root/'out.jsonl'; process=Process()
        class Clock:
            value=0.0
            def __call__(self): return self.value
            def pause(self, seconds):
                self.value+=seconds
                (root/'NFS16_d3d11.log').write_bytes(GOOD+b'\n')
        clock=Clock()
        with mock.patch.object(module.subprocess, 'Popen', return_value=process), \
             mock.patch.object(module.selectors, 'DefaultSelector', return_value=Selector()), \
             mock.patch.object(module.time, 'monotonic', side_effect=[0, 2]):
            reason=module.collect(root,root/'test.lifecycle.log',None,out,seconds=1,
                                  clock=clock,pause=clock.pause,writer_probe=module.writer_pids)
        data=out.read_bytes(); records=[json.loads(line) for line in data.splitlines()]
        assert reason=='writer_cleanup_timeout'
        assert len(records)==1 and records[0]['reason']==reason and records[0]['markers']==0
        assert process.killed and process.stdout.closed and process.wait_timeouts==[1]
        assert b'PRIVATE' not in data


checks=[v for k,v in globals().copy().items() if k.startswith('test_')]
for check in checks:
    check()
print(f'DXVK marker collector: {len(checks)} behavior checks passed.')
