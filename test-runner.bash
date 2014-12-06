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
  trap cleanup EXIT
  
  # setup git-ssh and copy private key to the cache directory
  setup_ssh

  # setup base, ruby and app containers if they doesn't exit
  setup_base_containers
  
  # Compile application
  compile_app

  # Start support services (pg and redis)
  start_services
  
  # Run tests
  run_tests
  
  # Tag the current build as deploy_branch
  if [ $? -eq 0 ]; then
    info "Build successful"
    tag_build
    exit 0
  else
    echo >&2 -e "Build failed"
    exit $?
  fi
}

function setup_ssh() {
  log "Copying SSH keys. Using SSH private key from ${sshkey}"
  cat > "${cachedir}/git-ssh" <<EOF
  ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \$*
EOF
 chmod +x "${cachedir}/git-ssh"
 mkdir -p ${cachedir}/app-base

 # copy keys to cache directories
 cp ${cachedir}/git-ssh ${cachedir}/app-base/git-ssh
 cp ${sshkey} ${cachedir}/app-base
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
  info "Compiling application"
  get_app_source
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

function get_app_source() {
  log "Fetching application source from ${repo} on branch ${branch}"
  local dir="${cachedir}/${devimg}/app"
  rm -rf ${dir} # keep it fresh
  mkdir -p ${dir}
  GIT_SSH="${cachedir}/git-ssh" git clone -b ${branch} ${repo} ${dir} --depth 1 >> ${logfile} 2>&1
}

function start_services() {
  info "Staring support services"
  redis=$(docker run --name $devimg-redis-${RANDOM} -d redis 2> ${logfile})
  redisip=$(docker inspect -f "{{ .NetworkSettings.IPAddress }}" ${redis})
  log "running redis container at ${redisip}:6379"
  
  pg=$(docker run --name $devimg-pg-${RANDOM} -d postgres)
  pgip=$(docker inspect -f "{{ .NetworkSettings.IPAddress }}" ${pg})
  log "running postgres container at ${pgip}:5432"

  envfile="${cachedir}/.env"

  cat > ${envfile} <<EOF
REDIS_HOST=${redisip}
POSTGRES_HOST=${pgip}
EOF
}

function run_tests() {
  log "Creating database using: ${dbcreatecmd}"
  docker run --env-file=${envfile} $devimg ${dbcreatecmd} >> ${logfile} 2>&1

  log "Running database migrations using: ${dbmigratecmd}"
  docker run --env-file=${envfile} $devimg ${dbmigratecmd} >> ${logfile} 2>&1

  info "Running tests using: ${testcmd}"
  docker run --env-file=${envfile} -t $devimg ${testcmd}
}

function tag_build() {
  local dir="${cachedir}/${devimg}/app"
  local tag="deploy_${branch}"
  log "Pushing tag ${tag} to ${repo}"
  (cd $dir && git tag -f ${tag} && GIT_SSH="${cachedir}/git-ssh" git push -f origin ${tag} >> ${logfile} 2>&1)
}

function cleanup() {
  info "Cleaning up"
  exitstatus=$?
  
  # stop support services
  if [ -n ${redis} ]; then
    docker rm -f ${redis} >> ${logfile} 2>&1
    log "Removed redis container"
  fi

  if [ -n ${pg} ]; then
    docker rm -f ${pg} >> ${logfile} 2>&1
    log "Removed postgres container"
  fi
  
  exit ${exitstatus}
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

  info "Starting tests for ${appname}"
  log "Logging to ${logfile}"
  
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

function info() {
  local msg="==> ${PROGRAM}: ${*}"
  local bold=$(tput bold)
  local reset=$(tput sgr0)
  echo -e "${msg}" >> ${logfile}
  echo -e "${bold}${msg}${reset}"
}

function log() {
  local msg="    ${PROGRAM}: ${*}"
  echo -e "${msg}"
  echo -e "${*}" >> ${logfile}
}

function debug() {
  local msg="    [debug] ${*}"
  if [ ${verbose} -gt 0 ]; then
    echo -e "${msg}"
  fi
  echo -e "${msg}" >> ${logfile}
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
  -b, --branch="master"                               Git branch
  -k, --ssh-key="\$HOME/.ssh/id_rsa"                   SSH key for git repo access
  -c, --cache-dir=""                                  Cache directory
  -t, --test-with="${testcmd}"                 Test command running tests
  --db-create-with="${dbcreatecmd}"       Command to create database migrations with
  --db-migrate-with="${dbmigratecmd}" Command to migrate run database migrations with
  --name=""                                           Application name. Autogenerated based on the git repo path
  -V, --verbose                                       Run in verbose mode
EOF
}

verbose=0
repo=''
cachedir=''
appname=''
logfile=''
devimg=''
sshkey="${HOME}/.ssh/id_rsa"
branch='master'
testcmd="bundle exec rspec"
dbcreatecmd="bundle exec rake db:create"
dbmigratecmd="bundle exec rake db:schema:load"
redis=''
redisip=''
pg=''
pgip=''

parse_opts "$@"
init
run

# vim: tw=80 noexpandtab
