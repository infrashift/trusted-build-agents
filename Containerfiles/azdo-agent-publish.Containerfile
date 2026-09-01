# The Azure DevOps PUBLISH agent.
#
# The other half of the split. It holds the Nexus OCI credential and pushes what
# the build pool staged, and it carries no kaniko, no envbuilder and no compiler:
# IT CANNOT AUTHOR WHAT IT MOVES. The build agent names skopeo in its forbidden
# list and this one names kaniko in its; image-contract.json asserts both against
# the bytes of the built images.
#
# Three stages:
#
#   gotools  -- the distribution registry, from a pinned COMMIT. It exists here
#               for one job: envbuilder writes its output as a distribution
#               FILESYSTEM layout, which skopeo cannot read directly, so this
#               re-serves that directory on 127.0.0.1 for the length of one
#               copy. See docs/envbuilder-output.md for why there is no simpler
#               path.
#
#   agent    -- the Microsoft agent tarball, verified by sha256 before unpacking.
#
#   runtime  -- our trusted ubi9-minimal, plus skopeo from the ubi9 repos.
#
# scripts/lint-containerfiles.sh enforces the invariants.

ARG UPSTREAM_BASE
ARG UPSTREAM_DIGEST
ARG TOOLCHAIN_BASE
ARG TOOLCHAIN_DIGEST

########################  gotools  ########################
FROM ${TOOLCHAIN_BASE}@${TOOLCHAIN_DIGEST} AS gotools

ARG DISTRIBUTION_URL
ARG DISTRIBUTION_COMMIT
ARG DISTRIBUTION_REF
ARG TARGETARCH

ENV CGO_ENABLED=0 \
    GOOS=linux \
    GOTOOLCHAIN=local

# A COMMIT, never a tag or a branch: a tag can be moved and a commit cannot.
RUN set -euo pipefail; \
    git init -q /src/distribution; \
    git -C /src/distribution remote add origin "${DISTRIBUTION_URL}"; \
    git -C /src/distribution fetch -q --depth 1 origin "${DISTRIBUTION_COMMIT}"; \
    git -C /src/distribution checkout -q FETCH_HEAD; \
    test "$(git -C /src/distribution rev-parse HEAD)" = "${DISTRIBUTION_COMMIT}"

RUN set -euo pipefail; \
    cd /src/distribution; \
    GOARCH="${TARGETARCH}" go build -trimpath \
      -ldflags="-s -w -X 'github.com/distribution/distribution/v3/version.revision=${DISTRIBUTION_COMMIT}'" \
      -o /out/registry ./cmd/registry; \
    /out/registry --version

########################  agent  ##########################
FROM ${TOOLCHAIN_BASE}@${TOOLCHAIN_DIGEST} AS agent

ARG AGENT_URL
ARG AGENT_SHA256

RUN set -euo pipefail; \
    curl -fsSL --retry 3 -o /tmp/agent.tar.gz "${AGENT_URL}"; \
    echo "${AGENT_SHA256}  /tmp/agent.tar.gz" | sha256sum -c -; \
    mkdir -p /out/agent; \
    tar -C /out/agent -xzf /tmp/agent.tar.gz; \
    rm -f /tmp/agent.tar.gz; \
    test -x /out/agent/config.sh; \
    test -x /out/agent/run.sh

########################  runtime  ########################
FROM ${UPSTREAM_BASE}@${UPSTREAM_DIGEST}

# Re-declared after FROM; see the note in azdo-agent-build.Containerfile.
ARG UPSTREAM_BASE
ARG UPSTREAM_DIGEST
ARG TOOLCHAIN_BASE
ARG TOOLCHAIN_DIGEST
ARG SOURCE_URL
ARG DISTRIBUTION_COMMIT
ARG AGENT_VERSION
ARG IMAGE_VERSION
ARG BUILD_DATE
ARG TARGETARCH
ARG GIT_COMMIT

LABEL org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.version="${AGENT_VERSION}" \
      io.infrashift.image.upstream.digest="${UPSTREAM_DIGEST}" \
      io.infrashift.image.upstream.source="${UPSTREAM_BASE}" \
      org.opencontainers.image.title="Trusted Azure DevOps Publish Agent" \
      org.opencontainers.image.description="Ephemeral Azure Pipelines agent carrying skopeo, and no tool that can author an image" \
      org.opencontainers.image.maintainer="Ryan Craig <ryan.craig@infrashift.io>" \
      org.opencontainers.image.vendor="Infrashift" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.architecture="${TARGETARCH}" \
      io.infrashift.image.variant="ubi9-minimal" \
      io.infrashift.build.recipe.revision="${GIT_COMMIT}" \
      io.infrashift.build.toolchain="${TOOLCHAIN_BASE}@${TOOLCHAIN_DIGEST}" \
      io.infrashift.agent.pool="Trusted-Publish" \
      io.infrashift.tool.distribution.commit="${DISTRIBUTION_COMMIT}" \
      io.openshift.tags="azure-devops,agent,skopeo,publish,ubi9,vetted"

USER root

RUN set -euo pipefail; \
    microdnf install -y --nodocs --setopt=install_weak_deps=0 \
      git-core tar gzip findutils which procps-ng skopeo \
      libicu krb5-libs openssl-libs zlib; \
    microdnf clean all; \
    rm -rf /var/cache/yum /var/cache/dnf

COPY --from=gotools /out/registry /usr/bin/registry
COPY --from=agent   /out/agent    /opt/azdo-agent
COPY rootfs/common/usr/local/bin/             /usr/local/bin/
COPY rootfs/azdo-agent-publish/usr/local/bin/ /usr/local/bin/

# THE CONTRACT, ASSERTED IN THE IMAGE ITSELF. microdnf resolves a dependency
# CLOSURE, so "this image cannot author an image" is true only until something
# drags a builder in as a transitive dependency of something else. Failing here
# costs seconds; finding out after a push to an ALLOW_ONCE registry costs the
# name permanently.
RUN set -euo pipefail; \
    test -s /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem; \
    test "$(stat -c %s /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem)" -gt 100000; \
    command -v skopeo; command -v registry; \
    ! command -v kaniko-executor; \
    ! command -v envbuilder; \
    ! command -v cosign; \
    ! command -v go; \
    ! command -v gcc; \
    printf 'agent:x:1001:0:Trusted Azure DevOps agent service account:/home/agent:/bin/bash\n' >> /etc/passwd; \
    mkdir -p /home/agent /azp/work /azp/serve; \
    chmod 0755 /usr/local/bin/*.sh; \
    chown -R 1001:0 /home/agent /azp /opt/azdo-agent; \
    chmod -R g=u /home/agent /azp /opt/azdo-agent

ENV HOME=/home/agent \
    AGENT_ALLOW_RUNASROOT=1 \
    AZP_WORK=/azp/work \
    SSL_CERT_FILE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem \
    TZ=UTC

WORKDIR /opt/azdo-agent

ENTRYPOINT ["/usr/local/bin/start-agent.sh"]

USER 1001
