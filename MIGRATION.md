# Applying this draft

Nothing here has been pushed and no repo calls these workflows yet. This is the
order to land it in, smallest reversible step first.

## 1. Create and tag `binge-ci`

Public, under `ScottCooper92`. Public matters: `binge-integrations` is public, and
a public repo calling a reusable workflow from a private one both needs the
private repo's Actions access setting opened up *and* prints the called
workflow's step bodies into the public caller's logs. A public `binge-ci`
sidesteps both. Nothing in these files is secret — every credential arrives as a
secret at call time.

Push, then tag `v1`. Every caller references `@v1`.

## 2. Prove it on Binge first

Binge is private, already has the runner, the apps, the secrets and the `agent`
label, and already has the governing docs the agents read. It is the only place
this can be validated without also inventing new documents — so it goes first,
and a difference in behaviour there is a bug in the extraction rather than a bug
in a new repo's setup.

Move `callers/Binge/*.yml` over the five originals in
`Binge/.github/workflows/`, and change one line in `Binge/.github/workflows/ci.yml`:

```diff
-        uses: ./.github/actions/ci-setup
+        uses: ScottCooper92/binge-ci/.github/actions/ci-setup@v1
```

Then delete `Binge/.github/actions/ci-setup/`. Keeping a second copy for `ci.yml`
alone is the drift this whole exercise exists to prevent — and it is a copy the
agent workflows would *not* be using, so the two would diverge invisibly.

Watch one PR through the full loop before going further: red CI → repair → green
CI → review → merge. The review and the repair both read documents from `master`,
so a wrong `default_branch` shows up immediately as "path does not exist in
origin/master".

## 3. Write binge-integrations' governing docs

This is the real work, and it is authoring, not plumbing. Three documents on
`main`, none of them copies of Binge's:

| File | What it has to say |
| --- | --- |
| `CLAUDE.md` | The repo's conventions. Proto style, the append-only rule, where `docs/Architecture.md` is authoritative, how follow-ups get filed. |
| `.ai/agents/pr-review-guide.md` | The review checklist and, critically, its calibration section. Binge's is about Compose, linters and a screenshot gate; this one is about wire compatibility, capability gating and the Binder 1 MB limit. |
| `.ai/agents/ci-triage.md` | A table mapping each way CI goes red here — `buf lint`, `buf breaking`, ktlint, `ProtoRoundTripTest`, a Gradle compile error — to the correct fix. Without it `author-ci-fix` triages from nothing. |

The bots are only as good as these. Porting the workflows without them produces
an agent reviewing a proto repo against a screenshot gate that does not exist.

## 4. Wire binge-integrations

Register the `agent-runner` runner against it, install both apps, add the five
secrets and `AUTHOR_BOT_ID`, create the maintainers-only `agent` label, then move
`callers/binge-integrations/*.yml` into `.github/workflows/`.

Two things to settle before the first labelled PR:

- **Resolve `bufbuild/buf-action@v1` to a SHA** in both `author-ci-fix.yml` and
  `author-comments.yml`, or leave `setup_buf: false`. It is the only unpinned
  action in the set, and it would run inside a job that hands an agent Bash and a
  contents:write token on a persistent runner.
- **Re-read the fork guard.** In Binge the same-repository check was a second
  line of defence behind a repo nobody could fork. Here it is the whole boundary.
  It is already in every job; the point is to have looked at it deliberately
  rather than inherited it.

`auto_merge: false` is set in the bot-review caller. Turn it on later if you want
to, but not in the same change as everything else.

## 5. Seerr

Roadmap stage 4. When the companion repo is scaffolded, it needs five caller
files of ~25 lines each — copy `callers/binge-integrations/`, change
`default_branch` if it differs, and swap `toolchain: jvm` for `android`. That is
the whole point of steps 1–4.
