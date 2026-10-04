#!/bin/bash
# vim:et:ai:sw=2:tw=0:ft=bash
#
# whisper.sh - whisper.cpp `whisper-server` container wrapper
# copyright 2026, thias <github.attic@typedef.net>, MIT
#
# This is a thin podman wrapper around `whisper-server` from whisper.cpp
# with some additional support for cli, stream, and downloading models.
#
# At first startup, download the models:
#
#   whisper.sh download-ggml-model medium
#   whisper.sh download-vad-model silero-v6.2.0
#
# The models are stored in a 'whisper.models' volume.  After that just
#
#   whisper.sh
#
# to start the whisper.cpp `whisper-server` "OpenAI like" on
#
#   http://localhost:51149/v1/audio/transcriptions
#
# See:
# * https://github.com/ggml-org/whisper.cpp

#set -vx; set -o functrace

IAM="${0##*/}"

usage() {
   cat <<EOF
usage: ${IAM} [COMMAND [ARG...]]

commands:
  server              start whisper-server (default)
  stream              start whisper-stream (needs custom container)
  cli [ARG...]        run whisper-cli with \$PWD mounted at /stage
  ggml MODEL          download a speech model
  vad MODEL           download a VAD model
  help                show this help
EOF
}

# defaults: speech model
#DEFAULT_MODEL='/models/ggml-small.bin'
DEFAULT_MODEL='/models/ggml-medium.bin'

# defaults: VAD model for voice/silence detection
DEFAULT_VAD='/models/ggml-silero-v6.2.0.bin'

# defaults: whisper-server port, arbitrary
DEFAULT_PORT='51149'

# default container image
IMAGE='ghcr.io/ggml-org/whisper.cpp:main-vulkan'
#IMAGE='ghcr.io/ggml-org/whisper.cpp:main-cuda'

# If available, use the most recently created local copy of an official
# whisper.cpp main-* image.
mapfile -t OFFICIALIMAGES < <(
  podman images --sort=created --format '{{.Repository}}:{{.Tag}}' |
    grep -E '^ghcr\.io/ggml-org/whisper\.cpp:main-.*$'
)

(( ${#OFFICIALIMAGES[@]} )) && IMAGE="${OFFICIALIMAGES[0]}"

# As of whisper.cpp v1.9.4 (2026-10-04), `whisper-stream` is not usable from
# the official CUDA container image because its runtime stage does not ship
# the required SDL2 library. To use `whisper-stream`, build the local variant
# with SDL2 support from ./Containerfile instead.
#IMAGE='localhost/whisper.cpp:v1.9.4-sdl-cuda'

# If available, prefer the most recently created local SDL/CUDA build.
mapfile -t LOCALIMAGES < <(
  podman images --sort=created --format '{{.Repository}}:{{.Tag}}' |
    grep -E '^localhost/whisper\.cpp:.*-sdl-cuda$'
)

(( ${#LOCALIMAGES[@]} )) && IMAGE="${LOCALIMAGES[0]}"

# container name
CNAME='whisper'

PMARGS_VOLUMES=(
  '--volume' "${CNAME}.models:/models"
)

PMARGS_MISC=(
  #'--interactive' '--tty'
  #'--detach'
  #'--replace'
  '--rm'
  #'--cpus=2' #'--memory=256m'
)

case "${IMAGE}" in
  *'-vulkan')
    # vulkan device access
    [[ -d '/dev/dri' ]] &&
      PMARGS_DEVICES+=( '--device' '/dev/dri' ) ;;
  *'-cuda')
    # cuda device access
    [[ -f '/etc/cdi/nvidia.yaml' ]] &&
      PMARGS_DEVICES+=( '--device' 'nvidia.com/gpu=all' ) ;;
esac

# timezone
[[ -r '/etc/timezone' ]] && PMARGS_ENV+=( '--env' "TZ=$(</etc/timezone)" )

# commandline arguments for the container payload

ENTRYPOINT_SERVER='/app/build/bin/whisper-server'
ENTRYPOINT_STREAM='/app/build/bin/whisper-stream'
ENTRYPOINT_CLI='/app/build/bin/whisper-cli'
ENTRYPOINT_DOWNLOAD_GGML='/app/models/download-ggml-model.sh'
ENTRYPOINT_DOWNLOAD_VAD='/app/models/download-vad-model.sh'

PMARGS_PUBLISH_SERVER=(
  # whisper.cpp whisper-server runs on 8080/tcp by default

  #'--publish' "${DEFAULT_PORT}:8080"
  '--publish' "127.0.0.1:${DEFAULT_PORT}:8080"
)

CMDARGV_SERVER=(
  '--host' '0.0.0.0'
  # mimic OpenAI API endpoint path, whisper.cpp default is /inference
  '--inference-path' '/v1/audio/transcriptions'
  '--convert'
  '--model' "${DEFAULT_MODEL}"
  '--vad' '--vad-model' "${DEFAULT_VAD}"
)

CMDARGV_STREAM=(
  '--model' "${DEFAULT_MODEL}"
  '--step' '0'				# default is 1
  #'--step' '300'           # abstract art, for recreational purposes
  #'--length' '30000'		# default is 30000
  '--threads' '8'			# default is 6
  #'--vad-thold' '0.6'		# default is 0.6
  '--language' 'auto'		# default is "en"
  '--max-tokens' '64'		# default is 32

  # use '-f transcript.txt' in $* instead
  #'--file' 'transcript.txt'

  # speaker turn detection requires a '-tdrz' model.  The only one in
  # whisper.cpp-s current model set is 'ggml-small.en-tdrz.bin'.
  # Unfortunately, "small" and "en" (only) is not worth the trouble.
  #'--tinydiarize'
)


[[ -n "${1}" ]] && { COMMAND="${1}"; shift; }
case "${COMMAND:-server}" in
  '-h'|'--help'|'help')
    usage; echo; exit
  ;;

  'server')
    PMARGS_MISC+=( '--name' "${CNAME:-whisper}-server" '--replace' )
    declare -n ENTRYPOINT='ENTRYPOINT_SERVER'
    declare -n CMDARGV='CMDARGV_SERVER'
    declare -n PMARGS_PUBLISH='PMARGS_PUBLISH_SERVER'
  ;;

  'stream')
    # audio source to capture: monitor of the default PulseAudio sink
    PASOURCE="$(pactl get-default-sink).monitor"

    PMARGS_MISC+=( '--name' "${CNAME:-whisper}-stream" '--replace' )
    declare -n ENTRYPOINT='ENTRYPOINT_STREAM'
    declare -n CMDARGV='CMDARGV_STREAM'

    PMARGS_VOLUMES+=( '--volume' "${XDG_RUNTIME_DIR}/pulse:/run/host-pulse" )
    PMARGS_MISC+=( '--env' 'PULSE_SERVER=unix:/run/host-pulse/native' )
    PMARGS_MISC+=( '--env' "PULSE_SOURCE=${PASOURCE}" )
    PMARGS_MISC+=( '--env' 'SDL_AUDIODRIVER=pulseaudio' )

    PMARGS_VOLUMES+=( '--volume' "${PWD}:/stage" )
    PMARGS_MISC+=( '--workdir' '/stage' )

    # most notably '-f transcript.txt'
    CMDARGV+=( "${@}" ); shift "${#}"
  ;;

  'cli')
    # this mounts $PWD into the container for input/output files; use
    # only relative paths inside $PWD.
    declare -n ENTRYPOINT='ENTRYPOINT_CLI'
    PMARGS_VOLUMES+=( '--volume' "${PWD}:/stage" )
    PMARGS_MISC+=( '--workdir' '/stage' )

    CMDARGV=( '--model' "${DEFAULT_MODEL}" )
    CMDARGV+=( "${@}" ); shift "${#}"
  ;;

  'download-ggml-model'|'ggml')
    declare -n ENTRYPOINT='ENTRYPOINT_DOWNLOAD_GGML'
    if (( $# == 1 )); then
      CMDARGV=( "${1}" '/models' ); shift "${#}"
    else

      printf 'usage: %s %s MODEL\n\n' "${IAM}" "${COMMAND}" >&2
      "${0}" 'ggml-usage' |sed -n '/^Available models:/,$p' >&2
      exit 1
    fi
  ;;

  'ggml-usage')
    declare -n ENTRYPOINT='ENTRYPOINT_DOWNLOAD_GGML'
    unset CMDARGV
  ;;

  'download-vad-model'|'vad')
    declare -n ENTRYPOINT='ENTRYPOINT_DOWNLOAD_VAD'
    if (( $# == 1 )); then
      CMDARGV=( "${1}" '/models' ); shift "${#}"
    else
      printf 'usage: %s %s MODEL\n\n' "${IAM}" "${COMMAND}" >&2
      "${0}" 'vad-usage' |sed -n '/^Available models:/,$p' >&2
      exit 1
    fi
  ;;
  
  'vad-usage')
    declare -n ENTRYPOINT='ENTRYPOINT_DOWNLOAD_VAD'
    unset CMDARGV
  ;;

  *)
    echo "${IAM}: unknown command: ${COMMAND}" >&2
    { echo; usage; echo; } >&2; exit 1
  ;;
esac

[[ -n "${ENTRYPOINT}" ]] && {
  mapfile -t ENTRYPOINT < <(printf '"%s"\n' "${ENTRYPOINT[@]}")
  PMARGS_MISC+=( "--entrypoint=[$(IFS=','; echo "${ENTRYPOINT[*]}")]" )
}

PMARGV=(
  ${PMARGS_MISC:+"${PMARGS_MISC[@]}"}
  ${PMARGS_ENV:+"${PMARGS_ENV[@]}"}
  ${PMARGS_DEVICES:+"${PMARGS_DEVICES[@]}"}
  ${PMARGS_VOLUMES:+"${PMARGS_VOLUMES[@]}"}
  ${PMARGS_PUBLISH:+"${PMARGS_PUBLISH[@]}"}
)

PMCMD=(
  podman run "${@}" "${PMARGV[@]}" "${IMAGE}" ${CMDARGV:+"${CMDARGV[@]}"}
)

# debug
echo "${PMCMD[@]}" >&2

exec "${PMCMD[@]}"

