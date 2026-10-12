FROM nginx:alpine

LABEL maintainer="AI DevOps Agent"
LABEL name="static-website"
LABEL description="Static HTML website served with nginx"
LABEL version="1.0.0"

# Install curl for healthcheck and create non-root user
RUN apk add --no-cache curl && \
    adduser -S appuser

WORKDIR /usr/share/nginx/html

# Copy static assets first (grouped for layer caching)
COPY css/ css/
COPY webfonts/ webfonts/
COPY imgs/ imgs/

# Copy HTML source files
COPY *.html ./

# Copy custom nginx config if needed and fix permissions for non-root runtime
RUN chown -R appuser:0 /usr/share/nginx/html && \
    chmod -R g+rw /usr/share/nginx/html && \
    chown -R appuser:0 /var/cache/nginx && \
    chown -R appuser:0 /var/run && \
    mkdir -p /var/cache/nginx/client_temp && \
    chown -R appuser:0 /var/cache/nginx/client_temp

# Create health endpoint file
RUN echo "OK" > /usr/share/nginx/html/health

# USER appuser

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 CMD curl --fail http://localhost:80/health || exit 1

CMD ["nginx", "-g", "daemon off;"]
