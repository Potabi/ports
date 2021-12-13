#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause-FreeBSD
#
# Copyright (c) 2010 iXsystems, Inc.  All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#
# $FreeBSD$

# Functions which perform the extraction / installation of system to disk

. ${BACKEND}/functions-mountoptical.sh

# Do the package base installation
start_extract_pkg()
{
  # Set the default ABI
  ABI="FreeBSD:`uname -r | cut -d '.' -f 1`:`uname -m`"
  export ABI
  export IGNORE_OSVERSION="YES"

  # Make sure the pkg db dir is ready to install
  rc_nohalt "mkdir -p ${FSMNT}/var/db/pkg"
  export PKG_DBDIR="${FSMNT}/var/db/pkg"

  # Update the local pkg DB
  rc_nohalt "pkg update"

  # Are we using legacy pkg-base system or new?
  pkg rquery '%v' os/userland >/dev/null 2>/dev/null
  if [ $? -eq 0 ] ; then
	  install_ports_base
  else
	  install_legacy_base
  fi

  # Workaround to issue in FreeBSD pkg base
  rc_nohalt "chroot ${FSMNT} chown root:operator /sbin/shutdown"
  rc_nohalt "chroot ${FSMNT} chmod 4554 /sbin/shutdown"
}

install_ports_base()
{
  BFLAVOR="generic"
  get_value_from_cfg baseFlavor
  if [ -n "$VAL" ] ; then
    BFLAVOR="${VAL}"
  fi

  # Install the specified OS flavor
  for inspkg in os-${BFLAVOR}-userland os-${BFLAVOR}-kernel ports-mgmt/pkg
  do
    # Skip any {debug|development} packages
    echo_log "pkg -r ${FSMNT} install -yf $inspkg"
    env ASSUME_ALWAYS_YES=YES pkg -r ${FSMNT} install -yf $inspkg
    if [ $? -ne 0 ] ; then
      exit_err "Failed installing $inspkg!"
    fi
  done

  unset PKG_DBDIR
  echo_log "chroot ${FSMNT} pkg set -y -A 00 os-${BFLAVOR}-userland"
  chroot ${FSMNT} pkg set -y -A 00 os-${BFLAVOR}-userland
  chroot ${FSMNT} pkg set -y -A 00 os-${BFLAVOR}-kernel
  chroot ${FSMNT} pkg set -y -A 00 ports-mgmt/pkg
}

install_legacy_base()
{
  # Figure out the base package name, if its FreeBSD or $OTHER
  BASENAME=$(pkg rquery '%o %n-%v' | grep ^base | grep -e '-runtime-' | head -n 1 | awk '{print $2}' | cut -d '-' -f 1)

  # Do the package installation
  for inspkg in `pkg rquery '%o %n' | grep "^base" | awk '{print $2}' | tr -s '\n' ' '`
  do
    # Skip any {debug|development} packages
    echo "$inspkg" | grep -q -e '-debug-' -e '-profile-'
    if [ $? -eq 0 ] ; then continue ; fi
    echo_log "pkg -r ${FSMNT} install -yf $inspkg"
    env ASSUME_ALWAYS_YES=YES pkg -r ${FSMNT} install -yf $inspkg
    if [ $? -ne 0 ] ; then
      exit_err "Failed installing $inspkg!"
    fi
  done

  # Don't allow any of the FreeBSD packages to be auto-removed
  unset PKG_DBDIR
  echo_log "chroot ${FSMNT} pkg set -y -A 00 -g $BASENAME-*"
  chroot ${FSMNT} pkg set -y -A 00 -g $BASENAME-\*
}

# Performs the extraction of data to disk from FreeBSD dist files
start_extract_dist()
{
  if [ -z "$1" ] ; then exit_err "Called dist extraction with no directory set!"; fi
  if [ -z "$INSFILE" ]; then exit_err "Called extraction with no install file set!"; fi
  local DDIR="$1"


  # Check if we are doing an upgrade, and if so use our exclude list
  if [ "${INSTALLMODE}" = "upgrade" ]; then
   TAROPTS="-X ${PROGDIR}/conf/exclude-from-upgrade"
  else
   TAROPTS=""
  fi

  get_value_from_cfg installQuiet
  if [ -z "$VAL" -o "$VAL" = "no" ] ; then
     TAROPTS="${TAROPTS} -v"
  fi

  # Loop though and extract dist files
  for di in $INSFILE
  do
      # Check the MANIFEST see if we have an archive size / count
      if [ -e "${DDIR}/MANIFEST" ]; then
         count=`grep "^${di}.txz" ${DDIR}/MANIFEST | awk '{print $3}'`
	 if [ ! -z "$count" ] ; then
            echo "INSTALLCOUNT: $count"
	 fi
      fi
      echo_log "pc-sysinstall: Starting Extraction (${di})"
      tar -xp -C ${FSMNT} ${TAROPTS} -f ${DDIR}/${di}.txz 2>&1 | tee -a ${FSMNT}/.tar-extract.log
      if [ $? -ne 0 ]; then
        cd /
        echo "TAR failure occurred:" >>${LOGOUT}
        cat ${FSMNT}/.tar-extract.log | grep "tar:" >>${LOGOUT}
        exit_err "ERROR: Failed extracting the dist file: $di"
      fi
  done

  # Check if this was a FTP download and clean it up now
  if [ "${INSTALLMEDIUM}" = "ftp" ]; then
    echo_log "Cleaning up downloaded archives"
    rm -rf ${DDIR}
  fi

  echo_log "pc-sysinstall: Extraction Finished"
}

# Performs the extraction of data to disk from a uzip or tar archive
start_extract_uzip_tar()
{
  if [ -z "$INSFILE" ]; then
    exit_err "ERROR: Called extraction with no install file set!"
  fi

  # Check if we have a .count file, and echo it out for a front-end to use in progress bars
  if [ -e "${INSFILE}.count" ]; then
    echo "INSTALLCOUNT: `cat ${INSFILE}.count`"
  fi

  # Check if we are doing an upgrade, and if so use our exclude list
  if [ "${INSTALLMODE}" = "upgrade" ]; then
   TAROPTS="-X ${PROGDIR}/conf/exclude-from-upgrade"
  else
   TAROPTS=""
  fi

  get_value_from_cfg installQuiet
  if [ -z "$VAL" -o "$VAL" = "no" ] ; then
    TAROPTS="${TAROPTS} -v"
  fi

  echo_log "pc-sysinstall: Starting Extraction"

  case ${PACKAGETYPE} in
    uzip)
      if ! kldstat -v | grep -q "geom_uzip" ; then
        exit_err "Kernel module geom_uzip not loaded"
      fi

      # Start by mounting the uzip image
      MDDEVICE=`mdconfig -a -t vnode -o readonly -f ${INSFILE}`
      mkdir -p ${FSMNT}.uzip
      mount -r /dev/${MDDEVICE}.uzip ${FSMNT}.uzip
      if [ $? -ne 0 ]
      then
        exit_err "ERROR: Failed mounting the ${INSFILE}"
      fi
      cd ${FSMNT}.uzip

      # Copy over all the files now!
      tar cvf - . 2>/dev/null | tar -xp -C ${FSMNT} ${TAROPTS} -f - 2>&1 | tee -a ${FSMNT}/.tar-extract.log
      if [ $? -ne 0 ]
      then
        cd /
        echo "TAR failure occurred:" >>${LOGOUT}
        cat ${FSMNT}/.tar-extract.log | grep "tar:" >>${LOGOUT}
        umount ${FSMNT}.uzip
        mdconfig -d -u ${MDDEVICE}
        exit_err "ERROR: Failed extracting the tar image"
      fi

      # All finished, now lets umount and cleanup
      cd /
      umount ${FSMNT}.uzip
      mdconfig -d -u ${MDDEVICE}
      ;;
    tar)
      tar -xpv -C ${FSMNT} -f ${INSFILE} ${TAROPTS} >&1 2>&1
      if [ $? -ne 0 ]; then
        exit_err "ERROR: Failed extracting the tar image"
      fi
      ;;
    livecd)
      if ! kldstat -v | grep -q "geom_uzip" ; then
        exit_err "Kernel module geom_uzip not loaded"
      fi

      # Start by mounting the uzip image
      MDDEVICE=`mdconfig -a -t vnode -o readonly -f ${USR_UZIP_FILE}`
      mkdir -p /tmp/.uzip
      mount -o ro /dev/${MDDEVICE}.uzip /tmp/.uzip
      if [ $? -ne 0 ]
      then
        exit_err "ERROR: Failed mounting the ${INSFILE}"
      fi

      cd /tmp/.uzip
      mkdir ${FSMNT}/usr
      # Copy over all the files now!
      tar cvf - . 2>/dev/null | tar -xp -C ${FSMNT}/usr -v -f - 2>&1 | tee -a ${FSMNT}/.tar-extract.log
      if [ $? -ne 0 ]
      then
        cd /
        echo "TAR failure occurred:" >> ${LOGOUT}
        cat ${FSMNT}/.tar-extract.log | grep "tar:" >> ${LOGOUT}
        umount /tmp/.uzip
        mdconfig -d -u ${MDDEVICE}
        exit_err "ERROR: Failed extracting the tar image"
      fi
      tar zxf /cdrom/data/mfs.tgz -C ${FSMNT}/
      # rc.conf from GhostBSD
      cp /etc/rc.conf $FSMNT/etc/rc.conf
      # All finished, now lets umount and cleanup
      cd /
      umount /tmp/.uzip
      mdconfig -d -u ${MDDEVICE}
      ;;
  esac

  # Check if this was a FTP download and clean it up now
  if [ "${INSTALLMEDIUM}" = "ftp" ]
  then
    echo_log "Cleaning up downloaded archive"
    rm ${INSFILE}
    rm ${INSFILE}.count >/dev/null 2>/dev/null
    rm ${INSFILE}.md5 >/dev/null 2>/dev/null
  fi

  echo_log "pc-sysinstall: Extraction Finished"

};

# Performs the extraction of data to disk from a directory with split files
start_extract_split()
{
  if [ -z "${INSDIR}" ]
  then
    exit_err "ERROR: Called extraction with no install directory set!"
  fi

  echo_log "pc-sysinstall: Starting Extraction"

  # Used by install.sh
  DESTDIR="${FSMNT}"
  export DESTDIR

  HERE=`pwd`
  DIRS=`ls -d ${INSDIR}/*|grep -Ev '(uzip|kernels|src)'`
  for dir in ${DIRS}
  do
    cd "${dir}"
    if [ -f "install.sh" ]
    then
      echo_log "Extracting" `basename ${dir}`
      echo "y" | sh install.sh >/dev/null
      if [ $? -ne 0 ]
      then
        exit_err "ERROR: Failed extracting ${dir}"
      fi
    else
      exit_err "ERROR: ${dir}/install.sh does not exist"
    fi
  done
  cd "${HERE}"

  KERNELS=`ls -d ${INSDIR}/*|grep kernels`
  cd "${KERNELS}"
  if [ -f "install.sh" ]
  then
    echo_log "Extracting" `basename ${KERNELS}`
    echo "y" | sh install.sh generic >/dev/null
    if [ $? -ne 0 ]
    then
      exit_err "ERROR: Failed extracting ${KERNELS}"
    fi
    rm -rf "${FSMNT}/boot/kernel"
    mv "${FSMNT}/boot/GENERIC" "${FSMNT}/boot/kernel"
  else
    exit_err "ERROR: ${KERNELS}/install.sh does not exist"
  fi
  cd "${HERE}"

  SOURCE=`ls -d ${INSDIR}/*|grep src`
  cd "${SOURCE}"
  if [ -f "install.sh" ]
  then
    echo_log "Extracting" `basename ${SOURCE}`
    echo "y" | sh install.sh all >/dev/null
    if [ $? -ne 0 ]
    then
      exit_err "ERROR: Failed extracting ${SOURCE}"
    fi
  else
    exit_err "ERROR: ${SOURCE}/install.sh does not exist"
  fi
  cd "${HERE}"

  echo_log "pc-sysinstall: Extraction Finished"
};

# Function which will attempt to fetch the dist file(s) before we start
fetch_dist_file()
{
  get_value_from_cfg ftpPath
  if [ -z "$VAL" ]
  then
    exit_err "ERROR: Install medium was set to ftp, but no ftpPath was provided!"
  fi

  FTPPATH="${VAL}"
  FBSDVER=`uname -r | cut -d "-" -f 1-2`
  ARCH=`uname -m`
  FTPPATH=`echo $FTPPATH | sed "s|%VERSION%|${FBSDVER}|g"`
  FTPPATH=`echo $FTPPATH | sed "s|%ARCH%|${ARCH}|g"`

  # Check if we have a /usr partition to save the download
  if [ -d "${FSMNT}/usr" ]
  then
    DLDIR="${FSMNT}/usr/.fetch.$$"
  else
    DLDIR="${FSMNT}/.fetch.$$"
  fi
  mkdir -p ${DLDIR}

  # Do the fetch of the dist archive(s) now
  for di in $INSFILE
  do
    fetch_file "${FTPPATH}/${di}.txz" "${DLDIR}/${di}.txz" "1"
  done

  # Check to see if there is a MANIFEST file for this install
  fetch_file "${FTPPATH}/MANIFEST" "${DLDIR}/MANIFEST" "0"

  export DLDIR
};

# Function which will attempt to fetch the install file before we start
# the install
fetch_install_file()
{
  get_value_from_cfg ftpPath
  if [ -z "$VAL" ]
  then
    exit_err "ERROR: Install medium was set to ftp, but no ftpPath was provided!"
  fi

  FTPPATH="${VAL}"

  # Check if we have a /usr partition to save the download
  if [ -d "${FSMNT}/usr" ]
  then
    OUTFILE="${FSMNT}/usr/.fetch-${INSFILE}"
  else
    OUTFILE="${FSMNT}/.fetch-${INSFILE}"
  fi

  # Do the fetch of the archive now
  fetch_file "${FTPPATH}/${INSFILE}" "${OUTFILE}" "1"

  # Check to see if there is a .count file for this install
  fetch_file "${FTPPATH}/${INSFILE}.count" "${OUTFILE}.count" "0"

  # Check to see if there is a .md5 file for this install
  fetch_file "${FTPPATH}/${INSFILE}.md5" "${OUTFILE}.md5" "0"

  # Done fetching, now reset the INSFILE to our downloaded archived
  export INSFILE="${OUTFILE}"

};

# Function which will download freebsd install files
fetch_split_files()
{
  get_ftpHost
  if [ -z "$VAL" ]
  then
    exit_err "ERROR: Install medium was set to ftp, but no ftpHost was provided!"
  fi
  FTPHOST="${VAL}"

  get_ftpDir
  if [ -z "$VAL" ]
  then
    exit_err "ERROR: Install medium was set to ftp, but no ftpDir was provided!"
  fi
  FTPDIR="${VAL}"

  # Check if we have a /usr partition to save the download
  if [ -d "${FSMNT}/usr" ]
  then
    OUTFILE="${FSMNT}/usr/.fetch-${INSFILE}"
  else
    OUTFILE="${FSMNT}/.fetch-${INSFILE}"
  fi

  DIRS="base catpages dict doc games info manpages proflibs kernels src"
  if [ "${FBSD_ARCH}" = "amd64" ]
  then
    DIRS="${DIRS} lib32"
  fi

  for d in ${DIRS}
  do
    mkdir -p "${OUTFILE}/${d}"
  done


  NETRC="${OUTFILE}/.netrc"
  cat <<EOF >"${NETRC}"
machine ${FTPHOST}
login anonymous
password anonymous
macdef INSTALL
bin
prompt
EOF

  for d in ${DIRS}
  do
    cat <<EOF >>"${NETRC}"
cd ${FTPDIR}/${d}
lcd ${OUTFILE}/${d}
mreget *
EOF
  done

  cat <<EOF >>"${NETRC}"
bye


EOF

  # Fetch the files via ftp
  echo "$ INSTALL" | ftp -N "${NETRC}" "${FTPHOST}"

  # Done fetching, now reset the INSFILE to our downloaded archived
  export INSFILE="${OUTFILE}"
}

# Function which does the rsync download from the server specified in cfg
start_rsync_copy()
{
  # Load our rsync config values
  get_value_from_cfg rsyncPath
  if [ -z "${VAL}" ]; then
    exit_err "ERROR: rsyncPath is unset! Please check your config and try again."
  fi
  export RSYNCPATH="${VAL}"

  get_value_from_cfg rsyncHost
  if [  -z "${VAL}" ]; then
    exit_err "ERROR: rsyncHost is unset! Please check your config and try again."
  fi
  export RSYNCHOST="${VAL}"

  get_value_from_cfg rsyncUser
  if [ -z "${VAL}" ]; then
    exit_err "ERROR: rsyncUser is unset! Please check your config and try again."
  fi
  export RSYNCUSER="${VAL}"

  get_value_from_cfg rsyncPort
  if [ -z "${VAL}" ]; then
    exit_err "ERROR: rsyncPort is unset! Please check your config and try again."
  fi
  export RSYNCPORT="${VAL}"

  COUNT=1
  while
  z=1
  do
    if [ ${COUNT} -gt ${RSYNCTRIES} ]
    then
     exit_err "ERROR: Failed rsync command!"
     break
    fi

    rsync -avvzHsR \
    --rsync-path="rsync --fake-super" \
    -e "ssh -p ${RSYNCPORT}" \
    ${RSYNCUSER}@${RSYNCHOST}:${RSYNCPATH}/./ ${FSMNT}
    if [ $? -ne 0 ]
    then
      echo "Rsync failed! Tries: ${COUNT}"
    else
      break
    fi

    COUNT=$((COUNT+1))
  done

};

start_image_install()
{
  if [ -z "${IMAGE_FILE}" ]
  then
    exit_err "ERROR: installMedium set to image but no image file specified!"
  fi

  # We are ready to start mounting, lets read the config and do it
  while read line
  do
    echo $line | grep -q "^disk0=" 2>/dev/null
    if [ $? -eq 0 ]
    then
      # Found a disk= entry, lets get the disk we are working on
      get_value_from_string "${line}"
      strip_white_space "$VAL"
      DISK="$VAL"
    fi

    echo $line | grep -q "^commitDiskPart" 2>/dev/null
    if [ $? -eq 0 ]
    then
      # Found our flag to commit this disk setup / lets do sanity check and do it
      if [ -n "${DISK}" ]
      then

        # Write the image
        write_image "${IMAGE_FILE}" "${DISK}"

        # Increment our disk counter to look for next disk and unset
        unset DISK
        break

      else
        exit_err "ERROR: commitDiskPart was called without procceding disk<num>= and partition= entries!!!"
      fi
    fi

  done <${CFGF}
};

# Entrance function, which starts the installation process
init_extraction()
{
  # Figure out what file we are using to install from via the config
  get_value_from_cfg installFile

  if [ -n "${VAL}" ]
  then
    export INSFILE="${VAL}"
  else
    # If no installFile specified, try our defaults
    if [ "$INSTALLTYPE" = "FreeBSD" ]
    then
      case $PACKAGETYPE in
        uzip) INSFILE="${FBSD_UZIP_FILE}" ;;
        tar) INSFILE="${FBSD_TAR_FILE}" ;;
        dist)
          get_value_from_cfg_with_spaces distFiles
          if [ -z "$VAL" ] ; then
            exit_err "No dist files specified!"
          fi
          INSFILE="${VAL}"
          ;;
        split)
          INSDIR="${FBSD_BRANCH_DIR}"
          # This is to trick opt_mount into not failing
          INSFILE="${INSDIR}"
          ;;
      esac
    else
      case $PACKAGETYPE in
        uzip) INSFILE="${UZIP_FILE}" ;;
        tar) INSFILE="${TAR_FILE}" ;;
        livecd) INSFILE="${USR_UZIP_FILE}" ;;
        dist)
          get_value_from_cfg_with_spaces distFiles
          if [ -z "$VAL" ] ; then
            exit_err "No dist files specified!"
          fi
          INSFILE="${VAL}"
          ;;
      esac
    fi
    export INSFILE
  fi

  # Lets start by figuring out what medium we are using
  case ${INSTALLMEDIUM} in
    dvd|usb)
      # Lets start by mounting the disk
      opt_mount
      if [ -n "${INSDIR}" ]
      then
        INSDIR="${CDMNT}/${INSDIR}" ; export INSDIR
        start_extract_split

      else
        if [ "$PACKAGETYPE" = "dist" ] ; then
          start_extract_dist "${CDMNT}/usr/freebsd-dist"
        else
          INSFILE="${CDMNT}/${INSFILE}" ; export INSFILE
          start_extract_uzip_tar
        fi
      fi
      ;;

    ftp)
      case $PACKAGETYPE in
    split)
           fetch_split_files

           INSDIR="${INSFILE}" ; export INSDIR
           start_extract_split
     ;;
    dist)
           fetch_dist_file
           start_extract_dist "$DLDIR"
     ;;
       *)
           fetch_install_file
           start_extract_uzip_tar
     ;;
       esac
      ;;

    sftp) ;;

    rsync) start_rsync_copy ;;
    image) start_image_install ;;
    local)
      get_value_from_cfg localPath
      if [ -z "$VAL" ]
      then
        exit_err "Install medium was set to local, but no localPath was provided!"
      fi
      LOCALPATH=$VAL
      if [ "$PACKAGETYPE" = "dist" ] ; then
        INSFILE="${INSFILE}" ; export INSFILE
        start_extract_dist "$LOCALPATH"
      elif [ "$PACKAGETYPE" = "pkg" ] ; then
        start_extract_pkg "$LOCALPATH"
      else
        INSFILE="${LOCALPATH}/${INSFILE}" ; export INSFILE
        start_extract_uzip_tar
      fi
      ;;
    livecd)
      start_extract_uzip_tar
      ;;
    livezfs)
      cpdup -i0 -s0 -vvv -X zpool.cache / ${FSMNT}
      ;;
    *) exit_err "ERROR: Unknown install medium" ;;
  esac

};
