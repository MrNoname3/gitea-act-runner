# The job image the ubuntu-latest label runs: Ubuntu 26.04, as GitHub's own
# ubuntu-latest is, with what workflows expect to find there and nothing more.
# Node runs the JavaScript actions, which the runner executes with the job
# container's node; setup-python reads the release with lsb_release and installs
# into the tool cache; actions/cache compresses with zstd. Anything else a
# workflow needs it installs itself with apt-get, as root. A workflow that wants
# more in an image of its own builds it FROM this one, so the runners keep the
# layers below once. .github/workflows/job-image.yml builds and pushes it.

FROM docker.io/library/node:24.22.2-trixie-slim@sha256:54f84b4cf8432b21aaffd5d3ce8d41e12cea0d10d33c09d2f3c9879d49d6b446 AS node

FROM docker.io/library/ubuntu:26.04@sha256:6a06111c3b0a8600feadb270aec771dc239bf407b25625f93f44ab00e11f4d3c
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
