#!/usr/bin/env bash
# set -x

# This script will build the project using either Nix or optionally, in the case of Ubuntu, Apt.

SIM_ROOT=$(cd "${0%/*}" && echo ${PWD})

USE_NIX=1 # Use Nix by default

usage() {
    echo "Usage: $0 [--help | -h] [--[no-]nix] [--clean] [--[only-]run] [--ubuntu-build-deps]" 1>&2; exit 1;
    echo ""
    echo "The project is built and run using Nix by default."
    echo "Specify --no-nix to use a build method specific to your distribution (only Ubuntu is currently supported)."
}

while getopts ":hi-:" o; do
    case "${o}" in
        -)
            case "${OPTARG}" in
                "nix")
                    USE_NIX=1
                    ;;
                "no-nix")
                    USE_NIX=""
                    ;;
                "clean")
                    find . -name ".stack-work" -type d -exec rm -r {} + 2>/dev/null
                    stack clean
                    ;;
                "run")
                    RUN=1
                    ;;
                "only-run")
                    RUN=1
                    NO_BUILD=1
                    ;;
                "ubuntu-build-deps")
                    UBUNTU_BUILD_DEPS=1
                    ;;
                "help"|*)
                    usage
                    ;;
            esac
            ;;
        h|*)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

withNix() {
    echo "Building project using Stack + Nix.."

    source $SIM_ROOT/util/NixHelpers.sh

    installNix
    checkIfUnfreeAllowed

    if [ ! $NO_BUILD ]; then buildSimula;  fi
    if [ $RUN ];        then launchSimula; fi
}

getDistroID() {
    cat /etc/os-release \
        | grep '^ID=' \
        | cut -d '=' -f 2 -
}

DISTROID="$(getDistroID)"
echo "Distribution ID: $DISTROID"
case "$DISTROID" in
    "nixos")
        if [ ! $USE_NIX ]; then
            echo "Not using Nix on NixOS makes no sense."
            exit 1
        else
            withNix
        fi
        ;;
    "ubuntu")
        if [ $USE_NIX ]; then
            withNix
        else
            # TODO: Test this process.

            source $SIM_ROOT/util/UbuntuHelpers.sh

            if [ $UBUNTU_BUILD_DEPS ]; then buildSimulaDependencies; fi

            if [ ! $NO_BUILD ]; then
                buildSimula \
                    || echo "If dependencies appear to be missing, use the option --ubuntu-build-deps to install them."
            fi

            if [ $RUN ]; then launchSimula; fi
        fi
        ;;
    *)
        if [ $USE_NIX ]; then
            withNix
        else
            echo "Your distribution has no specific build instructions. Nix is your only option at this time, sorry."
        fi
        ;;
esac