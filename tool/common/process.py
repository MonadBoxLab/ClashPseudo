"""子进程执行与显式环境。"""
import logging
import os
import shlex
import subprocess
import time

logger = logging.getLogger(__name__)


def run(command, cwd, env=None):
    command = list(map(str, command))
    label = shlex.join([os.path.basename(command[0]), *command[1:]])
    started = time.monotonic()
    logger.info("执行：%s", label)
    process = subprocess.run(
        command, cwd=cwd,
        env={**os.environ, "GOTOOLCHAIN": "local", "GOWORK": "off", "GIT_OPTIONAL_LOCKS": "0", **(env or {})},
        text=True, capture_output=True, check=False,
    )
    if process.returncode:
        raise ValueError(f"命令失败（{process.returncode}）：{' '.join(map(str, command))}\n"
                         + process.stdout + process.stderr)
    logger.info("命令完成，耗时 %.1f 秒：%s", time.monotonic() - started, label)
    return process.stdout
