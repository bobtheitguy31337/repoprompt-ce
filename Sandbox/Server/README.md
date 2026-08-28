# Sandbox deployment

RepoPrompt Server owns this deployment. It builds and activates independently from every other product.

Deploy the current `origin/sandbox` branch:

```sh
Sandbox/Server/deploy.sh
```

The two ordinary phases are also usable independently:

```sh
Sandbox/Server/build.sh
Sandbox/Server/activate.sh
```

`build.sh` is one `docker build`. Docker BuildKit owns layer and SwiftPM caching. `activate.sh` is one `docker compose up -d --wait --no-build`. The image has one stable sandbox tag and Compose has five fixed application data volumes.

The operator portal and internal API bind to localhost by default at ports 9081 and 9443. Override `REPOPROMPT_LISTEN_ADDRESS`, the two host ports, or `REPOPROMPT_PUBLIC_ORIGIN` in the normal Compose environment when external ingress is configured.

Provider CLIs are not image artifacts. The settings UI installs a selected CLI with its official installer into the disposable service-user home. RepoPrompt remembers only the selection in its state volume and reinstalls it after a container replacement.

This deployment intentionally has no checked-in revision, candidate manifest, generated volume names, cache-copy mechanism, build planner, automatic cache pruning, or dependency on another repository.
