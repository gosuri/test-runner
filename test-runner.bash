#!/usr/bin/env bash

# name of the current executable
PROGRAM=${0##*/}

RUBY_VERSION="2.1.2"
NODE_VERSION="0.10.33"

# Packages required to compile (install ruby and gems) the application
COMPILER_PACKAGES="
  unzip
  git
  git-core
  curl
  zlib1g-dev
  build-essential
  libssl-dev
  libreadline-dev
  libyaml-dev
  libsqlite3-dev
  sqlite3
  libxml2-dev
  libxslt1-dev
  libcurl4-openssl-dev
  python-software-properties
  postgresql-client
  mysql-client
  libmysqlclient-dev
  libpq-dev
  phantomjs
"

function run() {
  trap finish EXIT
  
  # setup git-ssh and copy private key to the cache directory
  setup_ssh

  # setup base, ruby and app containers if they doesn't exit
  setup_base_containers
  
  # Compile application
  compile_app

  # Start support services (pg and redis)
  start_services
  
  # Run tests and tag the current build as deploy_branch when successfull
  run_tests && tag_build
}

function setup_ssh() {
  log "Setting git-ssh with ${sshkey} Identity"
  echo "ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o IdentityFile=${sshkey} \$*" > "${cachedir}/git-ssh"
  chmod +x "${cachedir}/git-ssh"
}

function setup_base_containers() {
  info "Setting up base containers"

  # setup base container if it doesn't exist
  if [ -n "$(docker images | grep '^app-base ')" ]; then
    log "Using app-base container from cache"
  else
    build_app_base_container
  fi

  # setup base ruby compiler container if it doens't exists
  if [ -n "$(docker images | grep '^ruby-compiler-base ')" ]; then
    log "Using ruby-compiler-base container from cache"
  else
    build_ruby_compiler_base_container
  fi
  
  if [ -n "$(docker images | grep "^${devimg} ")" ]; then
    log "Using ${devimg} container from cache"
  else
    build_app_dev_container
  fi
}

function build_app_base_container() {
  log "building application base container"
  local dir="${cachedir}/app-base"
  mkdir -p ${dir}
 
  # copy keys and set ssh config
  cp ${sshkey} "${dir}/id_rsa"
  echo "ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \$*" > ${dir}/git-ssh

  cat > "${dir}/Dockerfile" <<EOF
# Pull the latest canonical ubuntu image
FROM ubuntu

ENV RUBY_VERSION ${RUBY_VERSION}
ENV NODE_VERSION ${NODE_VERSION}
ENV GEM_PATH /app/vendor/bundle

# Set the app, gem, ruby
# and node executables in the path
ENV PATH /app/bin:/app/vendor/bundle/bin:/app/vendor/ruby/${RUBY_VERSION}/bin:/app/vendor/node/${NODE_VERSION}/bin:\$PATH

# Add ssh keys
ADD id_rsa /root/.ssh/id_rsa
RUN chmod 600 /root/.ssh/id_rsa

ADD git-ssh /bin/git-ssh
RUN chmod +x /bin/git-ssh
ENV GIT_SSH /bin/git-ssh
EOF
  docker build --rm --tag app-base ${cachedir}/app-base 2>&1 | debug
}

function build_ruby_compiler_base_container() {
  log "building ruby-compiler-base container"
  local dir="${cachedir}/ruby-compiler-base"
  local pkgs=$(printf "%s " $COMPILER_PACKAGES)

  mkdir -p ${dir}
  cat > "${dir}/Dockerfile" <<EOF
FROM app-base
RUN apt-get update && apt-get install -y ${pkgs}

# Create the application directory
# where all the app's dependencies will be placed
RUN mkdir -p /app

# Install and build ruby in the app directory
RUN git clone https://github.com/sstephenson/ruby-build.git /ruby-build
RUN /ruby-build/bin/ruby-build ${RUBY_VERSION} /app/vendor/ruby/${RUBY_VERSION}

# Install and update rubygems and install bundler
RUN gem install rubygems-update bundler --no-ri --no-rdoc && update_rubygems

# Install nodejs binaries
RUN mkdir -p /app/vendor/node/${NODE_VERSION}
RUN curl http://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.gz | tar xz --strip-components=1 -C /app/vendor/node/${NODE_VERSION}
EOF
  docker build --rm --tag ruby-compiler-base ${dir} 2>&1 | debug
}

function build_app_dev_container() {
  log "building ${devimg} container"
  local dir="${cachedir}/${devimg}"
  mkdir -p ${dir}
  cat > "${dir}/Dockerfile" <<EOF
FROM ruby-compiler-base
ENV RAILS_ENV test
ENV RACK_ENV test
RUN mkdir -p /app
WORKDIR /app
EOF
  docker build --rm --tag ${devimg} ${dir} 2>&1 | debug
}

function compile_app() {
  info "Compiling application"
  get_app_source
  local dir="${cachedir}/${devimg}"
  mkdir -p ${dir}
  cat > "${dir}/Dockerfile" <<EOF
FROM ${devimg}
ADD app app
RUN bundle install --path=vendor/bundle --binstubs vendor/bundle/bin --jobs=4 --retry=3
EOF
  log "Building ${devimg} container"
  docker build --rm --tag ${devimg} $dir 2>&1 | debug
}

function get_app_source() {
  log "Fetching application source from ${repo} on branch ${branch}"
  local dir="${cachedir}/${devimg}/app"
  rm -rf ${dir} # keep it fresh
  mkdir -p ${dir}
  GIT_SSH="${cachedir}/git-ssh" git clone -q -b ${branch} ${repo} ${dir} --depth 1 > ${errlog} 2>&1 
  rm ${errlog}
}

function start_services() {
  info "Starting support services"
  log "Starting redis container"
  redis=$(docker run --name $devimg-redis-${RANDOM} -d redis 2> ${errlog})
  redisip=$(docker inspect -f "{{ .NetworkSettings.IPAddress }}" ${redis})
  log "Running redis at ${redisip}:6379"
  rm ${errlog}
  
  log "Starting postgres container"
  local pguser='postgres'
  local pgpass='password'
  pg=$(docker run -e POSTGRES_PASSWORD=${pgpass} --name $devimg-pg-${RANDOM} -d postgres 2> ${errlog})
  pgip=$(docker inspect -f "{{ .NetworkSettings.IPAddress }}" ${pg})
  log "Running postgres at ${pgip}:5432"
  rm ${errlog}

  log "Starting rabbitmq container"
  local rabbituser='admin'
  local rabbitpass="admin-${RANDOM}"
  rabbit=$(docker run --name ${devimg}-rabbit-${RANDOM} -e RABBITMQ_PASS=${rabbitpass} -d tutum/rabbitmq)
  rabbitip=$(docker inspect -f "{{ .NetworkSettings.IPAddress }}" ${rabbit})
  log "Running rabbitmq at ${rabbitip}:5672"
  
  envfile="${cachedir}/.env"

  cat > ${envfile} <<EOF
RACK_ENV=test
REDIS_HOST=${redisip}
POSTGRES_HOST=${pgip}
POSTGRES_USER='postgres'
POSTGRES_PASSWORD='password'
RABBITMQ_HOST=${rabbitip}
RABBITMQ_USER=${rabbituser}
RABBITMQ_PASSWORD=${rabbitpass}
EOF
}

function run_tests() {
  log "Creating database using: ${dbcreatecmd}"
  docker run --rm --env-file=${envfile} $devimg ${dbcreatecmd} 2>&1 | debug

  log "Running database migrations using: ${dbmigratecmd}"
  docker run --rm --env-file=${envfile} $devimg ${dbmigratecmd} 2>&1 | debug

  info "Running tests using: ${testcmd}"
  docker run --rm --env-file=${envfile} -t $devimg ${testcmd} 2>&1 | log
}

function tag_build() {
  local dir="${cachedir}/${devimg}/app"
  local tag="deploy_${branch}"
  log "Pushing tag ${tag} to ${repo}"
  pushd $dir > /dev/null
  git tag -f ${tag} 2>&1 | debug
  GIT_SSH="${cachedir}/git-ssh" git push -f origin ${tag} > ${errlog} 2>&1
  popd > /dev/null
}

function finish() {
  local exitcode=$?
  local red=$(tput setaf 1)
  local reset="\033[0m"
  local msg="${red}$@${reset}"
  
  info "Cleaning up"
  
  # stop support services
  if [[ -n "${redis}" ]]; then
    docker rm -f ${redis} 2>&1 | debug
    log "Removed redis container"
  fi

  if [[ -n "${pg}" ]]; then
    docker rm -f ${pg} 2>&1 | debug
    log "Removed postgres container"
  fi

  if [[ -n "${rabbit}" ]]; then
    docker rm -f ${rabbit} 2>&1 | debug
    log "Removed rabbitmq container"
  fi


  if [[ ${exitcode} -eq 0 ]]; then
    info "Build successful"
    rm -rf ${errlog}
    exit 0
  else
    [[ -f ${errlog} ]] && echo -e "${red}$(cat ${errlog})" | log
    info "${red}Build failed"
    rm -rf ${errlog}
    exit ${exitcode}
  fi
}


function init() {
  if [ -z "${cachedir}" ]; then
    cachedir=$(mktemp -d -t ${PROGRAM}-XXXXXX)
  fi

  # get absolute path 
  cachedir=$(cd $(dirname ${cachedir}); pwd)/$(basename ${cachedir})

  # determine applicaiton name from gitrepo
  if [ -z "${appname}" ]; then
    appname=$(echo "${repo}" | sed "s/^.*\///" | sed "s/.git//")
  fi
  
  if [ -z "${appname}" ]; then
    abort "error: could not determine application name. specify using --name=<appname>"
  fi

  devimg="${appname}-dev"

  if [ -z "${sshkey}" ]; then
    sshkey=${HOME}/.ssh/id_rsa
  fi
  
  # create cache directory if missing
  mkdir -p ${cachedir}/${appname}-dev
  
  info "Starting tests for ${appname}"
  
  # exit script if we would use an uninitialised variable
  set -o nounset

  # exit script when a simple command (not a control structure) fails
  set -o errexit

  set -o pipefail
}


function abort_if_missing_command() {
  local cmd=$1
  type ${cmd} >/dev/null 2>&1 || abort "${2}"
}

function info() {
  local msg="==> ${PROGRAM}: ${*}"
  local bold=$(tput bold)
  local reset="\033[0m"
  echo -e "${bold}${msg}${reset}"
}

function log() {
  # read stdin when piped
  set +o nounset
  if [ -z "${1}" ]; then
    while read line ; do
      echo >&2 -e "                 ${line}"
    done
  else
    echo >&2 -e "    ${PROGRAM}: ${*}"
  fi
  set -o nounset
}

function debug() {
  set +o nounset
  # read stdin when piped
  if [ -z "${1}" ]; then
    while read line ; do
      if [[ "${verbose}" == "1" ]]; then
        echo >&2 -e "                 ${line}"
      else
        echo ${line} > /dev/null
      fi
    done
  else
    if [[ "${verbose}" == "1" ]]; then
      echo >&2 -e "                 ${*}"
    fi
  fi
  set -o nounset
}

function abort() {
  local red=$(tput setaf 1)
  local reset=$(tput sgr0)
  local msg="${red}$@${reset}"
  echo >&2 -e "                 ${msg}"
  exit 1
}

function parse_opts() {
  repo="${@: -1}"
  
  while [[ $# > 0 ]]; do
    local key="$1"
    shift
    
    # Parse the long option and then the short
    # using substring removal ${string##substring}
    # http://tldp.org/LDP/abs/html/string-manipulation.html
    local val="${key#*=}"
    [ "${val}" == "${key}" ] &&
      local val="${1}"

    case ${key} in
      -b|--branch=*)
        branch=${val}
        ;;
      -c|--cache-dir=*)
        cachedir=${val}
        ;;
      -k|--ssh-key=*)
        sshkey=${val}
        ;;
      --name=*)
        appname=${val}
        shift
        ;;
      -t|--test-with=*)
        testcmd=${val}
        ;;
      --db-create-with=*)
        dbcreatecmd=${val}
        ;;
      --db-migrate-with=*)
        dbmigratecmd=${val}
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      -V|--verbose)
        verbose=1
        ;;
    esac
  done
  if [ -z "${repo}" ]; then
    show_help 
    exit 1
  fi
}

function show_help() {
  cat <<EOF
Usage: ${PROGRAM} [OPTIONS] GIT_REPO

Runs tests for the given repo in a container

Options:

  -b, --branch="master"
      Git branch to pull the source from

  -k, --ssh-key="$HOME/.ssh/id_rsa"
      SSH key for git repo access

  -c, --cache-dir="${cachedir}"
      Cache directory

  -t, --test-with="${testcmd}"
      Test command running tests with

  --db-create-with="${dbcreatecmd}"
      Command to create database with

  --db-migrate-with="${dbmigratecmd}" 
      Command to migrate run database migrations with

  --name=""
      Application name. Autogenerated based on the git repo path

  -V, --verbose
      Run in verbose mode
EOF
}

verbose=0
repo=''
cachedir=''
appname=''
devimg=''
sshkey="${HOME}/.ssh/id_rsa"
branch='master'
testcmd="bundle exec rspec"
dbcreatecmd="bundle exec rake db:create"
dbmigratecmd="bundle exec rake db:migrate"
redis=''
redisip=''
pg=''
pgip=''
rabbit=''
rabbitip=''
errlog=$(mktemp -t ${PROGRAM}-err-XXXX)

parse_opts "$@"
init
run

# vim: tw=80 noexpandtab
