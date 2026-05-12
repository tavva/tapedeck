# JWT payload notes

- Region claim name: `region` (no `aws:` prefix variant observed).
- Region value: `aws:eu-central-1` — value carries the `aws:` provider prefix,
  which `SourceClient.regionToHost` must strip before lookup.
- Other claims present in the live token but redacted from the fixture:
  `aud`, `client_id`, `sub`. None are needed for region routing.
- `iss` is not present in the live token; we synthesise a `"redacted"` value
  in the fixture so test code that expects a non-empty iss does not fail.
- `exp` / `iat` preserved verbatim so any future expiry-handling tests get
  realistic numbers.
