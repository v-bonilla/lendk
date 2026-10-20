FROM ubuntu:24.04
RUN apt-get update \
	&& DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
		pass gnupg zsh strace python3 git make gcc libc6-dev systemd libcap2-bin \
	&& rm -rf /var/lib/apt/lists/* \
	&& cp /usr/bin/strace /usr/local/bin/strace-ptrace \
	&& setcap cap_sys_ptrace+ep /usr/local/bin/strace-ptrace
