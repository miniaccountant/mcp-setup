#!/usr/bin/env bash
# Fails a pull request that changes what Claude Code loads from this plugin but
# leaves "version" in .claude-plugin/plugin.json as it was. Claude Code pins an
# installed plugin to its version, so without a bump existing users never get
# the change.
#
#   .github/scripts/plugin-version-check.sh <base-ref>     e.g. origin/main
#
# What counts as a plugin change: anything in plugin.json other than "version",
# and the component files Claude Code reads (.mcp.json, .lsp.json, settings.json,
# skills/, commands/, agents/, hooks/, output-styles/, monitors/, workflows/,
# themes/, bin/). README, server.json, marketplace.json, icon and CI do not count.
set -euo pipefail

base=${1:?usage: plugin-version-check.sh <base-ref>}
manifest=.claude-plugin/plugin.json
[ -f "$manifest" ] || { echo "no $manifest - nothing to check"; exit 0; }

mb=$(git merge-base "$base" HEAD)
if ! git cat-file -e "$mb:$manifest" 2>/dev/null; then
  echo "$manifest is new in this branch - nothing to compare against"
  exit 0
fi

old_version=$(git show "$mb:$manifest" | jq -r '.version // empty')
new_version=$(jq -r '.version // empty' "$manifest")

changed=()
if ! diff -q <(git show "$mb:$manifest" | jq -S 'del(.version)') <(jq -S 'del(.version)' "$manifest") >/dev/null; then
  changed+=("$manifest")
fi
while IFS= read -r f; do
  [ -n "$f" ] && changed+=("$f")
done < <(git diff --name-only "$mb" HEAD -- \
  .mcp.json .lsp.json settings.json \
  skills commands agents hooks output-styles monitors workflows themes bin)

if [ ${#changed[@]} -eq 0 ]; then
  echo "plugin unchanged (version $new_version)"
  exit 0
fi

if [ "$old_version" = "$new_version" ]; then
  echo "::error file=$manifest::The plugin changed but \"version\" is still $new_version. Bump it, or users who already installed the plugin will not receive this change. Changed: ${changed[*]}"
  exit 1
fi

echo "plugin changed (${changed[*]}) and version moved $old_version -> $new_version"
