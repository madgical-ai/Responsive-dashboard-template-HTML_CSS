# syntax=docker/dockerfile:1
# Static HTML/CSS/JS dashboard template served by nginx.
# Single stage: there is no compile/build step, assets are served as-is.
# Base image runs nginx as a non-root user (uid 101) out of the box.
FROM nginxinc/nginx-unprivileged:1.27-alpine

LABEL org.opencontainers.image.title="Responsive Dashboard Template" \
      org.opencontainers.image.description="Static HTML/CSS/JS dashboard served by nginx (non-root)" \
      org.opencontainers.image.licenses="MIT" \
      maintainer="AI DevOps Agent"

ENV NGINX_PORT=80 \
    NGINX_ENTRYPOINT_QUIET_LOGS=1

# Drop a hardened server config (write it as root, then hand it back to nginx)
USER root
RUN printf '%s\n' \
      'server {' \
      '    listen       80;' \
      '    listen       [::]:80;' \
      '    server_name  _;' \
      '' \
      '    root   /usr/share/nginx/html;' \
      '    index  index.html;' \
      '' \
      '    charset utf-8;' \
      '' \
      '    location = /healthz {' \
      '        access_log off;' \
      '        default_type text/plain;' \
      '        return 200 "OK";' \
      '    }' \
      '' \
      '    gzip              on;' \
      '    gzip_vary         on;' \
      '    gzip_min_length   1024;' \
      '    gzip_comp_level   5;' \
      '    gzip_types        text/plain text/css text/xml application/json' \
      '                      application/javascript application/xml+rss' \
      '                      image/svg+xml;' \
      '' \
      '    add_header X-Content-Type-Options nosniff always;' \
      '    add_header X-Frame-Options SAMEORIGIN always;' \
      '    add_header Referrer-Policy strict-origin-when-cross-origin always;' \
      '' \
      '    # Long-lived cache for hashed/static assets' \
      '    location ~* \.(?:css|js|mjs|png|jpe?g|gif|webp|avif|svg|ico|woff2?|ttf|eot)$ {' \
      '        access_log off;' \
      '        expires 30d;' \
      '        add_header Cache-Control "public, max-age=2592000, immutable";' \
      '    }' \
      '' \
      '    # Pretty URLs: /courses -> /courses.html' \
      '    location / {' \
      '        try_files $uri $uri/ $uri.html $uri/index.html =404;' \
      '    }' \
      '}' \
      > /etc/nginx/conf.d/default.conf \
    && chown 101:101 /etc/nginx/conf.d/default.conf \
    && chmod 0644 /etc/nginx/conf.d/default.conf \
    && rm -f /usr/share/nginx/html/index.html /usr/share/nginx/html/50x.html

# Copy the static site (only web-servable assets)
COPY --chown=101:101 *.html /usr/share/nginx/html/
COPY --chown=101:101 css/ /usr/share/nginx/html/css/
COPY --chown=101:101 webfonts/ /usr/share/nginx/html/webfonts/
COPY --chown=101:101 imgs/ /usr/share/nginx/html/imgs/

# Run as the image's non-root nginx user
USER 101

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -q -O /dev/null "http://127.0.0.1:${NGINX_PORT}/healthz" || exit 1

CMD ["nginx", "-g", "daemon off;"]
