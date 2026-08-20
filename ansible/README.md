# Ansible

## Install ansible
```zsh
brew install ansible
```

## Run playbooks
```zsh
ansible-playbook playbooks/update_packages.yml -i inventory --ask-become-pass
```
