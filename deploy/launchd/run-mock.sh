#!/bin/bash
set -euo pipefail
# launchd entry: local OpenAI mock used by the openai-local group.
. "$(dirname "$0")/common.sh"
sub2_prepare_env

export MOCK_OPENAI_HOST="${MOCK_OPENAI_HOST:-127.0.0.1}"
export MOCK_OPENAI_PORT="${MOCK_OPENAI_PORT:-18765}"
exec /usr/bin/python3 "$DEPLOY/mock-openai.py"