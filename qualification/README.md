# LiteLLM Gateway qualification

FlowAI packages the official LiteLLM `v1.104.0-rc.2` OCI index
`sha256:bc803c88c244d6193b0f40bffad1124c624109513e56332b03c20d121a9546fb`.
The upstream release commit is `e926084212ab2eb234c58840d741b3c62c35911b`.
Independent qualification targets Linux amd64. The upstream arm64
descriptor is verified, and arm64 runtime qualification remains pending.

The first build stage removes the commercially licensed `enterprise/`
source tree, its release archives, and the installed `litellm_enterprise`
package and metadata. The final stage copies that filesystem into a new
image. It includes the original upstream license, existing dependency
notices, and both PgBouncer 1.25.2 notices. Installed MIT-licensed proxy
extras provide the database migrations.

Dispatch **Qualify LiteLLM Gateway source** on the candidate ref with its
full revision as `expected_source_sha`. The workflow reports the upstream
index and platform manifest digests, then checks all layers of the
runner-local OCI image and reports its amd64 image manifest digest.
The packaged wrapper must reject missing credentials, start as UID and
GID 65532 with a disposable PostgreSQL dependency, and retain FlowAI
model metadata after gateway recreation.

The platform repository retains Model Registry’s integration cases and
the active LiteLLM route and E2E inputs. The original reports remain in
the platform’s baseline history. Independent qualification does not
exercise deployment routes, real provider calls, virtual-key lifecycle,
pricing, spend and budget behavior, or database-backed restore. Use the
platform’s qualification and deployment procedure for those gates.
