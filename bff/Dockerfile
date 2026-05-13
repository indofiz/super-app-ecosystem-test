FROM node:20-alpine AS build
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build && npm prune --omit=dev

FROM node:20-alpine
WORKDIR /app
# AUDIT PR-2:
#   - tini handles PID-1 signal forwarding so SIGTERM cleanly reaches Node.
#   - --enable-source-maps decodes stack traces against the emitted .map files.
#   - HEALTHCHECK gives the orchestrator a built-in liveness signal.
#   - Read-only app tree narrows the blast radius of any RCE.
RUN apk add --no-cache tini wget && addgroup -S app && adduser -S app -G app
ENV NODE_ENV=production \
    NODE_OPTIONS=--enable-source-maps
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY package.json ./
RUN chown -R app:app /app && chmod -R a-w /app/dist /app/node_modules
USER app
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:3000/readyz >/dev/null 2>&1 || exit 1
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "dist/index.js"]
