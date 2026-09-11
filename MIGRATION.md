# Applying this

**All three repositories call these workflows.** The steps below are kept as the record of
how it landed and why each choice was made, rather than as a plan — what is still open is
at the bottom, and it is which bots have actually been exercised rather than which are
wired.

Three decisions were settled on 2026-09-09 and the steps below assume them:

| Decision | Choice | Why |
| --- | --- | --- |
| How to catch up | **Re-derive from Binge HEAD**, not cherry-pick | 23 commits against a restructured file is 23 conflicts and no guarantee. The 09-02 draft is preserved in this repo's first commit so nothing editorial is lost silently. |
| Default posture | **Public-safe** | Two of three consumers are public. A caller that forgets to configure something should get the strict setting, not Binge's. |
| Prove it on | **binge-seerr first** | MIGRATION originally said Binge, but that was written before binge-seerr existed. It is now fully wired and is the lowest-stakes place a break costs nothing. |

## 1. Finish the re-derivation ✅

Done, 2026-09-09. All five are current as of Binge `30e2c6c66`; see the status table in
[README.md](README.md). Two things were settled while doing it, rather than inherited:

- **`secrets: inherit` is gone.** Every caller names the three secrets it passes. `inherit`
  hands the called workflow every secret the caller holds, which on a public repo calling a
  public reusable workflow is a wider grant than the job needs.
- **`bufbuild/buf-action` is pinned** to `8c6a16e1` (v1.5.0). It was the one action left on
  a mutable tag, in a job that hands an agent Bash, Edit, Write and a contents:write token.
  Every SHA in the repo now resolves — one reached for first did not exist.

## 2. Create and tag `binge-ci` ✅

Public, under `ScottCooper92`. Public matters: `binge-integrations` and `binge-seerr`
are public, and a public repo calling a reusable workflow from a private one both needs
the private repo's Actions access setting opened up *and* prints the called workflow's
step bodies into the public caller's logs. A public `binge-ci` sidesteps both. Nothing
here is secret — every credential arrives as a secret at call time.

Tag `v1` as soon as it is pushed, because every caller references `@v1` and step 3 cannot
run without a ref to call. Two tags, which is the usual Actions convention and matters here
for a specific reason:

- **`v1.0.0`** is immutable. It is what a caller can pin to when it wants no surprises.
- **`v1`** is a moving alias, re-pointed when a fix lands. That is what the callers use.

Until step 3 is green, `v1` may be force-moved freely - nothing calls it yet, so there is
nothing to break. After that, treat it as published: land the fix, tag `v1.0.N`, then move
`v1`. A `v1` that moves under a caller mid-review is the drift problem again, wearing a tag.

## 3. Prove it on binge-seerr ✅

binge-seerr is pre-alpha, has one open PR, no release train, and `auto_merge: false`, so
a bad review cannot merge anything. A break there costs nothing. It also exercises the
hosted-runner path that two of the three consumers use.

It is already wired: both apps installed, all five secrets, `AUTHOR_BOT_ID`, the `agent`
label, and a `CLAUDE.md` plus `.ai/agents/` that are about *that* repo.

Move `callers/binge-seerr/*.yml` into `binge-seerr/.github/workflows/`, replacing the
five full copies it was scaffolded with on 2026-09-06. Leave its `ci.yml` alone — CI
stays per-repo.

Done. The permissions trap in [README.md](README.md) was found here and nowhere else: three
runs died as `startup_failure` before the caller declared `actions: read`, and every run
since has behaved. A wrong `default_branch` shows up the same way, immediately, as "path
does not exist in origin/main".

What it did **not** settle is whether each bot works, which is the open item below.

## 4. Move Binge over ✅

Binge is the risky one — it ships daily, runs on self-hosted runners, and its bot merges
labelled PRs in about fifteen minutes. Go second, with binge-seerr already green.

Binge's callers are already staged on its own `ci/binge-ci-callers` branch, rather than
in this repo's `callers/` — see the note in [README.md](README.md). Merge that branch, and
change one line in `Binge/.github/workflows/ci.yml`:

```diff
-        uses: ./.github/actions/ci-setup
+        uses: ScottCooper92/binge-ci/.github/actions/ci-setup@v1
```

Then delete the local `ci-setup`. Keeping a second copy for `ci.yml` alone is the drift
this whole exercise exists to prevent — and it is a copy the agent workflows would *not*
be using, so the two would diverge invisibly.

Two corrections from doing it. It is **three** workflows, not one: the two device lanes use
the same setup, and the local copy cannot go until all three point here. And by the time it
was removed the two had already diverged — by a comment, where the shared one says "a
caller's own runners" and the copy named the hosts. That difference is deliberate, because
this repository is public and the consumer is not, but a difference nobody chose to keep in
two places is how the rest of it starts.

Binge's caller opts back out of every public-safe default: self-hosted `runner`,
`auto_merge: true`, `show_full_output: true`, `default_branch: master`, and the
`unbuilt_paths` pair that its six-pattern `paths-ignore` needs.

## 5. Write binge-integrations' governing docs, then wire it ✅

This is the real work in that repo, and it is authoring, not plumbing. Three documents
on `main`, none of them copies of Binge's:

| File | What it has to say |
| --- | --- |
| `CLAUDE.md` | The repo's conventions. Proto style, the append-only rule, where `docs/Architecture.md` is authoritative, how follow-ups get filed. |
| `.ai/agents/pr-review-guide.md` | The review checklist and, critically, its calibration section. Binge's is about Compose, linters and a screenshot gate; this one is about wire compatibility, capability gating and the Binder 1 MB limit. |
| `.ai/agents/ci-triage.md` | A table mapping each way CI goes red here — `buf lint`, `buf breaking`, ktlint, `ProtoRoundTripTest`, a Gradle compile error — to the correct fix. Without it `author-ci-fix` triages from nothing. |

The bots are only as good as these. Porting the workflows without them produces an agent
reviewing a proto repo against a screenshot gate that does not exist.

Done, along with replacing its five copies with `callers/binge-integrations/*.yml`.

## What is still open: exercising the bots

Wired is not proven. A workflow that is skipped by a guard proves the trigger and nothing
else, and most invocations are skipped by design — that is what the guards are for.

All five have real, successful runs in the private consumer, so none of them is unproven
as *code*. What is unproven is two of them on the path the public repos take, which is a
different one: hosted runners and a JVM toolchain rather than self-hosted and Android,
against a `ci.yml` that is one job rather than a matrix.

Successful runs in the two public consumers, at the time of writing:

| Bot | binge-seerr | binge-integrations |
| --- | --- | --- |
| `bot-review` | 3 | 5 |
| `author-conflicts` | 5 | 4 |
| `author-comments` | 0 | 1 |
| `author-ci-fix` | **0** | **0** |
| `author-retarget` | **never invoked** | **never invoked** |

So two of the five have never completed a real run here. `author-ci-fix` has been invoked
and has never got past a guard since its permissions were fixed: CI going red on a labelled
PR is simply rare, so it is untested by luck rather than by omission. `author-retarget` has
never been invoked at all, because a two-PR stack has not happened in either repo yet.

Neither is a suspected bug — both work in the private consumer. The gap is that the hosted
path has never carried them, and a toolchain input is exactly the sort of thing that is
wrong in one repo and right in another.

To exercise the two:

| Bot | Do this |
| --- | --- |
| `author-ci-fix` | Open a labelled PR with a ktlint violation. Check it makes exactly one repair attempt and then stops. |
| `author-retarget` | Open a two-PR stack and merge the base by hand. |

Both are cheapest in binge-seerr: pre-alpha, no release train, and `auto_merge: false`, so
nothing a bot does there can merge itself.

## 6. Then the Seerr extraction

Roadmap stage 4 in binge-integrations. That is what all of this was blocking: 325 files
moving through binge-seerr, on bots that are current rather than a week stale.
