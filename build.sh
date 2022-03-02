#!/bin/bash

set -u
set -e

export ROOT_PATH="$(cd $(dirname $0); echo $PWD)"
OUTPUT_DIRECTORY="$ROOT_PATH/output"
EXPORT_DIRECTORY=""

UPDATE_SUBMODULES=false
CONFIGURATION="Release"
CLEAN=false
PACKAGES=false
NIGHTLY=false
PORTABLE=false
HEADLESS=false
SKIP_FETCH=false
NET=false
TFM="net5.0"
PARAMS=()
CUSTOM_PROP=

function print_help() {
  echo "Usage: $0 [-cdvspnt] [-b properties-file.csproj] [--no-gui] [--skip-fetch]"
  echo ""
  echo "-c             clean instead of building"
  echo "-d             build Debug configuration"
  echo "-v             verbose output"
  echo "-p             create packages after building"
  echo "-n             create nightly packages after building"
  echo "-t             create a portable package (experimental, Linux only)"
  echo "-s             update submodules"
  echo "-b             custom build properties file"
  echo "-o             custom output directory"
  echo "--skip-fetch   skip fetching submodules and additional resources"
  echo "--no-gui       build with GUI disabled"
  echo "--net          build with dotnet"
}

while getopts "cdvpnstbo:-:" opt
do
  case $opt in
    c)
      CLEAN=true
      ;;
    d)
      CONFIGURATION="Debug"
      ;;
    v)
      PARAMS+=(/verbosity:detailed)
      ;;
    p)
      PACKAGES=true
      ;;
    n)
      NIGHTLY=true
      PACKAGES=true
      ;;
    t)
      PORTABLE=true
      ;;
    s)
      UPDATE_SUBMODULES=true
      ;;
    b)
      CUSTOM_PROP=$OPTARG
      ;;
    o)
      EXPORT_DIRECTORY=$OPTARG
      echo "Setting the output directory to $EXPORT_DIRECTORY"
      ;;
    -)
      case $OPTARG in
        "no-gui")
          HEADLESS=true
          ;;
        "skip-fetch")
          SKIP_FETCH=true
          ;;
        "net")
          NET=true
          PARAMS+=(/p:NET=true)
          ;;
        *)
          print_help
          exit 1
          ;;
      esac
      ;;
    \?)
      print_help
      exit 1
      ;;
  esac
done
shift "$((OPTIND-1))"

if [ -n "${PLATFORM:-}" ]
then
    echo "PLATFORM environment variable is currently set to: >>$PLATFORM<<"
    echo "This might cause problems during the build."
    echo "Please clear it with:"
    echo ""
    echo "    unset PLATFORM"
    echo ""
    echo " and run the build script again."

    exit 1
fi

# Update submodules if not initialized or if requested by the user
# Warn if not updating, but unclean
# Disabling -e to allow grep to fail
set +e
git submodule status --recursive | grep -q "^-"
SUBMODULES_NOT_INITED=$?

git submodule status --recursive | grep -q "^+"
SUBMODULES_NOT_CLEAN=$?
set -e

if $SKIP_FETCH
then
  echo "Skipping init/update of submodules"
else
  if $UPDATE_SUBMODULES || [ $SUBMODULES_NOT_INITED -eq 0 ]
  then
      echo "Updating submodules..."
      git submodule update --init --recursive
  elif [ $SUBMODULES_NOT_CLEAN -eq 0 ]
  then
      echo "Submodules are not updated. Use -s to force update."
  fi
fi

. "${ROOT_PATH}/tools/common.sh"

if $SKIP_FETCH
then
  echo "Skipping library fetch"
else
  "${ROOT_PATH}"/tools/building/fetch_libraries.sh
fi

if $HEADLESS
then
    BUILD_TARGET=Headless
    PARAMS+=(/p:GUI_DISABLED=true)
elif $ON_WINDOWS
then
    BUILD_TARGET=Windows
    TFM="net5.0-windows10.0.17763.0"
else
    BUILD_TARGET=Mono
fi

TARGET="`get_path \"$PWD/Renode.sln\"`"

# Update references to Xwt
TERMSHARP_PROJECT="${CURRENT_PATH:=.}/lib/termsharp/TermSharp.csproj"
TERMSHARP_PROJECT_COPY="${CURRENT_PATH:=.}/lib/termsharp/TermSharp-working_copy.csproj"
if [ ! -e "$TERMSHARP_PROJECT_COPY" ]
then
    cp "$TERMSHARP_PROJECT" "$TERMSHARP_PROJECT_COPY"
    sed -i.bak 's/"xwt\\Xwt\\Xwt.csproj"/"..\\xwt\\Xwt\\Xwt.csproj"/' "$TERMSHARP_PROJECT_COPY"
    rm "$TERMSHARP_PROJECT_COPY.bak"
fi

# Verify Mono and mcs version on Linux and macOS
if ! $ON_WINDOWS && ! $NET
then
    if ! [ -x "$(command -v mcs)" ]
    then
        MINIMUM_MONO=`get_min_mono_version`
        echo "mcs not found. Renode requries Mono $MINIMUM_MONO or newer. Please refer to documentation for installation instructions. Exiting!"
        exit 1
    fi

    verify_mono_version
fi

# Copy properties file according to the running OS
mkdir -p "$OUTPUT_DIRECTORY"
if [ -n "${CUSTOM_PROP}" ]; then
    PROP_FILE=$CUSTOM_PROP
else
    if $ON_OSX
    then
      PROP_FILE="$CURRENT_PATH/src/Infrastructure/src/Emulator/Cores/osx-properties.csproj"
    elif $ON_LINUX
    then
      PROP_FILE="$CURRENT_PATH/src/Infrastructure/src/Emulator/Cores/linux-properties.csproj"
    else
      PROP_FILE="$CURRENT_PATH/src/Infrastructure/src/Emulator/Cores/windows-properties.csproj"
    fi
fi
cp "$PROP_FILE" "$OUTPUT_DIRECTORY/properties.csproj"

# Build CCTask in Release configuration
if $NET
then
  dotnet build /p:Configuration=Release /p:NET=true "`get_path \"$ROOT_PATH/lib/cctask/CCTask.sln\"`" > /dev/null
else
  $CS_COMPILER /p:Configuration=Release "`get_path \"$ROOT_PATH/lib/cctask/CCTask.sln\"`" > /dev/null
fi

# clean instead of building
if $CLEAN
then
    if ! $NET
    then
      PARAMS+=(/t:Clean)
    fi
    for conf in Debug Release
    do
      for build_target in Windows Mono Headless
      do
        if $NET
        then
            dotnet clean "${PARAMS[@]}" /p:Configuration=${conf}${build_target} "$TARGET"
        else
            $CS_COMPILER "${PARAMS[@]}" /p:Configuration=${conf}${build_target} "$TARGET"
        fi
      done
      rm -fr $OUTPUT_DIRECTORY/bin/$conf
    done
    exit 0
fi

# check weak implementations of core libraries
pushd "$ROOT_PATH/tools/building" > /dev/null
./check_weak_implementations.sh
popd > /dev/null

PARAMS+=(/p:Configuration=${CONFIGURATION}${BUILD_TARGET} /p:GenerateFullPaths=true)
# build

if $NET
then
  dotnet build "${PARAMS[@]}" "$TARGET"
  # copy llvm library
  cp src/Infrastructure/src/Emulator/Peripherals/bin/$CONFIGURATION/$TFM/libllvm-disas.* output/bin/$CONFIGURATION/$TFM
else
  $CS_COMPILER "${PARAMS[@]}" "$TARGET"
  # copy llvm library
  cp src/Infrastructure/src/Emulator/Peripherals/bin/$CONFIGURATION/libllvm-disas.* output/bin/$CONFIGURATION
fi

# build packages after successful compilation
params=""

if [ $CONFIGURATION == "Debug" ]
then
    params="$params -d"
fi

if [ -n "$EXPORT_DIRECTORY" ]
then
    if [ "${DETECTED_OS}" != "linux" ]
    then
        echo "Custom output directory is currently available on Linux only"
        exit 1
    fi

    $ROOT_PATH/tools/packaging/export_${DETECTED_OS}_workdir.sh $EXPORT_DIRECTORY $params
    echo "Renode built to $EXPORT_DIRECTORY"
fi

if $PACKAGES && ! $NET
then
    if $NIGHTLY
    then
      params="$params -n"
    fi

    $ROOT_PATH/tools/packaging/make_${DETECTED_OS}_packages.sh $params
fi


if $PORTABLE && ! $NET
then
    if $ON_LINUX
    then
      $ROOT_PATH/tools/packaging/make_linux_portable.sh $params
    else
      echo "Portable packages are only available on Linux. Exiting!"
      exit 1
    fi
fi
