# The common node:lts plus corepack pattern. Node 26 images ship without
# corepack, so this broke when node:lts moved to Node 26 on 2026-10-28: the
# build now stops at corepack enable with "corepack: not found".
FROM node:lts-slim
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
WORKDIR /app
COPY package.json index.js ./
RUN corepack enable && pnpm install
EXPOSE 3000
CMD ["node", "index.js"]
