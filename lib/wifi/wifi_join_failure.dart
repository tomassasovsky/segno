/// How a failed WiFi join should be presented — and recovered from.
///
/// The console used to fold every activation failure into "check the
/// password", which taught exactly the wrong model of the most common failure:
/// a NetworkManager/iwd backend race that NM classifies as `no-secrets`
/// (#824). The owner's rational response — forget the network, re-type the
/// password — happens to work around store staleness, but it destroys the
/// diagnostic evidence. These kinds keep the two failures apart (#829).
enum WifiJoinErrorKind {
  /// The key itself was rejected. Re-asking for the password is the honest
  /// next step, and the only kind that ever routes back to the prompt.
  credentials,

  /// A backend or transient failure — iwd teardown races, D-Bus errors, NM's
  /// agent-less `no-secrets` on a join that supplied no fresh password. The
  /// password is not in question; the cubit re-activates instead of asking.
  transient,

  /// The association ran out the clock. Retryable — a slow AP or a mid-join
  /// backend hiccup, never proof of a bad key.
  timeout,

  /// Nothing recognizable. Shown as a plain failure with a manual retry.
  unknown,
}

/// Classifies a failed join by **(what the stack said, whether the user just
/// typed a password)** — the one place the mapping lives, so the bench
/// journal specimen from #824 can be checked against it.
///
/// [raw] is the error text as it reaches Dart: `segno-wifi-ctl`'s mapped
/// stderr on the appliance, or raw NetworkManager/nmcli/D-Bus wording if the
/// helper's own mapping ever passes it through. [interactive] is true only
/// when this activation carried a password the user typed moments ago.
///
/// The mapping, most-specific first:
///
/// | evidence in [raw]                     | interactive | kind        |
/// |---------------------------------------|-------------|-------------|
/// | 4-way handshake / psk may be wrong    | either      | credentials |
/// | wrong password / invalid passphrase   | either      | credentials |
/// | authentication failed                 | either      | credentials |
/// | `net.connman.iwd.Failed`/`.Aborted`   | either      | transient   |
/// | iwd Invalid exchange / connect-failed | either      | transient   |
/// | no-secrets / secrets were required    | yes         | credentials |
/// | no-secrets / secrets were required    | no          | transient   |
/// | timed out / took too long             | either      | timeout     |
/// | anything else                         | either      | unknown     |
///
/// Why `no-secrets` splits on context: this console runs no secret agent, so
/// NM ends *any* failed activation it cannot re-ask about as `no-secrets` —
/// the #824 boot race surfaced exactly that way while the saved profile held
/// a provably correct key. Only when the user has just submitted a password
/// is `no-secrets` plausibly about the password itself (iwd reports an
/// interactive wrong-password attempt through the same code). A failure on an
/// autonomous activation of a saved network is treated as backend/transient —
/// conservatively: mis-showing "retrying" for a genuinely wrong stored key
/// costs a delay; mis-showing "wrong password" for a race costs the evidence
/// and the owner's mental model.
WifiJoinErrorKind classifyWifiJoinFailure({
  required String raw,
  required bool interactive,
}) {
  final lower = raw.toLowerCase();
  bool has(Pattern p) => lower.contains(p);

  // Hard credential evidence: the supplicant tested the key and the key
  // failed. Trustworthy in any context.
  if (has('4-way handshake') ||
      has('pre-shared key may be incorrect') ||
      has('reason=wrong_key') ||
      has('wrong password') ||
      has('invalid passphrase') ||
      has('authentication failed')) {
    return WifiJoinErrorKind.credentials;
  }

  // The iwd backend refused or aborted mid-flight — the #824 shape. The key
  // was never tested, so this is never a password problem.
  if (has('net.connman.iwd.failed') ||
      has('net.connman.iwd.aborted') ||
      has('invalid exchange') ||
      has('connect-failed')) {
    return WifiJoinErrorKind.transient;
  }

  // NM's `no-secrets` family: about the password only when one was just
  // typed; otherwise it is NM's agent-less dead end for a backend failure.
  if (has('no secrets') || has('no-secrets') || has('secrets were required')) {
    return interactive
        ? WifiJoinErrorKind.credentials
        : WifiJoinErrorKind.transient;
  }

  if (has('timed out') || has('took too long')) {
    return WifiJoinErrorKind.timeout;
  }

  return WifiJoinErrorKind.unknown;
}
