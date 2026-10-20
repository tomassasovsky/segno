# Replace every character inside a quoted span -- and the quote marks
# themselves -- with a space, leaving everything else and the string's length
# alone. Quote state carries across lines, and a newline INSIDE a quote is
# blanked to a space too, so a multi-line quoted argument collapses onto one
# logical line instead of masquerading as several commands.
#
# Read by .claude/hooks/guard-push.sh. Blanking is what stops that guard from
# denying prose about `git push`, so a span that ends too early here becomes a
# false positive there -- see the escape handling below.
BEGIN { q = "" }
{
  line = $0; n = length(line); i = 1;
  while (i <= n) {
    if (q == "") {
      rest = substr(line, i);
      if (match(rest, /['"\\]/)) {
        if (RSTART > 1) printf "%s", substr(rest, 1, RSTART - 1);
        c = substr(rest, RSTART, 1);
        i += RSTART;
        if (c == "\\") { printf "  "; i++ }
        else { q = c; printf " " }
      } else { printf "%s", rest; i = n + 1 }
    } else {
      rest = substr(line, i);
      # Inside a DOUBLE-quoted span a backslash escapes the next character, so
      # `\"` does not close the string -- bash keeps reading. A plain index()
      # for the next `"` closes early and un-blanks the remainder, which is how
      # `gh pr create --body "never write \"cd x && git push\" here"` used to
      # be denied. Inside a SINGLE-quoted span nothing escapes, so index() is
      # exactly right there.
      if (q == "\"") { p = match(rest, /^(\\.|[^"\\])*"/) ? RLENGTH : 0 }
      else { p = index(rest, q) }
      if (p == 0) { printf "%*s", length(rest), ""; i = n + 1 }
      else { printf "%*s", p, ""; i += p; q = "" }
    }
  }
  if (q == "") printf "\n"; else printf " ";
}
