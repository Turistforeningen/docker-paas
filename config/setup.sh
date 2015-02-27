!#/bin/bash

# First, check that your APT system can deal with https URLs: the file
# /usr/lib/apt/methods/https should exist. If it doesn't, you need to install
# the package apt-transport-https.
[ -e /usr/lib/apt/methods/https ] || {
  apt-get update
  apt-get install apt-transport-https
}

# Then, add the Docker repository key to your local keychain.
apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 36A1D7869245C8950F966E92D8576A8BA88D21E9

# Add the Docker repository to your apt sources list, update and install the
# lxc-docker package.
sh -c "echo deb https://get.docker.com/ubuntu docker main > /etc/apt/sources.list.d/docker.list"
apt-get update \
  && apt-get dist-upgrade -y \
  && apt-get install -y python-setuptools lxc-docker-1.5.0 apparmor linux-image-extra-$(uname -r)

# Install Fig
easy_install pip && pip install -U docker-compose

# Fix broken dependency (docker/fig#918)
pip uninstall requests -y && pip install requests==2.4.3

# Add the docker group if it doesn't already exist.
groupadd docker

# Add vagrant user to the docker group.
gpasswd -a vagrant docker

# Roll our own Docker config
mv /etc/default/docker /etc/default/docker.back
ln -s /var/www/config/docker.conf /etc/default/docker

# Restart the Docker daemon.
service docker restart

echo "Appending sytem wide environment variables"
cat >> /etc/environment <<EOF

# Docker PAAS env vars
export PAAS_HIPACHE_DIR=/var/www/hipache
export PAAS_APP_DOMAIN=app.dnt.privat
export PAAS_APP_DIR=/var/www/apps
EOF

# Append some stuff to .bashrc
echo "Appending user local environment variables"
cat >> /home/vagrant/.bashrc <<EOF

alias docker-paas='/var/www/config/manage.sh'
cd /var/www
EOF

# Clean up so we don't waste our space
apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /wheels/*

