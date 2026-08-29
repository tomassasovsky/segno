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
      p = index(rest, q);
      if (p == 0) { printf "%*s", length(rest), ""; i = n + 1 }
      else { printf "%*s", p, ""; i += p; q = "" }
    }
  }
  if (q == "") printf "\n"; else printf " ";
}
