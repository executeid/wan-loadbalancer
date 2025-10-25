# WAN Load Balancer

This project provides a set of scripts and service files to set up a WAN load balancer on a Linux machine. It uses `macvlan` to create virtual interfaces, `redsocks` for transparent proxying, `nftables` for firewall rules, and a Go-based dispatch proxy for load balancing.

## Disclaimer

If you want to replicate this, we recommend to understand how it works and modify it for your use case. The most difficult are loadbalancer because this project using `macvlan` as virtual WAN to same network. As the results we can create many WAN as we want, but we recommend between 3-5 more WAN will give unstability and stalling the network.

This project meant for local network or LAN, if you want to use it only for your machine, please modify the nftables.conf as you will see br0 and br1 that is for bridge interface to local network.

## Use Case

Best Use case for this is if you want more bandwidth than limited by institutional networks. This Project give you ability to run machine 24/7 and not worrying being sign-out in the middle of night (read captive auto-login script).

## How it Works

At its core, this system creates a sophisticated load balancing setup by cleverly manipulating network traffic. It begins by using `macvlan` to spawn multiple virtual network interfaces, each with a unique MAC address, from a single physical network card. This allows the machine to acquire several IP addresses from the local network's DHCP server, effectively simulating multiple WAN connections.

The heart of the load balancing is the `go-dispatch-proxy`, a custom SOCKS5 proxy that listens for incoming connections. It intelligently distributes these connections across the pool of virtual `macvlan` interfaces, spreading the network load.

To ensure all traffic benefits from this load balancing, the system uses a combination of `nftables` and `redsocks`. `nftables` sets up firewall rules that transparently intercept all outgoing TCP traffic from the local network and redirect it to `redsocks`. `redsocks` then forwards this captured traffic to the `go-dispatch-proxy`, which takes care of the rest.

For networks that require authentication, the `captive_v2.2.sh` script automates the login process. It periodically checks each virtual interface for internet access and, if it detects a captive portal, uses the provided credentials to log in, ensuring uninterrupted connectivity.

Finally, the entire process is managed by the `loadbalance.service`, a `systemd` service that orchestrates the startup and shutdown of all components in the correct sequence, making the whole system easy to manage.

In essence, the traffic flows as follows: a client on the local network sends traffic to a bridge interface, which is then intercepted by `nftables`, redirected to `redsocks`, forwarded to `go-dispatch-proxy` for load balancing, and finally sent out to the internet through one of the virtual `macvlan` interfaces.

## Features

-   Distributes internet traffic across multiple WAN connections.
-   Automatic failover to a working connection.
-   Transparent proxying of TCP traffic.
-   Automatic login to captive portals.

## Requirements

-   A Linux machine with at least two network interfaces.
-   `systemd` for managing services.
-   `nftables` for firewall rules.
-   `redsocks` for transparent proxying.
-   `curl` for testing connectivity and logging into captive portals.
-   `dhclient` for obtaining IP addresses for the `macvlan` interfaces.
-   A Go compiler to build the `go-dispatch-proxy`.

## Installation

1.  **Clone the repository:**

    ```bash
    git clone https://github.com/executeid/wan-loadbalancer.git
    cd wan-loadbalancer
    ```

2.  **Build the `go-dispatch-proxy`:**

    Please read go-dispatch-proxy repository and download the release file.

    Place the compiled binary in `/home/user/`.

3.  **Install the service files:**

    Copy the service files to `/etc/systemd/system/`:

    ```bash
    sudo cp captive.service /etc/systemd/system/
    sudo cp go-dispatch-proxy.service /etc/systemd/system/
    sudo cp loadbalance.service /etc/systemd/system/
    sudo cp macvlan.service /etc/systemd/system/
    sudo cp redsocks.service /etc/systemd/system/
    ```

4.  **Install the scripts:**

    Copy the scripts to `/usr/local/bin/`:

    ```bash
    sudo cp scripts/captive_v2.2.sh /usr/local/bin/
    sudo cp scripts/go-dispatch.sh /usr/local/bin/
    ```

    Make the scripts executable:

    ```bash
    sudo chmod +x /usr/local/bin/captive_v2.2.sh
    sudo chmod +x /usr/local/bin/go-dispatch.sh
    ```

5.  **Configure `nftables`:**

    Copy the `nftables.conf` file to `/etc/`:

    ```bash
    sudo cp nftables.conf /etc/nftables.conf
    ```

    Enable and start the `nftables` service:

    ```bash
    sudo systemctl enable nftables.service
    sudo systemctl start nftables.service
    ```

6.  **Configure `redsocks`:**

    Copy the `redsocks.conf` file to `/etc/`:

    ```bash
    sudo cp redsocks.conf /etc/redsocks.conf
    ```

7.  **Configure the captive portal credentials:**

    Edit `/usr/local/bin/captive_v2.2.sh` and add your usernames and passwords to the `USERS` and `PASSWORDS` arrays.

8.  **Reload the `systemd` daemon:**

    ```bash
    sudo systemctl daemon-reload
    ```

## Usage

To start the load balancer, start the `loadbalance.service`:

```bash
sudo systemctl start loadbalance.service
```

To stop the load balancer, stop the `loadbalance.service`:

```bash
sudo systemctl stop loadbalance.service
```

To check the status of the services, you can use `systemctl status`:

```bash
systemctl status loadbalance.service
systemctl status macvlan.service
systemctl status captive.service
systemctl status go-dispatch-proxy.service
systemctl status redsocks.service
```

## Configuration

-   **`macvlan.service`**: This service creates the `macvlan` interfaces. You may need to change the name of the parent interface (`enp0s31f6`) to match your system.
-   **`go-dispatch.sh`**: This script waits for the `macvlan` interfaces to get IP addresses and then starts the `go-dispatch-proxy`.
-   **`captive_v2.2.sh`**: This script logs into the captive portal. You need to configure your credentials in this file.
-   **`nftables.conf`**: This file contains the firewall rules. You may need to adjust the rules to match your network configuration.
-   **`redsocks.conf`**: This file configures `redsocks`. The default configuration should work for most users.