FROM node:lts-trixie AS astrodev
WORKDIR /app

RUN apt-get update \
	&& apt-get install -y --no-install-recommends zip \
	&& rm -rf /var/lib/apt/lists/*

ENV HOST=0.0.0.0
ENV PORT=3033
EXPOSE 3033
EXPOSE 3034
CMD ["bash", "-c", "cd /app && \
npx astro telemetry disable && \
npm install && \
node build-server.mjs & \
npm run docker-dev"]
