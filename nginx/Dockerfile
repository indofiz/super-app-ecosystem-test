FROM nginx:1.27-alpine

# Replace the stock default.conf with our template-driven config.
RUN rm -f /etc/nginx/conf.d/default.conf

# AUDIT S-6: the base image symlinks access.log and error.log to stdout/stderr,
# but auth-access.log is our own file — without this it sinks into the writable
# layer where it's invisible to `docker logs` and lost on container recreate.
RUN ln -sf /dev/stdout /var/log/nginx/auth-access.log

# AUDIT S-1: directories the TLS overlay expects to exist. /etc/nginx/certs is
# the mount point for fullchain/privkey/chain PEMs; /var/www/certbot is the
# ACME HTTP-01 webroot certbot writes proofs into. Both are empty in dev.
RUN mkdir -p /etc/nginx/certs /var/www/certbot /etc/nginx/templates-tls

COPY nginx.conf /etc/nginx/nginx.conf
COPY snippets/ /etc/nginx/snippets/
COPY conf.d/default.conf.template /etc/nginx/templates/default.conf.template
# AUDIT S-1: TLS template lives in a separate dir — the envsubst entrypoint
# only processes /etc/nginx/templates/, so this file is NOT rendered until
# the 15-select-tls.envsh script copies it in based on NGINX_TLS_ENABLED.
COPY conf.d-tls/default.conf.template /etc/nginx/templates-tls/default.conf.template
COPY docker-entrypoint.d/ /docker-entrypoint.d/

# The official image's entrypoint runs envsubst on /etc/nginx/templates/*.template
# at container start, writing the result to /etc/nginx/conf.d/.
EXPOSE 80 443
