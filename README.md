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
diagnostics go to stderr. The plugin in `plugin/` packages it with its skills and its
settings; `plugin/README.md` says how to install it.

## Configuration

The policy is set in the plugin's settings: in Claude Code, `/plugin configure
container-mcp@container-mcp`, or from a shell:

```bash
claude plugin configure container-mcp@container-mcp --values-stdin < values.json
```

where `values.json` maps option keys to strings, for example
`{"write_tools_enabled": "true", "read_only_folders": "/Users/user/Code"}`. Claude Code
saves the values under `pluginConfigs` in your user settings (project settings cannot set
them) and passes them to the server as launch arguments when it starts it. The server
reads them once; no tool can change them. Restart Claude Code after changing them.

Write tools stay off until you turn on **Allow write tools**. Until then, and whenever the
values are invalid or the server is started without them, only the read tools work and
`system_status` says why. Unknown or missing options make the settings invalid, so a typo
cannot silently drop a limit.

| Option | Meaning | Default |
|---|---|---|
| `write_tools_enabled` | Allow write tools | off |
| `read_only_folders` | Folders containers may mount, read-only, and builds may read. Resolved (symlinks, `..`) when the server starts; each must exist. | none |
| `writable_folders` | Folders under which a mount may be read-write when the call asks | none |
| `host_port_min`, `host_port_max` | Host ports a container may publish, always on 127.0.0.1 (1024–65535) | 8000–8999 |
| `registries` | Registry domains images may be pulled from. `docker.io`, `registry-1.docker.io` and `index.docker.io` count as one. | docker.io, ghcr.io |
| `default_cpus`, `max_cpus` | CPUs a container gets when the call names none, and the most it may ask for | 2, 4 |
| `default_memory_mib`, `max_memory_mib` | Memory, the same way (at least 200 MiB) | 1024, 4096 |
| `log_max_lines`, `log_max_bytes` | The most a log call returns | 500, 65536 |
| `exec_timeout_seconds`, `exec_max_output_bytes` | Default and maximum time an exec may run before it is killed, and the most stdout plus stderr it returns | 60, 65536 |
| `pull_timeout_seconds`, `build_timeout_seconds` | Time after which a pull (or a run that has to pull) and a build are abandoned | 600, 1800 |
| `protected_containers` | Containers no tool may touch: no start, stop, exec, delete, inspect, logs or stats. Listing shows only their name and status. Every other container may be managed. | none |

Claude Code passes list options as one comma-separated argument, so a folder whose path
contains a comma cannot be listed.

Started outside the plugin, the server takes the same values as `--option value` pairs, one
per option (`--write-tools-enabled true --read-only-folders /Users/user/Code …`, every option
listed in `ConfigurationArguments.options`). With no arguments it runs read-only.

Files the server writes, all private to you:

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
| `containers_list` | `all?` | R | Every container, with `owned`, `protected` and `infrastructure`; protected ones show only name and status |
| `container_inspect` | `id` | R | Environment values redacted to `KEY=<redacted>`; refuses protected containers |
| `container_logs` | `id`, `lines?`, `boot?` | R | Last lines, capped at the configured lines and bytes |
| `container_stats` | `id` | R | One snapshot of a running container |
| `images_list` | – | R | With `owned` and `infrastructure` |
| `image_inspect` | `reference` | R | Index and per-platform configuration |
| `volumes_list`, `networks_list` | – | R | With `owned` |
| `disk_usage` | – | R | Images, containers, volumes |
| `container_run` | `image`, `name`, `start?`, `command?[]`, `entrypoint?`, `env?[]`, `workdir?`, `user?`, `cpus?`, `memory_mib?`, `ports?[{host_port, container_port, protocol?}]`, `mounts?[{host_path, container_path, writable?}]`, `volumes?[{volume, container_path, read_only?}]`, `network?`, `read_only_rootfs?`, `init?` | O | Creates a labelled container, started in the background unless `start` is false |
| `container_start` | `id` | I | Any container that is not protected or the container tool's own |
| `container_stop` | `id`, `timeout_seconds?` | D, I | The same |
| `container_exec` | `id`, `command[]`, `env?[]`, `workdir?`, `user?`, `timeout_seconds?` | D | Running containers that are not protected or the container tool's own; argument array; no TTY, no stdin |
| `image_pull` | `reference`, `platform?` | I, O | Listed registries only; reports progress |
| `image_build` | `context_path`, `tag`, `dockerfile?`, `build_args?[]`, `target?`, `no_cache?` | D, O | Context inside a mount root; reports progress; uses the shared `buildkit` container |
| `volume_create` | `name`, `size_mib?` | – | Labelled |
| `network_create` | `name`, `internal?`, `subnet?` | – | Labelled |
| `system_start` | – | I, O | Starts the service; never installs a kernel |
| `container_delete` | `id` | D | Stopped containers that are not protected or the container tool's own |
| `image_delete` | `reference` | D | Images the server pulled or built |
| `volume_delete`, `network_delete` | `name` | D | Volumes and networks the server created |

There is no tool, and no option on any tool, for: registry login, logout and push; stopping
the service; any "all" or prune form; kill; machines and Kubernetes clusters; DNS and system
property changes; TTY, stdin, privileges, capabilities, published sockets, SSH forwarding,
custom kernels or init images, Rosetta overrides or a host address for ports.

## Limits

Each limit is enforced in `Sources/ContainerMCPCore/Policy` and has unit tests in
`Tests/ContainerMCPCoreTests` named after it. `Scripts/check-limit-tests.swift` switches each
limit off in turn and checks that a test then fails.

1. **The policy is yours.** It comes from the plugin's settings, which only your user (or
   managed) settings can hold, is read once at startup and is changed by no tool. Without it,
   or until you allow write tools, only read tools work.
2. **Mount allowlist.** A host path is resolved with `realpath(3)` (symlinks, `..`, letter
   case) before it is checked, must lie inside a mount root, and is mounted read-only unless
   that root is writable and the call asks. Always refused, also when inside a root: any path
   that is, is inside, or contains the server's state or audit folder, Claude Code's
   settings (`~/.claude`, and the real folder of its settings file when that is a link),
   `~/.ssh`, `~/Library`, the keychain folders, the container tool's data (`~/.config/container`, its
   application root, `/usr/local/libexec/container`); and the home folder itself and `/`.
   Volumes the server did not create cannot be mounted.
3. **Loopback only.** Every published port binds 127.0.0.1; the input has no field for an
   address. Host ports must be in the configured range.
4. **Ownership.** Containers listed as protected cannot be touched by any tool: not
   started, stopped, exec'd into, deleted, inspected, read for logs or stats, and listing shows
   only their name and status. The list applies even while write tools are off. The container
   tool's own containers (labelled with a `com.apple.container` role or plugin, such as
   `buildkit`) can be read but never changed. Every other container may be managed; delete
   refuses running ones. Everything the server creates carries
   `container-mcp.managed-by=container-mcp`, and volumes, networks and images the server did
   not create (images: did not pull while absent, or build) cannot be deleted.
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
  server refuses. The same applies to Claude Code's settings, which hold the policy, and to
  the audit log: any process running as you can rewrite them, including Claude Code itself
  when it edits files on your behalf.
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
- **Containers you did not protect.** Any container that is not listed as protected can be
  stopped or deleted through the tools, including ones you made yourself. List the ones that
  matter.
- **The shared builder.** `image_build` uses the container tool's own `buildkit` container
  and may delete and recreate it when its settings differ, as `container build` does.
- **Tampering with the audit log.** It is append-only for the server, not tamper-evident.

## Development

```bash
swift test                                       # unit tests, fake backend
CONTAINER_MCP_INTEGRATION=1 swift test           # plus the live test against the real service
swift Scripts/check-limit-tests.swift            # every limit has a test that catches its removal
.build/release/container-mcp-probe .build/release/container-mcp <scratch folder> <policy options…>
```

The integration test and the probe create only resources named `container-mcp-it-…` or
`container-mcp-probe-…`, labelled as the server's, and delete them at the end. The
integration test needs `docker.io/library/alpine:3.21` to be absent beforehand, so that
deleting it afterwards is safe, and it starts the shared `buildkit` container, leaving it
stopped if it was stopped. The probe passes the policy options to the server itself; its read-only
and writable folders must be the scratch folder's `readonly` and `writable` subfolders.

## Repository layout

| Folder | Contents |
|---|---|
| `Sources/ContainerMCPCore` | Policy, the settings parser, audit log, tool schemas and dispatcher. Depends only on the MCP SDK. |
| `Sources/ContainerMCPNative` | The backend that talks to the container service through apple/container's client library |
| `Sources/container-mcp` | The stdio server executable |
| `Sources/container-mcp-probe` | A development MCP client that drives every tool |
| `Tests/ContainerMCPCoreTests` | Policy tests against a fake backend, one file per group of limits |
| `Tests/ContainerMCPIntegrationTests` | The opt-in live test |
| `Scripts` | The limit kill-check |
| `plugin` | The Claude plugin: manifest, MCP server entry and skills |

## License

MIT. See `LICENSE`.
