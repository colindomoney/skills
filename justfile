set shell := ["bash", "-euo", "pipefail", "-c"]
root := justfile_directory()
py := "python3 " + root / "scripts/skills.py"

default:
    @just --list

# Install all groups (or only the named ones: just install homelab mcp) into every agent CLI found
install *groups:
    {{root}}/scripts/install.sh {{groups}}

uninstall:
    {{root}}/scripts/install.sh --uninstall

# Inventory: just list | just list --group homelab | just list --tag traefik | just list --status skeleton
list *args:
    @{{py}} list {{args}}

groups:
    @{{py}} groups

# Validate: frontmatter conventions, then the Agent Skills spec (warnings fail)
check:
    {{py}} check
    for g in $({{py}} groups); do uvx skillscheck {{root}}/skills/$g --check spec,quality,disclosure --strict; done

# Regenerate the skills table in README.md from frontmatter
readme:
    @{{py}} readme

# Create skills/GROUP/GROUP-NAME/SKILL.md from the template
new group name:
    test ! -e {{root}}/skills/{{group}}/{{group}}-{{name}} || (echo "exists" && exit 1)
    mkdir -p {{root}}/skills/{{group}}/{{group}}-{{name}}/references
    sed -e "s/^name: group-pattern-name/name: {{group}}-{{name}}/" -e 's/tags: "group, technology, technology".*/tags: "{{group}}"/'  \
        {{root}}/templates/SKILL.md > {{root}}/skills/{{group}}/{{group}}-{{name}}/SKILL.md
    @echo "created skills/{{group}}/{{group}}-{{name}}/SKILL.md"

# Move a skill to _archive and mark it dormant (out of install path, still in git)
archive name:
    src=$(find {{root}}/skills -mindepth 2 -maxdepth 2 -type d -name {{name}} -not -path '*/_archive/*'); test -n "$src" || (echo "not found" && exit 1); \
    mkdir -p {{root}}/skills/_archive && git mv "$src" {{root}}/skills/_archive/{{name}} && \
    sed -i.bak 's/^  status: .*/  status: dormant/' {{root}}/skills/_archive/{{name}}/SKILL.md && rm {{root}}/skills/_archive/{{name}}/SKILL.md.bak && \
    echo "archived {{name}}"

# Skills still marked skeleton
skeletons:
    @{{py}} list --status skeleton
