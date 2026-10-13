# Local Provider Release Tooling

## Build and Verify

Run from the provider repository with Apple Container and Ruby available:

```sh
bash hack/scripts/local-release.sh build
bash hack/scripts/local-release.sh check
bash hack/scripts/local-release.sh generate
bash hack/scripts/local-release.sh unit-tests
```

The helper reads the selected checkout's pinned Speakeasy version and Go directive, and defaults to the matching Go image. Terraform defaults to `1.13.4`. `APIM_GO_IMAGE` and `APIM_TERRAFORM_VERSION` override the image versions; record overrides when comparing a baseline. `APIM_CODEGEN_IMAGE` selects a prebuilt tool image. The Go base supplies the system CA bundle missing from the standalone Speakeasy image. Avoid login shells, which can replace Go's PATH.

`APIM_CONTAINER_CPUS` and `APIM_CONTAINER_MEMORY` default to `4` and `4G`. The builder is also given these limits. Increase them explicitly for larger runs. Doc-gen uses amd64/Rosetta; the tool image uses native ARM64. `APIM_DOCGEN_IMAGE` can pin a doc-gen tag or digest, since the repository Makefile otherwise uses its moving default tag.

The image build context contains only the Containerfile. Neither the repository nor the user's home/config is copied into an image. Generation bind-mounts the selected checkout, formats its Terraform files, runs doc-gen, invokes Speakeasy with the Makefile's `--skip-versioning --skip-upload-spec` flags, removes the same ephemeral output as the Makefile, and builds the provider inside the container. These flags do not disable all Speakeasy service access; generation requires network access and an API key.

## Authentication

Prefer an existing `SPEAKEASY_API_KEY` environment variable. If unset, the helper reads `speakeasy_api_key` from `~/.speakeasy/config.yaml`; use `SPEAKEASY_CONFIG` for another local file. Protect the file with mode `600`. The key is passed by environment variable name, never as a literal command argument or build argument. Do not enable shell tracing or print container environments. Do not commit credential files, Terraform state, or debug logs.

The config is deliberately not mounted: the CLI may write to it, so a read-only config mount breaks generation. Speakeasy authentication is separate from the APIM credentials used by acceptance tests.

## Release Baseline

Choose the release tag explicitly. Use a clean isolated checkout; the following paths are examples, not required locations:

```sh
git worktree add --detach /tmp/apim-provider-baseline v1.0.2
APIM_WORKSPACE=/tmp/apim-provider-baseline bash hack/scripts/local-release.sh build
APIM_WORKSPACE=/tmp/apim-provider-baseline bash hack/scripts/local-release.sh check
APIM_WORKSPACE=/tmp/apim-provider-baseline bash hack/scripts/local-release.sh generate
git -C /tmp/apim-provider-baseline diff --exit-code
git -C /tmp/apim-provider-baseline status --short
```

Tracked files should match the release after generation. Report lock-file/snapshot changes separately from provider changes; do not silently restore them to claim reproducibility. Only after the baseline is confirmed should you sync the Automation API spec and regenerate a development branch. Review overlays, compiled schema, generated code, docs, and provider registration together: SDK endpoints alone do not create Terraform resources. Speakeasy persistent edits preserve the marked custom request-builder regions; verify those markers after regeneration.

## Tests Against MicroK8s

Unit tests do not require APIM. Acceptance tests perform actual Terraform CRUD and imports and require a compatible APIM server and Terraform. A portal-focused subset is:

```sh
APIM_SERVER_URL=http://HOST:PORT/automation TF_ACC=1 \
  go test -count=1 -p 1 -parallel 1 -timeout 5m -v ./tests/acceptance \
  -run '^Test(Portal|PortalListing|DocumentationPortal)Resource_'
```

Set APIM authentication through environment variables (`APIM_USERNAME`/`APIM_PASSWORD` or the provider-supported token) and `APIM_IMAGE_TAG` for version-gated tests. Do not assume `localhost` in a container reaches the host. In the observed Apple Container setup, the host bridge was `192.168.64.1`; confirm it before reuse. When the MicroK8s node/pod IP is unreachable from containers, forward the management API service on that bridge:

```sh
microk8s kubectl port-forward --address HOST_BRIDGE_IP \
  svc/apim-apim3-api 30083:83 -n gravitee
```

Bind only to the needed local interface, point the tests at `http://HOST_BRIDGE_IP:30083/automation`, and stop the forward afterward. The tool image includes Terraform for running the same test command inside Apple Container. Pass credentials with `-e VARIABLE_NAME`, and mount the checkout at `/workspace`; do not put their values in the command. Preserve create/update/remove/reorder/no-op/import coverage and verify cleanup rather than weakening fixtures to avoid an API failure.
