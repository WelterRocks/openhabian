#!/usr/bin/env bash

## Install code needed to compile ZRAM tools at installation time this
## can be called standalone from build.bash or during install from init_zram_mounts().
## The argument is the destination directory.
##
##    install_zram_code(String dir)
##
install_zram_code() {
  local overlayfsGit
  local zramGit

  overlayfsGit="https://github.com/kmxz/overlayfs-tools"
  zramGit="https://github.com/mstormi/openhabian-zram"

  echo -n "$(timestamp) [openHABian] Installing ZRAM code... "
  if ! cond_redirect mkdir -p "$1"; then echo "FAILED (create directory)"; return 1; fi

  if [[ -d "${1}/overlayfs-tools" ]]; then
    if ! cond_redirect update_git_repo "${1}/overlayfs-tools" "master"; then echo "FAILED (update overlayfs)"; return 1; fi
  else
    if ! cond_redirect git clone "$overlayfsGit" "$1"/overlayfs-tools; then echo "FAILED (clone overlayfs)"; return 1; fi
  fi

  if [[ -d "${1}/openhabian-zram" ]]; then
    if cond_redirect update_git_repo "${1}/openhabian-zram" "master"; then echo "OK"; else echo "FAILED (update zram)"; return 1; fi
  else
    if cond_redirect git clone "$zramGit" "$1"/openhabian-zram; then echo "OK"; else echo "FAILED (clone zram)"; return 1; fi
  fi
}

## Setup ZRAM for openHAB specific usage
## Valid arguments: "install" or "uninstall"
##
##    init_zram_mounts(String option)
##
init_zram_mounts() {
  if ! is_arm; then return 0; fi

  local introText
  local lowMemText
  local zramInstallLocation

  introText="You are about to activate the ZRAM feature.\\nBe aware you do this at your own risk of data loss.\\nPlease check out the \"ZRAM status\" thread at https://community.openhab.org/t/zram-status/80996 before proceeding."
  lowMemText="Your system has less than 1 GB of RAM. It is definitely NOT recommended to run ZRAM (AND openHAB) on your box. If you proceed now you will do so at your own risk!"
  zramInstallLocation="/opt/zram"

  if [[ $1 == "install" ]] && ! [[ -f /etc/ztab ]]; then
    if [[ -n $INTERACTIVE ]]; then
      # display warn disclaimer and point to ZRAM status thread on forum
      if ! (whiptail --title "Install ZRAM, Continue?" --yes-button "Continue" --no-button "Cancel" --yesno "$introText" 10 80); then echo "CANCELED"; return 0; fi
      # double check if there's enough RAM to run ZRAM
      if has_lowmem; then
        if ! (whiptail --title "WARNING, Continue?" --yes-button "REALLY Continue" --no-button "Cancel" --yesno --defaultno "$lowMemText" 10 80); then echo "CANCELED"; return 0; fi
      fi
    fi

    if ! dpkg -s 'make' 'libattr1-dev' &> /dev/null; then
      echo -n "$(timestamp) [openHABian] Installing ZRAM required packages (make, libattr1-dev)... "
      if cond_redirect apt-get install --yes make libattr1-dev; then echo "OK"; else echo "FAILED"; return 1; fi
    fi

    install_zram_code "$zramInstallLocation"

    echo -n "$(timestamp) [openHABian] Setting up OverlayFS... "
    if ! cond_redirect make --always-make --directory="$zramInstallLocation"/overlayfs-tools; then echo "FAILED (make overlayfs)"; return 1; fi
    if ! mkdir -p /usr/local/lib/zram-config/; then echo "FAILED (create directory)"; return 1; fi
    if cond_redirect install -m 755 "$zramInstallLocation"/overlayfs-tools/overlay /usr/local/lib/zram-config/overlay; then echo "OK"; else echo "FAILED (install overlayfs)"; return 1; fi

    echo -n "$(timestamp) [openHABian] Setting up ZRAM... "
    if ! install -m 755 "$zramInstallLocation"/openhabian-zram/zram-config /usr/local/bin/; then echo "FAILED (zram-config)"; return 1; fi
    if ! cond_redirect install -m 644 "${BASEDIR:-/opt/openhabian}"/includes/ztab /etc/ztab; then echo "FAILED (ztab)"; return 1; fi
    if ! mkdir -p /usr/local/share/zram-config/log; then echo "FAILED (create directory)"; return 1; fi
    if ! cond_redirect install -m 644 "$zramInstallLocation"/openhabian-zram/ro-root.sh /usr/local/share/zram-config/ro-root.sh; then echo "FAILED (ro-root)"; return 1; fi
    if cond_redirect install -m 644 "$zramInstallLocation"/openhabian-zram/zram-config.logrotate /etc/logrotate.d/zram-config; then echo "OK"; else echo "FAILED (logrotate)"; return 1; fi

    if [[ -f /etc/systemd/system/find3server.service ]]; then
      echo -n "$(timestamp) [openHABian] Adding FIND3 to ZRAM... "
      if ! cond_redirect sed -i '/^.*persistence.bind$/a dir	lz4	100M		350M		/opt/find3/server/main		/find3.bind' /etc/ztab; then echo "FAILED (sed)"; return 1; fi
    fi
    if ! dpkg -s 'openhab2' &> /dev/null; then
      sed -i 's|dir	lz4	150M		500M		/var/lib/openhab2/persistence	/persistence.bind||g' /etc/ztab
    fi

    echo -n "$(timestamp) [openHABian] Setting up ZRAM service... "
    if ! cond_redirect install -m 644 "$zramInstallLocation"/openhabian-zram/zram-config.service /etc/systemd/system/zram-config.service; then echo "FAILED (copy service)"; return 1; fi
    if ! cond_redirect systemctl enable zram-config.service; then echo "FAILED (enable service)"; return 1; fi
    if cond_redirect systemctl restart zram-config.service; then echo "OK"; else echo "FAILED (restart service)"; return 1; fi
  elif [[ $1 == "uninstall" ]]; then
    echo -n "$(timestamp) [openHABian] Removing ZRAM service... "
    if ! cond_redirect systemctl stop zram-config.service; then echo "FAILED (stop service)"; return 1; fi
    if ! cond_redirect systemctl disable zram-config.service; then echo "FAILED (disable service)"; return 1; fi
    if rm -f /etc/systemd/system/zram-config.service; then echo "OK"; else echo "FAILED (remove service)"; fi

    echo -n "$(timestamp) [openHABian] Removing ZRAM... "
    if ! rm -f /usr/local/bin/zram-config; then echo "FAILED (zram-config)"; return 1; fi
    if ! rm -f /etc/ztab; then echo "FAILED (ztab)"; return 1; fi
    if ! rm -rf /usr/local/share/zram-config; then echo "FAILED (zram-config share)"; return 1; fi
	  if ! rm -rf /usr/local/lib/zram-config; then echo "FAILED (zram-config lib)"; return 1; fi
    if rm -f /etc/logrotate.d/zram-config; then echo "OK"; else echo "FAILED (logrotate)"; return 1; fi
  else
    echo "$(timestamp) [openHABian] Refusing to install ZRAM as it is already installed, please uninstall and then try again... EXITING"
    return 1
  fi
}

zram_setup() {
  if is_arm; then
    if ! has_lowmem && ! is_pione && ! is_cmone && ! is_pizero && ! is_pizerow; then
      if dpkg -s 'openhab2' &> /dev/null; then
        cond_redirect systemctl stop openhab2.service
      fi
      echo -n "$(timestamp) [openHABian] Installing ZRAM... "
      if cond_redirect init_zram_mounts "install"; then echo "OK"; else echo "FAILED"; return 1; fi
      if dpkg -s 'openhab2' &> /dev/null; then
        cond_redirect systemctl stop openhab2.service
      fi
    else
      echo "$(timestamp) [openHABian] Skipping ZRAM install on ARM hardware without enough memory."
    fi
  else
    echo "$(timestamp) [openHABian] Skipping ZRAM install on non-ARM hardware."
  fi
}
