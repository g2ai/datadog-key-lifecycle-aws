#!/bin/bash
# Put the config in place, make the Agent start at boot, but do not run it in the image.
set -euo pipefail

install -o dd-agent -g dd-agent -m 0640 /tmp/datadog.yaml /etc/datadog-agent/datadog.yaml
rm -f /tmp/datadog.yaml

systemctl stop datadog-agent || true
systemctl enable datadog-agent

# Do not ship build-time state in the image.
rm -rf /opt/datadog-agent/run/* /var/log/datadog/* || true

echo "--- datadog.yaml (api_key line) ---"
grep -E '^api_key:' /etc/datadog-agent/datadog.yaml | sed -E 's/([a-f0-9]{28})([a-f0-9]{4})/****\2/'
