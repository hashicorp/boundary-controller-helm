#!/bin/sh
# Copyright IBM Corp. 2026
# SPDX-License-Identifier: MPL-2.0

set -u

OUTPUT_FILE=/tmp/output.log
boundary database migrate -config /etc/boundary/controller.hcl >"$OUTPUT_FILE" 2>&1
EXIT_CODE=$?

cat "$OUTPUT_FILE"
exit "$EXIT_CODE"
