# FlowAI production packaging. LiteLLM v1.104.0-rc.2, pinned by its OCI index.
FROM ghcr.io/berriai/litellm@sha256:bc803c88c244d6193b0f40bffad1124c624109513e56332b03c20d121a9546fb AS prepared

USER root
# The source tree also contains enterprise release archives.
# Keep the installed MIT proxy-extras package and its migration resources.
# Its parallel source checkout contains historical release archives.
RUN rm -rf /app/enterprise \
           /app/litellm-proxy-extras/dist \
           /app/.venv/lib/python3.13/site-packages/litellm_enterprise \
           /app/.venv/lib/python3.13/site-packages/litellm_enterprise-*.dist-info \
 && /app/.venv/bin/python -B -c "from importlib.util import find_spec; assert find_spec('litellm_enterprise') is None"

# Copy the sanitized filesystem into new layers and recreate the runtime config.
FROM scratch
COPY --from=prepared / /
COPY config/litellm.yaml /etc/flowai-litellm/litellm.yaml
COPY --chmod=0755 entrypoint.sh /usr/local/bin/flowai-litellm-gateway
COPY licenses/PgBouncer* /usr/share/licenses/flowai-litellm-gateway/
COPY LICENSE /usr/share/licenses/flowai-litellm-gateway/LICENSE
COPY licenses/LiteLLM-LICENSE /usr/share/licenses/flowai-litellm-gateway/LiteLLM-LICENSE

WORKDIR /app
ENV PATH=/app/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/sbin:/bin \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    PRISMA_BINARY_CACHE_DIR=/opt/prisma/binaries \
    PRISMA_CLI_PATH=/opt/prisma/binaries/node_modules/.bin/prisma \
    PRISMA_CLI_QUERY_ENGINE_TYPE=binary \
    PRISMA_OFFLINE_MODE=true \
    HOME=/tmp
USER 65532:65532
EXPOSE 4000/tcp
ENTRYPOINT ["/usr/local/bin/flowai-litellm-gateway"]
