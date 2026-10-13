#!/usr/bin/env bash
set +x
set -euo pipefail

tooling_root=$(cd "$(dirname "$0")/../.." && pwd -P)
workspace=$(cd "${APIM_WORKSPACE:-$tooling_root}" && pwd -P)

usage() {
  printf '%s\n' 'Usage: bash hack/scripts/local-release.sh {build|check|doc-gen|generate|unit-tests}'
  printf '%s\n' 'APIM_WORKSPACE selects the checkout. See .agents/skills/apim-local-env/references/local-setup.md.'
}

case "${1:-}" in
  build|check|doc-gen|generate|unit-tests) action=$1 ;;
  -h|--help|'') usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

speakeasy_version=$(ruby -ryaml -e 'print YAML.safe_load(File.read(ARGV.fetch(0))).fetch("speakeasyVersion")' "$workspace/.speakeasy/workflow.yaml")
go_version=$(awk '$1 == "go" { print $2; exit }' "$workspace/go.mod")
if [[ ! $speakeasy_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! $go_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf '%s\n' 'Expected pinned Go and Speakeasy versions in the target checkout.' >&2
  exit 1
fi
image=${APIM_CODEGEN_IMAGE:-apim-provider-codegen:speakeasy-$speakeasy_version-go-$go_version}
cpus=${APIM_CONTAINER_CPUS:-4}
memory=${APIM_CONTAINER_MEMORY:-4G}

run_tool() {
  container run --rm --platform linux/arm64 --cpus "$cpus" --memory "$memory" \
    -v "$workspace:/workspace" -w /workspace "$image" "$@"
}

doc_gen() {
  container run --rm --arch amd64 --rosetta --cpus "$cpus" --memory "$memory" \
    --uid "$(id -u)" --gid "$(id -g)" \
    -v "$workspace/.docgen/config:/config" -v "$workspace:/plugin" \
    "${APIM_DOCGEN_IMAGE:-graviteeio/doc-gen}"
}

case "$action" in
  build)
    container build --platform linux/arm64 --cpus "$cpus" --memory "$memory" \
      --build-arg "SPEAKEASY_VERSION=$speakeasy_version" \
      --build-arg "GO_IMAGE=${APIM_GO_IMAGE:-golang:$go_version}" \
      --build-arg "TERRAFORM_VERSION=${APIM_TERRAFORM_VERSION:-1.13.4}" \
      --tag "$image" --file "$tooling_root/hack/container/Containerfile" "$tooling_root/hack/container"
    ;;
  check)
    run_tool sh -ec 'test -s /etc/ssl/certs/ca-certificates.crt; go version; speakeasy --version; terraform version'
    ;;
  doc-gen) doc_gen ;;
  generate)
    if [[ -z ${SPEAKEASY_API_KEY:-} ]]; then
      credential_file=${SPEAKEASY_CONFIG:-${HOME}/.speakeasy/config.yaml}
      if [[ ! -r $credential_file ]]; then
        printf '%s\n' 'Set SPEAKEASY_API_KEY or provide a readable SPEAKEASY_CONFIG.' >&2
        exit 1
      fi
      SPEAKEASY_API_KEY=$(ruby -ryaml -e '
        begin
          key = YAML.safe_load(File.read(ARGV.fetch(0))).fetch("speakeasy_api_key")
          abort "Speakeasy API key is empty" unless key.is_a?(String) && !key.empty?
          print key
        rescue StandardError
          abort "Cannot read Speakeasy API key from the selected config"
        end
      ' "$credential_file")
    fi
    export SPEAKEASY_API_KEY
    run_tool terraform fmt -recursive
    doc_gen
    container run --rm --platform linux/arm64 --cpus "$cpus" --memory "$memory" \
      -v "$workspace:/workspace" -w /workspace -e SPEAKEASY_API_KEY "$image" \
      speakeasy run --output console --skip-versioning --skip-upload-spec
    rm -rf "$workspace/examples/data-sources" "$workspace/docs/data-sources" \
      "$workspace/examples/README.md" "$workspace/USAGE.md"
    run_tool go build -o /tmp/terraform-provider-apim .
    git -C "$workspace" diff --check
    ;;
  unit-tests)
    module_cache=${APIM_GO_MOD_CACHE:-${TMPDIR:-/tmp}/apim-provider-go-mod-cache}
    build_cache=${APIM_GO_BUILD_CACHE:-${TMPDIR:-/tmp}/apim-provider-go-build-cache}
    mkdir -p "$module_cache" "$build_cache"
    module_cache=$(cd "$module_cache" && pwd -P)
    build_cache=$(cd "$build_cache" && pwd -P)
    container run --rm --platform linux/arm64 --cpus "$cpus" --memory "$memory" \
      -v "$workspace:/workspace" -v "$module_cache:/go/pkg/mod" \
      -v "$build_cache:/root/.cache/go-build" -w /workspace "$image" \
      go test -count=1 ./internal/... ./tests/utils/...
    ;;
esac
