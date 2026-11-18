#!/usr/bin/env python3
"""Malformed parser fixtures never execute a command or write a protected path."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
with tempfile.TemporaryDirectory() as temp:
    env = {**os.environ, "CLAUDE_PROJECT_DIR": temp}
    for script in ["block-core-writes.sh", "block-core-writes-bash.sh"]:
        for payload in [b'{"tool_input":{},"metadata":', b'{"tool_input":{},"metadata":bareword}', b'{} trailing']:
            result = subprocess.run(["/bin/bash", str(root / ".claude/hooks" / script)], input=payload, env=env, capture_output=True)
            assert result.returncode == 2, (script, payload, result.returncode)
        result = subprocess.run(["/bin/bash", str(root / ".claude/hooks" / script)], input=b'{"tool_input":{}}', env=env, capture_output=True)
        assert result.returncode == 0, (script, result.returncode)
print("PASS: both write guards refuse malformed input and allow a valid empty tool input")
