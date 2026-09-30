SHELL := /bin/sh
BATS := test/lib/bats-core/bin/bats
SHELLCHECK := uvx --from shellcheck-py==0.11.0.1 shellcheck
DOCKER_RUN := docker run --rm -u 1000:1000 -e HOME=/tmp -v "$(CURDIR):/src:ro" -w /src

.PHONY: deps lint test check check-docker images bench

deps:
	git submodule update --init

lint:
	$(SHELLCHECK) bin/lend test/*.bats $$(find test -name '*.bash' -not -path 'test/lib/*') $$(grep -l '^#!' test/fixtures/*)
	bash test/lint-repo.bash

test:
	@test -x $(BATS) || { echo 'bats-core is missing; run: make deps' >&2; exit 1; }
	$(BATS) --filter-tags '!docker' test/*.bats

check: lint test

images:
	docker build -q -t lend-test:ubuntu -f test/docker/ubuntu.Dockerfile test/docker
	docker build -q -t lend-test:bash44 -f test/docker/bash44.Dockerfile test/docker

check-docker: images
	@test -x $(BATS) || { echo 'bats-core is missing; run: make deps' >&2; exit 1; }
	$(BATS) --filter-tags docker test/*.bats
	$(DOCKER_RUN) --cap-add SYS_PTRACE \
		-e TEST_REQUIRE="gpg pass zsh strace script python3 git environment-d" \
		lend-test:ubuntu $(BATS) --filter-tags '!docker' test/*.bats
	$(DOCKER_RUN) -e TEST_REQUIRE=script lend-test:bash44 $(BATS) --filter-tags '!docker' test/*.bats

bench:
	bash test/bench/bench.bash
