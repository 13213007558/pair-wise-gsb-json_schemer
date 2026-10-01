# Test262 ECMAScript 2024 `u`-mode vectors (fixed revision)

These vectors are a fixed, hand-selected subset of
[tc39/test262](https://github.com/tc39/test262) cases covering the regular
expression subset supported by `JSONSchemer::EcmaUnicodePattern`:

- literals, character classes, quantifiers, groups, alternation and anchors
- Unicode escapes (`\uXXXX`, `\u{...}`, surrogate pairs) and lone surrogates
- Unicode property escapes (`\p{...}` / `\P{...}`)
- named capture groups and named backreferences
- illegal identity escapes and other strict `u`-mode early errors
- Ruby/Perl-only syntax that must not be silently accepted

The vectors are consumed by `test/ecma_unicode_pattern_test.rb`. They do not
require Node or any JavaScript runtime at test time: each vector records the
expected parse result (`accept`/`syntax_error`/`unsupported`) and, for accepted
patterns, ECMAScript match expectations (`match: true/false` for each input).

## Provenance

- Upstream: https://github.com/tc39/test262
- Fixed revision: test262 `es2024-candidate` snapshot. The revision is pinned
  in `select_test262_vectors.rb` (`TEST262_REVISION`); the selector verifies the
  checkout's git revision before extracting anything, so a different revision
  never silently changes the vectors.
- Selection criteria: cases under
  `test/built-ins/RegExp/{named-capture-groups,unicode-property-escapes,unicode-escape,character-class-escape,quantifiers,assertions}`
  and the hand-curated strict-mode early-error list, restricted to constructs in
  the supported subset. Each vector records its test262 source file and (where
  one exists) the enclosing test name for traceability.
- Runtime cases use the `u` flag and features with identical semantics across
  every ECMAScript 2024 implementation; expectations here are derived from the
  spec grammar/runtime semantics, not from a particular engine.

The checked-in `vectors.json` is the source of truth for tests and requires no
network or JavaScript runtime. To regenerate/verify against a local test262
checkout of the fixed revision (network only needed to fetch test262), run:

```sh
bundle exec ruby test/fixtures/test262_regex/select_test262_vectors.rb /path/to/test262
```

The script refuses to run against any other revision and emits the same JSON
schema as `vectors.json`; accept/reject and match expectations are then diffed
in code review instead of relying on a local Node install.
