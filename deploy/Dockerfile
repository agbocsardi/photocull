# photocull-serve in a container (docs/HOME-SERVER.md). The build context is the
# repository root: docker build -f deploy/Dockerfile -t photocull-serve .
FROM swift:6.2-noble AS build
WORKDIR /src

# Dependencies come from the pin file only: a toolchain that would re-resolve
# Package.resolved fails here instead of shipping different versions.
COPY Package.swift Package.resolved ./
RUN swift package --only-use-versions-from-resolved-file resolve

COPY Sources ./Sources
# --static-swift-stdlib puts the Swift runtime into the binary, so the runtime
# stage needs no Swift toolchain.
RUN swift build -c release --product photocull-serve --static-swift-stdlib \
        --only-use-versions-from-resolved-file

FROM ubuntu:noble
COPY --from=build /src/.build/release/photocull-serve /usr/local/bin/photocull-serve
# The PWA the API serves at /; the data root and token come from the mounts.
COPY pwa /app/pwa

# No data is written inside the image; HOME only keeps Foundation from falling
# back to the image's /root when the container runs as the owner's uid.
ENV HOME=/tmp
# Noble's own uid 1000 user; the compose `user:` overrides it with the owner's.
USER 1000:1000
ENTRYPOINT ["/usr/local/bin/photocull-serve"]
