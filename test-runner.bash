#!/usr/bin/env bash

# name of the current executable
PROGRAM=${0##*/}

RUBY_VERSION="2.1.2"
NODE_VERSION="0.10.33"

# Minimal set of packages necessary for running the application
RUNTIME_PACKAGES="
  zlib1g
  libssl1.0.0
  libreadline6
  libyaml-0-2
  sqlite3
  libxml2
  libxslt1.1
  libcurl3
"

# Packages required to compile(install ruby and gems) the application
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
  # setup git-ssh and copy private key to the cache directory
  setup_ssh

  # build base container image if it doesn't exit
  app_base_container_exists           || build_app_base_container
  
  # build base ruby container image with compilers if it doesn't exit
  ruby_compiler_base_container_exists || build_ruby_compiler_base_container
  
  # fetch the new app code
  get_app_source
  
  # build application development image with compilers if it doesn't exit
  app_dev_container_exists            || build_app_dev_container

  # compile application
  compile_app

  # start support services (pg and redis)
  start_services
  
  trap finish EXIT
  
  # run tests
  run_tests
}

function finish() {
  exitstatus=$?
  
  # stop support services
  stop_services
  
  # tag the current build as deploy_branch
  if [ "${exitstatus}" == "0" ]; then
    info "build successful"
    tag_build
  else
    echo >&2 -e "build failed"
  fi

  exit ${exitstatus}
}

function setup_ssh() {
  cat > "${cachedir}/git-ssh" <<EOF
  ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \$*
EOF
 chmod +x "${cachedir}/git-ssh"
 mkdir -p ${cachedir}/app-base

 # copy keys to cache directories
 cp ${cachedir}/git-ssh ${cachedir}/app-base/git-ssh
 cp ${sshkey} ${cachedir}/app-base
}

function app_base_container_exists() {
  test -n "$(docker images | grep '^app-base ')"
}

function build_app_base_container() {
  log "building application base container"
  mkdir -p "${cachedir}/app-base"
  tee "${cachedir}/app-base/Dockerfile" > /dev/null <<EOF
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
  docker build --tag app-base ${cachedir}/app-base >> ${logfile} 2>&1
}

function get_app_source() {
  local dir="${cachedir}/${devimg}/app"
  
  # keep it fresh
  rm -rf ${dir} 
  mkdir -p ${dir}

  GIT_SSH="${cachedir}/git-ssh" git clone -b ${branch} ${repo} ${dir} --depth 1 >> ${logfile} 2>&1
  log "source cloned to ${dir}"
}

function ruby_compiler_base_container_exists() {
  test -n "$(docker images | grep '^ruby-compiler-base ')"
}

function build_ruby_compiler_base_container() {
  log "building base ruby compiler container"
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

# Install nodejs binaries
RUN curl http://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.gz | tar xz
RUN mkdir -p /app/vendor/node/${NODE_VERSION}
RUN mv node-v${NODE_VERSION}-linux-x64/* /app/vendor/node/${NODE_VERSION}

# Install and update rubygems and install bundler
RUN gem install rubygems-update bundler --no-ri --no-rdoc
RUN update_rubygems
EOF
  docker build --tag ruby-compiler-base ${dir} >> ${logfile} 2>&1
}

function app_dev_container_exists() {
  test -n "$(docker images | grep "^${devimg} ")"
}

function build_app_dev_container() {
  log "building ${devimg} container"
  local dir="${cachedir}/${devimg}"
  mkdir -p ${dir}
  cat > "${dir}/Dockerfile" <<EOF
FROM ruby-compiler-base
ENV RAILS_ENV test
RUN mkdir -p /app
WORKDIR /app
EOF
  docker build --tag ${devimg} ${dir} >> ${logfile} 2>&1
}

function compile_app() {
  info "compiling application"
  local dir="${cachedir}/${devimg}"
  mkdir -p ${dir}
  cat > "${dir}/Dockerfile" <<EOF
FROM ${devimg}
ADD app app
RUN bundle install --path=vendor/bundle --binstubs vendor/bundle/bin --jobs=4 --retry=3
#RUN bundle exec rake db:migrate
EOF
  docker build --tag ${devimg} $dir >> ${logfile} 2>&1
}

function run_tests() {
  log "creating db"
  docker run --env-file=${envfile}  $devimg bundle exec rake db:create
  
  log "loading schema"
  docker run --env-file=${envfile} $devimg bundle exec rake db:schema:load

  info "running testing using bundle exec rspec"
  docker run --env-file=${envfile} $devimg bundle exec rspec
}

function tag_build() {
  local dir="${cachedir}/${devimg}/app"
  (cd $dir && git tag -f "deploy_${branch}" && git push -f origin "deploy_${branch}")
}

function start_services() {
  redis=$(docker run --name $devimg-redis-${RANDOM} -d redis)
  log "running redis container"
  redisip=$(docker inspect -f "{{ .NetworkSettings.IPAddress }}" ${redis})
  
  pg=$(docker run --name $devimg-pg-${RANDOM} -d postgres)
  pgip=$(docker inspect -f "{{ .NetworkSettings.IPAddress }}" ${pg})
  log "running postgres"

  envfile="${cachedir}/.env"

  cat > ${envfile} <<EOF
REDIS_HOST=${redisip}
POSTGRES_HOST=${pgip}
EOF
}

function stop_services() {
  if [ -n ${redis} ]; then
    docker rm -f ${redis}
    log "removed redis container"
  fi

  if [ -n ${pg} ]; then
    docker rm -f ${pg}
    log "removed postgres container"
  fi
}

function copy_compiled_app() {
  local id=$(docker run -dt app-compiler /bin/bash)
  local dir=${cachedir}/app-runtime
  mkdir -p ${dir}
  docker cp ${id}:/app ${dir}
  log "application compiled to ${dir}"
  docker rm --force ${id} > /dev/null
  log "removing compiler copy container ${id}"
}

function app_runtime_container_exists() {
  test -n "$(docker images | grep '^app-runtime ')"
}

function build_app_runtime_container() {
 log "building app runtime base container"
 local secretsbase=$(date +%s | sha256sum | base64 | head -c 64)
 local pkgs=$(printf "%s " $RUNTIME_PACKAGES)
 local dir="${cachedir}/app-runtime"
 tee "${dir}/Dockerfile" > /dev/null <<EOF
FROM app-base
RUN apt-get update && apt-get install -y ${pkgs}
ENV RAILS_ENV production
ENV SECRET_KEY_BASE ${secretsbase}
RUN mkdir -p /app
EOF
  docker build --tag app-runtime ${dir} >> ${logfile} 2>&1
}

function build_runtime_image() {
  info "building app-runtime container image"
  dir="${cachedir}/app-runtime"
  mkdir -p ${dir}
  cat > ${dir}/Dockerfile <<EOF
FROM app-runtime
ADD app app
WORKDIR /app
EOF
  docker build --tag app-runtime ${dir} >> ${logfile} 2>&1
  info "application successfully built"
}

function info() {
  local msg="--> ${PROGRAM}: ${*}"
  echo -e "${msg}" >> ${logfile}
  echo -e "${msg}"
}

function log() {
  local msg="${*}"

  if [ ${verbose} -gt 0 ]; then
    echo -e "${msg}"
  fi
  echo -e "${msg}" >> ${logfile}
}


function show_help() {
  cat <<EOF
Usage: ${PROGRAM} [OPTIONS] GIT_REPO

Runs tests for the given repo in a container

Options:
  -b, --branch="master"               Git branch
  -k, --ssh-key="\$HOME/.ssh/id_rsa"   SSH key for git repo access
  -a, --app-name=""                   Application name. Autogenerated based on the git repo path
  -c, --cache-dir=""                  Cache directory
  -v, --verbose
EOF
}

function parse_opts() {
  repo="${@: -1}"

  while [[ $# > 0 ]]; do
    local key="$1"
    shift
    case ${key} in
      -b|--branch=)
        branch="${1}"
        shift
        ;;
      -c|--cache-dir=)
        cachedir="${1}"
        shift
        ;;
      -k|--ssh-key=)
        sshkey="${1}"
        shift
        ;;
      -a|--app-name=)
        appname="${1}"
        shift
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      -v|--verbose)
        verbose=1
        ;;
    esac
  done
  if [ -z "${repo}" ]; then
    show_help 
    exit 1
  fi
}

function init() {
  if [ -z "${cachedir}" ]; then
    cachedir=$(mktemp -d --tmpdir $TMPDIR build-compiler-XXXXXXX)
  fi

  # determine applicaiton name from gitrepo
  if [ -z "${appname}" ]; then
    appname=$(echo "${repo}" | sed "s/^.*\///" | sed "s/.git//")
  fi
  
  if [ -z "${appname}" ]; then
    abort "error: could not determine application name. specify using --app-name"
  fi

  devimg="${appname}-dev"

  if [ -z "${sshkey}" ]; then
    sshkey=${HOME}/.ssh/id_rsa
  fi
  
  # create cache directory if missing
  mkdir -p ${cachedir}/${appname}-dev
  
  logfile="${cachedir}/run.log"

  info "running tests for ${appname} from ${repo}. More info ${logfile}"
  
  # exit script if we would use an uninitialised variable
  set -o nounset

  # exit script when a simple command (not a control structure) fails
  set -o errexit
}

# Abort and writes the message in red to standard error
#
function abort() {
  local red=$(tput setaf 1)
  local reset=$(tput sgr0)
  echo >&2 -e "${red}$@${reset}"
  exit 1
}

# Aborts the given command is missing
#
function abort_if_missing_command() {
  local cmd=$1
  type ${cmd} >/dev/null 2>&1 || abort "${2}"
}

verbose=0
repo=''
cachedir=''
appname=''
logfile=''
devimg=''
sshkey="${HOME}/.ssh/id_rsa"
branch='master'

parse_opts $*
init
run
