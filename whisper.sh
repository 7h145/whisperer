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

PMARGS_MISC=(
  #'--interactive' '--tty'
  #'--detach'
  #'--replace'
  '--rm'
  #'--cpus=2' #'--memory=256m'
  '--entrypoint=bash'
)

PMARGS_VOLUMES=(
  '--volume' "${CNAME}.models:/models"
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

[[ -n "${1}" ]] && { COMMAND="${1}"; shift; }
case "${COMMAND:-server}" in
  '-h'|'--help'|'help')
    usage; echo; exit
  ;;

  'server')
    WHISPER_TOOL='whisper-server'
    PMARGS_MISC+=( '--name' "${CNAME:-whisper}-server" '--replace' )

    CMDARGV=(
      '--host' '0.0.0.0'
      # mimic OpenAI API endpoint path, whisper.cpp default is /inference
      '--inference-path' '/v1/audio/transcriptions'
      '--convert'
      '--model' "${DEFAULT_MODEL}"
      '--vad' '--vad-model' "${DEFAULT_VAD}"
    )

    # additional positional parameters, maybe?
    #CMDARGV+=( "${@}" ); shift "${#}"

    # whisper.cpp whisper-server runs on 8080/tcp by default, $DEFAULT_PORT
    # is an arbitrary free local port
    PMARGS_PUBLISH+=( '--publish' "127.0.0.1:${DEFAULT_PORT:-51149}:8080" )
  ;;

  'stream')
    WHISPER_TOOL='whisper-stream'
    PMARGS_MISC+=( '--name' "${CNAME:-whisper}-stream" '--replace' )

    CMDARGV=(
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

    # additional positional parameters, most notably '-f transcript.txt'
    CMDARGV+=( "${@}" ); shift "${#}"

    # audio source to capture: monitor of the default PulseAudio sink
    PASOURCE="$(pactl get-default-sink).monitor"

    PMARGS_VOLUMES+=( '--volume' "${XDG_RUNTIME_DIR}/pulse:/run/host-pulse" )
    PMARGS_MISC+=( '--env' 'PULSE_SERVER=unix:/run/host-pulse/native' )
    PMARGS_MISC+=( '--env' "PULSE_SOURCE=${PASOURCE}" )
    PMARGS_MISC+=( '--env' 'SDL_AUDIODRIVER=pulseaudio' )

    PMARGS_VOLUMES+=( '--volume' "${PWD}:/stage" )
    PMARGS_MISC+=( '--workdir' '/stage' )
  ;;

  'cli')
    # this mounts $PWD into the container for input/output files; use
    # only relative paths inside $PWD.
    WHISPER_TOOL='whisper-cli'

    PMARGS_VOLUMES+=( '--volume' "${PWD}:/stage" )
    PMARGS_MISC+=( '--workdir' '/stage' )

    CMDARGV=( '--model' "${DEFAULT_MODEL}" )
    CMDARGV+=( "${@}" ); shift "${#}"
  ;;

  'download-ggml-model'|'ggml')
    WHISPER_TOOL='download-ggml-model.sh'

    if (( $# == 1 )); then
      CMDARGV=( "${1}" '/models' ); shift "${#}"
    else

      printf 'usage: %s %s MODEL\n\n' "${IAM}" "${COMMAND}" >&2
      "${0}" 'ggml-usage' |sed -n '/^Available models:/,$p' >&2
      exit 1
    fi
  ;;

  'ggml-usage')
    WHISPER_TOOL='download-ggml-model.sh'
    unset CMDARGV
  ;;

  'download-vad-model'|'vad')
    WHISPER_TOOL='download-vad-model.sh'

    if (( $# == 1 )); then
      CMDARGV=( "${1}" '/models' ); shift "${#}"
    else
      printf 'usage: %s %s MODEL\n\n' "${IAM}" "${COMMAND}" >&2
      "${0}" 'vad-usage' |sed -n '/^Available models:/,$p' >&2
      exit 1
    fi
  ;;

  'vad-usage')
    WHISPER_TOOL='download-vad-model.sh'
    unset CMDARGV
  ;;

  *)
    echo "${IAM}: unknown command: ${COMMAND}" >&2
    { echo; usage; echo; } >&2; exit 1
  ;;
esac

CMDARGV=(
  # Inline entrypoint: bash -c receives the tool as $0 and its arguments as $@.
  # Append legacy tool/model-script directories to the image's $PATH.
  '-c' 'PATH=${PATH}:/app/build/bin:/app/models; exec "${0}" "${@}"'
  "${WHISPER_TOOL:?}"
  "${CMDARGV[@]}"
)

PMARGV=(
  ${PMARGS_MISC:+"${PMARGS_MISC[@]}"}
  ${PMARGS_ENV:+"${PMARGS_ENV[@]}"}
  ${PMARGS_DEVICES:+"${PMARGS_DEVICES[@]}"}
  ${PMARGS_VOLUMES:+"${PMARGS_VOLUMES[@]}"}
  ${PMARGS_PUBLISH:+"${PMARGS_PUBLISH[@]}"}
)

PMCMD=( podman run "${@}" "${PMARGV[@]}" "${IMAGE}" "${CMDARGV[@]}" )

# debug
#echo "${PMCMD[@]}" >&2

exec "${PMCMD[@]}"

