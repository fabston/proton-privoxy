# Pinned: `alpine:latest` means a rebuild six months from now silently ships a
# different base, different openvpn, and different privoxy than the image you
# validated. Bump this deliberately.
FROM alpine:3.21

LABEL maintainer="Proton-Privoxy User"

EXPOSE 8100 8081

# Default environment variables.
ENV PVPN_USERNAME="" \
    PVPN_PASSWORD="" \
    HOST_NETWORK= \
    DNS_SERVERS_OVERRIDE= \
    ROTATION_INTERVAL="300" \
    HEALTH_PORT="8081" \
    HEALTH_LISTEN_ADDR="0.0.0.0" \
    HEALTH_HTTP_ENABLED="1"

# Supply-chain pins for the third-party DNS script fetched below.
# Set both to a reviewed commit before deploying; master is not a version.
ARG UPDATE_RESOLV_CONF_REF=master
ARG UPDATE_RESOLV_CONF_SHA256=

# Install packages
RUN apk --no-cache add \
        coreutils \
        iproute2 \
        openvpn \
        openresolv \
        privoxy \
        procps \
        socat \
        wget \
        bash \
        findutils `# Usually part of base, but good to be explicit for 'find'` \
    && echo "Core packages installed." \
    \
    && echo "Downloading ProtonVPN DNS update script (update-resolv-conf.sh)..." \
    && mkdir -p /etc/openvpn \
    `# Pinned to a commit, not master: this script runs as root on every VPN` \
    `# connect via --script-security 2. Fetching HEAD of a third-party repo at` \
    `# build time means whatever is on master that day gets root in your` \
    `# container. Replace UPDATE_RESOLV_CONF_REF with a reviewed commit SHA and` \
    `# UPDATE_RESOLV_CONF_SHA256 with its checksum before deploying.` \
    && wget "https://raw.githubusercontent.com/ProtonVPN/scripts/${UPDATE_RESOLV_CONF_REF}/update-resolv-conf.sh" \
            -O "/etc/openvpn/update-resolv-conf" \
    && if [ -n "$UPDATE_RESOLV_CONF_SHA256" ]; then \
         echo "${UPDATE_RESOLV_CONF_SHA256}  /etc/openvpn/update-resolv-conf" | sha256sum -c - ; \
       else \
         echo "WARNING: update-resolv-conf checksum not pinned (set UPDATE_RESOLV_CONF_SHA256)" ; \
       fi \
    && chmod 0755 "/etc/openvpn/update-resolv-conf" \
    && echo "update-resolv-conf.sh downloaded and made executable." \
    \
    && echo "Ensuring Privoxy base config directory exists..." \
    && mkdir -p /etc/privoxy \
    && echo "Privoxy config directory /etc/privoxy ensured."

# Copy application scripts and Privoxy main configuration
COPY app /app

# Copy downloaded OpenVPN configuration files from host to image
COPY ovpn_configs /etc/openvpn/configs

# Copy minimal/empty Privoxy standard config files
COPY empty.filter /etc/privoxy/default.filter
COPY default.action /etc/privoxy/default.action
COPY match-all.action /etc/privoxy/match-all.action

# Make the scripts executable
RUN chmod +x /app/run \
    && chmod +x /app/rotate_vpn.sh \
    && chmod +x /app/health_httpd.sh \
    && chmod +x /app/health_handler.sh \
    && chmod +x /app/endpoint_stats.sh \
    && chmod +x /app/probe_ttfb.sh \
    && mkdir -p /var/lib/proxy

# Default command to run when the container starts
CMD ["/app/run"]

