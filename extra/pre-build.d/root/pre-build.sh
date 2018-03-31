#!/bin/bash

# needed so we override whatever's set in python
# alternatively, we can just mkdir -p $GNUPGHOME
#export GNUPGHOME=/root/.gnupg
unset GNUPGHOME
mkdir -p /var/empty/.gnupg


# set up a shell env
source /etc/profile

# Import settings.
source /root/VARS.txt

# Logging!
exec 3>&1 4>&2
trap 'exec 2>&4 1>&3' 0 1 2 3
exec 1>/var/log/chroot_install.log 2>&1

# we need this fix before anything.
dirmngr </dev/null
gpg --batch --yes --import /root/pubkey.gpg 
# This is unnecessary as we have no private key
#gpg --batch --yes --lsign-key 0x${SIGKEY}

exec 17<>/root/pubkey.gpg

cleanPacorigs()
{
	for x in $(find /etc/ -type f -iname "*.pacorig");
	do
		mv -f ${x} ${x%%.pacorig}
	done
}
getPkgList()
{
	if [ -f "${1}" ];
	then
		pkgfile=$(cat ${1})
		echo "${pkgfile}" | \
		sed -r -e '/^[[:space:]]*(#|$)/d' \
			-e 's/[[:space:]]*#.*$//g' | \
		tr '\n' ' ' | \
		sed -re 's/([+\_])/\\\1/g'
	fi
}

# Build the keys
pacman-key --init
pacman-key --populate archlinux
pacman-key -r 93481F6B
# Update the mirror cache
pacman -Syy
# Just in case.
cleanPacorigs
# Install some prereqs
pacman -S --noconfirm --needed sed
pacman -S --noconfirm --needed grep
sed -i.bak -e 's/^CheckSpace/#CheckSpace/g' /etc/pacman.conf
pacman -S --noconfirm --needed filesystem
pacman -S --noconfirm --needed core
mv /etc/pacman.conf.bak /etc/pacman.conf
pacman -S --noconfirm --needed base syslinux wget rsync unzip jshon sudo abs xmlto bc docbook-xsl git
locale-gen
# And get rid of files it wants to replace
cleanPacorigs
# Force update all currently installed packages in case the tarball's out of date
pacman -Su --force --noconfirm
# And in case the keys updated...
pacman-key --refresh-keys
cleanPacorigs
# We'll need these.
pacman -S --noconfirm --needed base-devel
cleanPacorigs
# Install apacman
pacman --noconfirm -U /root/apacman*.tar.xz &&\
	 mkdir /var/tmp/apacman && chmod 0750 /var/tmp/apacman &&\
	 chown root:aurbuild /var/tmp/apacman
chown aurbuild:aurbuild /var/empty/.gnupg
chmod 700 /var/empty/.gnupg
cleanPacorigs
apacman -Syy
for p in apacman apacman-deps apacman-utils expac;
do
	apacman -S --noconfirm --noedit --skipinteg --needed -S "${p}"
done
apacman --gendb
cleanPacorigs
# Install multilib-devel if we're in an x86_64 chroot.
if $(egrep -q '^\[multilib' /etc/pacman.conf);
then
	yes 'y' | pacman -S --needed gcc-multilib lib32-fakeroot lib32-libltdl
	pacman --noconfirm -S --needed multilib-devel
	cleanPacorigs
	TGT_ARCH='x86_64'
else
	TGT_ARCH='i686'
fi
# Install some stuff we need for the ISO.
#PKGLIST=$(sed -re '/^[[:space:]]*(#|$)/d' /root/iso.pkgs.both | tr '\n' ' ')
PKGLIST=$(getPkgList /root/iso.pkgs.both)
if [[ -n "${PKGLIST}" ]];
then
	apacman --noconfirm --noedit --skipinteg -S --needed ${PKGLIST}
	apacman --gendb
	cleanPacorigs
fi
# And install arch-specific packages for the ISO, if there are any.
#PKGLIST=$(sed -re '/^[[:space:]]*(#|$)/d' /root/iso.pkgs.arch | tr '\n' ' ')
PKGLIST=$(getPkgList /root/iso.pkgs.arch)
if [[ -n "${PKGLIST}" ]];
then
	apacman --noconfirm --noedit --skipinteg -S --needed ${PKGLIST}
	apacman --gendb
	cleanPacorigs
fi
# Do some post tasks before continuing
apacman --noconfirm --noedit -S --needed customizepkg-scripting
ln -s /usr/lib/libdialog.so.1.2 /usr/lib/libdialog.so
cleanPacorigs
apacman --noconfirm --noedit --skipinteg -S --needed linux
apacman --gendb
cleanPacorigs

# And install EXTRA functionality packages, if there are any.
#PKGLIST=$(sed -re '/^[[:space:]]*(#|$)/d' /root/packages.both | tr '\n' ' ')
PKGLIST=$(getPkgList /root/packages.both)
if [[ -n "${PKGLIST}" ]];
then
	echo "Now installing your extra packages. This will take a while and might appear to hang."
	#yes 1 | apacman --noconfirm --noedit --skipinteg -S --needed ${PKGLIST}
	for p in ${PKGLIST};
	do
		apacman --noconfirm --noedit --skipinteg -S --needed ${p}
	done
	apacman --gendb
	cleanPacorigs
fi
# Add the regular user
useradd -m -s /bin/bash -c "${USERCOMMENT}" ${REGUSR}
usermod -aG users,games,video,audio ${REGUSR}  # TODO: remove this in lieu of $REGUSR_GRPS? these are all kind of required, though, for regular users anyways
for g in $(echo ${REGUSR_GRPS} | sed 's/,[[:space:]]*/ /g');
do
	getent group ${g} > /dev/null 2>&1 || groupadd ${g}
	usermod -aG ${g} ${REGUSR}
done
passwd -d ${REGUSR}
# Add them to sudoers
mkdir -p /etc/sudoers.d
chmod 750 /etc/sudoers.d
printf "Defaults:${REGUSR} \041lecture\n${REGUSR} ALL=(ALL) ALL\n" >> /etc/sudoers.d/${REGUSR}
# Set the password, if we need to.
if [[ -n "${REGUSR_PASS}" && "${REGUSR_PASS}" != 'BLANK' ]];
    then
      sed -i -e "s|^${REGUSR}::|${REGUSR}:${REGUSR_PASS}:|g" /etc/shadow
elif [[ "${REGUSR_PASS}" == '{[BLANK]}' ]];
then
	passwd -d ${REGUSR}
else
	usermod -L ${REGUSR}
fi
# Set the root password, if we need to.
if [[ -n "${ROOT_PASS}" && "${ROOT_PASS}" != 'BLANK' ]];
then
	sed -i -e "s|^root::|root:${ROOT_PASS}:|g" /etc/shadow
elif [[ "${ROOT_PASS}" == 'BLANK' ]];
then
	passwd -d root
else
	usermod -L root
fi
cleanPacorigs
# And install arch-specific extra packages, if there are any.
#PKGLIST=$(sed -re '/^[[:space:]]*(#|$)/d' /root/packages.arch | tr '\n' ' ')
PKGLIST=$(getPkgList /root/packages.arch)
if [[ -n "${PKGLIST}" ]];
then
	#apacman --noconfirm --noedit --skipinteg -S --needed ${PKGLIST}
	for p in ${PKGLIST};
	do
		apacman --noconfirm --noedit --skipinteg -S --needed ${PKGLIST}
	done
	apacman --gendb
	cleanPacorigs
fi
# Run any arch-specific tasks here.
if [ -f '/root/pre-build.arch.sh' ];
then
	cnt=$(sed -re '/^[[:space:]]*(#|$)/d' /root/pre-build.arch.sh | wc -l)
	if [[ "${cnt}" -ge 1 ]];
	then
		/root/pre-build.arch.sh
	fi
	rm -f /root/pre-build.arch.sh
fi
# Cleanup
# TODO: look into https://wiki.archlinux.org/index.php/Pacman/Tips_and_tricks#Removing_unused_packages_.28orphans.29
mkinitcpio -p linux
paccache -rk0
localepurge-config
localepurge
localepurge-config
localepurge
rm -f /root/.bash_history
rm -f /root/.viminfo
rm -f /root/apacman-*.pkg.tar.xz
rm -f /root/pre-build.sh
pkill -9 dirmngr
pkill -9 gpg-agent
