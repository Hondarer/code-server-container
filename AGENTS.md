# code-server-container Agent Guide

## Source of truth

- Read `README.md` for the project entry point and `docs/README.md` for task routing.
- Treat scripts as the executable specification. Keep docs and skills aligned when behavior changes.
- Keep transient Azure URLs, passwords, image tags, and digests out of tracked documentation.
- Preserve unrelated and pre-existing worktree changes. Do not rewrite Git history unless explicitly requested.

## Container invariants

- Build with rootless Podman. Do not require a sibling `oracle-linux-container` clone or local
  `oracle-linux-8` image.
- `build-pod.sh` must pull
  `ghcr.io/hondarer/oracle-linux-container/oracle-linux-8-dev:latest` on every build, resolve its
  digest, and build from that digest. Preserve the base name and digest OCI labels.
- Keep code-server pinned in `src/Dockerfile`; validate version changes against its embedded Code
  version and the Japanese Language Pack.
- Start code-server as the configured non-root user without forcing `--locale`. Do not start SSH;
  let each user choose the display language after startup.
- Treat the user's `User/settings.json` as the completion marker for default settings and extension
  initialization. If it exists, skip the entire defaults workflow without inspecting User or
  Machine settings, the extension manifest, or installed extensions.
- When `User/settings.json` is absent, install and verify bundled extensions first, place
  `Machine/settings.json`, then place `User/settings.json` last. A failure must leave the User
  settings marker absent so the next process start retries.
- Accept both `publisher.extension` and `publisher.extension@version` in `extensions.txt`.
  Resolve extensions during image build, bundle the resolved VSIX files and hashes, and install
  from the image without runtime Marketplace access.
- Keep `Visual Studio Dark - C++`, the Japanese Language Pack, and
  `ms-vscode.cpptools-themes@2.0.0` unless the user requests a change.
- Preserve the base image's clang-format 23.1.1 and git-clang-format. Bundle the official x86_64
  clangd 22.1.0 standalone release with a pinned SHA-256, and keep
  `llvm-vs-code-extensions.vscode-clangd` in the initial extension manifest. Do not rely on the
  extension to download clangd at runtime.

## Local workflow

1. Run `./build-pod.sh`; it stops the normal local instance and replaces `code-server-ol8`.
2. Run `./verify-defaults.sh`; it uses a temporary home and `--network none` and must not touch
   `./storage`.
3. Restore the normal environment with `./start-pod.sh 1` and verify HTTP on port 8080.

Local instance numbers map to ports `8080 + instance - 1` and separate paths under `./storage`.
Do not delete or reset those paths unless explicitly authorized.

## Azure architecture and safety

- Use one Container App per user, not multiple replicas of one App. Each user must have a unique
  URL, password Secret, Azure Files Share, `/home/user`, and `/workspace`.
- Keep every App in Single revision mode with `maxReplicas=1`. Scaling-disabled Apps use
  `minReplicas=1`; scaling-enabled Apps use the configured `minReplicas` (default 0), an explicit
  HTTP rule, and the configured cooldown period (default 3600 seconds).
- Allocate each code-server App from the external deployment config, defaulting to 4.0 vCPU / 8Gi.
  Keep the per-instance init Job at 1.0 vCPU / 2Gi because Azure Files I/O is its main bottleneck.
- Store deployment config and password files under `$HOME/.azure`, outside Git. Password files
  must be mode 600 and unique. `aca-instance.sh list` and `show` intentionally expose passwords;
  never run them in shared screens, CI logs, or shell traces.
- Use `aca-environment.sh` for shared infrastructure and publishing. Use `aca-instance.sh` for
  individual user lifecycle operations.
- Treat `docs/azure-container-apps-multi-instance.md` as the lifecycle state-machine source of
  truth. Only `suspend` and `resume` may transition an App between Running and Stopped; they use
  the Container Apps stable REST API through `az rest`, not the Container Apps Job commands. This
  is unrelated to the per-instance init Job (`<App name>-init`, Manual trigger) that `create` and
  `reset` run to pre-populate `home` with defaults before the App ever starts; that Job never
  transitions the App's own Running/Stopped state.
- `create` and `reset` must pre-populate `home` via the init Job before the App can start or
  resume. Azure Files extension installs are slow enough to exceed the Container Apps default
  startup probe and cause a CrashLoopBackOff if done inside the App's own startup instead.
- Check provisioning and running status before every instance mutation. Never let `create`,
  `update`, or `rotate-password` implicitly start a stopped App. Transitional or unknown states
  permit only read operations and confirmed deletion.
- Permit `download` only for `Succeeded / Running` or `Succeeded / Stopped`. Export both `home`
  and `workspace`, never put the storage key in command arguments, never overwrite an existing
  path, and publish only a complete mode-600 archive. Suspend first when point-in-time consistency
  matters; the archive is a logical content export, not an Azure Files metadata/snapshot backup.
- Permit destructive `reset` only for `Succeeded / Stopped` and require exact `reset <slug>`
  confirmation. It may replace only the share's `home` and `workspace` directories, then runs the
  init Job to pre-populate defaults, and must not start the App itself. The next explicit `resume`
  only starts the App; defaults are already installed by the init Job.
- Roll out image, resource, and scaling updates sequentially. Update one user, verify the desired
  image and resources, Healthy state, traffic 100%, login, and persistent workspace, then update
  the next user and repeat.
- `aca-environment.sh publish` records the target scaling settings but does not mutate Apps.
  Apply those settings sequentially with `aca-instance.sh update`; a `create` override is replaced
  by the next update using the published settings.
- To update a stopped App, explicitly resume, update and verify it, then suspend it again if
  required. Keep any ACR image still referenced by a stopped App.
- A correct password POST to `/login` returns 302. Another user's password remains on the login
  page with 200. `/healthz` must return HTTP 200.
- `az containerapp exec` may require a TTY, may target a terminating replica, and may return 429
  after repeated calls. Prefer a few targeted checks; wait and retry only after confirming the
  App is Healthy.
- A Single-mode update may briefly show the old revision as Active with traffic 0 while it is
  Deprovisioning. Do not treat this as completion until the new revision is Healthy at 100%.
- Delete an old ACR tag only after every App references the new immutable tag; verify running Apps
  are healthy and stopped Apps remain intentionally stopped.
- Destructive instance and Resource Group commands require exact confirmation. Resource Group
  deletion can remain in `Deleting` for several minutes; interrupting the local wait does not
  cancel an accepted Azure deletion.

## Required verification

Run checks proportional to the change. Before handing off a release or operational change, run:

```bash
bash -n aca-environment.sh aca-instance.sh build-pod.sh start-pod.sh \
  stop-pod.sh verify-defaults.sh version-config.sh src/*.sh tests/*.sh
./tests/install-default-extensions-test.sh
./tests/code-server-bootstrap-defaults-test.sh
./tests/aca-environment-test.sh
./tests/aca-instance-test.sh
git diff HEAD --check
```

For image changes, also run `./build-pod.sh`, `./verify-defaults.sh`, and the normal local startup.
For Azure changes, verify the live resource state rather than recording a dated snapshot in docs.

## Documentation and skills

- Keep user-facing concepts and reproducible commands in `docs/`.
- Keep this file focused on non-negotiable project rules and safety boundaries.
- Keep task workflows in `.agents/skills`; reference docs rather than copying entire runbooks.
- Update the related docs, AGENTS.md, and skill whenever a command interface or invariant changes.
