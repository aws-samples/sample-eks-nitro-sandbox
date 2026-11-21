# Build the pinned OCE controller source without carrying build tooling into the
# runtime image. Both bases are supplied as immutable digest references by the
# sample build script.
ARG NODE_BUILD_BASE_IMAGE
ARG NODE_RUNTIME_BASE_IMAGE

FROM ${NODE_BUILD_BASE_IMAGE} AS dependencies
RUN apt-get update --error-on=any \
    && apt-get upgrade -y \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN node -e 'const [major, minor, patch] = process.versions.node.split(".").map(Number); if (major !== 24 || minor < 22 || (minor === 22 && patch < 1)) throw new Error(`Select a Node.js 24.22.1+ base image in the 24 series; found ${process.version}.`);'
COPY LICENSE package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY apps/controller/package.json apps/controller/package.json
COPY packages/audit/package.json packages/audit/package.json
COPY packages/contracts/package.json packages/contracts/package.json
COPY packages/iam/package.json packages/iam/package.json
COPY packages/occ/package.json packages/occ/package.json
COPY packages/utils/package.json packages/utils/package.json
RUN --mount=type=secret,id=corepack-env,required=false \
    --mount=type=secret,id=build-ca,required=false \
    set -eu; \
    if [ -f /run/secrets/build-ca ]; then export NODE_EXTRA_CA_CERTS=/run/secrets/build-ca; fi; \
    COREPACK_ENV_FILE=/run/secrets/corepack-env corepack pnpm --version
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc,required=false \
    --mount=type=secret,id=build-ca,required=false \
    set -eu; \
    if [ -f /run/secrets/build-ca ]; then export NODE_EXTRA_CA_CERTS=/run/secrets/build-ca; fi; \
    COREPACK_ENABLE_NETWORK=0 \
    corepack pnpm install --frozen-lockfile --prod --ignore-scripts

# These packages are build and migration tooling, not controller runtime
# dependencies. Some pnpm versions retain their optional binaries in the
# virtual store even after a production-only workspace install.
FROM dependencies AS runtime-dependencies
RUN set -eu; \
    find /app/node_modules/.pnpm -mindepth 1 -maxdepth 1 \
      \( -name 'esbuild@*' \
      -o -name '@esbuild+*' \
      -o -name '@esbuild-kit+*' \
      -o -name 'tsx@*' \
      -o -name 'drizzle-kit@*' \) \
      -exec rm -rf -- {} +; \
    find /app -type l ! -exec test -e {} \; -delete; \
    rm -f /app/node_modules/.bin/esbuild \
      /app/node_modules/.bin/tsx \
      /app/node_modules/.bin/drizzle-kit; \
    test -z "$(find /app/node_modules/.pnpm -mindepth 1 -maxdepth 1 \
      \( -name 'esbuild@*' \
      -o -name '@esbuild+*' \
      -o -name '@esbuild-kit+*' \
      -o -name 'tsx@*' \
      -o -name 'drizzle-kit@*' \) -print -quit)"

FROM ${NODE_BUILD_BASE_IMAGE} AS console-build
WORKDIR /app
ARG OCC_BUILD_REVISION=""
COPY apps/controller/src/console/index.html apps/controller/src/console/index.html
COPY scripts/build-console-metadata.mjs scripts/build-console-metadata.mjs
RUN node scripts/build-console-metadata.mjs "$OCC_BUILD_REVISION"

FROM ${NODE_BUILD_BASE_IMAGE} AS runtime-prepared
RUN node -e 'const [major, minor, patch] = process.versions.node.split(".").map(Number); if (major !== 24 || minor < 22 || (minor === 22 && patch < 1)) throw new Error(`Select a Node.js 24.22.1+ base image in the 24 series; found ${process.version}.`);'

ENV NODE_ENV=production
WORKDIR /app

COPY --from=runtime-dependencies --chown=1000:1000 /app/node_modules node_modules
COPY --from=runtime-dependencies --chown=1000:1000 /app/apps/controller/node_modules apps/controller/node_modules
COPY --from=runtime-dependencies --chown=1000:1000 /app/packages/audit/node_modules packages/audit/node_modules
COPY --from=runtime-dependencies --chown=1000:1000 /app/packages/contracts/node_modules packages/contracts/node_modules
COPY --from=runtime-dependencies --chown=1000:1000 /app/packages/iam/node_modules packages/iam/node_modules
COPY --from=runtime-dependencies --chown=1000:1000 /app/packages/occ/node_modules packages/occ/node_modules
COPY --chown=1000:1000 package.json package.json
RUN node -e 'const fs = require("node:fs"); const packageJson = JSON.parse(fs.readFileSync("package.json", "utf8")); delete packageJson.devDependencies; delete packageJson.scripts; delete packageJson.packageManager; fs.writeFileSync("package.json", `${JSON.stringify(packageJson, null, 2)}\n`);'
COPY --chown=1000:1000 packages/audit/package.json packages/audit/package.json
COPY --chown=1000:1000 packages/audit/src packages/audit/src
COPY --chown=1000:1000 packages/contracts/package.json packages/contracts/package.json
COPY --chown=1000:1000 packages/contracts/src packages/contracts/src
COPY --chown=1000:1000 packages/iam/package.json packages/iam/package.json
COPY --chown=1000:1000 packages/iam/src packages/iam/src
COPY --chown=1000:1000 packages/occ/package.json packages/occ/package.json
COPY --chown=1000:1000 packages/occ/src packages/occ/src
COPY --chown=1000:1000 packages/utils/package.json packages/utils/package.json
COPY --chown=1000:1000 packages/utils/src packages/utils/src
COPY --chown=1000:1000 apps/controller/src apps/controller/src
COPY --chown=1000:1000 apps/controller/plugins apps/controller/plugins
COPY --from=console-build --chown=1000:1000 /app/apps/controller/src/console/index.html apps/controller/src/console/index.html
COPY --chown=1000:1000 migrations/[0-9]*.sql migrations/
COPY --chown=1000:1000 migrations/meta/_journal.json migrations/meta/_journal.json
COPY --chown=1000:1000 migrations/meta/_canonical-history.json migrations/meta/_canonical-history.json
COPY --chown=1000:1000 scripts/migrate-production.mjs scripts/migrate-production.mjs
COPY --chown=1000:1000 scripts/migration-history.mjs scripts/migration-history.mjs
COPY --chown=1000:1000 scripts/migration-catalog.mjs scripts/migration-catalog.mjs
COPY --chown=1000:1000 scripts/bootstrap-installation.mjs scripts/bootstrap-installation.mjs
COPY --chown=1000:1000 scripts/lib/bootstrap-configuration.mjs scripts/lib/bootstrap-configuration.mjs
COPY --chown=1000:1000 scripts/auth-maintain.mjs scripts/auth-maintain.mjs
COPY --chown=1000:1000 scripts/auth-maintain.ts scripts/auth-maintain.ts
COPY --chown=1000:1000 scripts/lib/auth-maintain-arguments.mjs scripts/lib/auth-maintain-arguments.mjs
COPY --chown=1000:1000 scripts/lib/auth-maintain-arguments.ts scripts/lib/auth-maintain-arguments.ts
COPY --chown=1000:1000 deploy/presets deploy/presets
COPY --chown=1000:1000 scripts/production-healthcheck.mjs scripts/production-healthcheck.mjs
RUN --mount=type=bind,source=pnpm-lock.yaml,target=/app/pnpm-lock.yaml,readonly \
    node apps/controller/src/precompile-route-schemas.mjs \
    && test -z "$(find /app/node_modules/.pnpm -mindepth 1 -maxdepth 1 \
      \( -name 'esbuild@*' \
      -o -name '@esbuild+*' \
      -o -name '@esbuild-kit+*' \
      -o -name 'tsx@*' \
      -o -name 'drizzle-kit@*' \) -print -quit)"

# Ship only the prepared application and the Node runtime. The distroless image
# contains no shell or package manager, reducing the controller attack surface.
FROM ${NODE_RUNTIME_BASE_IMAGE} AS runtime
ENV NODE_ENV=production
ENV PATH="/nodejs/bin:${PATH}"
WORKDIR /app
COPY --from=runtime-prepared --chown=1000:1000 /app /app
USER 1000:1000
RUN ["/nodejs/bin/node", "-e", "const fs = require('node:fs'); const [major, minor, patch] = process.versions.node.split('.').map(Number); if (major !== 24 || minor < 22 || (minor === 22 && patch < 1)) throw new Error(`Expected Node.js 24.22.1+ in the 24 series; found ${process.version}.`); if (process.getuid() !== 1000 || process.getgid() !== 1000) throw new Error(`Expected UID:GID 1000:1000; found ${process.getuid()}:${process.getgid()}.`); for (const path of ['/bin/sh', '/bin/bash', '/usr/bin/apt', '/usr/bin/apt-get', '/usr/bin/dpkg']) if (fs.existsSync(path)) throw new Error(`Unexpected runtime tool: ${path}`);"]
ENTRYPOINT ["/nodejs/bin/node"]
CMD ["apps/controller/src/server.mjs"]
