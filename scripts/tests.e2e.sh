#!/usr/bin/env bash
set -e

# e.g.,
# ./scripts/tests.e2e.sh 1.7.3
#
# to keep the cluster alive
# SHUTDOWN=false ./scripts/tests.e2e.sh 1.7.3
if ! [[ "$0" =~ scripts/tests.e2e.sh ]]; then
  echo "must be run from repository root"
  exit 255
fi

VERSION=$1
if [[ -z "${VERSION}" ]]; then
  echo "Missing version argument!"
  echo "Usage: ${0} [VERSION]" >> /dev/stderr
  exit 255
fi

SHUTDOWN=${SHUTDOWN:-true}
if [[ ${SHUTDOWN} == true ]]; then
  _SHUTDOWN_FLAG="--shutdown"
else
  _SHUTDOWN_FLAG=""
fi

# download avalanchego
# https://github.com/ava-labs/avalanchego/releases
GOARCH=$(go env GOARCH)
GOOS=$(go env GOOS)
DOWNLOAD_URL=https://github.com/ava-labs/avalanchego/releases/download/v${VERSION}/avalanchego-linux-${GOARCH}-v${VERSION}.tar.gz
DOWNLOAD_PATH=/tmp/avalanchego.tar.gz
if [[ ${GOOS} == "darwin" ]]; then
  DOWNLOAD_URL=https://github.com/ava-labs/avalanchego/releases/download/v${VERSION}/avalanchego-macos-v${VERSION}.zip
  DOWNLOAD_PATH=/tmp/avalanchego.zip
fi

rm -rf /tmp/avalanchego-v${VERSION}
rm -rf /tmp/avalanchego-build
rm -f ${DOWNLOAD_PATH}

echo "downloading avalanchego ${VERSION} at ${DOWNLOAD_URL}"
curl -L ${DOWNLOAD_URL} -o ${DOWNLOAD_PATH}

echo "extracting downloaded avalanchego"
if [[ ${GOOS} == "linux" ]]; then
  tar xzvf ${DOWNLOAD_PATH} -C /tmp
elif [[ ${GOOS} == "darwin" ]]; then
  unzip ${DOWNLOAD_PATH} -d /tmp/avalanchego-build
  mv /tmp/avalanchego-build/build /tmp/avalanchego-v${VERSION}
fi
find /tmp/avalanchego-v${VERSION}

echo "building runner"
pushd ./tests/runner
go build -v -o /tmp/subnet-cli.runner .
popd

echo "building e2e.test"
# to install the ginkgo binary (required for test build and run)
go install -v github.com/onsi/ginkgo/v2/ginkgo@v2.0.0
ACK_GINKGO_RC=true ginkgo build ./tests/e2e
./tests/e2e/e2e.test --help

# TODO: remove hard-coded "--whitelisted-subnets" once we have dynamic subnet whitelisting
echo "launch local test cluster in the background"
/tmp/subnet-cli.runner \
--avalanchego-path=/tmp/avalanchego-v${VERSION}/avalanchego \
--whitelisted-subnets="24tZhrm8j8GCJRE9PomW8FaeqbgGS4UAQjJnqqn8pq5NwYSYV1" \
--output-path=/tmp/avalanchego-v${VERSION}/output.yaml 2> /dev/null &
PID=${!}

sleep 60
echo "wait until local cluster is ready from PID ${PID}"
while [[ ! -s /tmp/avalanchego-v${VERSION}/output.yaml ]]
  do
  echo "waiting for /tmp/avalanchego-v${VERSION}/output.yaml creation"
  sleep 5
  # wait up to 5-minute
  ((c++)) && ((c==60)) && break
done

if [[ -f "/tmp/avalanchego-v${VERSION}/output.yaml" ]]; then
  echo "cluster is ready!"
  cat /tmp/avalanchego-v${VERSION}/output.yaml
else
  echo "cluster is not ready in time... terminating ${PID}"
  kill ${PID}
  exit 255
fi

echo "running e2e tests against the local cluster with shutdown flag '${_SHUTDOWN_FLAG}'"
./tests/e2e/e2e.test \
--ginkgo.v \
--cluster-info-path /tmp/avalanchego-v${VERSION}/output.yaml \
--log-level debug ${_SHUTDOWN_FLAG}

echo "ALL SUCCESS!"
