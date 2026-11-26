def session_start: {hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: .}};
def fits: (session_start | tojson | utf8bytelength) + 1 <= 8500;

# Only a table that cannot fit with the rules needs a partial list of hosts.
def fit_table($title; $table; $rules; $notice):
  ($title + $notice) as $prefix |
  reduce ($table | split("\n")[] | select(length > 0)) as $row
    ($prefix; if (. + $row + "\n" + $rules | fits) then . + $row + "\n" else . end) |
  . + $rules;

(join("") | rtrimstr("\n")) as $whole |
if ($whole | fits) then $whole
else
  . as [$title, $table, $rules, $tools, $notes] |
  def notice($omitted): "\($omitted) omitted from startup. Read the full policy: \($command)\n\n";
  ($title + notice("Tool lists") + $table + $rules + $notes | rtrimstr("\n")) as $with_notes |
  ($title + notice("Tool lists and notes") + $table + $rules | rtrimstr("\n")) as $core |
  if ($with_notes | fits) then $with_notes
  elif ($core | fits) then $core
  elif $table != null then
    fit_table($title; $table; $rules; notice("Some host rows, tool lists and notes")) |
    if fits then . else notice("Policy including rules") end
  else notice("Policy diagnostic")
  end
end | session_start
