# Define arguments first
ARG TARGETARCH

# Builder stage
FROM nvidia/cuda:12.8.1-devel-ubuntu24.04 AS builder

# Architecture-specific settings
FROM builder AS builder-amd64
ENV NV_CUDNN_VERSION=9.8.0.87-1
ENV NV_CUDNN_PACKAGE_NAME=libcudnn9-cuda-12
ENV NV_CUDNN_PACKAGE=libcudnn9-cuda-12=${NV_CUDNN_VERSION}
ENV CUDSS_ARCH=amd64
ENV DEBIAN_FRONTEND=noninteractive

FROM builder AS builder-arm64
ENV NV_CUDNN_VERSION=9.8.0.87-1
ENV NV_CUDNN_PACKAGE_NAME=libcudnn9-cuda-12
ENV NV_CUDNN_PACKAGE=libcudnn9-cuda-12=${NV_CUDNN_VERSION}
ENV CUDSS_ARCH=arm64

# Select the appropriate builder based on TARGETARCH
FROM builder-${TARGETARCH} AS builder-final

LABEL maintainer="NVIDIA CORPORATION <cudatools@nvidia.com>"
LABEL com.nvidia.cudnn.version="${NV_CUDNN_VERSION}"

RUN apt-get update && apt-get install -y --no-install-recommends \
    ${NV_CUDNN_PACKAGE} \
    && apt-mark hold ${NV_CUDNN_PACKAGE_NAME} \
    && apt-get install -y \
        curl \
        wget \
        unzip \
        build-essential \
        git \
        libx11-xcb-dev \
        libxkbcommon-dev \
        libwayland-dev \
        libxrandr-dev \
        libegl1-mesa-dev \
        ninja-build \
        libopencv-dev \
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
        libcurl4-openssl-dev \
        ccache \
        libsuitesparse-dev \
        libblas-dev \
    && rm -rf /var/lib/apt/lists/*

# set env
ENV CUDA_ROOT=/usr/local/cuda
ENV CUDA_PATH=$CUDA_ROOT
ENV RUST_LOG=info
ENV PATH=$CUDA_ROOT/nvvm/lib64:/root/.cargo/bin:$PATH
ENV NVIDIA_DRIVER_CAPABILITIES=compute,graphics,utility

# install latest cmake
RUN wget -O - https://apt.kitware.com/keys/kitware-archive-latest.asc 2>/dev/null | gpg --dearmor - | tee /usr/share/keyrings/kitware-archive-keyring.gpg >/dev/null && \
    echo 'deb [signed-by=/usr/share/keyrings/kitware-archive-keyring.gpg] https://apt.kitware.com/ubuntu/ noble main' | tee /etc/apt/sources.list.d/kitware.list >/dev/null && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        cmake \
    && rm -rf /var/lib/apt/lists/*

# Install Abseil first with explicit version
RUN git clone https://github.com/abseil/abseil-cpp.git && \
    cd abseil-cpp && \
    git checkout 20240116.1 && \
    mkdir build && \
    cd build && \
    cmake .. \
        -DCMAKE_CXX_STANDARD=17 \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DABSL_PROPAGATE_CXX_STD=ON && \
    make -j$(nproc) && \
    make install && \
    ldconfig

# Install CUDSS based on architecture
RUN wget https://developer.download.nvidia.com/compute/cudss/0.5.0/local_installers/cudss-local-repo-ubuntu2404-0.5.0_0.5.0-1_${CUDSS_ARCH}.deb && \
    dpkg -i cudss-local-repo-ubuntu2404-0.5.0_0.5.0-1_${CUDSS_ARCH}.deb && \
    cp /var/cudss-local-repo-ubuntu2404-0.5.0/cudss-*-keyring.gpg /usr/share/keyrings/ && \
    apt-get update && \
    apt-get -y install cudss && \
    rm -rf /var/lib/apt/lists/*

# Build and install Ceres Solver with CUDA support and explicit Abseil config
RUN git clone https://ceres-solver.googlesource.com/ceres-solver && \
    cd ceres-solver && \
    mkdir build && \
    cd build && \
    cmake .. \
        -DCMAKE_CUDA_ARCHITECTURES="native" \
        -DBUILD_SHARED_LIBS=ON \
        -DBUILD_TESTING=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DCUDA=ON \
        -DCUDSS=ON \
        -DMINIGLOG=ON \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -Dabsl_DIR=/usr/local/lib/cmake/absl \
        -Dabsl_VERSION=20240116.1 && \
    make -j$(nproc) && \
    make install && \
    ldconfig

# Build and install COLMAP with CUDA support
RUN git clone https://github.com/colmap/colmap.git && \
    cd colmap && \
    git fetch https://github.com/colmap/colmap.git && \
    mkdir build && \
    cd build && \
    cmake .. -GNinja \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCUDA_ENABLED=ON && \
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

# Install rust
RUN curl https://sh.rustup.rs -sSf | sh -s -- --default-toolchain nightly -y

# Install brush
RUN git clone https://github.com/ArthurBrussee/brush.git && \
    cd brush && \
    cargo build --release && \
    cp target/release/brush_app /usr/local/bin/brush

RUN cargo install rerun-cli

# Runtime stage
FROM nvidia/cuda:12.8.1-runtime-ubuntu24.04 AS engine

# Architecture-specific settings
FROM engine AS engine-amd64
ENV NV_CUDNN_VERSION=9.8.0.87-1
ENV NV_CUDNN_PACKAGE_NAME=libcudnn9-cuda-12
ENV NV_CUDNN_PACKAGE=libcudnn9-cuda-12=${NV_CUDNN_VERSION}
ENV CUDSS_ARCH=amd64

FROM engine AS engine-arm64
ENV NV_CUDNN_VERSION=9.8.0.87-1
ENV NV_CUDNN_PACKAGE_NAME=libcudnn9-cuda-12
ENV NV_CUDNN_PACKAGE=libcudnn9-cuda-12=${NV_CUDNN_VERSION}
ENV CUDSS_ARCH=arm64

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
COPY --from=builder-final /root/.cargo/bin/rerun /usr/local/bin/rerun

# Set working directory
WORKDIR /workspace
RUN mkdir -p /workspace/ingest

# Define volumes
VOLUME ["/workspace/ingest"]
VOLUME ["/workspace/colmap_workspace"]
VOLUME ["/workspace/out"]
VOLUME ["/workspace/XDG"]

ENV QT_QPA_PLATFORM=offscreen
ENV XDG_RUNTIME_DIR=/workspace/XDG
ENV CUDA_ROOT=/usr/local/cuda
ENV CUDA_PATH=$CUDA_ROOT
ENV PATH=$CUDA_ROOT/nvvm/lib64:/usr/local/bin:$PATH
ENV NVIDIA_DRIVER_CAPABILITIES=compute,graphics,utility

# Install runtime dependencies including CUDA and cuDNN
RUN apt-get update && apt-get install -y --no-install-recommends \
    ${NV_CUDNN_PACKAGE} \
    imagemagick \
    wget \
    jq \
    ffmpeg \
    mesa-vulkan-drivers \
    libvulkan1 \
    libgl1 \
    libegl1 \
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
    libsuitesparse-dev \
    libblas-dev \
    libsqlite3-dev \
    libglew-dev \
    qtbase5-dev \
    libqt5opengl5-dev \
    libcgal-dev \
    libcurl4-openssl-dev \       
    nvidia-driver-550 \
    nvidia-utils-550 \
    && apt-mark hold ${NV_CUDNN_PACKAGE_NAME} \
    && rm -rf /var/lib/apt/lists/*

# Install CUDSS based on architecture
RUN wget https://developer.download.nvidia.com/compute/cudss/0.5.0/local_installers/cudss-local-repo-ubuntu2404-0.5.0_0.5.0-1_${CUDSS_ARCH}.deb && \
    dpkg -i cudss-local-repo-ubuntu2404-0.5.0_0.5.0-1_${CUDSS_ARCH}.deb && \
    cp /var/cudss-local-repo-ubuntu2404-0.5.0/cudss-*-keyring.gpg /usr/share/keyrings/ && \
    apt-get update && \
    apt-get -y install cudss && \
    rm -rf /var/lib/apt/lists/*

COPY colmap.sh /workspace/colmap.sh
RUN chmod +x /workspace/colmap.sh
ENV RUST_LOG=info
#ENTRYPOINT ["sh","/workspace/colmap.sh"]

# Install Python and FastAPI dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-pip \
    python3-dev \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Install Python packages
RUN python3 -m venv fastapi-env &&\
    source fastapi-env/bin/activate &&\
    pip install fastapi uvicorn python-multipart pydantic

# Copy API file
COPY ./api/api.py /workspace/api.py

# Add a new entrypoint script that can run either the API or COLMAP
COPY api_entrypoint.sh /workspace/entrypoint.sh
RUN chmod +x /workspace/entrypoint.sh
ENTRYPOINT ["sh","/workspace/entrypoint.sh"]