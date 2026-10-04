# syntax=docker/dockerfile:1
# copyright 2026 <github.attic@typedef.net>, MIT
#
# Containerfile - local whisper.cpp CUDA image with SDL2 support
#
# As of whisper.cpp v1.9.4 (2026-10-04), the official CUDA container image does
# not provide the SDL2 runtime support required by `whisper-stream`.
#
# This Containerfile builds a small local variant of the upstream CUDA image
# with `WHISPER_SDL2=ON` and the SDL2 runtime library included. The whisper.cpp
# sources are fetched directly from the upstream Git repository during the
# build; no local source checkout is required.
#
# Use ./build.sh to build/tag the image.
#
# See: https://github.com/ggml-org/whisper.cpp
#   https://github.com/ggml-org/whisper.cpp/blob/master/.devops/main-cuda.Dockerfile
#
# Get the current upstream Container file:
#   GHFILE='https://raw.githubusercontent.com/ggml-org/whisper.cpp/heads/master/.devops/main-cuda.Dockerfile'
#   curl -sS -o "${GHFILE##*/}" "${GHFILE}"

ARG UBUNTU_VERSION=22.04
# This needs to generally match the container host's environment.
ARG CUDA_VERSION=13.0.0
# Target the CUDA build image
ARG BASE_CUDA_DEV_CONTAINER=nvidia/cuda:${CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION}
# Target the CUDA runtime image
ARG BASE_CUDA_RUN_CONTAINER=nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION}


FROM ${BASE_CUDA_DEV_CONTAINER} AS build
WORKDIR /app

# Unless otherwise specified, we make a fat build.
ARG CUDA_DOCKER_ARCH=all
# Set nvcc architecture
ENV CUDA_DOCKER_ARCH=${CUDA_DOCKER_ARCH}

RUN apt-get update && \
    apt-get install -y build-essential libsdl2-dev wget cmake git \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# The build stage has no real GPU/driver, so the linker needs the forward-compat
# libcuda stub to resolve CUDA driver-API symbols.
# Ref: https://stackoverflow.com/a/53464012
ENV CUDA_MAIN_VERSION=13.0
ENV LD_LIBRARY_PATH=/usr/local/cuda-${CUDA_MAIN_VERSION}/compat:$LD_LIBRARY_PATH

# default: canonical ggml-org/whisper.cpp
ARG WHISPER_REPO='https://github.com/ggml-org/whisper.cpp'

# default: current master branch
ARG WHISPER_REF='master'

RUN true \
 && git init . \
 && git remote add origin "${WHISPER_REPO}" \
 && git fetch --depth 1 origin "${WHISPER_REF}" \
 && git checkout --detach FETCH_HEAD

RUN true \
  && cmake -B build \
    -DGGML_CUDA=1 \
    -DWHISPER_SDL2=ON \
    # upstream default as of v1.9.4
    #-DCMAKE_CUDA_ARCHITECTURES='75;80;86;90' \
    # Ampere GA10x (e.g. RTX A4500) and Blackwell (e.g. RTX 5080) only
    -DCMAKE_CUDA_ARCHITECTURES='86-real;120a-real' \
  && nice cmake --build build --config Release --parallel "$(nproc)"

RUN find /app/build -name "*.o" -delete && \
    find /app/build -name "*.a" -delete && \
    rm -rf /app/build/CMakeFiles && \
    rm -rf /app/build/cmake_install.cmake && \
    rm -rf /app/build/_deps


FROM ${BASE_CUDA_RUN_CONTAINER} AS runtime
WORKDIR /app

RUN apt-get update && \
  apt-get install -y curl ffmpeg wget cmake git libsdl2-2.0-0 \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

COPY --from=build /app /app
RUN du -sh /app/*
RUN find /app -type f -size +100M
ENV PATH=/app/build/bin:$PATH
ENTRYPOINT [ "bash", "-c" ]
