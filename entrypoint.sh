#!/bin/sh
#
# Copyright (c) 2019 Masayuki Morita
# Released under the MIT license
# https://github.com/minamijoyo/tfupdate/blob/master/LICENSE

set -e


# shellcheck disable=SC2113
function run_tfupdate {
  CURRENT_DATE=$(date "+%Y%m%d-%H%M%S")
  case ${INPUT_RESOURCE} in
    terraform)
      VERSION=$(tfupdate release latest hashicorp/terraform)
      PULL_REQUEST_BODY="For details see: https://github.com/hashicorp/terraform/releases"
      UPDATE_MESSAGE="[tfupdate] Bump Terraform to v${VERSION} at ${CURRENT_DATE}"
      ;;

    provider)
      if [ ! ${INPUT_PROVIDER_NAME} ]; then
        echo 'ERROR: "provier_name" needs to be set for "provider" resource'
        exit 1
      fi
      REPOSITORY="terraform-providers/terraform-provider-${INPUT_PROVIDER_NAME}"
      if [ -n "${INPUT_PROVIDER_REPO}" ]; then
        REPOSITORY=${INPUT_PROVIDER_REPO}
      fi
      VERSION=$(tfupdate release latest "$REPOSITORY")
      PULL_REQUEST_BODY="For details see: https://github.com/$REPOSITORY/releases"
      UPDATE_MESSAGE="[tfupdate] Bump Terraform Provider ${INPUT_PROVIDER_NAME} to v${VERSION} at ${CURRENT_DATE}"
      ;;
    module)
      if ! [ ${INPUT_MODULE_NAME} ] || ! [ ${INPUT_SOURCE_TYPE} ]; then
        echo 'ERROR: both "module_name" and "source_type" need to be set for "module" resource'
        exit 1
      fi
      VERSION=$(tfupdate release latest --source-type=${INPUT_SOURCE_TYPE} ${INPUT_MODULE_NAME})
      UPDATE_MESSAGE="[tfupdate] Bump Terraform Module ${INPUT_MODULE_NAME} to v${VERSION} at ${CURRENT_DATE}"
      case ${INPUT_SOURCE_TYPE} in
        github)
          PULL_REQUEST_BODY="For details see: https://github.com/${INPUT_MODULE_NAME}/releases"
          ;;
        gitlab)
          PULL_REQUEST_BODY="For details see: https://gitlab.com/${INPUT_MODULE_NAME}/releases"
          ;;
        tfregistryModule)
          PULL_REQUEST_BODY="For details see: https://registry.terraform.io/modules/${INPUT_MODULE_NAME}/${VERSION}"
          ;;
        *)
          echo "ERROR: unknown source type"
          exit 1
      esac
      ;;
    *)
      echo "ERROR: unknown resource"
      exit 1
      ;;
  esac

  # Set optional arguments
  ARGS="--version=${VERSION}"
  if [ ${INPUT_RECURSIVE} ]; then
    ARGS="${ARGS} --recursive=${INPUT_RECURSIVE}"
  fi
  if [ ${INPUT_IGNORE_PATH} ]; then
    ARGS="${ARGS} --ignore-path=${INPUT_IGNORE_PATH}"
  fi
  if [ -n "${INPUT_PROVIDER_NAME}" ]; then
    ARGS="${ARGS} ${INPUT_PROVIDER_NAME}"
  fi
  if [ ${INPUT_MODULE_NAME} ]; then
    ARGS="${ARGS} ${INPUT_MODULE_NAME}"
  fi

  # Set github config
  git config --local user.email "${USER_EMAIL}"
  git config --local user.name "${USER_NAME}"

  # Checkout a branch if a PR does not exist.
  if hub pr list -s "open" -f "%t: %U%n" | grep -F "${UPDATE_MESSAGE}"; then
    echo "A pull request already exists"
    exit 0
  elif hub pr list -s "merged" -f "%t: %U%n" | grep -F "${UPDATE_MESSAGE}"; then
    echo "A pull request is already merged"
    exit 0
  elif hub pr list -s "closed" -f "%t: %U%n" | grep -F "${UPDATE_MESSAGE}"; then
    echo "A pull request is already closed"
    exit 0
  else
    CURRENT_DATE=$(date "+%Y%m%d-%H%M%S")
    CHECKOUT_BRANCH="update-${INPUT_RESOURCE}-to-v${VERSION}-${CURRENT_DATE}"
    echo "Checking out to ${CHECKOUT_BRANCH} branch"
    git fetch --all
    git checkout -b ${CHECKOUT_BRANCH} origin/${INPUT_BASE_BRANCH}
  fi

  # Execute tfupdate command
  COMMAND="${INPUT_RESOURCE} ${ARGS} ${INPUT_FILE_PATH}"
  echo "Running tfupdate ${COMMAND}"
  tfupdate ${COMMAND}

  # update .terraform-version
  if [ "${INPUT_RESOURCE}" = 'terraform' ]; then
    TV_IGNORE_OPTION=''
    if [ "${INPUT_IGNORE_PATH}" != '' ]; then
      TV_IGNORE_OPTION="! -path \"${INPUT_IGNORE_PATH}\""
    fi
    # shellcheck disable=SC2090,SC2086
    find . -name .terraform-version ${TV_IGNORE_OPTION} -exec sh -c 'TV="$1";VERSION="$2";echo $VERSION > $TV' _ {} $VERSION \;
  fi

  if [ "${INPUT_RESOURCE}" = 'provider' ]; then
    generate_tflock
  fi

  # Send a pull reuqest agaist the base branch
  if git add . && git diff --cached --exit-code --quiet; then
    echo "No changes"
  else
    echo "Creating a pull request: ${UPDATE_MESSAGE}"
    git commit -m "${UPDATE_MESSAGE}"
    if [ ${INPUT_REVIEWER} ]; then
      git push origin HEAD && hub pull-request -m "${UPDATE_MESSAGE}" -m "${PULL_REQUEST_BODY}" -b "${INPUT_BASE_BRANCH}" -l "${INPUT_LABEL}" -r "${INPUT_REVIEWER}"
    else
      git push origin HEAD && hub pull-request -m "${UPDATE_MESSAGE}" -m "${PULL_REQUEST_BODY}" -b "${INPUT_BASE_BRANCH}" -l "${INPUT_LABEL}"
    fi
  fi
}

generate_tflock() {
  # create a plugin cache dir
  export TF_PLUGIN_CACHE_DIR="/tmp/terraform.d/plugin-cache"
  mkdir -p "${TF_PLUGIN_CACHE_DIR}"

  # create a local filesystem mirror to avoid duplicate downloads
  FS_MIRROR="/tmp/terraform.d/plugins"
  terraform providers mirror -platform=linux_amd64 -platform=darwin_amd64 "${FS_MIRROR}"

  # update the lock file
  TFLOCK_DIRS=$(find . -type f -name '.terraform.lock.hcl' | xargs dirname | sort)
  for dir in ${TFLOCK_DIRS}
  do
    pushd "$dir"
    # always create a new lock to avoid duplicate downloads by terraoform init -upgrade
    rm -f .terraform.lock.hcl
    # get modules to detect provider dependencies inside module
    terraform init -input=false -no-color -backend=false -plugin-dir="${FS_MIRROR}"
    # remove a temporary lock file to avoid a checksum mismatch error
    rm -f .terraform.lock.hcl
    # generate h1 hashes for all platforms you need
    # recording zh hashes requires to download from origin, so we intentionally ignore them.
    terraform providers lock -fs-mirror="${FS_MIRROR}" -platform=linux_amd64 -platform=darwin_amd64
    # clean up
    rm -rf .terraform
    popd
  done
}

run_tfupdate
