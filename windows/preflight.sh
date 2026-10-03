#!/bin/bash
# A file avoids PowerShell 5.1's lossy native quoting of nested bash -c strings.
set -e
for tool in perl curl openssl ssh ssh-keyscan tar sha256sum awk sed stat; do
  command -v "$tool" >/dev/null || { printf 'Missing runtime tool: %s\n' "$tool" >&2; exit 1; }
done
perl -MJSON::PP -MDigest::SHA -e 'print "runtime.ready\n"'
