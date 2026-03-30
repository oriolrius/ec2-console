#!/usr/bin/env bash
cd "$(dirname "$0")"
eval "$(micromamba shell hook -s bash)"
micromamba activate -p ./env
exec jupyter lab \
  --ip=0.0.0.0 \
  --port=8889 \
  --no-browser \
  --ServerApp.token='' \
  --ServerApp.disable_check_xsrf=True
