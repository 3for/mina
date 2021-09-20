#!/bin/bash

# Author's Note: Because the structure of this repo is inconsistent (Dockerfiles and build contexts placed willy-nilly)
# we have to trustlist and configure image builds individually because each one is going to be slightly different.
# This is needed as opposed to trusting the structure of the each project to be consistent for every deployable.

set -eo pipefail
set +x

CLEAR='\033[0m'
RED='\033[0;31m'
# Array of valid service names
VALID_SERVICES=('mina-archive', 'mina-daemon' 'mina-rosetta' 'mina-rosetta-ubuntu' 'mina-toolchain' 'bot' 'leaderboard')

function usage() {
  if [[ -n "$1" ]]; then
    echo -e "${RED}☞  $1${CLEAR}\n";
  fi
  echo "Usage: $0 [-s service-to-release] [-v service-version] [-n network]"
  echo "  -s, --service             The Service being released to Dockerhub"
  echo "  -v, --version             The version to be used in the docker image tag"
  echo "  -n, --network             The network configuration to use (devnet or mainnet). Default=devnet"
  echo "      --deb-codename        The debian codename (stretch or buster) to build the docker image from. Default=stretch"
  echo "      --deb-release         The debian package release channel to pull from (unstable,alpha,beta,stable). Default=unstable"
  echo "      --deb-version         The version string for the debian package to install"
  echo ""
  echo "Example: $0 --service faucet --version v0.1.0"
  echo "Valid Services: ${VALID_SERVICES[*]}"
  exit 1
}

while [[ "$#" -gt 0 ]]; do case $1 in
  --no-upload) NOUPLOAD=1;;
  -s|--service) SERVICE="$2"; shift;;
  -v|--version) VERSION="$2"; shift;;
  -n|--network) NETWORK="--build-arg network=$2"; shift;;
  -c|--cache-from) CACHE="--cache-from $2"; shift;;
  --deb-codename) DEB_CODENAME="--build-arg deb_codename=$2"; shift;;
  --deb-release) DEB_RELEASE="--build-arg deb_release=$2"; shift;;
  --deb-version) DEB_VERSION="--build-arg deb_version=$2"; shift;;
  --extra-args) EXTRA=${@:2}; shift $((${#}-1));;
  *) echo "Unknown parameter passed: $1"; exit 1;;
esac; shift; done

# Debug prints for visability
echo 'service="'${SERVICE}'" version="'${VERSION}'" deb_version="'${DEB_VERSION}'" deb_release="'${DEB_RELEASE}' "deb_codename="'${DEB_CODENAME}'" '
echo ${EXTRA}

# Verify Required Parameters are Present
if [[ -z "$SERVICE" ]]; then usage "Service is not set!"; fi;
if [[ -z "$VERSION" ]]; then usage "Version is not set!"; fi;
if [[ -z "$EXTRA" ]]; then EXTRA=""; fi;
if [[ $(echo ${VALID_SERVICES[@]} | grep -o "$SERVICE" - | wc -w) -eq 0 ]]; then usage "Invalid service!"; fi

case "${SERVICE}" in
mina-archive)
  DOCKERFILE_PATH="dockerfiles/Dockerfile-mina-archive"
  DOCKER_CONTEXT="dockerfiles/"
  ;;
bot)
  DOCKERFILE_PATH="frontend/bot/Dockerfile"
  DOCKER_CONTEXT="frontend/bot"
  ;;
mina-daemon)
  DOCKERFILE_PATH="dockerfiles/Dockerfile-mina-daemon"
  DOCKER_CONTEXT="dockerfiles/"
  ;;
mina-toolchain)
  DOCKERFILE_PATH="dockerfiles/stages/1-build-deps dockerfiles/stages/2-toolchain dockerfiles/stages/3-opam-deps"
  ;;
mina-rosetta)
  DOCKERFILE_PATH="dockerfiles/stages/1-build-deps dockerfiles/stages/2-toolchain dockerfiles/stages/3-opam-deps dockerfiles/stages/4-builder dockerfiles/stages/5-production"
  ;;
mina-rosetta-ubuntu)
  DOCKERFILE_PATH="dockerfiles/stages/1-build-deps dockerfiles/stages/2-toolchain dockerfiles/stages/3-opam-deps dockerfiles/stages/4-builder dockerfiles/stages/5-prod-ubuntu"
  ;;
leaderboard)
  DOCKERFILE_PATH="frontend/leaderboard/Dockerfile"
  DOCKER_CONTEXT="frontend/leaderboard"
  ;;
*)
esac


if [[ -z "${BUILDKITE_PULL_REQUEST_REPO}" ]]; then
  REPO="--build-arg MINA_REPO=https://github.com/MinaProtocol/mina"
else
  REPO="--build-arg MINA_REPO=${BUILDKITE_PULL_REQUEST_REPO}"
fi

# If DOCKER_CONTEXT is not specified, assume none and just pipe the dockerfile into docker build
extra_build_args=$(echo ${EXTRA} | tr -d '"')
if [[ -z "${DOCKER_CONTEXT}" ]]; then
  cat $DOCKERFILE_PATH | docker build $CACHE $NETWORK $DEB_CODENAME $DEB_RELEASE $DEB_VERSION $REPO $extra_build_args -t gcr.io/o1labs-192920/$SERVICE:$VERSION -
else
  docker build $CACHE $NETWORK $DEB_CODENAME $DEB_RELEASE $DEB_VERSION $extra_build_args $REPO $DOCKER_CONTEXT -t gcr.io/o1labs-192920/$SERVICE:$VERSION -f $DOCKERFILE_PATH
fi

tag-and-push() {
  docker tag "gcr.io/o1labs-192920/$SERVICE:$VERSION" "$1"
  docker push "$1"
}

if [[ -z "$NOUPLOAD" ]] || [[ "$NOUPLOAD" -eq 0 ]]; then
  tag-and-push "minaprotocol/$SERVICE:$VERSION"
  docker push "gcr.io/o1labs-192920/$SERVICE:$VERSION"
fi
