# Lightweight launcher image — just needs Azure CLI to create/manage ACI container groups.
# Base pinned by tag + digest (#15). When updating the tag, refresh the digest:
#   docker buildx imagetools inspect debian:bookworm-slim
FROM debian:bookworm-slim@sha256:f9c6a2fd2ddbc23e336b6257a5245e31f996953ef06cd13a59fa0a1df2d5c252

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        jq && \
    rm -rf /var/lib/apt/lists/*

# TODO(#24): Microsoft does not publish a stable SHA256 for InstallAzureCLIDeb
# (the script is re-generated as the CLI is updated). We pin to a SHA captured
# at a known point in time and verify before execution; when the upstream
# script changes, the build fails loudly and a human updates
# AZCLI_INSTALLER_SHA256 after reviewing the diff. Consider mirroring a pinned
# copy to ACR.
# SHA captured 2026-04-22 from https://aka.ms/InstallAzureCLIDeb
ARG AZCLI_INSTALLER_SHA256=01fada4dafe903fa6edae138d3e3ca2e6e4295d7c8a35e48632bba4aa9dbe9d9
RUN curl -sSL https://aka.ms/InstallAzureCLIDeb -o /tmp/azure-cli-install.sh && \
    echo "${AZCLI_INSTALLER_SHA256}  /tmp/azure-cli-install.sh" | sha256sum -c - && \
    chmod +x /tmp/azure-cli-install.sh && \
    /tmp/azure-cli-install.sh && \
    rm -f /tmp/azure-cli-install.sh && \
    rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
