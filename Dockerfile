FROM nginxinc/nginx-unprivileged:alpine

LABEL org.opencontainers.image.title="madgical-ai-responsive-dashboard" \
      org.opencontainers.image.description="Static HTML/CSS dashboard served by unprivileged nginx" \
      org.opencontainers.image.version="1.0.0"

USER root

# Static assets (grouped for better layer caching: rarely-changing assets first)
COPY css/ /usr/share/nginx/html/css/
COPY webfonts/ /usr/share/nginx/html/webfonts/
COPY imgs/ /usr/share/nginx/html/imgs/

# HTML entry points
COPY *.html /usr/share/nginx/html/

# Lightweight health endpoint file + correct ownership for the non-root user
RUN printf 'OK\n' > /usr/share/nginx/html/health && \
    chown -R 101:0 /usr/share/nginx/html && \
    chmod -R g+rwX /usr/share/nginx/html

# Drop privileges to the non-root nginx user (uid 101)
USER 101

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8080/health || exit 1

CMD ["nginx", "-g", "daemon off;"]
