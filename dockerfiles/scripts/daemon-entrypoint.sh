#!/bin/bash

set -euo pipefail

# If glob doesn't match anything, return empty string rather than literal pattern
shopt -s nullglob

INPUT_ARGS="$@"

# stderr is mostly used to print "reading password from environment varible ..."
# prover and verifier logs are also sparse, mostly memory stats and debug info
# mina-best-tip.log is useful for organizing a hard fork and is one way to monitor new blocks as they are added, but not critical
declare -a VERBOSE_LOG_FILES=('mina-stderr.log' '.mina-config/mina-prover.log' '.mina-config/mina-verifier.log' '.mina-config/mina-best-tip.log')

EXTRA_FLAGS=""

# Attempt to execute or source custom entrypoint scripts accordingly
# Example: mount a mina-env file with variable evironment variables to source and pass to the daemon
for script in /entrypoint.d/*; do
  if [ -x "$script" ]; then
    "$script" $INPUT_ARGS
  else
    source "$script"
  fi
done

set +u # allow these variables to be unset
# Support flags from .mina-env on debian
if [[ ${PEER_LIST_URL} ]]; then
  EXTRA_FLAGS+=" --peer-list-url ${PEER_LIST_URL}"
fi
if [[ ${LOG_LEVEL} ]]; then
  EXTRA_FLAGS+=" --log-level ${LOG_LEVEL}"
fi
if [[ ${FILE_LOG_LEVEL} ]]; then
  EXTRA_FLAGS+=" --file-log-level ${FILE_LOG_LEVEL}"
fi

# If VERBOSE=true then print daemon flags
if [[ ${VERBOSE} ]]; then
  # Print the flags to the daemon for debugging use
  echo "[Debug] Input Args: ${INPUT_ARGS}"
  echo "[Debug] Extra Flags: ${EXTRA_FLAGS}"
fi

set -u

# Mina daemon initialization
mkdir -p .mina-config
# Create all of the log files that we will tail later
touch "${LOG_FILES[@]}"

set +e # Allow remaining commands to fail without exiting early
rm -f .mina-config/.mina-lock
mina $INPUT_ARGS $EXTRA_FLAGS 2>mina-stderr.log
echo "Mina process exited with status code $?"

# TODO: would a specified directory of "post-failure" scripts make sense here?
# Something like `mina client export-local-logs > ~/.mina-config/log-exports/blah`

# TODO: have a better way to intersperse log files like we used to, without infinite disk use
# For now, tail the last 20 lines of the verbose log files when the node shuts down
if [[ ${VERBOSE} ]]; then
  tail -n 20 "${VERBOSE_LOG_FILES[@]}"
fi

sleep 15 # to allow all mina proccesses to quit, cleanup, and finish logging
