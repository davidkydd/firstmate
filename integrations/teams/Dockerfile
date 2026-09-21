FROM node:22.22.0-alpine3.22@sha256:7aa86fa052f6e4b101557ccb56717cb4311be1334381f526fe013418fe157384 AS dependencies
WORKDIR /app
COPY integrations/teams/package.json integrations/teams/package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force

FROM node:22.22.0-alpine3.22@sha256:7aa86fa052f6e4b101557ccb56717cb4311be1334381f526fe013418fe157384
ENV NODE_ENV=production
WORKDIR /app
USER node
COPY --from=dependencies --chown=node:node /app/node_modules ./node_modules
COPY --chown=node:node integrations/teams/package.json ./package.json
COPY --chown=node:node integrations/teams/src ./src
EXPOSE 8080
CMD ["node", "src/cloud-main.mjs"]
