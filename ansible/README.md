# ansible/

Configures the Jenkins EC2 instance `terraform/modules/jenkins-server` provisions. Terraform's job stops at "a reachable box with the right IAM role exists" — this playbook installs and starts everything on top of it: Jenkins itself, Docker, and the CLI tools (`kubectl`, `helm`, `trivy`, `yq`, `jq`, `awscli`, Node.js) the Jenkinsfile's stages call directly.

## Usage

```bash
cd terraform/global
JENKINS_IP=$(terraform output -raw jenkins_public_ip)
cd ../../ansible

cp inventory.ini.example inventory.ini
# edit inventory.ini: replace REPLACE_WITH_JENKINS_PUBLIC_IP with $JENKINS_IP,
# and YOUR_KEY.pem with the private key matching jenkins_ssh_key_name

ansible-playbook jenkins.yml
```

Idempotent — every task uses Ansible's normal state-checking (`state: present`, `creates: ...`), so re-running after a change only applies what actually changed.

Jenkins is reachable afterward at `http://<jenkins_public_ip>:8080` — the playbook prints the initial admin password at the end. See `employee-task-app`'s [INSTALL.md](https://github.com/rashmiranjandevops/employee-task-app/blob/main/INSTALL.md) for the Jenkins job/credentials setup that comes after this.
