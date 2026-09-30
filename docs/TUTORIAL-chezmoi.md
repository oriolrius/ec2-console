# Tutorial: keep your ec2-console configuration with chezmoi

Your ec2-console machine is **disposable**. When the AWS sandbox lease ends, the machine and everything in the AWS account are deleted. This tutorial shows how to keep your **personal configuration** in a private GitHub repository with [chezmoi](https://www.chezmoi.io/), so every new machine gets it back in about two minutes.

**Time needed:** about 20 minutes for the one-time setup (Part A), and 2 minutes on every new machine (Part C).

## What goes where

| What                                                  | Tool              | Where it lives                                |
| ----------------------------------------------------- | ----------------- | --------------------------------------------- |
| Software (Docker, VS Code, desktop, ...)              | Ansible playbook  | the`ec2-console` repository                 |
| **Your configuration** (shell, git, editors...) | **chezmoi** | your private`ec2-console-config` repository |
| Your project work (code)                              | git               | one repository per project                    |

## How chezmoi works (2-minute version)

- **Target**: your real files in your home folder, for example `~/.bashrc`.
- **Source directory**: `~/.local/share/chezmoi`. chezmoi keeps a copy of every file it manages here. It is a normal git repository, and it is what you push to GitHub.
- **`chezmoi apply`** copies the source directory into your home folder.
- File names in the source directory are encoded. `dot_bashrc` is `~/.bashrc`, `dot_config/kitty/kitty.conf` is `~/.config/kitty/kitty.conf`, and a `.tmpl` ending means the file is a **template** that is filled in when applied.
- **`~/.config/chezmoi/chezmoi.toml`** holds values for this machine only (your name and email in this tutorial). It is **not** in the repository.

Everything below runs **on the ec2-console machine**, in an SSH session or a terminal in the Chrome Remote Desktop session. Ansible has already installed `chezmoi` and the GitHub CLI `gh`. Check with:

```bash
chezmoi --version && gh --version
```

---

## Part A: one-time setup (on your first machine)

### A1. Create the private repository

On GitHub, click **New repository**:

- **Name:** `ec2-console-config`
- **Visibility:** **Private**
- Leave "Add a README" unchecked (the repository must be empty).

### A2. Log in to GitHub from the machine

```bash
gh auth login
```

Answer the questions:

1. **Where do you use GitHub?** GitHub.com
2. **Preferred protocol for Git operations?** HTTPS
3. **Authenticate Git with your GitHub credentials?** Yes
4. **How would you like to authenticate?** Login with a web browser

It shows a one-time code such as `ABCD-1234`. On your own computer, open **https://github.com/login/device**, enter the code and authorize. Check the result with:

```bash
gh auth status
```

> `gh` stores its login on this machine only. It is **never** added to the chezmoi repository.

### A3. Start chezmoi

```bash
chezmoi init
chezmoi cd        # opens a shell inside the source directory
```

`chezmoi init` creates the source directory `~/.local/share/chezmoi` as an **empty git repository**, and nothing else yet. `chezmoi cd` takes you inside it. Stay in this shell for steps A4–A6.

### A4. Ask for your name and email instead of storing them

Create the file `.chezmoi.toml.tmpl`:

```bash
cat > .chezmoi.toml.tmpl <<'EOF'
{{- $name := promptStringOnce . "name" "Your full name (for git commits)" -}}
{{- $email := promptStringOnce . "email" "Your email (for git commits)" -}}
[data]
    name = {{ $name | quote }}
    email = {{ $email | quote }}
EOF
```

Now run `chezmoi init` **again**. This is not a repeat of A3: this time chezmoi finds `.chezmoi.toml.tmpl`, asks the two questions, and saves your answers in `~/.config/chezmoi/chezmoi.toml`, on this machine only. Your repository contains the questions, not your answers.

```bash
chezmoi init
cat ~/.config/chezmoi/chezmoi.toml    # shows your answers
```

> Re-running `chezmoi init` is safe. It never deletes your source directory, and `promptStringOnce` only asks questions that don't have an answer yet.

### A5. Add a templated `.gitconfig`

```bash
cat > dot_gitconfig.tmpl <<'EOF'
[user]
	name = {{ .name }}
	email = {{ .email }}
[init]
	defaultBranch = main
[pull]
	rebase = false
# GitHub CLI as credential helper (same as `gh auth setup-git`), so chezmoi
# and git can reach private GitHub repos after `gh auth login`.
[credential "https://github.com"]
	helper =
	helper = !/usr/bin/gh auth git-credential
[credential "https://gist.github.com"]
	helper =
	helper = !/usr/bin/gh auth git-credential
EOF
```

`{{ .name }}` and `{{ .email }}` are filled in from your answers in A4. The `credential` lines keep git connected to your GitHub login. Step A2 wrote them into `~/.gitconfig`, and chezmoi will now manage that file, so they must be part of the template too.

### A6. Tell chezmoi which files to ignore

The repository gets a README for humans, but that README must not be copied into your home folder:

```bash
echo "README.md" > .chezmoiignore
echo "# ec2-console-config — my dotfiles, managed with chezmoi" > README.md
exit              # leave the source-directory shell
```

### A7. Add your existing configuration files

Pick the files you have customised. For example:

```bash
chezmoi add ~/.bashrc
chezmoi add ~/.config/kitty/kitty.conf ~/.config/zellij/config.kdl
chezmoi add ~/.config/Code/User/settings.json
```

You can also create a new file and add it. For example, some aliases (Ubuntu's `.bashrc` loads `~/.bash_aliases` automatically):

```bash
cat > ~/.bash_aliases <<'EOF'
alias ll='ls -alF'
alias gs='git status'
alias k='kubectl'
alias dc='docker compose'
EOF
chezmoi add ~/.bash_aliases
```

> **Never add secrets.** Don't add `~/.ssh/` private keys, `ec2-key.pem`, `~/.aws/credentials`, `~/.config/gh/`, `.env` files or anything with a token or password. The repository is private, but secrets still don't belong in git.

### A8. Check and apply

```bash
chezmoi diff       # what would change in your home folder (should be only .gitconfig)
chezmoi apply      # write it
chezmoi managed    # list everything chezmoi manages
```

### A9. Save it to GitHub

Replace `<your-github-user>` with your GitHub username:

```bash
chezmoi cd
git add -A
git commit -m "Initial ec2-console configuration"
git branch -M main
git remote add origin https://github.com/<your-github-user>/ec2-console-config.git
git push -u origin main
exit
```

Refresh the repository page on GitHub: you should see `dot_bashrc`, `dot_gitconfig.tmpl`, `dot_config/` and the rest.

---

## Part B: daily use

When you change a managed file, save the change to the repository.

| I want to...                  | Command                                                                                                    |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Edit a managed file           | `chezmoi edit ~/.bashrc`, then `chezmoi apply`                                                         |
| Keep a change I made directly | `chezmoi re-add` (copies changed files back into the source)                                             |
| Start managing a new file     | `chezmoi add ~/.config/<app>/<file>`                                                                     |
| See what differs              | `chezmoi status` or `chezmoi diff`                                                                     |
| Stop managing a file          | `chezmoi forget ~/.some-file`                                                                            |
| Save everything to GitHub     | `chezmoi git -- add -A`, then `chezmoi git -- commit -m "update config"`, then `chezmoi git -- push` |

> **Push before the lease ends.** Anything not pushed is lost when the machine is deleted. Make `chezmoi git -- push` a habit, just like pushing your project code.

---

## Part C: recover your configuration on a new ec2-console

After a new lease:

1. Deploy the machine with [RUNBOOK-terraform.md](RUNBOOK-terraform.md) or [RUNBOOK-cloudformation.md](RUNBOOK-cloudformation.md), steps 1–7. The Ansible playbook installs `chezmoi` and `gh`.
2. SSH into the new machine and log in to GitHub, exactly as in A2:

   ```bash
   gh auth login
   ```
3. Download and apply your configuration in one command:

   ```bash
   chezmoi init --apply <your-github-user>/ec2-console-config
   ```

   It asks for your name and email (A4), then writes all your files.
4. Check it:

   ```bash
   chezmoi verify && echo "configuration restored"
   source ~/.bashrc
   ```
5. Continue with the Chrome Remote Desktop setup (step 8 of the runbook).

---

## Ansible and chezmoi together

Ansible writes a **default** version of some files (for example `kitty.conf`, the Zellij config, the VS Code settings, and the prompt lines in `.bashrc`). chezmoi then replaces them with **your** version. The rule is simple:

- **Always run `chezmoi apply` after the Ansible playbook.** If you re-run the playbook later, run `chezmoi apply` again afterwards.
- If `chezmoi apply` says a file *has changed since chezmoi last wrote it*, answer **overwrite** to keep your version, or **skip** and run `chezmoi re-add` if the new version is the one you want.

## Troubleshooting

| Problem                                           | Fix                                                                                                                                                                                                                                                             |
| ------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Authentication failed` when cloning or pushing | Run`gh auth status`. If you're not logged in, run `gh auth login`; otherwise run `gh auth setup-git`.                                                                                                                                                     |
| `could not open a new TTY`                      | You ran chezmoi without an interactive terminal (for example from a script). Run it in a normal SSH session, or pass the answers:`--promptString "Your full name (for git commits)=Your Name" --promptString "Your email (for git commits)=you@example.com"`. |
| A file is not restored                            | `chezmoi managed` shows whether it is managed. If not, `chezmoi add` it on the old machine and push.                                                                                                                                                        |
| Anything else                                     | `chezmoi doctor` checks the installation.                                                                                                                                                                                                                     |

## Further reading

- chezmoi quick start: https://www.chezmoi.io/quick-start/
- Templates and machine-specific values: https://www.chezmoi.io/user-guide/templating/
- Secrets from a password manager (for example Bitwarden) instead of files: https://www.chezmoi.io/user-guide/password-managers/
