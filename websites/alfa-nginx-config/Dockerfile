# Alfa Nginx — serves www.example.com + bot subdomains.
# Behind Cloudflare Tunnel (cf-alfa). No origin TLS; listens on HTTP 80.
# Per Docker best practices: minimal base, non-root where possible, healthcheck.
# See DOCKER_NETWORK_CONSTANTS.md and ALFA_NGINX_SETUP.md.
FROM nginx:alpine
RUN apk add --no-cache curl
COPY alfa-nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:8080/health -o /dev/null || exit 1
CMD ["nginx", "-g", "daemon off;"]
