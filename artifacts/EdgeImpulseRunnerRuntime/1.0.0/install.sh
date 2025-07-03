#!/bin/sh

# Defaults for NodeJS/NPM
NODE_VERSION="20.18.2"
NPM_VERSION="10.8.1"

INSTALL_DIR=$1
NODEJS_VERSION=$2
TARGET_DIR=$3
TARGET_USER=$4
TARGET_GROUP=$5
LOCAL_ARTIFACTS=$6
ARTIFACTS_DIR=$7
shift 7
EI_GGC_USER_GROUPS="$*"

# machine specifics
ARCH=`uname -m`
APT=`which apt`
YUM=`which yum`
OS=`uname -s | tr '[:upper:]' '[:lower:]'`
ALL=`uname -a`

# enable non-npm runner
USE_LOCAL_RUNNER="no"

# Greengrass Configuration
export GREENGRASS_SERVICEUSER=${TARGET_USER}
export GREENGRASS_SERVICEGROUP=${TARGET_GROUP}
export HOME_DIR=${TARGET_DIR}
export GG_LITE="NO"
if [ -f /etc/greengrass/config.d/greengrass-lite.yaml ]; then
    export GG_LITE="YES"
    export GREENGRASS_SERVICEUSER="ggcore"
    export GREENGRASS_SERVICEGROUP="ggcore"
    export TARGET_USER=${GREENGRASS_SERVICEUSER}
    export TARGET_GROUP=${GREENGRASS_SERVICEGROUP}
    export HOME_DIR=/home/${GREENGRASS_SERVICEUSER}
    export TARGET_DIR=${HOME_DIR}
fi

# Yocto RO/RW filesystem check
export RESET_TO_RO="NO"

#
# Is Debian, Ubuntu, Yocto?
#
IS_DEBIAN=`uname -v | grep Debian`
IS_UBUNTU=`uname -v | grep -E '(Ubuntu|RT)'`
export YOCTO=`uname -a | grep -E '(yocto|rzboard|linux4microchip|qc|qli|frdm)'`
IS_AVNET_RZBOARD=`uname -a | grep -E '(rzboard)'`
IS_FRDM_BOARD=`uname -a | grep -E '(frdm)'`
IS_QC_BOARD=`uname -a | grep -E '(qli)'`
ROOT_DIR="/"

#
# Qualcomm special /usr handling
#
if [ ! -z "${IS_QC_BOARD}" ]; then
    ROOT_DIR="/usr"
fi

#
# Rationalize 
#
if [ ! -z "${IS_FRDM_BOARD}" ]; then
    export IS_DEBIAN=""
    export IS_UBUNTU=""
    export APT=""
    export YUM=""
    export YOCTO="yocto"
fi
if [ ! -z "${IS_QC_BOARD}" ]; then
    export IS_DEBIAN=""
    export IS_UBUNTU=""
    export APT=""
    export YUM=""
    export YOCTO="yocto"
fi

# Rationalize for those yocto instances whose 'uname -a' does not reveal that its yocto
if [ -z "${YOCTO}" ]; then
    if [ -z "${IS_UBUNTU}" ] && [ -z "${IS_DEBIAN}" ]; then
        YOCTO_CHECK=`uname -a | cut -d ' ' -f 3 | grep "v"`  # look for version in release version (i.e. "v8" in scarthgap)
        if [ ! -z "${YOCTO_CHECK}" ]; then
            echo "Override check: On Yocto Platform: ${YOCTO_CHECK}."
            export YOCTO="yocto"
        else 
            echo "WARNING: Unable to ascertain whether we are on Yocto or not: check: ${YOCTO_CHECK} yocto: ${YOCTO} all: ${ALL}"
        fi
    else 
        echo "On either Ubuntu or Debian. OK"
    fi
else
    echo "On Yocto platform: ${YOCTO}"
fi

# patch uname -a responses for quirky nodejs download filenaming conventions...
NODE_ARCHIVE_ARCH=${ARCH}
if [ "${ARCH}" = "aarch64" ]; then
    NODE_ARCHIVE_ARCH="arm64"
fi

if [ "${ARCH}" = "x86_64" ]; then
    NODE_ARCHIVE_ARCH="x64"
fi

#
# Sanity check local artifacts
#
if [ "${LOCAL_ARTIFACTS}" = "yes" ]; then
    if [ ! -d ${ARTIFACTS_DIR} ]; then
        echo "WARNING: Local artifacts enabled but artifact directory ${ARTIFACTS_DIR} does not seem to exist. Disabling..."
        export LOCAL_ARTIFACTS="no"
    else
        echo "Confirmed: local artifacts enabled. Local artifacts directory: ${ARTIFACTS_DIR} OK"
        if [ ! -f ${ARTIFACTS_DIR}/models.tar.gz ]; then
            echo "WARNING: Local artifacts enable but missing models archive in ${ARTIFACTS_DIR}... Disabling..."
            export LOCAL_ARTIFACTS="no"
        fi
        if [ ! -f ${ARTIFACTS_DIR}/samples.tar.gz ]; then
            echo "WARNING: Local artifacts enable but missing samples archive in ${ARTIFACTS_DIR}... Disabling..."
            export LOCAL_ARTIFACTS="no"
        fi
        if [ "${USE_LOCAL_RUNNER}" = "yes" ]; then
            if [ ! -f ${ARTIFACTS_DIR}/runner.tar.gz ]; then
                echo "WARNING: Local artifacts enable but missing runner archive in ${ARTIFACTS_DIR}... Disabling..."
                export LOCAL_ARTIFACTS="no"
            fi
        else 
            echo "NOTICE: using NPM version of edge-impulse-linux-runner... OK"
        fi
    fi
fi

extract_models() {
    if [ "${LOCAL_ARTIFACTS}" = "yes" ]; then
        cd ${TARGET_DIR}
        tar xzpf ${ARTIFACTS_DIR}/models.tar.gz
    else
        cd ${TARGET_DIR}
        tar xzpf ${INSTALL_DIR}/models.tar.gz
    fi
}

extract_samples() {
    if [ "${LOCAL_ARTIFACTS}" = "yes" ]; then
        cd ${TARGET_DIR}
        tar xzpf ${ARTIFACTS_DIR}/samples.tar.gz
    else
        cd ${TARGET_DIR}
        tar xzpf ${INSTALL_DIR}/samples.tar.gz
    fi
}

install_deps_debian() {
    # hack for Debian/Raspberry Pi... ugh...
    if [ ! -z "${IS_DEBIAN}" ]; then
       echo "Adjusting libjpeg for RPi/Debian..."
        LIBJPEG="libjpeg62-turbo-dev"
    fi
    apt update
    apt install -y gcc g++ make build-essential pkg-config libglib2.0-dev libexpat1-dev sox v4l-utils ${LIBJPEG} meson ninja-build
    apt install -y gstreamer1.0-tools gstreamer1.0-plugins-good gstreamer1.0-plugins-base gstreamer1.0-plugins-base-apps
    apt install -y gstreamer1.0-libav ffmpeg
}

install_deps_yum() {
    yum -y groupinstall 'Development Tools'
    yum -y install glib2-devel expat-devel libjpeg-turbo-devel
    yum -y install gstreamer1 gstreamer1-devel gstreamer1-plugins-base gstreamer1-plugins-base-tools gstreamer1-plugins-good
}

patch_drpai_dev_permissions() {
    LIST="/dev/rgnmm /dev/rgnmmbuf /dev/uvcs /dev/vspm_if /dev/drpai0 /dev/udmabuf0"
    for i in ${LIST}; do
        if [ -r $i ]; then
            echo "Adding GG service group access to $i..."
            chgrp ${TARGET_GROUP} $i
            chmod 660 $i
        else 
            echo "DRPAI Dev Patch: $i does not appear to be readable/exist... skipping..."
        fi
    done
}

install_deps_yocto() {
    # Patch up DRPAI /dev permissions
    patch_drpai_dev_permissions $*

    # Set permissions on GST launch
    if [ -f /usr/bin/gst-launch-1.0 ]; then
        chmod u+s /usr/bin/gst-launch-1.0
    fi
}

install_deps() {
    if [ ! -z "${YOCTO}" ]; then
        echo "On Yocto based platform. Installing OS deps..."
        install_deps_yocto $*
    elif [ ! -z "${APT}" ]; then
        echo "On debian-based platform. Installing OS deps..."
        install_deps_debian $*
    elif [ ! -z "${YUM}" ]; then
        echo "On YUM-based platform. Installing OS deps..."
        install_deps_yum $*
    else 
        echo "install_deps(): Platform: ${ALL} not supported. No deps installed"
        exit 1
    fi
}

install_nodejs() {
    NODE=`which node`
    if [ ! -z "${NODE}" ]; then
        NODE_VER=`node --version`
        if [ "${NODE_VER}" != "v${NODE_VERSION}" ]; then
            echo "Other version of NodeJS installed: ${NODE_VER}. Changing to v${NODE_VERSION}..." 
            if [ -f node-v${NODE_VERSION}-${OS}-${NODE_ARCHIVE_ARCH}.tar.xz ]; then
               rm -f node-v${NODE_VERSION}-${OS}-${NODE_ARCHIVE_ARCH}.tar.xz
            fi
            wget https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-${OS}-${NODE_ARCHIVE_ARCH}.tar.xz
            tar -xJf node-v${NODE_VERSION}-${OS}-${NODE_ARCHIVE_ARCH}.tar.xz -C /usr
            rm node-v${NODE_VERSION}-${OS}-${NODE_ARCHIVE_ARCH}.tar.xz
            if [ ! -d /usr/local ]; then
                mkdir /usr/local
            fi
            if [ ! -L /usr/local/bin ]; then
                if [ ! -d /usr/local/bin ]; then
                    mkdir /usr/local/bin
                fi
            fi
            if [ ! -L /usr/local/lib ]; then
                if [ ! -d /usr/local/lib ]; then
                    mkdir /usr/local/lib
                fi
            fi
            ln -sf /usr/node-v${NODE_VERSION}-${OS}-${NODE_ARCHIVE_ARCH}/bin/* /usr/local/bin
            ln -sf /usr/node-v${NODE_VERSION}-${OS}-${NODE_ARCHIVE_ARCH}/lib/* /usr/local/lib
            ln -sf /usr/node-v${NODE_VERSION}-${OS}-${NODE_ARCHIVE_ARCH}include /usr/local
            ln -sf /usr/node-v${NODE_VERSION}-${OS}-${NODE_ARCHIVE_ARCH}/share /usr/local
        else
            echo "NodeJS ${NODE} already installed. Skipping install... OK. Version: ${NODE_VER}"
            ln -sf /usr/node-v${NODE_VERSION}-${OS}-${NODE_ARCHIVE_ARCH}/bin/* /usr/local/bin
            ln -sf /usr/node-v${NODE_VERSION}-${OS}-${NODE_ARCHIVE_ARCH}/lib/* /usr/local/lib
            ln -sf /usr/node-v${NODE_VERSION}-${OS}-${NODE_ARCHIVE_ARCH}include /usr/local
            ln -sf /usr/node-v${NODE_VERSION}-${OS}-${NODE_ARCHIVE_ARCH}/share /usr/local
        fi
    else 
        echo "NodeJS not installed. Installing ${NODE_VERSION}..." 
        if [ -f node-v${NODE_VERSION}-${OS}-${NODE_ARCHIVE_ARCH}.tar.xz ]; then
            rm -f node-v${NODE_VERSION}-${OS}-${NODE_ARCHIVE_ARCH}.tar.xz
        fi
        wget https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-${OS}-${NODE_ARCHIVE_ARCH}.tar.xz
        tar -xJf node-v${NODE_VERSION}-${OS}-${NODE_ARCHIVE_ARCH}.tar.xz -C /usr
        rm node-v${NODE_VERSION}-${OS}-${NODE_ARCHIVE_ARCH}.tar.xz
        if [ ! -d /usr/local ]; then
            mkdir /usr/local
        fi
        if [ ! -L /usr/local/bin ]; then
            if [ ! -d /usr/local/bin ]; then
                mkdir /usr/local/bin
            fi
        fi
        if [ ! -L /usr/local/lib ]; then
            if [ ! -d /usr/local/lib ]; then
                mkdir /usr/local/lib
            fi
        fi
        ln -sf /usr/node-v${NODE_VERSION}-${OS}-${NODE_ARCHIVE_ARCH}/bin/* /usr/local/bin
        ln -sf /usr/node-v${NODE_VERSION}-${OS}-${NODE_ARCHIVE_ARCH}/lib/* /usr/local/lib
        ln -sf /usr/node-v${NODE_VERSION}-${OS}-${NODE_ARCHIVE_ARCH}include /usr/local
        ln -sf /usr/node-v${NODE_VERSION}-${OS}-${NODE_ARCHIVE_ARCH}/share /usr/local
    fi

    #
    # Set the prefix to /usr/local
    #
    npm config set prefix /usr/local
}

install_npm() {
    NPM=`which npm`
    if [ ! -z "${NPM}" ]; then
        NPM_VER=`npm --version`
        echo "NodeJS ${NPM} already installed. Skipping install... OK. Version: ${NPM_VER}"
    else 
        echo "NodeJS npm not installed. Installing npm..." 
        if [ ! -z "${APT}" ]; then
            echo "On debian-based platform. Installing npm..."
            apt install -y npm
        elif [ ! -z "${YUM}" ]; then
            echo "On YUM-based platform. Installing npm..."
            yum -y install npm
        elif [ ! -z "${YOCTO}" ]; then
            echo "On YOCTO-based platform. Unable to install npm manually (ERROR)"
            exit 2
        else 
            echo "Platform: ${ALL} not supported. npm NOT installed"
            exit 1
        fi
    fi
}

install_nvm() {
     # install nvm
    cd ${TARGET_DIR}
    wget https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh
    chmod 755 ./install.sh
    sudo -u ${TARGET_USER} bash ./install.sh
    CHECK=`cat ${TARGET_DIR}/.profile | grep v20.16`
    if [ -z "${CHECK}" ]; then
        cat ${INSTALL_DIR}/profile.txt >> ${TARGET_DIR}/.profile
    fi
    rm ./install.sh
}

install_prereqs() {
    # install any OS reqs...
    install_deps $*
}

fixup_perms() {
    cd ${TARGET_DIR}
    chown -R ${TARGET_USER}:${TARGET_GROUP} .
}

setup_npm_runner() {
    # install via NPM
    echo "Installing edge-impulse-linux via NPM..."
    npm install -g --unsafe-perm=true --upgrade edge-impulse-linux

    # dont need this installer if we used NPM...
    if [ -f ${TARGET_DIR}/ei_install.sh ]; then
        rm ${TARGET_DIR}/ei_install.sh
    fi

    # Fixup permissions
    fixup_perms $*
}

setup_local_runner() {
    # Install runner PR segment
    if [ "${LOCAL_ARTIFACTS}" = "yes" ]; then
        cd ${TARGET_DIR}
        tar xzpf ${ARTIFACTS_DIR}/runner.tar.gz
    else
        cd ${TARGET_DIR}
        tar xzpf ${INSTALL_DIR}/runner.tar.gz
    fi

    # Fixup permissions
    fixup_perms $*

    # Complete the installation
    if [ -f ${TARGET_DIR}/ei_install.sh ]; then
       cd ${TARGET_DIR}
       echo "Completing installation of the runner runtime..."
       chmod 755 ${TARGET_DIR}/ei_install.sh
       sudo -u ${TARGET_USER} ${TARGET_DIR}/ei_install.sh
       echo "Cleaning up runner installation..."
       cd ${TARGET_DIR}/edgeimpulse-PR-runner
       rm -rf ./studio ./api-bindings ./monitoring-agent ./serial-daemon
       rm ${TARGET_DIR}/ei_install.sh
       echo "Runner installation completed... Continuing..."
    else
       echo "Runtime completion script already run. Continuing..."
    fi
}

check_root_rw() {
    if [ ! -z "${YOCTO}" ]; then
        touch /usr/test
        status=$?
        if [ "${status}" != "0" ]; then
            echo "Yocto Root filesystem is RO. Changing to RW..."
            mount -o remount,rw ${ROOT_DIR}
            touch /usr/test
            status=$?
            if [ "${status}" = "0" ]; then
                echo "Root filesystem set to RW... Reboot when component install is complete"
                rm -f /tmp/usr/test
                export RESET_TO_RO="YES"
            else
                echo "Unable to enable rw the yocto root filesystem. Exiting..."
                exit 2
            fi
        else
            echo "Root filesystem already rw... OK"
            rm -f /usr/test
        fi
    else
        echo "Not on YOCTO - no need to check root rw status. OK"
    fi
}

set_root_ro() {
    if [ "${RESET_TO_RO}" = "YES" ]; then
       echo "Resetting root filesystem to RO..."
       mount -o remount,ro ${ROOT_DIR}
    fi
}

complete_init() {
    chown -R ${GREENGRASS_SERVICEUSER} ${HOME_DIR}
    chgrp -R ${GREENGRASS_SERVICEGROUP} ${HOME_DIR}
    cd ${TARGET_DIR}/data
    if [ ! -L ./testSample.mp4 ]; then
        sudo -u ${TARGET_USER} ./change_sample 1
    fi
    if [ ! -L ./currentModel.eim ]; then
        sudo -u ${TARGET_USER} ./change_model v1
    fi
    fixup_perms $*
    set_root_ro $*
}

setup_GG_service_user_perms() {
    echo "Setting up GG service account group permissions"
    PERM_LIST="${EI_GGC_USER_GROUPS}"
    for PERM in ${PERM_LIST}; do
        echo "Adding group: ${PERM} for ${GREENGRASS_SERVICEUSER}..."
        usermod -aG ${PERM} ${GREENGRASS_SERVICEUSER}
    done

    # hack for ugly ubuntu 22+ pipewire gunk...
    if [ ! -z "${IS_UBUNTU}" ]; then
        echo "Adding work around for pipewire changes in ubuntu 22+..."
        loginctl enable-linger ${GREENGRASS_SERVICEUSER}
    fi
}

check_service_user() {
    # User existance check
    id -u ${GREENGRASS_SERVICEUSER} 2>&1 1> /dev/null
    USER_CHECK=$?
    if [ "${USER_CHECK}" != "0" ]; then
        echo "Creating Greengrass Service User: ${GREENGRASS_SERVICEUSER} in group ${GREENGRASS_SERVICEGROUP}..."
        addgroup ${GREENGRASS_SERVICEGROUP}
        useradd ${GREENGRASS_SERVICEUSER} -d ${HOME_DIR} --shell /bin/bash --groups ${GREENGRASS_SERVICEGROUP}${GG_EXTRA_GROUPS}
        id -u ${GREENGRASS_SERVICEUSER} 2>&1 1> /dev/null
        USER_CHECK=$?
        if [ "${USER_CHECK}" != "0" ]; then
            echo "Greengrass Service User: ${GREENGRASS_SERVICEUSER} creation FAILED."
        else
            echo "Greengrass Service User: ${GREENGRASS_SERVICEUSER} creation SUCCESS."
        fi
    else
        echo "Greengrass Service User: ${GREENGRASS_SERVICEUSER} already exists... OK"
    fi

    # Home directory check
    if [ ! -d ${HOME_DIR} ]; then
        echo "Creating home directory for Greengrass Service User: ${GREENGRASS_SERVICEUSER} Home Directory: ${HOME_DIR}..."
        mkdir -p ${HOME_DIR}
        chown ${GREENGRASS_SERVICEUSER} ${HOME_DIR}
        chgrp ${GREENGRASS_SERVICEGROUP} ${HOME_DIR}
        chmod 775 ${HOME_DIR}
        chmod -R 777 ${HOME_DIR}/data
        echo "Greengrass Service User home directory: ${HOME_DIR} created."
    else
        echo "Greengrass Service User home directory: ${HOME_DIR} exists already (OK)."
    fi

    # Set group membership for the service user
    setup_GG_service_user_perms $*
}

main() {
    check_root_rw $*
    check_service_user $*
    extract_models $*
    extract_samples $*
    install_deps $*
    install_nodejs $*
    install_npm $*
    if [ "${USE_LOCAL_RUNNER}" = "yes" ]; then
        setup_local_runner $*
    else
        setup_npm_runner $*
    fi
    complete_init $*
}

main $*

#
# We are done!
#
echo "Runtime Installer install/setup is complete. Exiting with status 0"
exit 0