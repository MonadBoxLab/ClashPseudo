"""子进程执行与显式环境。"""
import os
import subprocess

def run(command, cwd, env=None):
    process = subprocess.run(
        list(map(str, command)), cwd=cwd,
        env={**os.environ, "GOTOOLCHAIN": "local", "GOWORK": "off", "GIT_OPTIONAL_LOCKS": "0", **(env or {})},
        text=True, capture_output=True, check=False,
    )
    if process.returncode:
        raise ValueError(f"命令失败（{process.returncode}）：{' '.join(map(str, command))}\n"
                         + process.stdout + process.stderr)
    return process.stdout
