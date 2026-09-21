#!/bin/bash
set -euo pipefail
# login-time helper: ClashX Meta is already a login item; open it if 7890 is down.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

if nc -z -G 1 127.0.0.1 7890 >/dev/null 2>&1; then
  exit 0
fi

open -ga "ClashX Meta"
exit 0