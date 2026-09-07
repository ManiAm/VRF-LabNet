FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    sudo \
    nano \
    curl \
    lsb-release \
    gnupg2 \
    iputils-ping \
    traceroute \
    net-tools \
    iproute2 \
    tcpdump \
    python3 \
    python3-pip \
    ca-certificates

# Scapy for traffic generation and analysis
RUN pip3 install scapy

# FRR
RUN curl -s https://deb.frrouting.org/frr/keys.gpg | tee /usr/share/keyrings/frrouting.gpg > /dev/null

ARG FRRVER="frr-10"

RUN echo "deb [signed-by=/usr/share/keyrings/frrouting.gpg] https://deb.frrouting.org/frr $(lsb_release -s -c) $FRRVER" | tee /etc/apt/sources.list.d/frr.list

RUN apt-get update && apt-get install -y \
    frr \
    frr-pythontools

COPY frr-restart.sh /usr/local/bin/frr-restart
RUN chmod +x /usr/local/bin/frr-restart

COPY configs/ /etc/frr/hosts/
COPY scripts/ /scripts/

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY host-entrypoint.sh /usr/local/bin/host-entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/host-entrypoint.sh

CMD ["/usr/local/bin/entrypoint.sh"]
