#!/bin/sh
# Copyright IBM Corp. 2026
# SPDX-License-Identifier: MPL-2.0

set -u

OUTPUT_FILE=/tmp/output.log
boundary database init \
  -skip-initial-authenticated-user-role-creation \
  -skip-auth-method-creation \
  -skip-host-resources-creation \
  -skip-scopes-creation \
  -skip-target-creation \
  -config /etc/boundary/controller.hcl >"$OUTPUT_FILE" 2>&1
EXIT_CODE=$?

if [ "$EXIT_CODE" -eq 0 ]; then
  cat "$OUTPUT_FILE"
  exit 0
elif grep -q "already been initialized\|already initialized" "$OUTPUT_FILE"; then
  cat "$OUTPUT_FILE"
  exit 0
else
  cat "$OUTPUT_FILE"
  exit 1
fi
