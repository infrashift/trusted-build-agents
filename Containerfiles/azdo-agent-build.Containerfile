# The Azure DevOps BUILD agent.
#
# Runs pipeline jobs that turn a repository into an OCI image with kaniko, or a
# devcontainer.json into an image with envbuilder. It carries NO registry client
# and NO credential, and that is the whole design: kaniko is perfectly capable of
# pushing -- that is what --destination is for -- and the task holding
# repository-supplied YAML must never be the task that can. The absent skopeo is
# the device; the --no-push flag is only the discipline.
#
# Three stages:
#
#   gotools  -- kaniko-executor and envbuilder, from pinned COMMITS. The image
#               Go must be >= 1.26.5: kaniko's go.mod names `toolchain go1.26.5'
#               and module mode ENFORCES it. The pinned toolchain ships 1.26.7.
#
#   agent    -- the Microsoft agent tarball. It is .NET/Node and is not built
#               from source, so the release sha256 IS the pin and is verified
#               before anything is unpacked.
#
#   runtime  -- our trusted ubi9-minimal. NOT ubi9-micro, which the sibling
#               service-container repo uses: the agent needs a package manager,
#               git and libicu, and micro has none of them. ubi9-minimal already
#               ships /etc/pki/ca-trust, so there is no CA-donor stage here --
#               the bundle is asserted in place instead.
#
# scripts/lint-containerfiles.sh enforces the invariants.

ARG UPSTREAM_BASE
ARG UPSTREAM_DIGEST
ARG TOOLCHAIN_BASE
ARG TOOLCHAIN_DIGEST

########################  gotools  ########################
FROM ${TOOLCHAIN_BASE}@${TOOLCHAIN_DIGEST} AS gotools

ARG KANIKO_URL
ARG KANIKO_COMMIT
ARG KANIKO_REF
ARG ENVBUILDER_URL
ARG ENVBUILDER_COMMIT
ARG ENVBUILDER_REF
ARG TARGETARCH

ENV CGO_ENABLED=0 \
    GOOS=linux \
    GOTOOLCHAIN=local

# A COMMIT, never a tag or a branch: a tag can be moved and a commit cannot. The
# rev-parse assertion is what makes that a check rather than a hope -- a shallow
# fetch of a moved tag would otherwise succeed quietly.
RUN set -euo pipefail; \
    git init -q /src/kaniko; \
    git -C /src/kaniko remote add origin "${KANIKO_URL}"; \
    git -C /src/kaniko fetch -q --depth 1 origin "${KANIKO_COMMIT}"; \
    git -C /src/kaniko checkout -q FETCH_HEAD; \
    test "$(git -C /src/kaniko rev-parse HEAD)" = "${KANIKO_COMMIT}"

RUN set -euo pipefail; \
    git init -q /src/envbuilder; \
    git -C /src/envbuilder remote add origin "${ENVBUILDER_URL}"; \
    git -C /src/envbuilder fetch -q --depth 1 origin "${ENVBUILDER_COMMIT}"; \
    git -C /src/envbuilder checkout -q FETCH_HEAD; \
    test "$(git -C /src/envbuilder rev-parse HEAD)" = "${ENVBUILDER_COMMIT}"

# The -X ldflag is load-bearing: without it kaniko reports its version as
# "unknown" and the provenance label below says nothing.
RUN set -euo pipefail; \
    cd /src/kaniko; \
    GOARCH="${TARGETARCH}" go build -trimpath \
      -ldflags="-s -w -X 'github.com/osscontainertools/kaniko/pkg/version.version=${KANIKO_REF}'" \
      -o /out/kaniko-executor ./cmd/executor; \
    /out/kaniko-executor version

# envbuilder does NOT link the kaniko built above. Its go.mod carries
# `replace github.com/GoogleContainerTools/kaniko => github.com/coder/kaniko',
# so the standalone executor and envbuilder's embedded builder are two different
# kanikos and always will be. Recorded in versions.json and in the label below so
# the difference is a documented fact rather than a silent surprise.
RUN set -euo pipefail; \
    cd /src/envbuilder; \
    GOARCH="${TARGETARCH}" go build -trimpath \
      -ldflags="-s -w -X 'github.com/coder/envbuilder/buildinfo.tag=${ENVBUILDER_REF}'" \
      -o /out/envbuilder ./cmd/envbuilder; \
    /out/envbuilder --help >/dev/null

########################  agent  ##########################
FROM ${TOOLCHAIN_BASE}@${TOOLCHAIN_DIGEST} AS agent

ARG AGENT_URL
ARG AGENT_SHA256

# sha256sum -c BEFORE tar, not after. An archive that fails its hash must never
# have been unpacked, because the failure mode of unpacking first is a tree that
# looks right and came from somewhere else.
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

# Re-declared after FROM. ARGs before the first FROM are global build args and
# are NOT in scope inside a build stage, so the LABELs below would silently
# expand to empty strings. This is a real bug the sibling repos had to fix and
# the policy's BUILD_LABEL_EMPTY rule exists to catch it.
ARG UPSTREAM_BASE
ARG UPSTREAM_DIGEST
ARG TOOLCHAIN_BASE
ARG TOOLCHAIN_DIGEST
ARG SOURCE_URL
ARG KANIKO_COMMIT
ARG ENVBUILDER_COMMIT
ARG AGENT_VERSION
ARG IMAGE_VERSION
ARG BUILD_DATE
ARG TARGETARCH
ARG GIT_COMMIT

# The first five are REQUIRED by .github/pdp/policies.rego.
LABEL org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.version="${AGENT_VERSION}" \
      io.infrashift.image.upstream.digest="${UPSTREAM_DIGEST}" \
      io.infrashift.image.upstream.source="${UPSTREAM_BASE}" \
      org.opencontainers.image.title="Trusted Azure DevOps Build Agent" \
      org.opencontainers.image.description="Ephemeral Azure Pipelines agent carrying kaniko and envbuilder, and no registry client" \
      org.opencontainers.image.maintainer="Ryan Craig <ryan.craig@infrashift.io>" \
      org.opencontainers.image.vendor="Infrashift" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.architecture="${TARGETARCH}" \
      io.infrashift.image.variant="ubi9-minimal" \
      io.infrashift.build.recipe.revision="${GIT_COMMIT}" \
      io.infrashift.build.toolchain="${TOOLCHAIN_BASE}@${TOOLCHAIN_DIGEST}" \
      io.infrashift.agent.pool="Trusted-Build" \
      io.infrashift.tool.kaniko.commit="${KANIKO_COMMIT}" \
      io.infrashift.tool.envbuilder.commit="${ENVBUILDER_COMMIT}" \
      io.openshift.tags="azure-devops,agent,kaniko,envbuilder,ubi9,vetted"

USER root

# lttng-ust is deliberately NOT installed. Microsoft's installdependencies.sh
# lists it, but it lives in CRB/EPEL rather than the ubi9 base repos and .NET
# needs it only when tracing is enabled. Adding a repository to reach an
# optional package would widen the image's input set for nothing.
RUN set -euo pipefail; \
    microdnf install -y --nodocs --setopt=install_weak_deps=0 \
      git-core tar gzip findutils which procps-ng \
      libicu krb5-libs openssl-libs zlib; \
    microdnf clean all; \
    rm -rf /var/cache/yum /var/cache/dnf

COPY --from=gotools /out/kaniko-executor /usr/bin/kaniko-executor
COPY --from=gotools /out/envbuilder      /usr/bin/envbuilder
COPY --from=agent   /out/agent           /opt/azdo-agent
COPY rootfs/common/usr/local/bin/           /usr/local/bin/
COPY rootfs/azdo-agent-build/usr/local/bin/ /usr/local/bin/

# ubi9-minimal has microdnf but no shadow-utils, so the passwd entry is appended
# rather than created with useradd. Without a UID 1001 entry, os/user lookups
# return "unknown userid" and $HOME is undefined -- which surfaces from kaniko as
# `unable to resolve HOME directory: user: unknown userid 0', an error about HOME
# that is really about NSS.
#
# GID 0 plus `chmod g=u' keeps the image usable under OpenShift's arbitrary-UID
# SCC, which runs the container as a random UID in group 0.
#
# There is deliberately NO /kaniko-executor symlink here. kaniko derives its
# working directory from proc/self/exe and adds that directory to its ignore
# list, so an executor answering at the filesystem ROOT makes kaniko ignore
# everything and emit empty layers. kaniko-chroot.sh stages it at
# /kaniko/executor inside the chroot instead. See docs/kaniko-chroot.md.
RUN set -euo pipefail; \
    test -s /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem; \
    test "$(stat -c %s /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem)" -gt 100000; \
    printf 'agent:x:1001:0:Trusted Azure DevOps agent service account:/home/agent:/bin/bash\n' >> /etc/passwd; \
    mkdir -p /home/agent /azp/work /azp/kaniko /azp/layercache; \
    chmod 0755 /usr/local/bin/*.sh; \
    chown -R 1001:0 /home/agent /azp /opt/azdo-agent; \
    chmod -R g=u /home/agent /azp /opt/azdo-agent

# HOME is exported here as well as in start-agent.sh. Belt and braces on purpose:
# the entrypoint can be overridden by a jobspec, and every failure this prevents
# reads as an error about something other than HOME.
ENV HOME=/home/agent \
    AGENT_ALLOW_RUNASROOT=1 \
    AZP_WORK=/azp/work \
    SFD_KANIKO_ROOT=/azp/kaniko \
    ENVBUILDER_LAYER_CACHE_DIR=/azp/layercache \
    SSL_CERT_FILE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem \
    TZ=UTC

WORKDIR /opt/azdo-agent

ENTRYPOINT ["/usr/local/bin/start-agent.sh"]

USER 1001
