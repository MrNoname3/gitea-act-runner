# The job image the ubuntu-latest label runs: Ubuntu 26.04, as GitHub's own
# ubuntu-latest is, with what workflows expect to find there and nothing more.
# Node runs the JavaScript actions, which the runner executes with the job
# container's node; setup-python reads the release with lsb_release and installs
# into the tool cache; actions/cache compresses with zstd. Anything else a
# workflow needs it installs itself with apt-get, as root. A workflow that wants
# more in an image of its own builds it FROM this one, so the runners keep the
# layers below once. .github/workflows/job-image.yml builds and pushes it.

FROM docker.io/library/node:24.21.0-trixie-slim@sha256:173f125896c3b47ddf056734c7ea789d04595a6a08769a8f78e0df642781fb66 AS node

FROM docker.io/library/ubuntu:26.04@sha256:c098726dd9b9733f3e885f8de0ef375206a311b0a317eadc40d347b1115fb944
# scripts/cleanup.sh keeps the newest image carrying this label and removes the
# older untagged ones once no container uses them.
LABEL gitea-act-runner.job-image="true"
# upgrade: a rebuild also brings the base image's own packages up to date, not
# only the ones installed here.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl git jq lsb-release python3 python3-venv sudo unzip xz-utils zstd \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /opt/hostedtoolcache
COPY --from=node /usr/local/bin/node /usr/local/bin/node
ENV ImageOS=ubuntu26 AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache RUNNER_TOOL_CACHE=/opt/hostedtoolcache
