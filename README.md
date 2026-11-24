# container-mcp

A local [MCP](https://modelcontextprotocol.io) server, written in Swift, that lets Claude
manage the Linux containers run by Apple's [`container`](https://github.com/apple/container)
tool on a Mac, under a fixed security policy the user writes. Claude can list, run, start,
stop, exec into, build and delete containers without a terminal, and every call passes one
policy layer that the tools cannot skip.

The server talks to the container service through apple/container's own Swift client
library (`ContainerAPIClient`), the code the `container` command itself uses. It runs no
other program, except `/bin/launchctl` when it starts the service, exactly as `container
system start` does.

## Requirements

- macOS 15 or later on Apple silicon (networks other than `default` need macOS 26).
- `container` **1.7.1** installed from the official package, with its service running
  (`container system start`) and a default kernel installed.
- Swift 6.2 or later (Xcode 26 or later) to build.

The server is built against the exact `container` release it talks to, because the
service's messages are Swift structures with no version negotiation. After upgrading
`container`, change the pin in `Package.swift` and `NativeBackend.expectedServiceVersion`
together and rebuild. Until then the server only answers `system_status`, which reports the
mismatch.

## Build and install

```bash
swift build -c release
```

The binary is `.build/release/container-mcp`. It speaks MCP over stdio, and its
diagnostics go to stderr. To use it on its own in Claude Code:

```bash
claude mcp add container -- "$PWD/.build/release/container-mcp"
```

The plugin in `plugin/` packages the server with its skills; see its README.

## Configuration

The server reads one file when it starts:

```
~/Library/Application Support/container-mcp/config.json
```

The file is yours. No tool can write it or change the policy while the server runs. It must
be a regular file (not a symlink), owned by you and not writable by group or others
(`chmod 600`). If it is missing or invalid, only the read tools work and `system_status`
says why. Unknown keys make the file invalid, so a typo cannot silently drop a limit.
`config.example.json` is a starting point.

```json
{
  "version": 1,
  "mountRoots": [
    { "path": "/Users/user/Code", "writable": false },
    { "path": "/Users/user/Scratch", "writable": true }
  ],
  "hostPorts": { "min": 8000, "max": 8999 },
  "registries": ["docker.io", "ghcr.io"],
  "resources": { "defaultCpus": 2, "maxCpus": 4, "defaultMemoryMiB": 1024, "maxMemoryMiB": 4096 },
  "logs": { "maxLines": 500, "maxBytes": 65536 },
  "exec": { "timeoutSeconds": 60, "maxOutputBytes": 65536 },
  "pull": { "timeoutSeconds": 600 },
  "build": { "timeoutSeconds": 1800 },
  "adopted": ["example-db"]
}
```

| Key | Meaning | Accepted values |
|---|---|---|
| `version` | File format version | `1` |
| `mountRoots[].path` | Folder under which host paths may be mounted and builds may read their context. Resolved (symlinks, `..`) when the server starts. | Absolute path to an existing folder |
| `mountRoots[].writable` | Whether a mount under this root may be read-write when the call asks for it | `true`, `false` (default) |
| `hostPorts.min`, `hostPorts.max` | Host ports a container may publish, always on 127.0.0.1 | 1024 ≤ min ≤ max ≤ 65535 |
| `registries` | Registry domains images may be pulled from. `docker.io`, `registry-1.docker.io` and `index.docker.io` count as one. | Bare domains |
| `resources.defaultCpus`, `resources.maxCpus` | CPUs a container gets when the call names none, and the most it may ask for | 1 ≤ default ≤ max |
| `resources.defaultMemoryMiB`, `resources.maxMemoryMiB` | Memory, the same way | 200 ≤ default ≤ max |
| `logs.maxLines`, `logs.maxBytes` | The most a log call returns | 1–100000 lines, 1–10485760 bytes |
| `exec.timeoutSeconds` | Default and maximum time an exec may run before it is killed | 1–3600 |
| `exec.maxOutputBytes` | The most stdout and stderr an exec returns, together | 1–10485760 |
| `pull.timeoutSeconds` | Time after which a pull (and a run that has to pull) is abandoned | 1–86400 |
| `build.timeoutSeconds` | Time after which a build is abandoned | 1–86400 |
| `adopted` | Containers the server did not create that it may start and stop, never exec into or delete | Container names |

Other files the server writes, all private to you:

| File | Contents |
|---|---|
| `~/Library/Logs/container-mcp/audit.jsonl` | The audit log, one JSON line per call |
| `~/Library/Application Support/container-mcp/state.json` | The images the server pulled or built, which are the only ones it may delete |

## Tools

Every tool has a typed input schema closed with `additionalProperties: false`; the server
also rejects unknown fields and wrong types itself, whatever the client does with the
schema. Annotations: R read-only, D destructive, I idempotent, O reaches the network.

| Tool | Inputs | Hints | Notes |
|---|---|---|---|
| `system_status` | – | R | Service running, versions, whether they match, configuration state |
| `containers_list` | `all?` | R | Every container, with `owned` and `adopted` |
| `container_inspect` | `id` | R | Environment values redacted to `KEY=<redacted>` |
| `container_logs` | `id`, `lines?`, `boot?` | R | Last lines, capped at the configured lines and bytes |
| `container_stats` | `id` | R | One snapshot of a running container |
| `images_list` | – | R | With `owned` and `infrastructure` |
| `image_inspect` | `reference` | R | Index and per-platform configuration |
| `volumes_list`, `networks_list` | – | R | With `owned` |
| `disk_usage` | – | R | Images, containers, volumes |
| `container_run` | `image`, `name`, `start?`, `command?[]`, `entrypoint?`, `env?[]`, `workdir?`, `user?`, `cpus?`, `memory_mib?`, `ports?[{host_port, container_port, protocol?}]`, `mounts?[{host_path, container_path, writable?}]`, `volumes?[{volume, container_path, read_only?}]`, `network?`, `read_only_rootfs?`, `init?` | O | Creates a labelled container, started in the background unless `start` is false |
| `container_start` | `id` | I | Owned or adopted containers |
| `container_stop` | `id`, `timeout_seconds?` | D, I | Owned or adopted containers |
| `container_exec` | `id`, `command[]`, `env?[]`, `workdir?`, `user?`, `timeout_seconds?` | D | Owned, running containers; argument array; no TTY, no stdin |
| `image_pull` | `reference`, `platform?` | I, O | Listed registries only; reports progress |
| `image_build` | `context_path`, `tag`, `dockerfile?`, `build_args?[]`, `target?`, `no_cache?` | D, O | Context inside a mount root; reports progress; uses the shared `buildkit` container |
| `volume_create` | `name`, `size_mib?` | – | Labelled |
| `network_create` | `name`, `internal?`, `subnet?` | – | Labelled |
| `system_start` | – | I, O | Starts the service; never installs a kernel |
| `container_delete` | `id` | D | Owned, stopped containers |
| `image_delete` | `reference` | D | Images the server pulled or built |
| `volume_delete`, `network_delete` | `name` | D | Volumes and networks the server created |

There is no tool, and no option on any tool, for: registry login, logout and push; stopping
the service; any "all" or prune form; kill; machines and Kubernetes clusters; DNS and system
property changes; TTY, stdin, privileges, capabilities, published sockets, SSH forwarding,
custom kernels or init images, Rosetta overrides or a host address for ports.

## Limits

Each limit is enforced in `Sources/ContainerMCPCore/Policy` and has unit tests in
`Tests/ContainerMCPCoreTests` named after it. `Scripts/check_limit_tests.py` switches each
limit off in turn and checks that a test then fails.

1. **The configuration is yours.** One file at a fixed path, read at startup, never written
   by a tool. Without it only read tools work.
2. **Mount allowlist.** A host path is resolved with `realpath(3)` (symlinks, `..`, letter
   case) before it is checked, must lie inside a mount root, and is mounted read-only unless
   that root is writable and the call asks. Always refused, also when inside a root: any path
   that is, is inside, or contains the server's configuration or audit folder, `~/.ssh`,
   `~/Library`, the keychain folders, the container tool's data (`~/.config/container`, its
   application root, `/usr/local/libexec/container`); and the home folder itself and `/`.
   Volumes the server did not create cannot be mounted.
3. **Loopback only.** Every published port binds 127.0.0.1; the input has no field for an
   address. Host ports must be in the configured range.
4. **Ownership.** Everything the server creates carries `container-mcp.managed-by=container-mcp`.
   Start, stop, exec and delete refuse containers without it, except that adopted containers
   may be started and stopped. Delete also refuses running containers. Listing, inspecting,
   logs and stats work on every container. Volumes, networks and images the server did not
   create (images: did not pull while absent, or build) cannot be deleted.
5. **No host environment.** Environment variables and build arguments only as `KEY=value`;
   the key-only form is refused. At startup the server also removes from its own process
   every environment variable except `HOME`, `USER`, `LOGNAME`, `TMPDIR` and a fixed `PATH`,
   so library code that reads the environment (`SSH_AUTH_SOCK`, `BUILDKIT_COLORS`) finds
   nothing to pass on.
6. **No shell.** Commands are argument arrays from the tool input to the service; a string
   is refused. Nothing is interpolated anywhere.
7. **Bounds.** Logs are cut to the configured lines and bytes. Exec has a timeout (the
   process is killed) and an output cap. Pull and build have timeouts and report MCP
   progress. Every run gets the default CPUs and memory and cannot exceed the maximums.
8. **Images.** Pulls only from listed registries. A run whose image is not stored locally
   would pull it, so the same rule applies, also to the service's init image. A build
   context must be inside a mount root and the Dockerfile inside the context. The images a
   Dockerfile makes BuildKit fetch (`FROM`, `COPY --from`, `RUN --mount=from=`, `# syntax=`)
   must come from listed registries and may not be named through variables. A build may not
   take over the tag of an image the server did not create.
9. **Audit log.** One JSON line per call, refusals and failures included: time, tool,
   arguments with environment and build-argument values redacted, decision, the rule that
   decided, and a short result. The file is created `0600` in a `0700` folder and opened
   with `O_APPEND`. Its folder can never be mounted.
10. **Refusals** read `Refused by rule <rule>: <reason>. Allowed: <what would be>` and never
    include an environment or build-argument value.

## Threat model

The server stands between Claude and the container service. It limits what a model can make
the service do through these tools. It does **not** protect against:

- **Other software running as you.** The container service accepts any process with your
  user ID; it checks nothing else. Anything that can run `container` can do everything the
  server refuses. The same applies to the configuration file and the audit log, which any
  process running as you can rewrite.
- **What runs inside a container.** Containers have outbound network access. Code in a
  container can read everything in its read-only mounts and send it anywhere, change
  everything in its writable mounts, and reach other containers on its network, including
  ones the server did not create.
- **The images themselves.** An image from a listed registry can still be malicious, and a
  build's `RUN` steps execute with network access. The Dockerfile check only sees literal
  references in the file: an `ONBUILD` step in a base image, or a BuildKit frontend loaded
  some other way, is not checked.
- **What a build reads.** The whole build context is sent to BuildKit, including files such
  as `.env` that a `.dockerignore` does not exclude.
- **Races on paths.** A path is resolved and checked, then handed to the service, which
  mounts it later. Something that replaces the folder with a symlink in between is not
  detected. How the service treats absolute symlinks inside a mounted folder was not
  verified.
- **Local access to published ports.** Loopback keeps ports off the network, not away from
  other local processes and users.
- **Text from containers.** Logs and exec output are marked as data, but the server cannot
  stop a model from following instructions written there.
- **Resource exhaustion by count.** Each run is capped, but the number of containers,
  volumes and images is not. A volume's default size is the service's (sparse, 512 GiB).
- **The shared builder.** `image_build` uses the container tool's own `buildkit` container
  and may delete and recreate it when its settings differ, as `container build` does.
- **Tampering with the audit log.** It is append-only for the server, not tamper-evident.

## Development

```bash
swift test                                       # unit tests, fake backend
CONTAINER_MCP_INTEGRATION=1 swift test           # plus the live test against the real service
Scripts/check_limit_tests.py                     # every limit has a test that catches its removal
.build/release/container-mcp-probe .build/release/container-mcp <scratch folder>
```

The integration test and the probe create only resources named `container-mcp-it-…` or
`container-mcp-probe-…`, labelled as the server's, and delete them at the end. The
integration test needs `docker.io/library/alpine:3.21` to be absent beforehand, so that
deleting it afterwards is safe, and it starts the shared `buildkit` container, leaving it
stopped if it was stopped. The probe needs a configuration whose mount roots are the scratch
folder's `readonly` and `writable` subfolders.

## Repository layout

| Folder | Contents |
|---|---|
| `Sources/ContainerMCPCore` | Policy, configuration, audit log, tool schemas and dispatcher. Depends only on the MCP SDK. |
| `Sources/ContainerMCPNative` | The backend that talks to the container service through apple/container's client library |
| `Sources/container-mcp` | The stdio server executable |
| `Sources/container-mcp-probe` | A development MCP client that drives every tool |
| `Tests/ContainerMCPCoreTests` | Policy tests against a fake backend, one file per group of limits |
| `Tests/ContainerMCPIntegrationTests` | The opt-in live test |
| `Scripts` | The limit kill-check |
| `plugin` | The Claude plugin: manifest, MCP server entry and skills |
