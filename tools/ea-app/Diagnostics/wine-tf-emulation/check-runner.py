#!/usr/bin/env python3
"""Regression checks for owned cleanup and bootstrap failure handling."""
import errno
import importlib.util
from pathlib import Path
import shutil
import tempfile
import uuid
from unittest import mock

spec = importlib.util.spec_from_file_location("runner", Path(__file__).with_name("run-contract.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def fixture():
    session = Path(tempfile.mkdtemp(prefix="nfs2015-tf-cleanup-check-", dir=Path.home() / "Library/Caches"))
    owner = uuid.uuid4().hex
    marker = session / ".owner"
    marker.write_text(owner)
    (session / "runtime").mkdir()
    return session, marker, owner


session, marker, owner = fixture()
calls = 0


def once(path):
    global calls
    calls += 1
    assert marker.read_text() == owner
    if calls == 1:
        (path / ".DS_Store").write_bytes(b"test")
        raise OSError(errno.ENOTEMPTY, "deterministic metadata race")
    shutil.rmtree(path)


runner.remove_owned_directory(session, marker, owner, once)
assert calls == 2 and not session.exists()
print("PASS metadata race retries with ownership retained")

session, marker, owner = fixture()
calls = 0


def always(path):
    global calls
    calls += 1
    assert path.is_dir() and marker.read_text() == owner
    raise OSError(errno.ENOTEMPTY, "persistent metadata race")


try:
    runner.remove_owned_directory(session, marker, owner, always)
    raise AssertionError("persistent race was not reported")
except OSError as error:
    assert error.errno == errno.ENOTEMPTY and calls == 3 and marker.read_text() == owner
runner.remove_owned_directory(session, marker, owner)
print("PASS retry count is bounded and failure preserves ownership")

session, marker, owner = fixture()
try:
    runner.remove_owned_directory(session, marker, "wrong owner")
    raise AssertionError("ownership mismatch was accepted")
except RuntimeError:
    assert (session / "runtime").is_dir() and marker.read_text() == owner
runner.remove_owned_directory(session, marker, owner)
print("PASS ownership mismatch preserves files")

# Exercise main's bootstrap gate without compiling or invoking Wine.
session, marker, owner = fixture()
try:
    sources = session / "sources"
    sources.mkdir()
    for name in ("contract-probe.c", "contract-fixtures.S", "run-contract.py"):
        shutil.copyfile(Path(__file__).with_name(name), sources / name)
    supplied_runtime = session / "runtime"
    for relative in ("bin/wineserver", "lib/wine/x86_64-unix/ntdll.so", "lib/wine/x86_64-windows/ntdll.dll"):
        target = supplied_runtime / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"owned bootstrap test fixture")
    stopped = []

    def fake_run(command, **kwargs):
        if command[0] == "/bin/cp":
            shutil.copytree(command[2], command[3])
        elif command[0] == "owned-test-compiler":
            pass
        else:
            assert Path(command[0]).name == "wineserver" and command[1] in ("-k", "-w")
            stopped.append(command[1])
        return runner.subprocess.CompletedProcess(command, 0)

    overflow = ({"exit": 0, "timeout": False, "output_overflow": True}, b"")
    with mock.patch.object(runner, "__file__", str(sources / "run-contract.py")), \
         mock.patch("sys.argv", ["run-contract.py", "--runtime", str(supplied_runtime)]), \
         mock.patch.object(runner.shutil, "which", return_value="owned-test-compiler"), \
         mock.patch.object(runner.subprocess, "run", side_effect=fake_run), \
         mock.patch.object(runner, "capture", side_effect=[overflow, RuntimeError("case entered after overflow")]) as capture:
        try:
            runner.main()
            raise AssertionError("bootstrap overflow was accepted")
        except RuntimeError as error:
            assert str(error).startswith("Private prefix initialization failed:"), str(error)
        assert capture.call_count == 1
    assert stopped == ["-k", "-w"]
finally:
    runner.remove_owned_directory(session, marker, owner)
print("PASS bootstrap output overflow fails before any probe case")
