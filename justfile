set shell := ["bash", "-euo", "pipefail", "-c"]
root := justfile_directory()

default:
    @just --list

# Symlink all skills into every agent CLI found on this machine
install:
    {{root}}/scripts/install.sh

uninstall:
    {{root}}/scripts/install.sh --uninstall

# List skills in this repo
list:
    @{{root}}/scripts/install.sh --list | xargs -n1 basename

# Validate every skill against the Agent Skills spec (warnings fail)
check:
    uvx skillscheck {{root}}/skills --check spec,quality,disclosure --strict

# Create a new skill from the template
new name:
    test ! -e {{root}}/skills/{{name}} || (echo "{{name}} exists" && exit 1)
    mkdir -p {{root}}/skills/{{name}}/references
    sed "s/^name: pattern-name/name: {{name}}/" {{root}}/templates/SKILL.md > {{root}}/skills/{{name}}/SKILL.md
    @echo "created {{name}}/SKILL.md — now fill it in (or run the extract-pattern skill)"

# Skills still marked skeleton
skeletons:
    @grep -l '^  status: skeleton' {{root}}/skills/*/SKILL.md | xargs -n1 dirname | xargs -n1 basename || true
