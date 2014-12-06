# -*- mode: ruby -*-
# vi: set ft=ruby :

VAGRANTFILE_API_VERSION = "2"

# copies pivate key when set to true for git repo ssh access
COPY_ID_RSA             = ENV['COPY_ID_RSA'] || true 

$shell = <<-BASH
sudo apt-get update -y && sudo apt-get install docker
BASH

$copyid = <<-BASH
echo "#{`cat $HOME/.ssh/id_rsa`}" > /root/.ssh/id_rsa
chmod go-rwx /root/.ssh/id_rsa
BASH

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|
  config.vm.box = "ubuntu/precise64"
  config.vm.provision :shell, inline: $copyid if COPY_ID_RSA
  config.vm.provision :shell, inline: $shell
  config.vm.synced_folder ".", "/test-runner"
end
