# Never render source snippets or raw Markdown from a finding in the Summary.
def cell:
  tostring | @html | gsub("[\r\n\t]"; " ") | explode
  | map(if . == 33 or . == 35 or . == 40 or . == 41 or . == 42 or . == 91
           or . == 92 or . == 93 or . == 95 or . == 96 or . == 124
        then "&#\(.);" else [.] | implode end) | join("");
def location:
  ([.locations[] | select(.symbolic.kind == "Primary")][0] // .locations[0])
  | {path: .symbolic.key.Local.verbatim_path, line: (.concrete.location.start_point.row + 1)};
def location_link:
  . as $loc | "\($loc.path):\($loc.line)" as $label
  | if $source_base == "" then $label | cell
    else "[\($label | cell)](\($source_base)/\($loc.path | split("/") | map(@uri) | join("/"))#L\($loc.line))" end;
def severity:
  map(.determinations.severity) | unique
  | max_by({"Unknown": 0, "Informational": 1, "Low": 2, "Medium": 3, "High": 4}[.]);
def explanation:
  if .ident == "secrets-outside-env" then
    "Secrets are accessed by jobs without a dedicated Environment. GitHub access rules and secret storage remain to be configured."
  elif .ident == "anonymous-definition" then "A job or workflow has no display name."
  else .desc end;

if type != "array" then error("Expected a Zizmor JSON-v1 findings array") else . end
| if all(.[];
    (.ident | type == "string" and test("^[a-z][a-z0-9-]*$"))
    and (.desc | type == "string")
    and (.determinations.severity | IN("Unknown", "Informational", "Low", "Medium", "High"))
    and (.determinations.persona | IN("Regular", "Pedantic", "Auditor"))
    and (.locations | type == "array" and length > 0)
    and (location | (.path | type == "string")
      and (.line | type == "number" and . >= 1 and floor == .)))
  then . else error("Unsupported Zizmor finding schema") end
| map(select(.ignored != true)) as $findings
| ($findings | group_by(.ident)) as $groups
| "## Zizmor analysis",
  "",
  "Regular scan: **\(if $regular_exit == 0 then "passed" else "findings — blocking" end)**. Auditor scan: **\(if $audit_exit == 0 then "no findings" else "findings reported below" end)**.",
  "",
  "**\($findings | length) findings**, grouped into **\($groups | length) rules**. Repeated references are counted separately, not as independent vulnerabilities.",
  "",
  "Regular findings block validation. Additional auditor findings are report-only; analysis and report errors still fail the job.",
  "",
  (if $findings | length == 0 then "No findings to report."
   else
    "| Rule | Severity | Policy | Count | Files | Explanation |",
    "| --- | --- | --- | ---: | --- | --- |",
    ($groups[] |
      "| \(.[0].ident | cell) | \(severity | cell) | \(if any(.[]; .determinations.persona == "Regular") then "Blocking" else "Report only" end) | \(length) | \(map(location.path) | unique | map(cell) | join("<br>")) | \(.[0] | explanation | cell) |"),
    "",
    ($groups[] |
      "<details>",
      "<summary>\(.[0].ident | cell): affected locations</summary>",
      "",
      (map(location) | unique | sort_by(.path, .line) | .[] | "- \(location_link)"),
      "",
      "</details>",
      "")
   end),
  "",
  "Full diagnostics, source snippets and rule documentation are in the **Analyze workflow security without GitHub API access** step log."
