---
name: "container-image-build"
description: "Builds a container image from a project folder with the container-mcp image_build tool for Apple's container tool on this Mac: reads the Dockerfile's base images, checks what the folder would send to the builder, chooses the tag, builds and diagnoses a failed build. Use when the user asks to build or rebuild an image, types container build, docker build, construir la imagen, compila la imagen, mentions a Dockerfile or Containerfile to build or a build step that fails, or wants an image of their app. Not for running, starting or debugging a container made from the image, which is managing containers."
---

# Container image build

How to turn a project folder into a tagged image with the container-mcp `image_build` tool,
so that the build passes the user's policy the first time and sends the builder nothing it
should not see.

## Tools

- `image_build`: builds one tag from a context folder; its description lists what it
  refuses. Two traps it does not state:
  - Ignore patterns are read only from a file named after the Dockerfile plus
    `.dockerignore`, next to it (`Dockerfile.dockerignore` for `Dockerfile`). A plain
    `.dockerignore` in the project is not applied.
  - A failed build returns the builder's error, not the full build log.
- `system_status`: the registries and mount roots the policy allows.
- `images_list`: the tags that already exist.
- The session's file tools, to read the Dockerfile and write the ignore file.

## Procedure

1. **Read the Dockerfile.** List every image it fetches: each `FROM` that is not an earlier
   stage, `COPY --from=` and `RUN --mount=…,from=` naming an image, and a `# syntax=` line.
   Each must be a literal reference from a registry `system_status` lists. When one is not,
   tell the user which line and why; change it only with their agreement, and never to the
   same image from a different registry without saying so.
2. **Check the context.** Everything in the folder is sent to the builder unless ignored.
   Look for secrets and bulk: `.env`, keys, credentials, `.git`, dependency and build output
   folders. When the project has a `.dockerignore`, propose copying it to the name the tool
   reads; otherwise propose one. Write it only once the user agrees.
3. **Choose the tag** as `name:version`, checking with `images_list` that it is not taken by
   an image the server did not create.
4. **Build** with `image_build`. Before the first build of the conversation, ask the user:
   it starts the container tool's shared builder, and may delete and recreate it.
5. **Read a failure.** Find the instruction the error names and propose the fix to that step;
   edit the user's Dockerfile only with their agreement. Use `no_cache` only when a cached
   layer is the suspected cause. When the error does not say enough, build up to the
   failing stage with `target`, or, with the user's agreement, a separate test Dockerfile inside
   the context passed as `dockerfile` and deleted afterwards, rather than changing the original.
6. **Confirm** with `images_list` that the tag exists and is owned by the server.

## Before finishing

- [ ] Every fetched image is a literal reference from an allowed registry, and any change to
      one was agreed.
- [ ] The user knows what the context sends, and secrets are ignored or absent.
- [ ] The final message names the tag built, or the failing step and the proposed fix, and
      says whether the shared builder was left running (`containers_list`).

## Files

- `SKILL.md`: this procedure; the skill has no other files.
