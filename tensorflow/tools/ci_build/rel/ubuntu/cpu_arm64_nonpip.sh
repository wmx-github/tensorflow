#!/bin/bash
# Copyright 2022 The TensorFlow Authors. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ==============================================================================

set -e
set -x

source tensorflow/tools/ci_build/release/common.sh

# Strip leading and trailing whitespaces
str_strip () {
  echo -e "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# Clean up bazel build & test flags with proper configuration.
update_bazel_flags() {
  # Add git tag override flag if necessary.
  GIT_TAG_STR=" --action_env=GIT_TAG_OVERRIDE"
  if [[ -z "${GIT_TAG_OVERRIDE}" ]] && \
    ! [[ ${TF_BUILD_FLAGS} = *${GIT_TAG_STR}* ]]; then
    TF_BUILD_FLAGS+="${GIT_TAG_STR}"
  fi
  # Clean up whitespaces
  TF_BUILD_FLAGS=$(str_strip "${TF_BUILD_FLAGS}")
  TF_TEST_FLAGS=$(str_strip "${TF_TEST_FLAGS}")
  # Cleaned bazel flags
  echo "Bazel build flags (cleaned):\n" "${TF_BUILD_FLAGS}"
  echo "Bazel test flags (cleaned):\n" "${TF_TEST_FLAGS}"
}

sudo install -o ${CI_BUILD_USER} -g ${CI_BUILD_GROUP} -d /tmpfs
sudo install -o ${CI_BUILD_USER} -g ${CI_BUILD_GROUP} -d /tensorflow
sudo chown -R ${CI_BUILD_USER}:${CI_BUILD_GROUP} /usr/local/lib/python*
sudo chown -R ${CI_BUILD_USER}:${CI_BUILD_GROUP} /usr/local/bin
sudo chown -R ${CI_BUILD_USER}:${CI_BUILD_GROUP} /usr/lib/python3/dist-packages

# Update bazel
install_bazelisk

# Set python version string
python_version=$(python3 -c 'import sys; print("python"+str(sys.version_info.major)+"."+str(sys.version_info.minor))')

# Setup virtual environment
setup_venv_ubuntu ${python_version}

# Env vars used to avoid interactive elements of the build.
export HOST_C_COMPILER=(which gcc)
export HOST_CXX_COMPILER=(which g++)
export TF_ENABLE_XLA=1
export TF_DOWNLOAD_CLANG=0
export TF_SET_ANDROID_WORKSPACE=0
export TF_NEED_MPI=0
export TF_NEED_ROCM=0
export TF_NEED_GCP=0
export TF_NEED_S3=0
export TF_NEED_OPENCL_SYCL=0
export TF_NEED_CUDA=0
export TF_NEED_HDFS=0
export TF_NEED_OPENCL=0
export TF_NEED_JEMALLOC=1
export TF_NEED_VERBS=0
export TF_NEED_AWS=0
export TF_NEED_GDR=0
export TF_NEED_OPENCL_SYCL=0
export TF_NEED_COMPUTECPP=0
export TF_NEED_KAFKA=0
export TF_NEED_TENSORRT=0

# Export required variables for running the tests
export OS_TYPE="UBUNTU"
export CONTAINER_TYPE="CPU"

# Get the default test targets for bazel
source tensorflow/tools/ci_build/build_scripts/DEFAULT_TEST_TARGETS.sh

# Get the extended skip test list for arm
source tensorflow/tools/ci_build/build_scripts/ARM_SKIP_TESTS_EXTENDED.sh

# Export optional variables for running the tests
export TF_BUILD_FLAGS="--config=mkl_aarch64_threadpool --copt=-flax-vector-conversions"
export TF_TEST_FLAGS="${TF_BUILD_FLAGS} \
    --test_env=TF_ENABLE_ONEDNN_OPTS=1 --test_env=TF2_BEHAVIOR=1 --define=tf_api_version=2 \
    --test_lang_filters=py --test_size_filters=small,medium \
    --test_output=errors --verbose_failures=true --test_keep_going --notest_verbose_timeout_warnings"
export TF_TEST_TARGETS="${DEFAULT_BAZEL_TARGETS} ${ARM_SKIP_TESTS}"
export TF_FILTER_TAGS="-no_oss,-oss_excluded,-oss_serial,-v1only,-benchmark-test,-no_aarch64,-gpu,-tpu,-no_oss_py38,-no_oss_py39,-no_oss_py310"
export TF_AUDITWHEEL_TARGET_PLAT="manylinux2014"

if [ ${IS_NIGHTLY} == 1 ]; then
  ./tensorflow/tools/ci_build/update_version.py --nightly
fi

sudo sed -i '/^build --profile/d' /usertools/aarch64.bazelrc
sudo sed -i '\@^build.*=\"/usr/local/bin/python3\"$@d' /usertools/aarch64.bazelrc
sed -i '$ aimport /usertools/aarch64.bazelrc' .bazelrc

# Override breaking change in setuptools v60 (https://github.com/pypa/setuptools/pull/2896)
export SETUPTOOLS_USE_DISTUTILS=stdlib

# Obtain the path to python binary as written by ./configure if it was run.
if [[ -e tools/python_bin_path.sh ]]; then
  source tools/python_bin_path.sh
fi
# Assume PYTHON_BIN_PATH is exported by the script above or the caller.
if [[ -z "$PYTHON_BIN_PATH" ]]; then
  die "PYTHON_BIN_PATH was not provided. Did you run configure?"
fi

# Local variables
WHL_DIR="${KOKORO_ARTIFACTS_DIR}/tensorflow/whl"
mkdir -p "${WHL_DIR}"
WHL_DIR=$(realpath "${WHL_DIR}") # Get absolute path

# Determine the major.minor versions of python being used (e.g., 3.7).
# Useful for determining the directory of the local pip installation.
PY_MAJOR_MINOR_VER=$(${PYTHON_BIN_PATH} -c "print(__import__('sys').version)" 2>&1 | awk '{ print $1 }' | head -n 1 | cut -d. -f1-2)

update_bazel_flags

bazel build \
  --action_env=PYTHON_BIN_PATH=${PYTHON_BIN_PATH} \
  ${TF_BUILD_FLAGS} \
  //tensorflow/tools/pip_package:build_pip_package \
  || die "Error: Bazel build failed for target: '${PIP_BUILD_TARGET}'"

./bazel-bin/tensorflow/tools/pip_package/build_pip_package ${WHL_DIR} ${NIGHTLY_FLAG} "--project_name" ${PROJECT_NAME} || die "build_pip_package FAILED"

PY_DOTLESS_MAJOR_MINOR_VER=$(echo $PY_MAJOR_MINOR_VER | tr -d '.')
if [[ $PY_DOTLESS_MAJOR_MINOR_VER == "2" ]]; then
  PY_DOTLESS_MAJOR_MINOR_VER="27"
fi

# Set wheel path and verify that there is only one .whl file in the path.
WHL_PATH=$(ls "${WHL_DIR}"/"${PROJECT_NAME}"-*"${PY_DOTLESS_MAJOR_MINOR_VER}"*"${PY_DOTLESS_MAJOR_MINOR_VER}"*.whl)
if [[ $(echo "${WHL_PATH}" | wc -w) -ne 1 ]]; then
  echo "ERROR: Failed to find exactly one built TensorFlow .whl file in "\
  "directory: ${WHL_DIR}"
fi

# Print the size of the wheel file and log to sponge.
WHL_SIZE=$(ls -l ${WHL_PATH} | awk '{print $5}')
echo "Size of the PIP wheel file built: ${WHL_SIZE}"

# Repair the wheels for manylinux2014
echo "auditwheel repairing ${WHL_PATH}"
auditwheel repair --plat ${AUDITWHEEL_TARGET_PLAT}_$(uname -m) -w "${WHL_DIR}" "${WHL_PATH}"

if [[ $(ls ${WHL_DIR} | grep ${AUDITWHEEL_TARGET_PLAT} | wc -l) == 1 ]] ; then
  WHL_PATH=${WHL_DIR}/$(ls ${WHL_DIR} | grep ${AUDITWHEEL_TARGET_PLAT})
  echo "Repaired ${AUDITWHEEL_TARGET_PLAT} wheel file at: ${WHL_PATH}"
else
  die "WARNING: Cannot find repaired wheel."
fi


bazel test ${TF_TEST_FLAGS} \
    --repo_env=PYTHON_BIN_PATH="${PYTHON_BIN_PATH}" \
    --build_tag_filters=${TF_FILTER_TAGS} \
    --test_tag_filters=${TF_FILTER_TAGS} \
    --local_test_jobs=$(grep -c ^processor /proc/cpuinfo) \
    --build_tests_only \
    -- ${TF_TEST_TARGETS}


# remove duplicate wheel and copy wheel to mounted volume for local access
rm -rf ${WHL_DIR}/*linux_aarch64.whl && cp -r ${WHL_DIR} .

# Remove virtual environment
remove_venv_ubuntu
