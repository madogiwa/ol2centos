#!/bin/sh

# Script to switch Oracle Linux (or other similar distribution) to
# CentOS yum repository.

#
# This script is derived from https://linux.oracle.com/switch/centos2ol.sh
# ( https://linux.oracle.com/switch/centos/ )
#
# modified by Hidenori Sugiyama <madogiwa@gmail.com>
#

# 
# (original copyright notice)
#
# Author: Tim Hill <tim.hill@oracle.com>
#
# Copyright 2012 Oracle, Inc.
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

set -e
unset CDPATH

yum_url=http://mirror.centos.org/centos/
bad_packages="centos-release-cr libreport-plugin-rhtsupport yum-rhn-plugin"
removed_packages=""

usage() {
    echo "Usage: ${0##*/} [OPTIONS]"
    echo
    echo "OPTIONS"
    echo "-h"
    echo "        Display this help and exit"
    exit 1
} >&2

have_program() {
    hash "$1" >/dev/null 2>&1
}

dep_check() {
    if ! have_program "$1"; then
        exit_message "'${1}' command not found. Please install or add it to your PATH and try again."
    fi
}

exit_message() {
    echo "$1"
    exit 1
} >&2

restore_repos() {
    yum remove -y $new_releases
    find . -name 'repo.*' | while read repo; do
        destination=`head -n1 "$repo"`
        if [ "$destination" ]; then
            tail -n+2 "$repo" > "$destination"
        fi
    done

    while read repo; do
       rm "${reposdir}/`basename ${repo}`"
    done < ${tempdir}/new_repo_files

    if [ "$removed_packages" ]; then
        yum install -y $removed_packages
    fi
    exit_message "Could not install CentOS packages.
Your repositories have been restored to your previous configuration."
}

## Start of script

while getopts "h" option; do
    case "$option" in
        h) usage ;;
        *) usage ;;
    esac
done

if [ `id -u` -ne 0 ]; then
    echo "You must run this script as root."
    if [ -x /usr/bin/sudo ]; then
        echo "Try running 'sudo ${0}'."
    fi
    exit 1
fi >&2

echo "Checking for required packages..."
for pkg in rpm yum python curl; do
    dep_check "$pkg"
done

echo "Checking your distribution..."
if ! old_release=`rpm -q --whatprovides redhat-release`; then
    exit_message "You appear to be running an unsupported distribution."
fi

if [ `echo "$old_release" | wc -l` -ne 1 ]; then
    exit_message "Could not determine your distribution because multiple
packages are providing redhat-release:
$old_release
"
fi

case "$old_release" in
    redhat-release*) ;;
    sl-release*) ;;
    oraclelinux-release*|enterprise-release*) ;;
    centos-release*)
        exit_message "You appear to be already running CentOS."
        ;;
    *) exit_message "You appear to be running an unsupported distribution." ;;
esac

rhel_version=`rpm -q "$old_release" --qf "%{version}"`
rhel_arch=`rpm -q "$old_release" --qf "%{arch}"`
base_packages='basesystem initscripts'
case "$rhel_version" in
    6*)
        release_pkg="6.3/os/x86_64/Packages/centos-release-6-3.el6.centos.9.x86_64.rpm"
        repo_file="public-yum-el6.repo"
        repo_name=centos6
        new_releases=centos-release
        base_packages="$base_packages centos-release-notes plymouth grub grubby"
        ;;
    5*)
        release_pkg="5.8/os/x86_64/CentOS/centos-release-5-8.el5.centos.x86_64.rpm"
        repo_file="public-yum-el5.repo"
        repo_name=centos5
        new_releases=centos-release
        base_packages="$base_packages centos-release-notes"
        ;;
    *) exit_message "You appear to be running an unsupported distribution." ;;
esac

echo "Looking for yumdownloader..."
if ! have_program yumdownloader; then
    yum -y install yum-utils || true
    dep_check yumdownloader
fi

echo "Finding your repository directory..."
tempdir=`mktemp -d`
cd "$tempdir"

echo "Downloading and Extract CentOS yum repository file..."
if ! curl "${yum_url}/${release_pkg}" | rpm2cpio | cpio -id "*.repo"; then
    exit_message "Could not download $repo_file from $yum_url.
Are you behind a proxy? If so, make sure the 'http_proxy' environment
variable is set with your proxy address."
fi

python > reposdir_list <<EOF
import yum

for dir in yum.YumBase().doConfigSetup(init_plugins=False).reposdir:
    print dir
EOF

while read reposdir; do
    if [ -d "$reposdir" ]; then
        cd "$reposdir"
        break;
    fi
done < reposdir_list

if [ "$PWD" = "$tempdir" ]; then
    exit_message "Could not locate your repository directory.
Tried the following:
`cat reposdir_list`
"
fi

echo "Move CentOS yum repository file into repository direcotry..."
ls ${tempdir}/etc/yum.repos.d/*.repo > ${tempdir}/new_repo_files
while read repo; do
    if ! cp -a "$repo" "${PWD}/"; then
        exit_message "Could not move yum repository file into repository directory."
    fi
done < ${tempdir}/new_repo_files

trap restore_repos ERR

# Bad packages
echo "Removing unsupported packages..."
for bad_package in $bad_packages; do
    if rpm -q $bad_package >/dev/null 2>&1; then
        removed_packages="$removed_packages $bad_package"
        yum remove $bad_package
    fi
done

cd "$tempdir"

echo "Backing up and removing old repository files..."
if [ -f "${reposdir}/${repo_file}" ]; then
    echo "${reposdir}/${repo_file}" > repo_files
else
    rpm -ql "$old_release" | grep '\.repo$' > repo_files
fi

while read repo; do
    if [ -f "$repo" ]; then
        cat - "$repo" > "$repo".disabled <<EOF
# This is a yum repository file that was disabled by
# ${0##*/}, a script to convert Oracle Linux to CentOS.

EOF
        tmpfile=`mktemp repo.XXXXX`
        echo "$repo" | cat - "$repo" > "$tmpfile"
        rm "$repo"
    fi
done < repo_files

echo "Downloading CentOS release package..."
if ! yumdownloader $new_releases; then
    {
        echo "Could not download the following packages from $yum_url:"
        echo "$new_releases"
        echo
        echo "Are you behind a proxy? If so, make sure the 'http_proxy' environment"
        echo "variable is set with your proxy address."
    } >&2
    restore_repos
fi

echo "Switching old release package with CentOS..."
rpm -i --force *.rpm
rpm -e --nodeps "$old_release"

# At this point, the switch is completed.
trap - ERR

echo "Installing base packages for CentOS..."
if ! yum -y install $base_packages; then
    exit_message "Could not install base packages.
Run 'yum upgrade' to manually install them."
fi
if [ -x /usr/libexec/plymouth/plymouth-update-initrd ]; then
    echo "Updating initrd..."
    /usr/libexec/plymouth/plymouth-update-initrd
fi

echo "Installation successful!"
echo "Run 'yum upgrade' or 'yum downgrade' to synchronize your installed packages"
echo "with the CentOS repository."
