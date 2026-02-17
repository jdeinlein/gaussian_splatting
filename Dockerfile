FROM nixos/nix
ENV NIXPKGS_ALLOW_UNFREE=1

WORKDIR /workspace
RUN mkdir -p /workspace/ingest

VOLUME ["/workspace/ingest"]
VOLUME ["/workspace/colmap_workspace"]
VOLUME ["/workspace/out"]

RUN nix-channel --update && \
        nix profile add \
        nixpkgs#colmapWithCuda \
        nixpkgs#imagemagick \
        nixpkgs#ffmpeg_7-headless \
        nixpkgs#linuxKernel.packages.linux_xanmod_stable.nvidia_x11_vulkan_beta \
        nixpkgs#jq \
        nixpkgs#python3 \
        nixpkgs#uv \
        nixpkgs#brush-splat \
         --extra-experimental-features nix-command --extra-experimental-features flakes --impure && \
        nix-store --gc --print-roots | egrep -v "^(/nix/var|/run/\w+-system|\{memory|/proc)" && \
        nix-collect-garbage

#RUN git clone https://github.com/jdeinlein/brushnix.git && \
#    cd brushnix && \
#    nix build --experimental-features 'nix-command flakes' --impure && \
#    nix-collect-garbage
COPY prefect-docker-worker/pyproject.toml /workspace/pyproject.toml
COPY prefect-docker-worker/uv.lock /workspace/uv.lock
COPY workflow.sh /workspace/colmap.sh

RUN uv sync --no-dev --frozen
RUN chmod +x /workspace/colmap.sh

ENTRYPOINT []