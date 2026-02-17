FROM ghcr.io/astral-sh/uv:python3.13-trixie-slim

ENV LANG=C.UTF-8 \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PROJECT_ROOT=/opt/lara_3d \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

ENV VIRTUAL_ENV=$PROJECT_ROOT/.venv \
    DEBIAN_FRONTEND=noninteractive \
    PATH="$PROJECT_ROOT/.venv/bin:$PATH"

# Debian package caching
ARG APT_PROXY
RUN set -x \
    && if [ "${APT_PROXY}" ]; \
    then echo "Acquire::http { Proxy \"http://${APT_PROXY}\"; };" > /etc/apt/apt.conf.d/01proxy \
    ; fi

WORKDIR ${PROJECT_ROOT}

# Copy only dependency files first (best cache layer)
COPY pyproject.toml uv.lock README.md ./
COPY src/ ./src/

# Install dependencies with cache mount for maximum speed
RUN uv sync 
    #--frozen

# Copy remaining application files

RUN echo "----- Dependencies installed, running gaussian splat workflows ... ----"