#!/bin/bash

# Creates a debian rootfs image which can be flashed on Edison
# Requires that the host system has the following packages: debootstrap debian-archive-keyring python

top_repo_dir=$(dirname $(dirname $(dirname $(readlink -f $0))))
build_dir=$top_repo_dir/build

function usage()
{
  echo "Creates a debian image starting from a sucessful yocto build"
  echo "This needs to be run as root. It was tested successfully on Ubuntu 14.04+"
  echo "On older versions, please install manually debootstrap >= 1.0.59"
  echo "Options:"
  echo -e "\t-h --help\t\tdisplay this help and exit"
  echo -e "\t--skip_debootstrap\tavoids running deboostrap from scratch to save time."
  echo -e "\t--build_dir\tspecify the yocto build directory. Defaults to ../../build"
  echo ""
}

skip_debootstrap="false"
add_graphical_packages="false"

while [ "$1" != "" ]; do
  PARAM=`echo $1 | awk -F= '{print $1}'`
  VALUE=`echo $1 | awk -F= '{print $2}'`
  case $PARAM in
    -h | --help)
      usage
      exit
      ;;
    --skip_debootstrap)
      echo "Skip running deboostrap from scratch to save time in case of re-run"
      skip_debootstrap="true"
      ;;
    --add_graphical_packages)
      echo "Add graphical packages in the rootfs. Requires a larger rootfs"
      add_graphical_packages="true"
      ;;
    --build_dir)
      build_dir=$(readlink -f "$VALUE")
      ;;
    *)
    echo "ERROR: unknown parameter \"$PARAM\""
    usage
    exit 1
    ;;
  esac
  shift
done

cd $build_dir

# Check the version of host debootstrap
debootstrap_version=`debootstrap --version | cut -d' ' -f2`
echo """import sys
from distutils.version import LooseVersion
if LooseVersion('1.0.59') <= LooseVersion(sys.argv[1]):
    exit(0)
else:
    exit(1)""" > tmp.py
python tmp.py $debootstrap_version
ok="$?"
rm tmp.py
if [ ! $ok -eq 0 ]; then
  echo "Bootstrap version too old: needs >= 1.0.59, found $debootstrap_version"
  exit -1
fi

# Check that .deb packages were properly created
if ! grep -q "package_deb" ./conf/local.conf; then
  echo "No .deb packages were generated by bitbake (only .ipk). Please re-run setup.sh using the --deb_packages option."
  exit -1
fi

# Re-run post build to avoid losing hairs
rm -rf ./toFlash
$top_repo_dir/meta-intel-edison/utils/flash/postBuild.sh $build_dir

echo "*** Start creating a debian rootfs image ***"
#############################################################
################# KALI EDITS START HERE #####################
#############################################################
#EDIT change to kali
ROOTDIR=kali

if [ "$skip_debootstrap" != "true" ]; then
  rm -rf $ROOTDIR
  mkdir $ROOTDIR
  #EDIT change to kali debootstrap
  #debootstrap --arch i386 --no-check-gpg jessie $ROOTDIR http://http.debian.net/debian/
  #debootstrap --arch i386 --no-check-gpg --include=vim-nox,openssh-server,ntpdate,less,wireless-tools,wpasupplicant,dnsmasq,psmisc,locales,locales-all,screen --exclude=nano kali $ROOTDIR http://archive.kali.org/kali
  debootstrap --arch i386 --no-check-gpg --foreign kali-rolling $ROOTDIR http://http.kali.org/kali
fi

LANG=C chroot $ROOTDIR /debootstrap/debootstrap --second-stage

mkdir -p $ROOTDIR/home/root

export MALLOC_CHECK_=0 # workaround for LP: #520465
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

mount sysfs $ROOTDIR/sys -t sysfs
mount proc $ROOTDIR/proc -t proc
mount -o bind /dev/pts $ROOTDIR/dev/pts

cat << EOF > $ROOTDIR/etc/network/interfaces
auto lo
iface lo inet loopback
EOF

cat << EOF > $ROOTDIR/etc/resolv.conf
nameserver 8.8.8.8
EOF

cat << EOF > $ROOTDIR/etc/apt/sources.list
deb http://http.kali.org/kali kali-rolling main contrib non-free
EOF

echo "kali" > $ROOTDIR/etc/hostname

cat << EOF > $ROOTDIR/etc/hosts
127.0.0.1       kali    localhost
::1             localhost ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff00::0         ip6-mcastprefix
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

cat << EOF > $ROOTDIR/debconf.set
console-common console-data/keymap/policy select Select keymap from full list
console-common console-data/keymap/full select en-latin1-nodeadkeys
EOF


cat << EOF > $ROOTDIR/third-stage
#!/bin/bash
dpkg-divert --add --local --divert /usr/sbin/invoke-rc.d.chroot --rename /usr/sbin/invoke-rc.d
cp /bin/true /usr/sbin/invoke-rc.d
echo -e "#!/bin/sh\nexit 101" > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

apt-get update
apt-get --yes --force-yes install locales-all

debconf-set-selections /debconf.set
rm -f /debconf.set
apt-get update
apt-get -y install git-core binutils ca-certificates initramfs-tools u-boot-tools
apt-get -y install locales console-common less nano git
echo "root:toor" | chpasswd
sed -i -e 's/KERNEL\!=\"eth\*|/KERNEL\!=\"/' /lib/udev/rules.d/75-persistent-net-generator.rules
rm -f /etc/udev/rules.d/70-persistent-net.rules
export DEBIAN_FRONTEND=noninteractive
#apt-get --yes --force-yes install $packages
apt-get --yes --force-yes dist-upgrade
apt-get --yes --force-yes autoremove

rm -f /usr/sbin/policy-rc.d
rm -f /usr/sbin/invoke-rc.d
dpkg-divert --remove --rename /usr/sbin/invoke-rc.d

rm -f /third-stage
EOF

chmod +x $ROOTDIR/third-stage
LANG=C chroot $ROOTDIR /third-stage

## Backup config
#cp $ROOTDIR/etc/environment $ROOTDIR/etc/environment.sav
#cp $ROOTDIR/etc/resolv.conf $ROOTDIR/etc/resolv.conf.sav
#cp $ROOTDIR/etc/hosts $ROOTDIR/etc/hosts.sav
#
## Use host system network config to be able to apt-get later on
#echo `export | grep http_proxy  | sed 's/declare -x http_proxy=/Acquire::http::proxy /'`\;    >> $ROOTDIR/etc/apt/apt.conf.d/50proxy
#echo `export | grep https_proxy | sed 's/declare -x https_proxy=/Acquire::https::proxy /'`\;  >> $ROOTDIR/etc/apt/apt.conf.d/50proxy
#echo `export | grep HTTP_PROXY  | sed 's/declare -x HTTP_PROXY=/Acquire::http::proxy /'`\;    >> $ROOTDIR/etc/apt/apt.conf.d/50proxy
#echo `export | grep HTTPS_PROXY | sed 's/declare -x HTTPS_PROXY=/Acquire::https::proxy /'`\;  >> $ROOTDIR/etc/apt/apt.conf.d/50proxy
#cp /etc/resolv.conf $ROOTDIR/etc/resolv.conf
#cp /etc/hosts $ROOTDIR/etc/hosts

CHROOTCMD="eval LC_ALL=C LANGUAGE=C LANG=C chroot $ROOTDIR"

# Install necessary packages
$CHROOTCMD apt-get clean
$CHROOTCMD apt-get update
$CHROOTCMD apt-get -y --force-yes install dbus nano openssh-server sudo bash-completion dosfstools
$CHROOTCMD apt-get -y --force-yes install bluez hostapd file ethtool network-manager
cat << EOF > $ROOTDIR/etc/resolv.conf
nameserver 8.8.8.8
EOF
$CHROOTCMD apt-get -y --force-yes install python

# This service is added by the network-manager debian package but we don't want it activated
# as it causes an UART console corruption at boot
$CHROOTCMD rm /etc/systemd/system/multi-user.target.wants/ModemManager.service /etc/systemd/system/dbus-org.freedesktop.ModemManager1.service

# Create a default user "user" with password "edison"
# Encrypted password is created with mkpasswd
$CHROOTCMD useradd -m user -p YyleQbUNcJwao
$CHROOTCMD adduser user sudo
$CHROOTCMD adduser user netdev
$CHROOTCMD chsh -s /bin/bash user


# Fixup watchdog in systemd
echo "RuntimeWatchdogSec=90" >> $ROOTDIR/etc/systemd/system.conf

my_mode="external"
if [ -d "$top_repo_dir/meta-intel-edison-devenv" ]; then
  my_mode="devenv"
fi

# Install kernel/modules/firmware base packages generated by yocto
cp -r tmp/deploy/deb $ROOTDIR/tmp/
if [ "$my_mode" = "devenv" ]; then
  $CHROOTCMD dpkg -i /tmp/deb/edison/kernel-image-3.10.17-poky-edison+_1.0-r2_i386.deb
  $CHROOTCMD dpkg -i /tmp/deb/edison/kernel-3.10.17-poky-edison+_1.0-r2_i386.deb
  $CHROOTCMD dpkg -i /tmp/deb/edison/kernel-module-bcm4334x_1.141-r47_i386.deb
  $CHROOTCMD dpkg -i /tmp/deb/edison/kernel-module-bcm-bt-lpm_1.0-r2_i386.deb
  $CHROOTCMD dpkg -i /tmp/deb/edison/kernel-module-libcomposite_1.0-r2_i386.deb
  $CHROOTCMD dpkg -i /tmp/deb/edison/kernel-module-u-serial_1.0-r2_i386.deb
  $CHROOTCMD dpkg -i /tmp/deb/edison/kernel-module-usb-f-acm_1.0-r2_i386.deb
  $CHROOTCMD dpkg -i /tmp/deb/edison/kernel-module-g-multi_1.0-r2_i386.deb
  $CHROOTCMD dpkg -i /tmp/deb/edison/kernel-module-aufs_1.0-r2_i386.deb
else
  $CHROOTCMD dpkg -i /tmp/deb/edison/kernel-image-3.10.17-yocto-standard_3.10.17-r0_i386.deb
  $CHROOTCMD dpkg -i /tmp/deb/edison/kernel-3.10.17-yocto-standard_3.10.17-r0_i386.deb
  $CHROOTCMD dpkg -i /tmp/deb/edison/kernel-module-bcm4334x_1.141-r47_i386.deb
  $CHROOTCMD dpkg -i /tmp/deb/edison/kernel-module-bcm-bt-lpm_3.10.17-r0_i386.deb
  $CHROOTCMD dpkg -i /tmp/deb/edison/kernel-module-libcomposite_3.10.17-r0_i386.deb
  $CHROOTCMD dpkg -i /tmp/deb/edison/kernel-module-u-serial_3.10.17-r0_i386.deb
  $CHROOTCMD dpkg -i /tmp/deb/edison/kernel-module-usb-f-acm_3.10.17-r0_i386.deb
  $CHROOTCMD dpkg -i /tmp/deb/edison/kernel-module-g-multi_3.10.17-r0_i386.deb
  $CHROOTCMD dpkg -i /tmp/deb/edison/kernel-module-aufs_3.10.17-r0_i386.deb
fi
  $CHROOTCMD dpkg -i /tmp/deb/all/bcm43340-fw_6.20.190-r2_all.deb
  $CHROOTCMD dpkg -i /tmp/deb/core2-32/bcm43340-bt_1.0-r0_i386.deb

# Enables USB networking at startup
cat > $ROOTDIR/lib/systemd/network/usb0.network <<EOF
[Match]
Name=usb0

[Network]
Address=192.168.2.15/24
EOF
$CHROOTCMD ln -s /lib/systemd/system/systemd-networkd.service /etc/systemd/system/multi-user.target.wants/


# Provides fw_setenv/fw_printenv
$CHROOTCMD dpkg -i /tmp/deb/edison/u-boot-fw-utils_2014.04-1-r0_i386.deb

# First install script, probably not much needed for a debian
$CHROOTCMD dpkg -i /tmp/deb/core2-32/post-install_1.0-r0_i386.deb

# Add this service as it's not present on debian, but is required by the first-install script
cat > $ROOTDIR/lib/systemd/system/sshdgenkeys.service <<EOF
[Unit]
Description=OpenSSH Key Generation
[Service]
ExecStart=/bin/sh -c "if ! sshd -t &> /dev/null ; then rm /etc/ssh/*_key* ; ssh-keygen -A ; sync ; fi"
Type=oneshot
RemainAfterExit=yes
EOF

# Set up uboot env configuration
cat > $ROOTDIR/etc/fw_env.config <<EOF
# MTD device name	Device offset	Env. size	Flash sector size	Number of sectors
# On Edison, the u-boot environments are located on partitions 2 and 4 and both have a size of 64kB
/dev/mmcblk0p2		0x0000		0x10000
/dev/mmcblk0p4		0x0000		0x10000
EOF

#if [ "$add_graphical_packages" == "true" ]; then
#  # Add X.org, mesa, wayland and graphical stuff
#  $CHROOTCMD apt-get -y --force-yes install xorg mesa-utils weston
#fi
#
## Cleanup space on rootfs
#$CHROOTCMD apt-get clean
#
## Setup config files with final versions
#mv $ROOTDIR/etc/environment.sav $ROOTDIR/etc/environment
#mv $ROOTDIR/etc/resolv.conf.sav $ROOTDIR/etc/resolv.conf
#mv $ROOTDIR/etc/hosts.sav $ROOTDIR/etc/hosts.conf
#echo "127.0.0.1       localhost.localdomain           edison" >> $ROOTDIR/etc/hosts
#echo "edison" > $ROOTDIR/etc/hostname
echo "rootfs               /                    auto       nodev,noatime,discard,barrier=1,data=ordered,noauto_da_alloc    1  1" > $ROOTDIR/etc/fstab
echo "/dev/disk/by-partlabel/boot     /boot       auto    noauto,comment=systemd.automount,nosuid,nodev,noatime,discard     1   1" >> $ROOTDIR/etc/fstab

## Clean up
#umount -l -f $ROOTDIR/sys
## Kill remaining processes making use of the /proc before unmounting it
#lsof | grep $ROOTDIR/proc | awk '{print $2}' | xargs kill -9
#umount -l -f $ROOTDIR/proc

cat << EOF > $ROOTDIR/cleanup
#!/bin/bash
rm -rf /root/.bash_history
apt-get update
apt-get clean
rm -f /0
rm -f /hs_err*
rm -f cleanup
rm -f /usr/bin/qemu*
EOF

chmod +x $ROOTDIR/cleanup
LANG=C chroot $ROOTDIR /cleanup

rm -rf $ROOTDIR/tmp/deb

umount $ROOTDIR/proc/sys/fs/binfmt_misc
umount $ROOTDIR/dev/pts
umount $ROOTDIR/dev/
umount $ROOTDIR/proc

## Create the rootfs ext4 image
#rm edison-image-edison.ext4
#fsize=$((`stat --printf="%s" toFlash/edison-image-edison.ext4` / 524288))
#dd if=/dev/zero of=edison-image-edison.ext4 bs=512K count=$fsize
#mkfs.ext4 -F -L rootfs edison-image-edison.ext4
#
## Copy the rootfs content in the ext4 image
#rm -rf tmpext4
#mkdir tmpext4
#mount -o loop edison-image-edison.ext4 tmpext4
#cp -a $ROOTDIR/* tmpext4/
#umount tmpext4
#rmdir tmpext4
#
#cp edison-image-edison.ext4 toFlash/
## Make sure that non-root users can read write the flash files
## This seems to fix a strange flashing issue in some cases
#chmod -R a+rw toFlash

