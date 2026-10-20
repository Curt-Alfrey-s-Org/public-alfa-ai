# docker-bake.hcl -- shared BuildKit caches for the cluster.
#
# Heavy images (alfa-ai-app, rankings-bot-base) are built via `docker buildx bake`
# so we can reuse layers across nodes and publish cache manifests to the
# hub (hub) registry mirror.
#
# Prereqs:
#   docker buildx create --use --name alfa-builder
#   docker login hub
#
# Typical calls:
#   docker buildx bake --push alfa-ai-stack
#   docker buildx bake --push rankings-bot-stack
#
# Docs:
#   https://docs.docker.com/build/bake/
#   https://docs.docker.com/build/cache/backends/registry/
#   https://docs.docker.com/build/cache/backends/local/

variable "REGISTRY" {
    default = "hub"
}

variable "TAG" {
    default = "latest"
}

variable "BUILD_HASH" {
    default = "unknown"
}

variable "CLUSTER_CACHE" {
    default = "/mnt/cluster/caches/buildkit"
}

group "default" {
    targets = ["alfa-ai-stack", "rankings-bot-stack"]
}

target "_shared" {
    args = {
        BUILD_HASH = "${BUILD_HASH}"
    }
    platforms = ["linux/amd64"]
    output = ["type=registry"]
    cache-from = [
        "type=registry,ref=${REGISTRY}/alfa-ai/buildcache:alfa-ai-app",
        "type=registry,ref=${REGISTRY}/alfa-ai/buildcache:rankings-bot-base",
        "type=local,src=${CLUSTER_CACHE}/alfa-ai",
    ]
    cache-to = [
        "type=local,dest=${CLUSTER_CACHE}/alfa-ai,mode=max",
    ]
}

target "alfa-ai-api" {
    inherits = ["_shared"]
    context    = "../.."
    dockerfile = "deploy/Dockerfile.api"
    tags = ["${REGISTRY}/alfa-ai/alfa-ai-app:${TAG}", "alfa-ai-app:local"]
}

target "alfa-ai-frontend" {
    inherits = ["_shared"]
    context    = "../../frontend"
    dockerfile = "../deploy/Dockerfile.frontend"
    tags = ["${REGISTRY}/alfa-ai/alfa-ai-frontend:${TAG}", "alfa-ai-frontend:local"]
}

group "alfa-ai-stack" {
    targets = ["alfa-ai-api", "alfa-ai-frontend"]
}

target "rankings-bot-base" {
    inherits = ["_shared"]
    context    = "../../../rankings-bot"
    dockerfile = "Dockerfile.base"
    tags = ["${REGISTRY}/rankings-bot/base:${TAG}", "rankings-bot-base:local"]
    cache-to = [
        "type=registry,ref=${REGISTRY}/rankings-bot/buildcache:base,mode=max",
    ]
}

target "rankings-bot-app" {
    inherits = ["_shared"]
    context    = "../../../rankings-bot"
    dockerfile = "Dockerfile"
    contexts = {
        rankings-base = "target:rankings-bot-base"
    }
    tags = ["${REGISTRY}/rankings-bot/app:${TAG}", "rankings-bot:local"]
}

group "rankings-bot-stack" {
    targets = ["rankings-bot-base", "rankings-bot-app"]
}
