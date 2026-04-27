# Attribution: Docker pattern adapted from ethorneloe/azure-apps-jobs-github-runners (MIT)
# https://github.com/ethorneloe/azure-apps-jobs-github-runners
#
# Base image: GitHub official Actions runner, pinned by version tag and digest (#15).
# When bumping the version tag, also refresh the @sha256 digest:
#   docker buildx imagetools inspect ghcr.io/actions/actions-runner:<version>
# https://github.com/actions/runner/pkgs/container/actions-runner
FROM ghcr.io/actions/actions-runner:2.334.0@sha256:b6614fce332517f74d0a76e7c762fb08e4f2ff13dcf333183397c8a5725b6e8e

USER root

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        jq \
        lsb-release \
        openssl \
        software-properties-common \
        wget && \
    rm -rf /var/lib/apt/lists/*

# PowerShell 7 — used by workflows that run on this runner
RUN export VERSION_ID=$(grep VERSION_ID /etc/os-release | cut -d'=' -f2 | tr -d '"') && \
    wget -q "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb" && \
    dpkg -i packages-microsoft-prod.deb && \
    apt-get update && \
    apt-get install -y --no-install-recommends powershell && \
    rm -f packages-microsoft-prod.deb && \
    rm -rf /var/lib/apt/lists/*

# Azure CLI — available to workflows that run on this runner.
# Microsoft does not publish a stable SHA256 for InstallAzureCLIDeb (the script
# is re-generated as the CLI is updated). We pin to a SHA captured at a known
# point in time and verify before execution; when the upstream script changes,
# the build fails loudly and a human updates AZCLI_INSTALLER_SHA256 after
# reviewing the diff. Consider mirroring a pinned copy to ACR (#24).
# SHA captured 2026-04-22 from https://aka.ms/InstallAzureCLIDeb
ARG AZCLI_INSTALLER_SHA256=01fada4dafe903fa6edae138d3e3ca2e6e4295d7c8a35e48632bba4aa9dbe9d9
RUN curl -sSL https://aka.ms/InstallAzureCLIDeb -o /tmp/azure-cli-install.sh && \
    echo "${AZCLI_INSTALLER_SHA256}  /tmp/azure-cli-install.sh" | sha256sum -c - && \
    chmod +x /tmp/azure-cli-install.sh && \
    /tmp/azure-cli-install.sh && \
    rm -f /tmp/azure-cli-install.sh && \
    rm -rf /var/lib/apt/lists/*

# Python 3 + .NET SDK 8 (LTS) — required by the smoke test in
# .github/workflows/test-runners.yml. Microsoft's apt repo (packages-microsoft-prod)
# is already configured by the pwsh install step above, so dotnet-sdk-8.0 resolves
# cleanly here. Ubuntu 22.04 includes python3 in some variants but not always the
# `python3` symlink, so install explicitly plus pip.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv \
        dotnet-sdk-8.0 && \
    rm -rf /var/lib/apt/lists/*

# Node.js LTS via NodeSource — declarative setup. We deliberately do NOT run
# NodeSource's `setup_lts.x` bootstrap script: that script executes as root
# before any signature check and fetches its own signing key from the same
# origin, so a compromise of deb.nodesource.com would let an attacker run
# arbitrary code at image build time. Instead we:
#   1. Download the GPG key over TLS
#   2. Verify its fingerprint matches the pinned value (fail build if not)
#   3. Install the key to /etc/apt/keyrings
#   4. Write the APT source entry ourselves with signed-by=<key>
#   5. apt-get install nodejs — apt verifies package signatures against the key
# Pinned fingerprint = NodeSource LTS signing key as of 2026-04-22.
# If NodeSource rotates the key, this build fails loudly and a human reviews.
ARG NODESOURCE_KEY_FPR="6F71F525282841EEDAF851B42F59B5F99B1BE0B4"
ARG NODESOURCE_NODE_MAJOR="22"
RUN set -eux; \
    mkdir -p /etc/apt/keyrings; \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key -o /tmp/nodesource.asc; \
    GNUPGHOME="$(mktemp -d)"; export GNUPGHOME; \
    KEYRING="$GNUPGHOME/import.gpg"; \
    gpg --batch --no-default-keyring --keyring "$KEYRING" --import /tmp/nodesource.asc; \
    COLONS="$(gpg --batch --no-default-keyring --keyring "$KEYRING" --list-keys --with-colons --with-fingerprint)"; \
    PUB_COUNT="$(printf '%s\n' "$COLONS" | awk -F: '/^pub:/ {c++} END {print c+0}')"; \
    if [ "$PUB_COUNT" -ne 1 ]; then \
        echo "NodeSource key bundle contains $PUB_COUNT primary keys, expected exactly 1"; \
        printf '%s\n' "$COLONS"; \
        exit 1; \
    fi; \
    ACTUAL_FPR="$(printf '%s\n' "$COLONS" | awk -F: 'f{if($1=="fpr"){print $10;exit}} /^pub:/ {f=1}')"; \
    if [ "$ACTUAL_FPR" != "$NODESOURCE_KEY_FPR" ]; then \
        echo "NodeSource GPG fingerprint mismatch: got $ACTUAL_FPR, expected $NODESOURCE_KEY_FPR"; \
        exit 1; \
    fi; \
    gpg --batch --no-default-keyring --keyring "$KEYRING" --export "$NODESOURCE_KEY_FPR" > /etc/apt/keyrings/nodesource.gpg; \
    test -s /etc/apt/keyrings/nodesource.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODESOURCE_NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list; \
    rm -f /tmp/nodesource.asc; \
    rm -rf "$GNUPGHOME"; unset GNUPGHOME; \
    apt-get update; \
    apt-get install -y --no-install-recommends nodejs; \
    rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh ./entrypoint.sh
RUN chmod +x ./entrypoint.sh

USER runner

ENTRYPOINT ["./entrypoint.sh"]
