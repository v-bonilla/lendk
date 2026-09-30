FROM ubuntu:24.04
RUN apt-get update \
	&& DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
		pass gnupg zsh strace python3 git make systemd \
	&& rm -rf /var/lib/apt/lists/*
