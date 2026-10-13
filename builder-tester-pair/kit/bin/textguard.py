"""textguard — shared refusal check for free text written by builder/tester tools (handoff, verdict tools).

Refuses text that looks like Argus scenario content (holdout) or a secret. Hardened over two adversary
reviews (2026-10-10):
  v1 bypasses: zero-width chars, fullwidth letters, "EX PECT", secrets without '='/':'.
  v2 bypasses: combining marks, Cyrillic/Greek homoglyphs, paraphrased expectations ("should return 409"),
               base64/hex blobs, "pw:", "client_secret", split prefixes ("odt s_"), backslash kit paths,
               a keyword split across two fields.
  v2 false positives fixed: "token refresh failed", "secret rotation failed", "EXPECTATIONS doc".
It is a tripwire, not a boundary — describe what was OBSERVED in plain words and it will not trip.
"""
import base64, math, re, unicodedata

ZW = re.compile(r"[­͏ᅟᅠ᠎​-‏ -‮⁠-⁯ㅤ︀-️﻿"
                r"\U000e0000-\U000e007f]")
# Cyrillic / Greek letters that look like Latin ones → their Latin twin (then any OTHER Cyrillic/Greek letter refuses)
CONFUSE = str.maketrans("АВСЕНІЈКМОРЅТХУаеіјорсѕхуԁһԛԝΑΒΕΖΗΙΚΜΝΟΡΤΥΧαβεικνοτυχ",
                        "ABCEHIJKMOPSTXYaeijopcsxydhqwABEZHIKMNOPTYXabeiknotux")
ALIEN = re.compile(r"[Ͱ-ϿЀ-ӿԀ-ԯ]")

# On the normalised text as written
RAW = re.compile(
    r"\bEXPECT\b|"                                                                  # the scenario DSL keyword
    r"\b(expect|expects|expected)\b\W{0,3}((http|status)\W{0,3}(code\W{0,3})?)?\d{3}\b|"  # "expected: HTTP 409"
    r"\b(should\s+(return|respond\s+with|be)|assert\w*\W+(status|code|response)\w*\W{0,4}(==|is|equals?))\W{0,5}\d{3}\b|"
    r"\bstatus\s+code\s+(should|must)\b|"
    r"(^|[\s/\\'\"=:(])(kits|scenarios?)\s*[/\\]|"                                  # kit / scenario paths, either slash
    r"odts_|eyJ[A-Za-z0-9_-]{10}|gh[pousr]_[A-Za-z0-9]|github_pat_|xox[abposr]-|AKIA[A-Z0-9]{8}|sk-ant-|-----\s*BEGIN|"
    r"\b(pwd|pw|passwd|password|secret|token|bearer|client_?secret|api[_-]?key)\b\s*[=:]\s*\S{2,}|"   # key: value
    r"\b(pwd|pw|passwd|password|secret|token|bearer|client_?secret)\b\s+(?=\S*[0-9=/+_])\S{4,}|"     # key value-with-digits
    r"\b(client_?secret|api[_-]?key)\b\W{0,3}[A-Za-z0-9_\-]{8,}|"
    r"://[^/\s:@]+:[^@\s/]+@",
    re.I)
RAW_CS = re.compile(r"\bEXPECT\b")
# On the text with separators removed BETWEEN letters/digits only ("odt s_" -> "odts_", "E X P E C T" -> "EXPECT")
SQUASHED = re.compile(r"\bEXPECT\b|odts_|github_?pat_|-----BEGIN|-*BEGIN(RSA|OPENSSH|PRIVATE|EC)|sk-?ant-?(api)?[0-9a-z]")
SQUASHED_LC = re.compile(r"(?<!un)expect(ed|s)?(http|status)?(code)?\d{3}")
B64 = re.compile(r"[A-Za-z0-9+/_-]{16,}={0,2}")


def _entropy(s):
    from collections import Counter
    n = len(s)
    return -sum(c / n * math.log2(c / n) for c in Counter(s).values())


def normalise(s):
    s = unicodedata.normalize("NFKD", ZW.sub("", str(s)))
    s = "".join(ch for ch in s if unicodedata.category(ch) != "Mn")   # drop combining marks (É -> E)
    s = unicodedata.normalize("NFKC", s).translate(CONFUSE)
    return s


def _blob_secret(n):
    for m in B64.finditer(n):
        tok = m.group(0)
        if re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", tok):    # git SHAs / sha256 digests are not secrets
            continue
        # high-entropy secret = mixed upper+lower+digit, no path/word structure (URLs, ids and SHAs are lowercase)
        if re.search(r"[0-9]", tok) and re.search(r"[A-Z]", tok) and re.search(r"[a-z]", tok) \
                and len(tok) >= 20 and _entropy(tok) >= 3.8 and not re.search(r"/[a-z]{3,}/", tok):
            return True
        try:   # base64 that decodes to something secret-shaped
            raw = base64.b64decode(tok + "=" * (-len(tok) % 4), validate=False).decode("utf-8", "ignore")
            if raw and (RAW.search(raw) or "odts_" in raw):
                return True
        except Exception:
            pass
    return False


def bad(s):
    if s is None:
        return False
    n = normalise(s)
    if ALIEN.search(n):                     # a Cyrillic/Greek letter left after mapping = deliberate disguise
        return True
    sq = re.sub(r"(?<=[A-Za-z0-9_])[\s.\-'\"`,*~|]+(?=[A-Za-z0-9_])", "", n)
    return bool(RAW.search(n) or RAW_CS.search(n) or SQUASHED.search(sq) or SQUASHED_LC.search(sq.lower())
                or _blob_secret(n))


# Requirement text (the tester → the builder, 2026-10-12): acceptance criteria and design ARE for the builder, so expected
# behaviour ("over-limit amounts are refused with 400") is allowed. Still refused: secrets, kit/scenario paths and the
# scenario DSL keyword — the test CASES (inputs, edge values, EXPECT blocks) stay the holdout.
REQ_RAW = re.compile(
    r"(^|[\s/\\'\"=:(])(kits|scenarios?)\s*[/\\]|"
    r"odts_|eyJ[A-Za-z0-9_-]{10}|gh[pousr]_[A-Za-z0-9]|github_pat_|xox[abposr]-|AKIA[A-Z0-9]{8}|sk-ant-|-----\s*BEGIN|"
    r"\b(pwd|pw|passwd|password|secret|token|bearer|client_?secret|api[_-]?key)\b\s*[=:]\s*\S{2,}|"
    r"\b(client_?secret|api[_-]?key)\b\W{0,3}[A-Za-z0-9_\-]{8,}|"
    r"://[^/\s:@]+:[^@\s/]+@",
    re.I)


def bad_requirement(s):
    if s is None:
        return False
    n = normalise(s)
    if ALIEN.search(n):
        return True
    sq = re.sub(r"(?<=[A-Za-z0-9_])[\s.\-'\"`,*~|]+(?=[A-Za-z0-9_])", "", n)
    return bool(REQ_RAW.search(n) or RAW_CS.search(n) or re.search(r"\bEXPECT\b|odts_|github_?pat_|-----BEGIN", sq)
                or _blob_secret(n))


def check_requirement(*values):
    """Like check(), for requirement/acceptance/design text: expected BEHAVIOUR is allowed, test cases are not."""
    flat = [str(x) for v in values for x in (v if isinstance(v, (list, tuple)) else [v]) if x is not None]
    for s in flat + [" ".join(flat)]:
        if bad_requirement(s):
            raise SystemExit("refused: requirement text holds a secret, a kit/scenario path or a scenario EXPECT block — "
                             "state the required behaviour; keep the test cases in the Argus catalog")


def check(*values):
    """Raise SystemExit if any value — or all values joined — looks like scenario content or a secret."""
    flat = []
    for v in values:
        flat.extend(v if isinstance(v, (list, tuple)) else [v])
    flat = [str(x) for x in flat if x is not None]
    for s in flat + ["".join(flat), " ".join(flat)]:     # catches "EXP" + "ECT 200" split across fields
        if bad(s):
            raise SystemExit("refused: text looks like scenario content or a secret — describe what was "
                             "OBSERVED in plain words (no expected values, kit paths or credentials)")


def selftest():
    kp, sp = "ki" + "ts", "scen" + "arios"   # assembled so this file never trips the builder holdout guard
    refuse = ["E​XPECT 200", "ＥＸＰＥＣＴ 200", "EX PECT status 200", "expected 409",
              "expect status 202", "pwd hunter2", "token abc123", "export PASSWORD=hunter2", "ghp_abcdef",
              "see " + kp + "/api/x", "http://u:p@host", "ÉXPECT 200", "ЕXPECT 200", "EXPЕCT 200",
              "paѕsword=x1", "expected: HTTP 409", "expected status code 409", "should return 409",
              "assert status == 409", "ex pect status 200", base64.b64encode(b"password=hunter2").decode(),
              "pw: hunter2", "client_secret abcdefgh", "odt s_x", "----- BEGIN", "sk -ant-x", kp + "\\api",
              "Bearer: eyJhbGciOiJIUzI1NiJ9xx", "q8Zx3Lm0Pw9Rt5Vn2Bk7Yh4Gf1Ds6Ja",
              sp + "/web-ui/a.md", "сlient_secret abcdefgh12"]
    allow = ["unexpected 500 from gateway", "web POST returned 415", "scenario API-ING-004 failed",
             "Delete then list: row gone", "soft delete", "Jane Doe <jane.doe@example.com>",
             "https://github.com/my-org/x/pull/9", "the toolkits page", "expected behaviour unclear",
             "token refresh failed", "Token refresh failed", "token expired after 3600s", "the secret store rotated",
             "secret volume mount failed", "secret rotation failed", "bearer auth failed with 401",
             "password reset page returned 500", "api key rotation pending", "passwordless login works",
             "EXPECTATIONS doc updated", "Lukáš Choulik confirmed", "commit 37bc797f1a2b3c4d5e6f708192a3b4c5d6e7f809",
             "run r-2026-10-10-api-0042", "ho-20261010-6448a1",
             "https://github.com/my-org/payments-api/pull/130",
             "registry.example.com/library/api@sha256:" + "ab" * 32]
    fails = [("should refuse", t) for t in refuse if not bad(t)] + [("should allow", t) for t in allow if bad(t)]
    try:
        check("EXP", "ECT 200"); fails.append(("should refuse", "EXP + ECT 200 across fields"))
    except SystemExit:
        pass
    for why, t in fails:
        print("FAIL", why, repr(t))
    n = len(refuse) + len(allow) + 1
    print("ALL PASS" if not fails else f"{len(fails)} FAIL", f"({n} cases)")
    return not fails


if __name__ == "__main__":
    import sys
    sys.exit(0 if selftest() else 1)
