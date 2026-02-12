FROM nixos/nix
RUN nix-channel --update
ENV NIXPKGS_ALLOW_UNFREE=1

WORKDIR /workspace
RUN mkdir -p /workspace/ingest

VOLUME ["/workspace/ingest"]
VOLUME ["/workspace/colmap_workspace"]
VOLUME ["/workspace/out"]

RUN nix profile add \
        nixpkgs#colmapWithCuda \
        nixpkgs#imagemagick \
        nixpkgs#ffmpeg_7-headless \
        nixpkgs#brush-splat \
        nixpkgs#linuxKernel.packages.linux_xanmod_stable.nvidia_x11_vulkan_beta \
        nixpkgs#jq \
         --extra-experimental-features nix-command --extra-experimental-features flakes --impure

RUN nix-store --gc --print-roots | egrep -v "^(/nix/var|/run/\w+-system|\{memory|/proc)"
RUN nix-collect-garbage

COPY colmap.sh /workspace/colmap.sh
RUN chmod +x /workspace/colmap.sh

ENTRYPOINT ["sh", "/workspace/colmap.sh"]
