# syntax=docker/dockerfile:1
# ---------------------------------------------------------------------------
# Madgical AI - Responsive Dashboard Template (HTML5 / CSS3)
# Pure static site: no build step, assets are served directly by nginx.
# Runs as an unprivileged user (uid 1001) and serves on port 80 (and 8080).
# ---------------------------------------------------------------------------
FROM nginx:1.27-alpine

LABEL org.opencontainers.image.title="madgical-ai-responsive-dashboard-template" \
      org.opencontainers.image.description="Responsive dashboard UI template (HTML5 + CSS3) served by nginx" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="docker.io/library/nginx:1.27-alpine"

# --- Unprivileged runtime user ---------------------------------------------
RUN addgroup -g 1001 -S appuser \
 && adduser -u 1001 -S -G appuser -s /sbin/nologin appuser

# --- nginx server configuration --------------------------------------------
# Listens on 80 (conventional) and 8080 (usable when unprivileged port
# binding is disabled by the runtime). Adds compression, immutable asset
# caching and a dependency-free health endpoint.
RUN printf '%s\n' \
    'server {' \
    '    listen       80 default_server;' \
    '    listen       [::]:80 default_server;' \
    '    listen       8080;' \
    '    listen       [::]:8080;' \
    '    server_name  _;' \
    '' \
    '    root         /usr/share/nginx/html;' \
    '    index        index.html;' \
    '    charset      utf-8;' \
    '    server_tokens off;' \
    '' \
    '    gzip            on;' \
    '    gzip_vary       on;' \
    '    gzip_comp_level 5;' \
    '    gzip_min_length 256;' \
    '    gzip_proxied    any;' \
    '    gzip_types      text/plain text/css text/xml application/javascript' \
    '                    application/json application/xml image/svg+xml' \
    '                    font/woff font/woff2;' \
    '' \
    '    # Dependency-free container health probe' \
    '    location = /healthz {' \
    '        access_log off;' \
    '        default_type text/plain;' \
    '        return 200 "OK\n";' \
    '    }' \
    '' \
    '    # Static assets: long-lived immutable caching' \
    '    location ~* \.(?:css|js|mjs|png|jpe?g|gif|svg|ico|webp|woff2?|ttf|otf|eot)$ {' \
    '        access_log off;' \
    '        expires 1y;' \
    '        add_header Cache-Control "public, immutable";' \
    '        try_files $uri =404;' \
    '    }' \
    '' \
    '    # Never expose dotfiles (.git, .secrets, ...)' \
    '    location ~ /\.(?!well-known) {' \
    '        deny all;' \
    '    }' \
    '' \
    '    # Multi-page template: allow /courses -> /courses.html' \
    '    location / {' \
    '        try_files $uri $uri/ $uri.html /index.html;' \
    '    }' \
    '}' \
    > /etc/nginx/conf.d/default.conf

# --- Writable runtime paths for the non-root master process ----------------
RUN mkdir -p /var/cache/nginx/client_temp \
             /var/cache/nginx/proxy_temp \
             /var/cache/nginx/fastcgi_temp \
             /var/cache/nginx/uwsgi_temp \
             /var/cache/nginx/scgi_temp \
             /var/log/nginx \
             /tmp/nginx \
 && touch /var/run/nginx.pid \
 && chown -R appuser:appuser /var/cache/nginx /var/log/nginx /var/run/nginx.pid /tmp/nginx \
 && chmod -R 755 /var/cache/nginx /var/log/nginx

# --- Static site content ----------------------------------------------------
WORKDIR /usr/share/nginx/html

COPY --chown=appuser:appuser css/ css/
COPY --chown=appuser:appuser webfonts/ webfonts/
COPY --chown=appuser:appuser imgs/ imgs/
COPY --chown=appuser:appuser ./*.html ./

USER appuser

EXPOSE 80 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:80/healthz || exit 1

STOPSIGNAL SIGQUIT

CMD ["nginx", "-g", "daemon off;"]
