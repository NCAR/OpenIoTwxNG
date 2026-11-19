# syntax=docker/dockerfile:1
# One image runs the web app, the API and the MQTT bridge (different commands).

FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
# The node-server preset (the default) builds .output/server/index.mjs.
RUN npm run build

FROM node:22-alpine AS run
WORKDIR /app
ENV NODE_ENV=production HOST=0.0.0.0 PORT=8080
COPY --from=build /app/.output ./.output
COPY --from=build /app/migrations ./migrations
COPY --from=build /app/scripts ./scripts
# The migrator and the MQTT bridge are plain scripts that need pg / mqtt at runtime.
RUN npm init -y >/dev/null && npm install --omit=dev --ignore-scripts pg@^8 mqtt@^5 && npm cache clean --force
# The running image needs node and nothing else. npm, npx, corepack and yarn only came with the base image and were
# used above, once, at build time; leaving them in would ship their dependencies (and their known vulnerabilities).
# `apk upgrade` brings the operating-system packages (zlib and friends) up to date.
RUN apk upgrade --no-cache \
 && rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
           /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack /usr/local/bin/yarn /usr/local/bin/yarnpkg /opt/yarn-*
USER node
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s \
  CMD wget -qO- http://127.0.0.1:8080/api/health || exit 1
CMD ["node", ".output/server/index.mjs"]
