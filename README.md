# Proton-Privoxy Docker

This project sets up a Privoxy HTTP proxy that routes all its traffic through a ProtonVPN OpenVPN connection. The OpenVPN server is automatically rotated at a configurable interval.

## Features

-   Privoxy HTTP Proxy
-   ProtonVPN integration using OpenVPN
-   Automatic rotation of ProtonVPN servers
-   Configurable rotation interval
-   DNS override capability
-   Dockerized for easy deployment

## Prerequisites

-   Docker
-   Docker Compose
-   A ProtonVPN account (Free or Paid)

## Setup

1.  **Clone the Repository (if applicable later):**
    ```bash
    git clone <repository_url>
    cd proton-privoxy-docker
    ```

2.  **OpenVPN Configurations:**
    -   Download your desired ProtonVPN OpenVPN configuration files (UDP recommended) from the [ProtonVPN Account Downloads page](https://account.protonvpn.com/downloads).
    -   Place the `.ovpn` files into the `ovpn_configs/` directory in this project.

3.  **Create `.env` File:**
    -   Copy the example environment file:
        ```bash
        cp .env.example .env
        ```
    -   Edit the `.env` file and fill in your ProtonVPN credentials and other settings:
        ```env
        PVPN_USERNAME=YOUR_PROTONVPN_OPENVPN_USERNAME
        PVPN_PASSWORD=YOUR_PROTONVPN_OPENVPN_PASSWORD

        # Optional: Set the rotation interval in seconds (default is 300 seconds / 5 minutes)
        ROTATION_INTERVAL=300

        # Optional: Override DNS servers used by the container after VPN connection.
        # Comma-separated. Examples:
        # DNS_SERVERS_OVERRIDE=1.1.1.1,1.0.0.1 # Cloudflare
        # DNS_SERVERS_OVERRIDE=8.8.8.8,8.8.4.4 # Google
        # DNS_SERVERS_OVERRIDE=10.2.0.1       # Example ProtonVPN internal DNS
        DNS_SERVERS_OVERRIDE=
        ```
    **IMPORTANT:** The `PVPN_USERNAME` and `PVPN_PASSWORD` are your OpenVPN/IKEv2 credentials, **not** your main Proton account login. You can find these in your ProtonVPN account dashboard under Account -> OpenVPN / IKEv2 username.

4.  **Build and Run:**
    ```bash
    docker-compose build
    docker-compose up -d
    ```

## Usage

Once the container is running, configure your browser or application to use an HTTP proxy:

-   **Host/Address:** `localhost` (if running Docker locally) or the IP address of the machine running Docker.
-   **Port:** `8100` (or as configured in `docker-compose.yml` and Privoxy's `app/config`).

Check the logs to see the VPN server rotation:
```bash
docker-compose logs -f proton_privoxy_service
```

## Using IVPN

IVPN runs as a second, separate stack next to the ProtonVPN one, with its own credentials, exits, ports and endpoint history. It uses `docker-compose.ivpn.yml`, and you can run it on its own or alongside the ProtonVPN stack.

| | ProtonVPN | IVPN |
|---|---|---|
| Proxy | `127.0.0.1:8100` | `127.0.0.1:8101` |
| Health and metrics | `127.0.0.1:8081` | `127.0.0.1:8082` |
| Credentials | `.env` | `.env.ivpn` |
| Configs | `ovpn_configs/` | `ovpn_configs_ivpn/` |
| Container | `proton_privoxy_service` | `ivpn_privoxy_service` |

1.  **Generate the configs.** This needs Python 3 and no IVPN account:
    ```bash
    tools/gen_ivpn_configs.py --country CH,SE,DE
    ```
    Use this instead of IVPN's stock download. Those files use hostnames, which can leave the container unable to reconnect after OpenVPN is killed, and many of them list several servers, which breaks per-exit scoring. The script writes one IP-based file per server.

    Pick a handful of countries. The scoring defaults are tuned for about 8 exits, and at the default daily rotation the full list of about 90 servers takes months to visit. `--proto tcp` and `--port` are also available.

2.  **Add your credentials:**
    ```bash
    cp .env.ivpn.example.txt .env.ivpn
    ```
    Set `PVPN_USERNAME` to your IVPN account ID. The password can be any non-blank value.

3.  **Build and run:**
    ```bash
    docker compose -f docker-compose.ivpn.yml up -d --build
    ```

The configs are baked into the image. To refresh them, for example if servers start failing because their IPs changed, re-run the script and then the build command.

### Testing a new deployment

Set `ROTATION_INTERVAL=300` in `.env.ivpn` so a rotation happens within minutes, start the stack, then:

```bash
# The login works and the exit is the VPN's
CONTAINER=ivpn_privoxy_service HEALTH=127.0.0.1:8082 PROXY=127.0.0.1:8101 ./verify.sh

# A killed tunnel recovers on its own: look for event=tunnel_down, then a new event=exit_ip
docker exec ivpn_privoxy_service pkill -KILL openvpn
docker logs -f ivpn_privoxy_service
```

Once both pass, remove `ROTATION_INTERVAL` and run `docker compose -f docker-compose.ivpn.yml up -d` again, because the container only reads `.env.ivpn` when it is created.

Each stack holds one VPN session, so a second IVPN container needs a free device slot on your IVPN plan. `docker-compose.canary.yml` covers ProtonVPN only: it uses `.env` and `ovpn_configs/`, so it takes a ProtonVPN slot and does not test IVPN.
