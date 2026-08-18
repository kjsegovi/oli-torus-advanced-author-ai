FROM mcr.microsoft.com/playwright:v1.56.1-noble

USER root
WORKDIR /opt/torus

COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force

COPY validate-simulation.cjs ./validate-simulation.cjs

USER pwuser
ENTRYPOINT ["node", "/opt/torus/validate-simulation.cjs"]
