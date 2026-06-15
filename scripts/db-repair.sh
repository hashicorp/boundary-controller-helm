#!/bin/sh
# Copyright IBM Corp. 2026
# SPDX-License-Identifier: MPL-2.0

set -u

if [ "$#" -lt 1 ] || [ -z "$1" ]; then
  echo "repair version argument is required"
  exit 1
fi

REPAIR_VERSION="$1"
OUTPUT_FILE=/tmp/output.log
boundary database migrate -config /etc/boundary/controller.hcl -repair "$REPAIR_VERSION" >"$OUTPUT_FILE" 2>&1
EXIT_CODE=$?

cat "$OUTPUT_FILE"
exit "$EXIT_CODE"
