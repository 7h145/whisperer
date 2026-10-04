#!/bin/bash
# vim:et:ai:sw=2:tw=0:ft=bash
# copyright 2026 <github.attic@typedef.net>, MIT

# default
#WHISPER_REPO='https://github.com/ggml-org/whisper.cpp'

# default
#WHISPER_REF='master'
WHISPER_REF='v1.9.4'

IMAGE='whisper.cpp'

cleanup() {
  podman builder prune		# remove cache mounts/build cache
  podman image prune		# remove untagged/intermediate layers
}

# treat the first non-option positional parameter as $WHISPER_REF
[[ -n "${1}" && "${1:0:1}" != '-' ]] && {
  WHISPER_REF="${1}"; shift
  echo "using WHISPER_REF='${WHISPER_REF}'" >&2
}

declare -a TAGS
#TAGS+=( 'latest-cuda' )
TAGS+=( "${WHISPER_REF}-sdl-cuda" )

unset ARGV; declare -a ARGV
[[ -n "${WHISPER_REPO}" ]] &&
  ARGV+=( '--build-arg' "WHISPER_REPO=${WHISPER_REPO}" )
[[ -n "${WHISPER_REF}" ]] &&
  ARGV+=( '--build-arg' "WHISPER_REF=${WHISPER_REF}" )

ARGV+=(
  '--target=runtime'		# build the 'runtime' stage
)

[ -n "${IMAGE}" ] && {
  for TAG in "${TAGS[@]:-latest}"; do
    ARGV+=( '-t' "${IMAGE}:${TAG}" )
  done
}

# debug
echo podman build ${ARGV:+"${ARGV[@]}"} "${@}" "${0%/*}" >&2

podman build ${ARGV:+"${ARGV[@]}"} "${@}" "${0%/*}"

#cleanup

