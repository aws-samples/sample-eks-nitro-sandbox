# The web app image: the Node server, and xterm.js vendored from node_modules so the
# page loads no third-party CDN. Pins in package.json; recorded in the README.
FROM public.ecr.aws/docker/library/node:22-bookworm-slim

WORKDIR /app

# Install dependencies first for layer caching.
COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force

# Vendor the browser xterm assets into public/vendor (served as same-origin static files).
RUN set -eu; \
    mkdir -p public/vendor; \
    cp node_modules/@xterm/xterm/lib/xterm.js public/vendor/xterm.js; \
    cp node_modules/@xterm/xterm/css/xterm.css public/vendor/xterm.css; \
    cp node_modules/@xterm/addon-fit/lib/addon-fit.js public/vendor/xterm-addon-fit.js

COPY server ./server
COPY public ./public

# Run as the stock non-root `node` user (uid 1000 on this base image).
RUN chown -R node:node /app
USER node

EXPOSE 8080
CMD ["node", "server/index.js"]
