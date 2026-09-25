# ---------- Stage 1: install production dependencies ----------
FROM node:20-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# ---------- Stage 2: runtime image ----------
FROM node:20-alpine AS runtime
ENV NODE_ENV=production
WORKDIR /app
RUN apk add --no-cache curl
COPY --from=deps /app/node_modules ./node_modules
COPY . .
USER node
EXPOSE 8080
CMD ["node", "server.js"]
