"""Subprocess execution with explicit environments."""
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
    logger.info("Running: %s", label)
    process = subprocess.run(
        command, cwd=cwd,
        env={**os.environ, "GOTOOLCHAIN": "local", "GOWORK": "off", "GIT_OPTIONAL_LOCKS": "0", **(env or {})},
        text=True, capture_output=True, check=False,
    )
    if process.returncode:
        raise ValueError(f"Command failed ({process.returncode}): {' '.join(map(str, command))}\n"
                         + process.stdout + process.stderr)
    logger.info("Command completed in %.1f seconds: %s", time.monotonic() - started, label)
    return process.stdout
