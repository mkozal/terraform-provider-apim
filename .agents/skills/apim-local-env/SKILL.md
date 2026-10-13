---
name: apim-local-env
description: Prepare local APIM Terraform generation and tests with Apple Container/MicroK8s, or consult documented Docker/Minikube alternatives.
---

# APIM Local Environment

Use this skill for local provider generation and tests with Apple Container.

Apple Container and MicroK8s are the preferred local setup, not requirements. Docker and Minikube are independent alternatives for tooling and APIM hosting; consult the reference before choosing them. Do not install tools or replace the working setup merely because alternatives are documented.

- Read the target checkout's `go.mod`, `.speakeasy/workflow.yaml`, `.speakeasy/gen.lock`, and `Makefile`. Release pins and development pins differ.
- Use `hack/scripts/local-release.sh` to build and verify a native ARM64 Go/Speakeasy/Terraform image. Doc-gen uses amd64 with Rosetta. Set `APIM_WORKSPACE` when operating on a different checkout.
- For reproducibility checks, generate in a clean release checkout and compare tracked files before syncing OpenAPI. Preserve the user's regular checkout.
- A sandbox permission failure is not evidence that Apple Container is broken. Request approved execution outside the sandbox before diagnosing or restarting the runtime.
- Supply `SPEAKEASY_API_KEY` at runtime. The helper can read the existing local CLI config without printing its contents; never mount that config or put credentials in image layers.
- Stop on generation/build/test failure and report the failing command before changing versions or trying a workaround. A runtime sandbox escalation does not require replacing the runtime.

Read [local setup](references/local-setup.md) for commands, credential handling, baseline checks, MicroK8s routing, and Docker/Minikube alternatives. The alternatives are starting points, not locally verified replacements.
