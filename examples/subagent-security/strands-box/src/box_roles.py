"""Render fixed filesystem grants and launch one independently configured Box role."""
import json
import strict_json
import os
from pathlib import Path
import signal
import subprocess
import sysconfig

ROLES = ("reader", "evaluator", "writer")
POLICIES = Path(__file__).resolve().parent.parent / "policies"


def configuration(role, workspace, broker, shared_analyst, python, adapter, state=None):
    if role not in ROLES:
        raise ValueError("Unknown analyst role: " + role)
    workspace, broker = Path(workspace).resolve(), Path(broker).resolve()
    shared_analyst, python, adapter = (Path(p).resolve(strict=True)
                                       for p in (shared_analyst, python, adapter))
    runtime_paths = [Path(sysconfig.get_path("stdlib")), Path("/usr/lib"), Path("/usr/lib64")]
    runtime_paths = {p.resolve() for p in runtime_paths if p.exists()}
    runtime_paths = sorted(str(p) for p in runtime_paths
                           if not any(parent in runtime_paths for parent in p.parents))
    # Native extension modules contain executable code. The pinned Box runtime
    # does not infer this permission for /usr/local Python installations.
    extension_directory = sysconfig.get_config_var("DESTSHARED")
    exec_paths = ([str(Path(extension_directory).resolve(strict=True))]
                  if extension_directory and Path(extension_directory).is_dir() else [])
    read_paths = [str(shared_analyst), str(workspace / "in"), str(workspace / "out"), *runtime_paths]
    state = Path(state).resolve() if state else broker / "state"
    return ("name=" + json.dumps("analyst-" + role) + "\n"
            + "box_dir=" + json.dumps(str(state)) + "\n"
            + 'policy="policy.dw"\n[agent]\n'
            + "command=" + json.dumps([str(python), str(adapter), str(shared_analyst), "box-probes",
                                       str(workspace / "in/probes.json")]) + "\n"
            + "workspace=" + json.dumps(str(workspace)) + "\n"
            + "[agent.filesystem]\nread=" + json.dumps(read_paths) + "\n"
            + "read_file=" + json.dumps([str(adapter), str(Path(__file__).with_name("strict_json.py").resolve(strict=True))]) + "\n"
            + "write=" + json.dumps([str(workspace / "out")]) + "\n"
            + "exec=" + json.dumps(exec_paths) + "\n")


def prepare(role, workspace, broker, shared_analyst, python, adapter, *, supplier_host="127.0.0.1", supplier_port=0, state=None):
    broker = Path(broker).resolve()
    broker.mkdir(parents=True, exist_ok=False, mode=0o700)
    workspace = Path(workspace).resolve()
    if not isinstance(supplier_port, int) or not 0 <= supplier_port <= 65535:
        raise ValueError("Invalid supplier port")
    text = (POLICIES / (role + ".dw")).read_text().replace("__PORT__", str(supplier_port))
    text = text.replace("__HOST__", json.dumps(supplier_host)[1:-1])
    for name, path in (("__INPUT__", workspace / "in"), ("__OUTPUT__", workspace / "out")):
        try:
            spelling = "~/" + str(path.relative_to(Path.home().resolve()))
        except ValueError:
            spelling = str(path)
        text = text.replace(name, json.dumps(spelling)[1:-1])
    (broker / "policy.dw").write_text(text)
    config = broker / "box.toml"
    config.write_text(configuration(role, workspace, broker, shared_analyst, python, adapter, state))
    return config


def execute(box, config, timeout=60):
    config = Path(config).resolve()
    env = {"PATH": "/usr/bin:/bin", "HOME": str(Path.home()), "LANG": "C.UTF-8",
           "EXPERIMENTAL_LINUX_SUPPORT": "TRUE"}
    process = subprocess.Popen([str(Path(box).resolve(strict=True)), "run", "--config", str(config)],
                               env=env, cwd=config.parent, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            stdout, stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate(timeout=5)
        (config.parent / "stdout.txt").write_text(stdout)
        (config.parent / "stderr.txt").write_text(stderr)
        raise RuntimeError("Box role exceeded its deadline")
    (config.parent / "stdout.txt").write_text(stdout)
    (config.parent / "stderr.txt").write_text(stderr)
    if process.returncode:
        raise RuntimeError("Box role failed with exit " + str(process.returncode)
                           + ": " + stderr[-1800:])
    from worker import MARKER
    results = [line[len(MARKER):] for line in stdout.splitlines() if line.startswith(MARKER)]
    if len(results) != 1:
        raise RuntimeError("Box role did not produce exactly one structured result")
    return strict_json.loads(results[0])
