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

## Alternative Setups

These are documented ideas, not setups exercised in this workspace. They do not change the preferred MicroK8s/Apple Container arrangement. Choose the Kubernetes cluster and the tooling runtime independently:

| Combination | Reason to consider it | Tradeoff |
| --- | --- | --- |
| MicroK8s + Docker tooling | Retain APIM and its data; use familiar Docker commands for generation/tests | Requires a Docker daemon and a verified container-to-host route |
| Minikube + Apple Container tooling | Keep native Apple tooling while isolating APIM in a separate cluster | Separate cluster resources and networking; use a supported Minikube driver |
| Minikube + Docker tooling | Familiar cross-platform Kubernetes and OCI workflows | On macOS, Docker Desktop adds a VM and Minikube service access may need a tunnel |
| Docker Compose for APIM + Docker tooling | Avoid Kubernetes for a minimal management-API smoke bench | Does not exercise Helm/Kubernetes behavior; database configuration and readiness need separate wiring |

Changing these layers does not require changing provider HCL or the Terraform test sequence. Keep the APIM version, authentication, database settings, generation pins, and assertions equivalent.

### Minikube Instead of MicroK8s

Use a dedicated profile rather than reusing a shared cluster. With an existing Docker daemon, an example is:

```sh
minikube start -p apim --driver=docker --cpus=4 --memory=8192
minikube -p apim kubectl -- get nodes
```

This is an initial resource budget, not a minimum requirement; leave headroom for the host and test containers. If the cluster and test containers both use Docker Desktop, budget them together within its VM rather than assuming each has a separate allocation. The Docker driver supports ARM64 and amd64. For Minikube without Docker, choose a supported VM driver for the host, such as QEMU; do not assume Apple Container provides Minikube's Docker driver API. See the official [driver list](https://minikube.sigs.k8s.io/docs/drivers/), [Docker driver](https://minikube.sigs.k8s.io/docs/drivers/docker/), and [start options](https://minikube.sigs.k8s.io/docs/commands/start/).

Deploy APIM through the same pinned Helm chart and reviewed values, with `--kube-context apim --namespace gravitee --create-namespace` explicitly supplied to Helm. `hack/kind/apim/values-minimal.yaml` is a starting point, not a ready-made Minikube deployment: it expects a locally loaded `dev` API image and particular MongoDB service naming. Review the image tag, database URI, storage, and disabled components before using it. Do not run `make start-cluster` for this route; that target creates Kind, not Minikube.

Once APIM is deployed, discover its actual service and port, then forward only the management API:

```sh
minikube -p apim kubectl -- get pods,svc -n gravitee
# Replace API_SERVICE_NAME and SERVICE_PORT with values from the service.
minikube -p apim kubectl -- port-forward --address 127.0.0.1 \
  svc/API_SERVICE_NAME 30083:SERVICE_PORT -n gravitee
```

Host-run tests can use `http://127.0.0.1:30083/automation`. For Apple Container tests, use the verified host bridge and bind the forward to that interface instead. Docker Desktop tests should use a verified `host.docker.internal` route, as described below. Avoid binding to every interface just to make connectivity work.

With the Docker driver on macOS, do not assume `minikube ip` plus a NodePort is reachable. An alternative to port-forwarding is `minikube -p apim service API_SERVICE_NAME -n gravitee --url`; keep its tunnel process running and use the returned URL plus `/automation`. The returned host-loopback URL is not automatically reachable from a test container. See [Minikube service access](https://minikube.sigs.k8s.io/docs/handbook/accessing/). Stop forwards/tunnels when finished; `minikube stop -p apim` stops the dedicated cluster without deleting it. Delete the profile only when its data is no longer needed.

### Docker Instead of Apple Container

`hack/scripts/local-release.sh` calls Apple Container directly and does not accept a Docker runtime switch. The Containerfile can also be built with Docker; these manual equivalents are starting points from a checkout containing the tooling:

```sh
SPEAKEASY_VERSION=$(ruby -ryaml -e 'print YAML.safe_load(File.read(ARGV.fetch(0))).fetch("speakeasyVersion")' .speakeasy/workflow.yaml)
GO_VERSION=$(awk '$1 == "go" { print $2; exit }' go.mod)
TOOL_PLATFORM=linux/arm64 # Use linux/amd64 on an Intel/AMD host.
CODEGEN_IMAGE=apim-provider-codegen:docker-local
docker build --platform "$TOOL_PLATFORM" \
  --build-arg "SPEAKEASY_VERSION=$SPEAKEASY_VERSION" \
  --build-arg "GO_IMAGE=golang:$GO_VERSION" \
  --build-arg TERRAFORM_VERSION=1.13.4 \
  -t "$CODEGEN_IMAGE" -f hack/container/Containerfile hack/container
docker run --rm --platform "$TOOL_PLATFORM" "$CODEGEN_IMAGE" \
  sh -ec 'test -s /etc/ssl/certs/ca-certificates.crt; go version; speakeasy --version; terraform version'
```

Docker and Apple Container do not share a local image store. Build/import the image into the selected runtime rather than assuming the Apple-built tag is available to Docker. Keep the same pins and credential handling. For a release baseline, read versions and mount the isolated release checkout while retaining the Containerfile from the tooling checkout.

Generation requires the same sequence as the helper, including doc-gen and cleanup. Export `SPEAKEASY_API_KEY` securely before running these commands; never substitute its literal value or mount the credential file:

```sh
docker run --rm --platform "$TOOL_PLATFORM" -v "$PWD:/workspace" -w /workspace \
  "$CODEGEN_IMAGE" terraform fmt -recursive
docker run --rm --platform linux/amd64 --user "$(id -u):$(id -g)" \
  -v "$PWD/.docgen/config:/config" -v "$PWD:/plugin" \
  "${APIM_DOCGEN_IMAGE:-graviteeio/doc-gen}"
docker run --rm --platform "$TOOL_PLATFORM" --cpus=4 --memory=4g \
  -v "$PWD:/workspace" -w /workspace -e SPEAKEASY_API_KEY "$CODEGEN_IMAGE" \
  speakeasy run --output console --skip-versioning --skip-upload-spec
```

Doc-gen's amd64 image needs working emulation on ARM hosts; Docker does not use Apple's `--rosetta` CLI flag. After successful generation, remove the same ephemeral outputs listed in the helper, build with `go build -o /tmp/terraform-provider-apim .` inside the tool container, and compare tracked files. Unit tests use the same checkout mount with `go test -count=1 ./internal/... ./tests/utils/...`; acceptance tests use the earlier test command plus runtime-only APIM environment variables. Stop on failures rather than continuing cleanup and claiming success. Use CPU/memory limits and writable Go caches as appropriate; on Linux, account for bind-mounted output ownership. See [Docker container execution](https://docs.docker.com/engine/containers/run/).

On Docker Desktop, `host.docker.internal` is the documented host-service name; verify reachability from the actual test image before setting `APIM_SERVER_URL=http://host.docker.internal:30083/automation`. Host aliases and routes differ on plain Linux Docker and other daemons; do not reuse Apple's `192.168.64.1` blindly. When APIM itself runs in Compose, attach the test container to the same user-defined network and address the API by service name and container port instead of going through a host forward. Publish host ports only on loopback when host access is needed. See [Docker Desktop host connectivity](https://docs.docker.com/desktop/features/networking/networking-how-tos/) and [port publishing](https://docs.docker.com/desktop/features/networking/#how-exposed-ports-work).

For a Compose smoke bench, start with the management API plus MongoDB, use a reviewed APIM configuration compatible with the selected version, disable unused analytics/gateway/UI components, and wait for API/database readiness before tests. Pin images, confirm each image's architecture, and preserve database volumes unless an explicit reset is requested. This is an alternative deployment idea, not a Compose file maintained or verified here.
