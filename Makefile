.PHONY: all init format_backend  format lint build    run_backend dev help tests coverage clean_python_cache clean_npm_cache clean_all

# Configurations
VERSION=$(shell grep "^version" pyproject.toml | sed 's/.*\"\(.*\)\"$$/\1/')
DOCKERFILE=docker/build_and_push.Dockerfile
DOCKERFILE_BACKEND=docker/build_and_push_backend.Dockerfile
DOCKER_COMPOSE=docker_example/docker-compose.yml
PYTHON_REQUIRED=$(shell grep '^requires-python[[:space:]]*=' pyproject.toml | sed -n 's/.*"\([^"]*\)".*/\1/p')
RED=\033[0;31m
NC=\033[0m # No Color
GREEN=\033[0;32m

log_level ?= debug
host ?= 0.0.0.0
port ?= 7860
env ?= .env
open_browser ?= true

workers ?= 1
async ?= true
lf ?= false
ff ?= true
all: help

######################
# UTILITIES
######################

# Some directories may be mount points as in devcontainer, so we need to clear their
# contents rather than remove the entire directory. But we must also be mindful that
# we are not running in a devcontainer, so need to ensure the directories exist.
# See https://code.visualstudio.com/remote/advancedcontainers/improve-performance
CLEAR_DIRS = $(foreach dir,$1,$(shell mkdir -p $(dir) && find $(dir) -mindepth 1 -delete))

# increment the patch version of the current package
patch: ## bump the version in langflow and langflow-base
	@echo 'Patching the version'
	@poetry version patch
	@echo 'Patching the version in langflow-base'
	@cd base && poetry version patch
	@make lock

# check for required tools
check_tools:
	@command -v uv >/dev/null 2>&1 || { echo >&2 "$(RED)uv is not installed. Aborting.$(NC)"; exit 1; }
	@command -v npm >/dev/null 2>&1 || { echo >&2 "$(RED)NPM is not installed. Aborting.$(NC)"; exit 1; }
	@echo "$(GREEN)All required tools are installed.$(NC)"


help: ## show this help message
	@echo '----'
	@grep -hE '^\S+:.*##' $(MAKEFILE_LIST) | \
	awk -F ':.*##' '{printf "\033[36mmake %s\033[0m: %s\n", $$1, $$2}' | \
	column -c2 -t -s :
	@echo '----'

######################
# INSTALL PROJECT
######################

reinstall_backend: ## forces reinstall all dependencies (no caching)
	@echo 'Installing backend dependencies'
	@uv sync -n --reinstall --frozen

install_backend: ## install the backend dependencies
	@echo 'Installing backend dependencies'
	@uv sync --frozen

init: check_tools clean_python_cache clean_npm_cache ## initialize the project
	@make install_backend
	@echo "$(GREEN)All requirements are installed.$(NC)"
	@uv run langflow run

######################
# CLEAN PROJECT
######################

clean_python_cache:
	@echo "Cleaning Python cache..."
	find . -type d -name '__pycache__' -exec rm -r {} +
	find . -type f -name '*.py[cod]' -exec rm -f {} +
	find . -type f -name '*~' -exec rm -f {} +
	find . -type f -name '.*~' -exec rm -f {} +
	$(call CLEAR_DIRS,.mypy_cache )
	@echo "$(GREEN)Python cache cleaned.$(NC)"


clean_all: clean_python_cache clean_npm_cache # clean all caches and temporary directories
	@echo "$(GREEN)All caches and temporary directories cleaned.$(NC)"

setup_uv: ## install poetry using pipx
	pipx install uv

add:
	@echo 'Adding dependencies'
ifdef devel
	@cd base && uv add --group dev $(devel)
endif

ifdef main
	@uv add $(main)
endif

ifdef base
	@cd base && uv add $(base)
endif



######################
# CODE TESTS
######################

coverage: ## run the tests and generate a coverage report
	@uv run coverage run
	@uv run coverage erase

unit_tests: ## run unit tests
	@uv sync --extra dev --frozen
	@EXTRA_ARGS=""
	@if [ "$(async)" = "true" ]; then \
		EXTRA_ARGS="$$EXTRA_ARGS --instafail -n auto"; \
	fi; \
	if [ "$(lf)" = "true" ]; then \
		EXTRA_ARGS="$$EXTRA_ARGS --lf"; \
	fi; \
	if [ "$(ff)" = "true" ]; then \
		EXTRA_ARGS="$$EXTRA_ARGS --ff"; \
	fi; \
	uv run pytest tests/unit \
	--ignore=tests/integration $$EXTRA_ARGS \
	--instafail -ra -m 'not api_key_required' \
	--durations-path tests/.test_durations \
	--splitting-algorithm least_duration $(args)

unit_tests_looponfail:
	@make unit_tests args="-f"

integration_tests:
	uv run pytest tests/integration \
		--instafail -ra \
		$(args)

integration_tests_no_api_keys:
	uv run pytest tests/integration \
		--instafail -ra -m "not api_key_required" \
		$(args)

integration_tests_api_keys:
	uv run pytest tests/integration \
		--instafail -ra -m "api_key_required" \
		$(args)

tests: ## run unit, integration, coverage tests
	@echo 'Running Unit Tests...'
	make unit_tests
	@echo 'Running Integration Tests...'
	make integration_tests
	@echo 'Running Coverage Tests...'
	make coverage

######################
# CODE QUALITY
######################

codespell: ## run codespell to check spelling
	@poetry install --with spelling
	poetry run codespell --toml pyproject.toml

fix_codespell: ## run codespell to fix spelling errors
	@poetry install --with spelling
	poetry run codespell --toml pyproject.toml --write

format_backend: ## backend code formatters
	@uv run ruff check . --fix --ignore EXE002
	@uv run ruff format . --config pyproject.toml



format: format_backend  ## run code formatters

unsafe_fix:
	@uv run ruff check . --fix --unsafe-fixes

lint: install_backend ## run linters
	@uv run mypy --namespace-packages -p "langflow"



run_cli:  install_backend  ## run the CLI
	@echo 'Running the CLI'
	@uv run langflow run \
		--log-level $(log_level) \
		--host $(host) \
		--port $(port) \
		$(if $(env),--env-file $(env),) \


run_cli_debug:
	@echo 'Running the CLI in debug mode'
	@echo 'Install backend dependencies'
	@make install_backend > /dev/null
ifdef env
	@make start env=$(env) host=$(host) port=$(port) log_level=debug
else
	@make start host=$(host) port=$(port) log_level=debug
endif


setup_devcontainer: ## set up the development container
	make install_backend
	uv run langflow 

setup_env: ## set up the environment
	@sh ./scripts/setup/setup_env.sh


backend: setup_env install_backend ## run the backend in development mode
	@-kill -9 $$(lsof -t -i:7860) || true
ifdef login
	@echo "Running backend autologin is $(login)";
	LANGFLOW_AUTO_LOGIN=$(login) uv run uvicorn \
		--factory langflow.main:create_app \
		--host 0.0.0.0 \
		--port $(port) \
		$(if $(filter-out 1,$(workers)),, --reload) \
		--env-file $(env) \
		--loop asyncio \
		$(if $(workers),--workers $(workers),)
else
	@echo "Running backend respecting the $(env) file";
	uv run uvicorn \
		--factory langflow.main:create_app \
		--host 0.0.0.0 \
		--port $(port) \
		$(if $(filter-out 1,$(workers)),, --reload) \
		--env-file $(env) \
		--loop asyncio \
		$(if $(workers),--workers $(workers),)
endif

build_and_run: setup_env ## build the project and run it
	$(call CLEAR_DIRS,dist base/dist)
	uv run pip install dist/*.tar.gz
	uv run langflow run

build_and_install: ## build the project and install it
	@echo 'Removing dist folder'
	$(call CLEAR_DIRS,dist base/dist)
	make build && uv run pip install dist/*.whl && pip install base/dist/*.whl --force-reinstall

build: setup_env ## build the frontend static files and package the project
ifdef base
	make build_langflow_base args="$(args)"
endif

ifdef main
	make build_langflow_base args="$(args)"
	make build_langflow args="$(args)"
endif

build_langflow_base:
	cd base && uv build $(args)

build_langflow_backup:
	uv lock && uv build

build_langflow:
	uv lock --no-upgrade
	uv build $(args)
ifdef restore
	mv pyproject.toml.bak pyproject.toml
	mv uv.lock.bak uv.lock
endif


docker_build: dockerfile_build clear_dockerimage ## build DockerFile

docker_build_backend: dockerfile_build_be clear_dockerimage ## build Backend DockerFile


dockerfile_build:
	@echo 'BUILDING DOCKER IMAGE: ${DOCKERFILE}'
	@docker build --rm \
		-f ${DOCKERFILE} \
		-t langflow:${VERSION} .

dockerfile_build_be: dockerfile_build
	@echo 'BUILDING DOCKER IMAGE BACKEND: ${DOCKERFILE_BACKEND}'
	@docker build --rm \
		--build-arg LANGFLOW_IMAGE=langflow:${VERSION} \
		-f ${DOCKERFILE_BACKEND} \
		-t langflow_backend:${VERSION} .


clear_dockerimage:
	@echo 'Clearing the docker build'
	@if docker images -f "dangling=true" -q | grep -q '.*'; then \
		docker rmi $$(docker images -f "dangling=true" -q); \
	fi

docker_compose_up: docker_build docker_compose_down
	@echo 'Running docker compose up'
	docker compose -f $(DOCKER_COMPOSE) up --remove-orphans

docker_compose_down:
	@echo 'Running docker compose down'
	docker compose -f $(DOCKER_COMPOSE) down || true

dcdev_up:
	@echo 'Running docker compose up'
	docker compose -f docker/dev.docker-compose.yml down || true
	docker compose -f docker/dev.docker-compose.yml up --remove-orphans

lock_base:
	cd base && uv lock

lock_langflow:
	uv lock

lock: ## lock dependencies
	@echo 'Locking dependencies'
	cd base && uv lock
	uv lock

update: ## update dependencies
	@echo 'Updating dependencies'
	cd base && uv sync --upgrade
	uv sync --upgrade

publish_base:
	cd base && uv publish

publish_langflow:
	uv publish

publish_base_testpypi:
	# TODO: update this to use the test-pypi repository
	cd base && uv publish -r test-pypi

publish_langflow_testpypi:
	# TODO: update this to use the test-pypi repository
	uv publish -r test-pypi

publish: ## build the frontend static files and package the project and publish it to PyPI
	@echo 'Publishing the project'
ifdef base
	make publish_base
endif

ifdef main
	make publish_langflow
endif

publish_testpypi: ## build the frontend static files and package the project and publish it to PyPI
	@echo 'Publishing the project'

ifdef base
	#TODO: replace with uvx twine upload dist/*
	poetry config repositories.test-pypi https://test.pypi.org/legacy/
	make publish_base_testpypi
endif

ifdef main
	#TODO: replace with uvx twine upload dist/*
	poetry config repositories.test-pypi https://test.pypi.org/legacy/
	make publish_langflow_testpypi
endif


# example make alembic-revision message="Add user table"
alembic-revision: ## generate a new migration
	@echo 'Generating a new Alembic revision'
	cd base/langflow/ && uv run alembic revision --autogenerate -m "$(message)"


alembic-upgrade: ## upgrade database to the latest version
	@echo 'Upgrading database to the latest version'
	cd base/langflow/ && uv run alembic upgrade head

alembic-downgrade: ## downgrade database by one version
	@echo 'Downgrading database by one version'
	cd base/langflow/ && uv run alembic downgrade -1

alembic-current: ## show current revision
	@echo 'Showing current Alembic revision'
	cd base/langflow/ && uv run alembic current

alembic-history: ## show migration history
	@echo 'Showing Alembic migration history'
	cd base/langflow/ && uv run alembic history --verbose

alembic-check: ## check migration status
	@echo 'Running alembic check'
	cd base/langflow/ && uv run alembic check

alembic-stamp: ## stamp the database with a specific revision
	@echo 'Stamping the database with revision $(revision)'
	cd base/langflow/ && uv run alembic stamp $(revision)
