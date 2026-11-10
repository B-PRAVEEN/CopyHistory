## 2024-05-18 - String optimization loop check

**Learning:** When dealing with string replacements using `while out.contains(...)`, repeatedly calling `contains` inside the loop creates string allocations. If the string is long, this is very slow.
**Action:** Replace `while out.contains(X) { out = out.replacingOccurrences(of: X, with: Y) }` with a single Regex replacement or an iterative approach that does not constantly call `contains` and `replacingOccurrences` which creates new strings.
