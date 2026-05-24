# Ansible Vault - Squid CA Private Key

This directory contains the Squid CA private key, encrypted with Ansible Vault.

## Files

- `squid-ca.key` - CA private key (encrypted with Ansible Vault)

## First Time Setup

When you run the playbook for the first time, it will:
1. Generate the CA private key in this directory
2. Automatically encrypt it with Ansible Vault
3. Prompt you to create a vault password

## Running the Playbook

**With vault password prompt:**
```bash
ansible-playbook -i inventory.ini site.yml --ask-vault-pass
```

**With vault password file:**
```bash
ansible-playbook -i inventory.ini site.yml --vault-password-file ~/.vault_pass
```

## Viewing/Editing the Private Key

**View the encrypted key:**
```bash
ansible-vault view files/vault/squid-ca.key
```

**Edit the encrypted key:**
```bash
ansible-vault edit files/vault/squid-ca.key
```

**Decrypt temporarily:**
```bash
ansible-vault decrypt files/vault/squid-ca.key
# Do your work
ansible-vault encrypt files/vault/squid-ca.key
```

## Rotating the CA Certificate

If you need to regenerate the CA certificate:

```bash
# Remove existing files
rm files/vault/squid-ca.key
rm files/squid-ca.crt

# Run playbook to generate new ones
ansible-playbook -i inventory.ini site.yml --ask-vault-pass
```

**Important:** After rotating, you must update all microservices with the new `squid-ca.crt`!

## Vault Password Management

**Never commit the vault password to git!**

Store it securely:
- Password manager (1Password, LastPass, etc.)
- GCP Secret Manager
- HashiCorp Vault
- CI/CD secrets (GitHub Actions, GitLab CI, etc.)

For local development, you can create `~/.vault_pass`:
```bash
echo "your-secure-vault-password" > ~/.vault_pass
chmod 600 ~/.vault_pass
```

Then use:
```bash
ansible-playbook -i inventory.ini site.yml --vault-password-file ~/.vault_pass
```

## Security Notes

⚠️ The private key in this file can MITM ALL HTTPS traffic from your microservices!

- Keep the vault password secure
- Use different vault passwords for dev/staging/prod
- Rotate the CA certificate annually
- Audit who has access to the vault password
