#!/bin/bash
# Install a pinned Datadog Agent from the official RPM repo, without an API key.
# The official install script needs DD_API_KEY, so we add the repo ourselves.
set -euo pipefail

cat > /etc/yum.repos.d/datadog.repo <<'REPO'
[datadog]
name=Datadog, Inc.
baseurl=https://yum.datadoghq.com/stable/7/x86_64/
enabled=1
gpgcheck=1
repo_gpgcheck=1
priority=1
gpgkey=https://keys.datadoghq.com/DATADOG_RPM_KEY_CURRENT.public
       https://keys.datadoghq.com/DATADOG_RPM_KEY_4F09D16B.public
       https://keys.datadoghq.com/DATADOG_RPM_KEY_B01082D3.public
REPO

dnf -y install "datadog-agent-${AGENT_VERSION}"
datadog-agent version
