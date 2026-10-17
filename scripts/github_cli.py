#!/usr/bin/env python3
"""Run gh with existing github.com Git credentials; never print or persist secrets."""
import os
import subprocess
import sys

environment = os.environ.copy()
if not environment.get("GH_TOKEN") and not environment.get("GITHUB_TOKEN"):
    credential = subprocess.run(
        ["git", "credential", "fill"], input="protocol=https\nhost=github.com\n\n",
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        env={**environment, "GIT_TERMINAL_PROMPT": "0"},
    )
    fields = dict(line.split("=", 1) for line in credential.stdout.splitlines() if "=" in line)
    if fields.get("password"):
        environment["GH_TOKEN"] = fields["password"]
sys.exit(subprocess.run(["gh", *sys.argv[1:]], env=environment).returncode)
