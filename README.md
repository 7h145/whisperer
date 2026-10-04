# whisperer — a small whisper.cpp helper

A small Bash script for running [whisper.cpp](https://github.com/ggml-org/whisper.cpp)
with [Podman](https://podman.io/), mainly as a local transcription server. It also
handles file transcription, with desktop audio streaming as an optional extension.
Mainly for personal use, but it works quite well for me and is helpful—feel free to
try it.

This reflects my setup, not a promise that it works on every machine.

## Getting started

You need Bash and Podman on Linux, plus working GPU access for the selected image:
Vulkan through `/dev/dri`, or NVIDIA CUDA through Podman's CDI setup.

Download the default speech and voice-activity detection models once:

```sh
./whisper.sh ggml medium
./whisper.sh vad silero-v6.2.0
```

They live in the persistent Podman volume `whisper.models`, separate from the
containers. Downloads require internet access; transcription runs locally.

If a model cannot be loaded, check that its download completed and that the
filename matches the defaults in `whisper.sh`.

## Local server (default)

```sh
./whisper.sh
```

The server listens on localhost port `51149`, with an OpenAI-like transcription
endpoint. From another terminal:

```sh
curl http://localhost:51149/v1/audio/transcriptions \
  -F file=@recording.wav \
  -F response_format=json
```

A successful request returns the transcription. This is whisper.cpp's API, not a
claim of full OpenAI API compatibility. Stop the foreground server with Ctrl-C.

## File transcription

Put an audio file in your current directory, then run:

```sh
/path/to/whisper.sh cli -f recording.wav
```

This prints a transcript. The current directory is mounted read/write at `/stage`
inside the container; use relative file paths.

## Optional extension: desktop audio streaming

`stream` needs the locally built container with SDL2 support. The included
[Containerfile](Containerfile) builds this CUDA variant; [build.sh](build.sh)
builds and tags it, and `whisper.sh` automatically prefers it once available.

```sh
./build.sh
./whisper.sh stream
```

The build defaults to whisper.cpp `v1.9.4`, CUDA 13.0, and GPU architectures `86`
and `120a`; adjust the Containerfile for your hardware.

Streaming also needs `pactl` and a PulseAudio-compatible server, including
PipeWire's PulseAudio service. It captures the **default audio output's monitor**,
not your microphone, and prints the transcript as audio plays.

To save a transcript in the current directory:

```sh
./whisper.sh stream -f transcript.txt
```

Only capture audio you intend to transcribe.

## A few setup details

- The script prefers a local `*-sdl-cuda` build, then the newest locally created
  official `main-*` image. Otherwise it uses the official `main-vulkan` image.
- Server and stream use separate container names. Starting either again replaces
  the previous instance of that same mode. Both share the model volume.
- CLI and stream arguments are passed to whisper.cpp. Model paths, server port,
  and other defaults are deliberately kept in `whisper.sh` rather than a separate
  configuration system.

This is a thin helper, not a service manager. See `./whisper.sh help` and the
[upstream documentation](https://github.com/ggml-org/whisper.cpp#readme) for more.
