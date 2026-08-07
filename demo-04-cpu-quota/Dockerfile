# Demo 4's service image. Built once and run twice, unchanged, under two different
# CPU quotas.
#
# That is the demo's whole argument, so this file matters more than it looks: if
# the two modes could differ by so much as a build flag, "the code did not change"
# would be a claim rather than a fact. There is one image, one tag, one digest, and
# both runs report the same digest for the work they computed.
#
# Build context is the repository root, not this directory — the service imports
# internal/diag and internal/httpsrv from the shared module:
#
#   docker compose -f demo-04-cpu-quota/docker-compose.yml build

FROM golang:1.26 AS build
WORKDIR /src

# Dependencies first, so editing the demo's Go files does not re-download the
# module cache on every rebuild during rehearsal.
COPY go.mod go.sum ./
RUN go mod download

COPY internal ./internal
COPY demo-04-cpu-quota ./demo-04-cpu-quota

# CGO_ENABLED=0 for a static binary, so the runtime stage can be a minimal image
# and the same binary runs regardless of the base's libc.
#
# The output name is load-bearing. An eBPF tool that filters on the process's comm
# sees a name Linux truncates to 15 characters; "demo4-service" is 13, so it
# survives intact and can be matched exactly.
ENV CGO_ENABLED=0
RUN go build -trimpath -o /out/demo4-service ./demo-04-cpu-quota/cmd/service

FROM alpine:3.19

# The demo reads /sys/fs/cgroup by hand on stage — `cat cpu.stat` next to
# `curl /throttle` is how the audience sees that the endpoint is not inventing
# its numbers. That needs a shell in the image, which is why this is Alpine and
# not scratch. curl comes along so /healthz and /stats can be checked from
# inside the container when a host port is in doubt.
RUN apk add --no-cache curl

COPY --from=build /out/demo4-service /usr/local/bin/demo4-service

EXPOSE 8083 6063

# No mode flag, no quota flag, no environment switch that changes the work. Both
# modes run this exact command; only the cgroup around it differs.
ENTRYPOINT ["/usr/local/bin/demo4-service"]
