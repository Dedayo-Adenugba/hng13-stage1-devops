FROM node:20-alpine

WORKDIR /app

# copy both files so npm ci can use the lockfile
COPY package.json package-lock.json ./

# deterministic production install
RUN npm ci --omit=dev

# copy the rest of the app
COPY . .

ENV PORT=3000
EXPOSE 3000

# healthcheck (uses curl; install it on alpine)
RUN apk add --no-cache curl
HEALTHCHECK --interval=30s --timeout=3s --retries=3 CMD curl -fsS http://127.0.0.1:3000/health || exit 1

CMD ["npm", "start"]
