#!/usr/bin/env bash
PROGRAM=${0##*/}
BASEIMG=ovrclk/test-runner
VERSION=0.1.1

verbose=0
repo=
cachedir="$(mktemp -d -t ${PROGRAM}-XXXXXX)"
approot=
appname=
devimg=
sshkey="${HOME}/.ssh/id_rsa"
branch='master'
dbcreatecmd="bundle exec rake db:create"
dbmigratecmd="bundle exec rake db:migrate"
redis=
redisip=
pg=
pgip=
rabbit=
rabbitip=
errlog=$(mktemp -t ${PROGRAM}-err-XXXX)
rmctrns=1
depends=
pre=
testcmd="bundle exec rake"
post=
envvars=

function run() {
  set -o nounset 
  set -o errexit 
  set -o pipefail
  trap finish EXIT
  
  # get absolute path 
  [ "${cachedir}" ] || abort "cache directory is missing"
  cachedir=$(cd $(dirname ${cachedir}); pwd)/$(basename ${cachedir})
  debug "using cache directory ${cachedir}"

  # determine applicaiton name from gitrepo
  [[ "${appname}" ]] \
    || appname=$(echo "${repo}" | sed "s/^.*\///" | sed "s/.git//") \
    || abort "error: could not determine application name. specify using --name=<appname>"
  debug "setting appname to: ${appname}"
  
  info "Starting tests for ${appname}"

  devimg="${appname}-dev"
  approot="${cachedir}/${appname}-dev"
  mkdir -p ${approot}
  
  setssh
  getsrc
  setimage
  compile
  start_services
  runtest
  tag
}

# setup git-ssh and copy private key to the cache directory
function setssh() {
  log "Setting git-ssh with ${sshkey} Identity"
  echo "ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o IdentityFile=${sshkey} \$*" > "${cachedir}/git-ssh"
  chmod +x "${cachedir}/git-ssh"
}

function setimage() {
  local src="${cachedir}/${devimg}/app"
  if [ -f "$src/.ruby-version" ]; then
    local img="ovrclk/test-runner-$(cat $src/.ruby-version)"
    info "Searching for base image ${img} in the docker registry"
    results=$(docker search $img | wc -l)
    if [ $results -gt 1 ]; then
      BASEIMG=$img
      log "Using base image ($img) from the registry."
    else
      BASEIMG="ovrclk/test-runner-2.1.2"
      log "Suitable base image was not found in registry, using $BASEIMG as base. Futher versions will support compilation for base images"
    fi
  fi
}

function compile() {
  local dir="${cachedir}/${devimg}"
  
  log "Copying ssh keys"
  mkdir -p ${dir}/app/.ssh
  cp ${sshkey} ${dir}/app/.ssh/id_rsa

  cat > ${dir}/app/.ssh/config <<EOF
Host github.com
     UserKnownHostsFile /dev/null
     StrictHostKeyChecking no 
     IdentityFile /app/.ssh/id_rsa
EOF

  # setup base, ruby and app containers if they doesn't exit
  if [[ "$(docker images | grep "^${devimg}")" ]]; then
    local img=${devimg}
  else
    local img=$BASEIMG
  fi

  info "Compiling application"
  cat > "${dir}/Dockerfile" <<EOF
FROM ${img}
ADD app /app
ENV HOME /app
RUN cp /app/.ssh/config /etc/ssh/ssh_config
WORKDIR /app
EOF
  docker build --rm --tag ${devimg} $dir 2>&1 | debug

  if [ -f "${dir}/app/Gemfile" ]; then
    log "Ruby app detected. Installing gem dependencies using bundler."
    local name="${devimg}-${RANDOM}"
    docker run --name=${name} ${devimg} bundle install --path=/app/vendor/bundle --binstubs /app/vendor/bundle/bin --jobs=4 --retry=3 2>&1 | debug
    docker commit ${name} ${devimg}:latest 2>&1 | debug
  fi

  # if [ -f "${dir}/app/package.json" ]; then
  #   log "Javascript app detected. Installing nodejs dependencies using npm."
  #   local name="${devimg}-${RANDOM}"
  #   docker run --name=${name} ${devimg} npm install 2>&1 | debug
  #   docker commit ${name} ${devimg}:latest 2>&1 | debug
  # fi
}

function getsrc() {
  log "Fetching application source from ${repo} on branch ${branch}"
  local dir="${cachedir}/${devimg}/app"
  rm -rf ${dir} # keep it fresh
  mkdir -p ${dir}
  gitssh clone -q -b ${branch} ${repo} ${dir} --depth 1 > ${errlog} 2>&1 
  rm ${errlog}
}

function gitssh() {
  GIT_SSH="${cachedir}/git-ssh" git $*
}

function getdeps() {
  local branch="master"
  for dep in ${depends}; do
    local dir="${cachedir}/${devimg}/app/vendor"
    log "Fetching dependency application source from ${dep} to ${dir}"
    rm -rf ${dir} # keep it fresh
    mkdir -p ${dir}
    $(cd ${dir}; gitssh clone -q -b ${branch} ${dep} --depth 1 > ${errlog} 2>&1)
    rm ${errlog}
  done
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
  # wait for all services to bootup
  sleep 3
}

function runtest() {
  cmd=${testcmd}
  [[ "${pre}" ]]  && cmd="${pre}; ${cmd}" 
  info "Running tests using: ${cmd}"
  local runcmd="docker run --rm ${envvars} --env-file=${envfile} -t $devimg /bin/bash -c '${cmd}'"
  debug "running tests: ${runcmd}"
  eval $runcmd 2>&1 | log
}

function tag() {
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
  
  if [ "${rmctrns}" == "1" ]; then
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
  fi

  if [ ${exitcode} -eq 0 ]; then
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

function gitappname() {
  local source="${1}"
  echo "${source}" | sed "s/^.*\///" | sed "s/.git//"
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

function version() {
  echo "test-runner ${VERSION}"
}

function parseopts() {
  # short flags
  local flags="V"
  local inputs=("$@")
  local options=()
  local arguments=()
  local values=()
  local postion=0
  let position=0
  while [ ${position} -lt ${#inputs[*]} ]; do
    local arg="${inputs[${position}]}"
    if [ "${arg:0:1}" = "-" ]; then
      # parse long options (--option=value)
      if [ "${arg:1:1}" = "-" ]; then
        local key="${arg:2}"
        local val="${key#*=}"
        local opt="${key/=${val}}"
        local values[${#options[*]}]=${val}
        local options[${#options[*]}]=${opt}
      else
        # parse short options (-o value) and 
        # stacked options (-opq val val val)
        let index=1
        while [ ${index} -lt ${#arg} ]; do
          local opt=${arg:${index}:1}
          let index+=1
          let isflag=0
          for flag in ${flags}; do
            if [ "${opt}" == "${flag}" ]; then
              let isflag=1
            fi
          done
          # skip storing the value if this it is a flag
          if [ ${isflag} == 0 ]; then
            let position+=1
            local values[${#options[*]}]=${inputs[position]}
          fi
          local options[${#options[*]}]="${opt}"
        done
      fi
    else
      # parse positional arguments
      local arguments[${#arguments[*]}]="$arg"
    fi
    let position+=1
  done


  local index=0
  for option in "${options[@]}"; do
    case "$option" in
    "h" | "help" )
      help
      exit 0
      ;;
    "v" | "version" )
      version
      exit 0
      ;;
    "c" | "cache" )
      cachedir=${values[${index}]}
      ;;
    "b" | "branch" )
      branch=${values[${index}]}
      ;;
    "k" | "ssh-key" )
      sshkey=${values[${index}]}
      ;;
    "n" | "name" )
      appname=${values[${index}]}
      ;;
    "p" | "pre" )
      pre=${values[${index}]}
      ;;
    "t" | "test" )
      testcmd=${values[${index}]}
      ;;
    "post" )
      post=${values[${index}]}
      ;;
    "rm" )
      [[ "${values[${index}]}" == "false" ]] && rmctrns=0
      ;;
    "e" | "env" )
      envvars="${envvars} -e ${values[${index}]}"
      ;;
    "V" | "verbose" )
      verbose=1
      ;;
    * )
      echo "Usage: $(usage)" >&2
      exit 1
      ;;
    esac
    let local index+=1
  done
  
  # accept only one argument
  if [ ${#arguments[*]} -gt 1 ]; then
    echo "Usage: $(usage)" >&2
    exit 1
  fi

  repo=${arguments[0]} 
  if [ -z "${repo}" ]; then
    ${PROGRAM} --help
    exit 1
  fi
}

function usage() {
  echo "${PROGRAM} [options] REPO"
}

function help() {
  version
  echo
  echo "Usage:"
  echo "  $(usage)"
  echo
  echo "Options:"
  echo "  -c DIR --cache=DIR          Use the cache from DIR."
  echo "  -b BRANCH --branch=BRANCH   Use instead of the default. [default: master]"
  echo "  -k KEY --ssh-key=KEY        Private key for accessing git. [default: ${HOME}/.ssh/id_rsa]"
  echo "  -t CMD --test=CMD           Run tests with CMD. [default: rake]" 
  echo "  -p CMD --pre=CMD            Run CMD before running tests."
  echo "  --post=CMD                  Run CMD before after tests."
  echo "  --rm=false                  Always keep the containers after the run. [default: true]"
  echo "  -n --name=NAME              Application name, autogenerated based on the git repo path."
  echo "  -e [VAR=VAL..]              Environment variables to set."
  echo "  -V --verbose                Run in verbose mode."
  echo "  -h --help                   Display this help message."
  echo "  -v --version                Display the version number."
}

function debugopts() {
  debug "executing with options"
  debug "repo: ${repo}" 
  debug "cachedir: ${cachedir}" 
  debug "branch: ${branch}" 
  debug "sshkey: ${sshkey}" 
  debug "testcmd: ${testcmd}" 
  debug "pre: ${pre}" 
  debug "post: ${post}" 
  debug "appname: ${appname}" 
  debug "verbose: ${verbose}" 
  debug "envvars: ${envvars}" 
}

parseopts "$@"
debugopts
run

# vim: tw=80 noexpandtab
