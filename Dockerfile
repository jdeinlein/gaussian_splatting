# Define arguments first
ARG TARGETARCH

# Builder stage
FROM nvidia/cuda:12.8.1-devel-ubuntu24.04 AS builder

# Architecture-specific settings
FROM builder AS builder-amd64
ENV NV_CUDNN_VERSION=9.8.0.87-1
ENV NV_CUDNN_PACKAGE_NAME=libcudnn9-cuda-12
ENV NV_CUDNN_PACKAGE=libcudnn9-cuda-12=${NV_CUDNN_VERSION}

FROM builder AS builder-arm64
ENV NV_CUDNN_VERSION=9.8.0.87-1
ENV NV_CUDNN_PACKAGE_NAME=libcudnn9-cuda-12
ENV NV_CUDNN_PACKAGE=libcudnn9-cuda-12=${NV_CUDNN_VERSION}

# Select the appropriate builder based on TARGETARCH
FROM builder-${TARGETARCH} AS builder-final

LABEL maintainer="NVIDIA CORPORATION <cudatools@nvidia.com>"
LABEL com.nvidia.cudnn.version="${NV_CUDNN_VERSION}"

RUN apt-get update && apt-get install -y --no-install-recommends \
    ${NV_CUDNN_PACKAGE} \
    && apt-mark hold ${NV_CUDNN_PACKAGE_NAME} \
    && apt-get install -y \
        curl \
        build-essential \
        git \
        libx11-xcb-dev \
        libxkbcommon-dev \
        libwayland-dev \
        libxrandr-dev \
        libegl1-mesa-dev \
        cmake \
        ninja-build \
        libboost-program-options-dev \
        libboost-graph-dev \
        libboost-system-dev \
        libeigen3-dev \
        libflann-dev \
        libfreeimage-dev \
        libmetis-dev \
        libgoogle-glog-dev \
        libgtest-dev \
        libgmock-dev \
        libsqlite3-dev \
        libglew-dev \
        libvulkan1 \
        qtbase5-dev \
        libqt5opengl5-dev \
        libcgal-dev \
        libceres-dev \
        libcurl4-openssl-dev \
        ccache \
    && rm -rf /var/lib/apt/lists/*

RUN curl https://sh.rustup.rs -sSf | sh -s -- --default-toolchain nightly -y

# set env
ENV CUDA_ROOT=/usr/local/cuda
ENV CUDA_PATH=$CUDA_ROOT
ENV RUST_LOG=info
ENV PATH=$CUDA_ROOT/nvvm/lib64:/root/.cargo/bin:$PATH
ENV NVIDIA_DRIVER_CAPABILITIES=compute,graphics,utility

# Build and install COLMAP.
RUN git clone https://github.com/colmap/colmap.git && \
    cd colmap && \
    git fetch https://github.com/colmap/colmap.git && \
    mkdir build && \
    cd build && \
    cmake .. -GNinja \
        -DCMAKE_INSTALL_PREFIX=/usr/local && \
    ninja && \
    ninja install

# Build and install GLOMAP
RUN git clone https://github.com/colmap/glomap && \
    cd glomap && \
    mkdir build && \
    cd build && \
    cmake .. -GNinja \
        -DCMAKE_INSTALL_PREFIX=/usr/local && \
    ninja && \
    ninja install

# Install brush
RUN git clone https://github.com/ArthurBrussee/brush.git && \
    cd brush && \
    cargo build --release && \
    cp target/release/brush_app /usr/local/bin/brush

# Runtime stage
FROM nvidia/cuda:12.8.1-runtime-ubuntu24.04 AS engine

# Architecture-specific settings
FROM engine AS engine-amd64
ENV NV_CUDNN_VERSION=9.8.0.87-1
ENV NV_CUDNN_PACKAGE_NAME=libcudnn9-cuda-12
ENV NV_CUDNN_PACKAGE=libcudnn9-cuda-12=${NV_CUDNN_VERSION}

FROM engine AS engine-arm64
ENV NV_CUDNN_VERSION=9.8.0.87-1
ENV NV_CUDNN_PACKAGE_NAME=libcudnn9-cuda-12
ENV NV_CUDNN_PACKAGE=libcudnn9-cuda-12=${NV_CUDNN_VERSION}

# Select the appropriate engine based on TARGETARCH
FROM engine-${TARGETARCH} AS runtime

LABEL maintainer="NVIDIA CORPORATION <cudatools@nvidia.com>"
LABEL com.nvidia.cudnn.version="${NV_CUDNN_VERSION}"

# Copy built artifacts from builder
COPY --from=builder-final /usr/local/bin/colmap /usr/local/bin/colmap
COPY --from=builder-final /usr/local/bin/glomap /usr/local/bin/glomap
COPY --from=builder-final /usr/local/lib /usr/local/lib
COPY --from=builder-final /usr/local/include /usr/local/include
COPY --from=builder-final /usr/local/bin/brush /usr/local/bin/brush

# Set working directory
WORKDIR /workspace
RUN mkdir -p /workspace/ingest

# Define volumes
VOLUME ["/workspace/ingest"]
VOLUME ["/workspace/colmap_workspace"]
VOLUME ["/workspace/nerfstudio_dataset"]
VOLUME ["/workspace/XDG"]

ENV QT_QPA_PLATFORM=offscreen
ENV XDG_RUNTIME_DIR=/workspace/XDG
ENV CUDA_ROOT=/usr/local/cuda
ENV CUDA_PATH=$CUDA_ROOT
ENV RUST_LOG=info
ENV PATH=$CUDA_ROOT/nvvm/lib64:/usr/local/bin:$PATH
ENV NVIDIA_DRIVER_CAPABILITIES=compute,graphics,utility
# There is probably a way to optimize those runtime dependencies but Ubuntu is really weird with package names
RUN apt-get update && apt-get install -y --no-install-recommends \
    imagemagick \
    wget \
    ffmpeg \
    mesa-vulkan-drivers \
    libvulkan1 \
    libgl1 \
    libglu1-mesa \
    libgl1-mesa-dev \
    libglew-dev \
    libosmesa6-dev \
    libx11-xcb-dev \
    libxkbcommon-dev \
    libwayland-dev \
    libxrandr-dev \
    libegl1-mesa-dev \
    libboost-program-options-dev \
    libboost-graph-dev \
    libboost-system-dev \
    libeigen3-dev \
    libflann-dev \
    libfreeimage-dev \
    libmetis-dev \
    libgoogle-glog-dev \
    libgmock-dev \
    libsqlite3-dev \
    libglew-dev \
    libvulkan1 \
    qtbase5-dev \
    libqt5opengl5-dev \
    libcgal-dev \
    libceres-dev \
    libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*

COPY colmap.sh /workspace/colmap.sh
RUN chmod +x /workspace/colmap.sh
#RUN chmod 700 /workspace/XDG

ENTRYPOINT ["sh","/workspace/colmap.sh"]

