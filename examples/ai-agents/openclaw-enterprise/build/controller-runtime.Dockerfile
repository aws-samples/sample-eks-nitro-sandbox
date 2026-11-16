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

FROM ${NODE_RUNTIME_BASE_IMAGE} AS console-build
WORKDIR /app
ARG OCC_BUILD_REVISION=""
COPY apps/controller/src/console/index.html apps/controller/src/console/index.html
COPY scripts/build-console-metadata.mjs scripts/build-console-metadata.mjs
RUN node scripts/build-console-metadata.mjs "$OCC_BUILD_REVISION"

FROM ${NODE_RUNTIME_BASE_IMAGE} AS runtime
RUN node -e 'const [major, minor, patch] = process.versions.node.split(".").map(Number); if (major !== 24 || minor < 22 || (minor === 22 && patch < 1)) throw new Error(`Select a Node.js 24.22.1+ base image in the 24 series; found ${process.version}.`);'
RUN apt-get update --error-on=any \
    && apt-get upgrade -y \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /usr/local/lib/node_modules/npm \
      /usr/local/lib/node_modules/corepack \
    && rm -f /usr/local/bin/npm \
      /usr/local/bin/npx \
      /usr/local/bin/corepack \
      /usr/local/bin/pnpm \
      /usr/local/bin/pnpx \
      /usr/local/bin/yarn \
      /usr/local/bin/yarnpkg

ENV NODE_ENV=production
WORKDIR /app

COPY --from=runtime-dependencies --chown=node:node /app/node_modules node_modules
COPY --from=runtime-dependencies --chown=node:node /app/apps/controller/node_modules apps/controller/node_modules
COPY --from=runtime-dependencies --chown=node:node /app/packages/audit/node_modules packages/audit/node_modules
COPY --from=runtime-dependencies --chown=node:node /app/packages/contracts/node_modules packages/contracts/node_modules
COPY --from=runtime-dependencies --chown=node:node /app/packages/iam/node_modules packages/iam/node_modules
COPY --from=runtime-dependencies --chown=node:node /app/packages/occ/node_modules packages/occ/node_modules
COPY --chown=node:node package.json package.json
RUN node -e 'const fs = require("node:fs"); const packageJson = JSON.parse(fs.readFileSync("package.json", "utf8")); delete packageJson.devDependencies; delete packageJson.scripts; delete packageJson.packageManager; fs.writeFileSync("package.json", `${JSON.stringify(packageJson, null, 2)}\n`);'
COPY --chown=node:node packages/audit/package.json packages/audit/package.json
COPY --chown=node:node packages/audit/src packages/audit/src
COPY --chown=node:node packages/contracts/package.json packages/contracts/package.json
COPY --chown=node:node packages/contracts/src packages/contracts/src
COPY --chown=node:node packages/iam/package.json packages/iam/package.json
COPY --chown=node:node packages/iam/src packages/iam/src
COPY --chown=node:node packages/occ/package.json packages/occ/package.json
COPY --chown=node:node packages/occ/src packages/occ/src
COPY --chown=node:node packages/utils/package.json packages/utils/package.json
COPY --chown=node:node packages/utils/src packages/utils/src
COPY --chown=node:node apps/controller/src apps/controller/src
COPY --chown=node:node apps/controller/plugins apps/controller/plugins
COPY --from=console-build --chown=node:node /app/apps/controller/src/console/index.html apps/controller/src/console/index.html
COPY --chown=node:node migrations/[0-9]*.sql migrations/
COPY --chown=node:node migrations/meta/_journal.json migrations/meta/_journal.json
COPY --chown=node:node migrations/meta/_canonical-history.json migrations/meta/_canonical-history.json
COPY --chown=node:node scripts/migrate-production.mjs scripts/migrate-production.mjs
COPY --chown=node:node scripts/migration-history.mjs scripts/migration-history.mjs
COPY --chown=node:node scripts/migration-catalog.mjs scripts/migration-catalog.mjs
COPY --chown=node:node scripts/bootstrap-installation.mjs scripts/bootstrap-installation.mjs
COPY --chown=node:node scripts/lib/bootstrap-configuration.mjs scripts/lib/bootstrap-configuration.mjs
COPY --chown=node:node scripts/auth-maintain.mjs scripts/auth-maintain.mjs
COPY --chown=node:node scripts/auth-maintain.ts scripts/auth-maintain.ts
COPY --chown=node:node scripts/lib/auth-maintain-arguments.mjs scripts/lib/auth-maintain-arguments.mjs
COPY --chown=node:node scripts/lib/auth-maintain-arguments.ts scripts/lib/auth-maintain-arguments.ts
COPY --chown=node:node deploy/presets deploy/presets
COPY --chown=node:node scripts/production-healthcheck.mjs scripts/production-healthcheck.mjs
RUN --mount=type=bind,source=pnpm-lock.yaml,target=/app/pnpm-lock.yaml,readonly \
    node apps/controller/src/precompile-route-schemas.mjs \
    && test ! -e /usr/local/lib/node_modules/npm \
    && test -z "$(find /app/node_modules/.pnpm -mindepth 1 -maxdepth 1 \
      \( -name 'esbuild@*' \
      -o -name '@esbuild+*' \
      -o -name '@esbuild-kit+*' \
      -o -name 'tsx@*' \
      -o -name 'drizzle-kit@*' \) -print -quit)"

USER node
ENTRYPOINT ["node"]
CMD ["apps/controller/src/server.mjs"]
