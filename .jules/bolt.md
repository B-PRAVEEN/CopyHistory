## 2024-05-24 - Avoiding O(N) allocations for string checks
**Learning:** Checking if a string is empty or doing substring checks using `.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty` allocates a new string in memory. On a large clipboard buffer (up to 512KB+), this introduces heavy overhead and blocks the main thread.
**Action:** Use `.allSatisfy(\.isWhitespace)` for whitespace checks. Also apply `.filter` before `.sorted()` to minimize sorting overhead.
