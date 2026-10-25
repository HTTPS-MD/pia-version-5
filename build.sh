#!/bin/sh
# Cloudflare Pages runs "sh build.sh". The real build is in config/build.sh.
exec sh "$(dirname "$0")/config/build.sh"
