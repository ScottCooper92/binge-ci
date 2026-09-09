# Applying this

No repo calls these workflows yet and there is no `v1` tag. This is the order to land
it in, smallest reversible step first.

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

## 2. Create and tag `binge-ci`

Public, under `ScottCooper92`. Public matters: `binge-integrations` and `binge-seerr`
are public, and a public repo calling a reusable workflow from a private one both needs
the private repo's Actions access setting opened up *and* prints the called workflow's
step bodies into the public caller's logs. A public `binge-ci` sidesteps both. Nothing
here is secret — every credential arrives as a secret at call time.

Push first, tag `v1` only once step 3 is green. A `v1` that moves under its callers is
the drift problem again, wearing a tag.

## 3. Prove it on binge-seerr

binge-seerr is pre-alpha, has one open PR, no release train, and `auto_merge: false`, so
a bad review cannot merge anything. A break there costs nothing. It also exercises the
hosted-runner path that two of the three consumers use.

It is already wired: both apps installed, all five secrets, `AUTHOR_BOT_ID`, the `agent`
label, and a `CLAUDE.md` plus `.ai/agents/` that are about *that* repo.

Move `callers/binge-seerr/*.yml` into `binge-seerr/.github/workflows/`, replacing the
five full copies it was scaffolded with on 2026-09-06. Leave its `ci.yml` alone — CI
stays per-repo.

Then watch one PR through the full loop. The three author bots have **never actually
run** in that repo — every invocation to date was skipped by a guard, which proves the
trigger wiring and nothing else. So drive each one deliberately:

| To exercise | Do this |
| --- | --- |
| `bot-review` | Already proven on binge-seerr#1. Re-run it and check the verdict still posts. |
| `author-ci-fix` | Open a labelled PR with a ktlint violation. Check it makes exactly one repair attempt. |
| `author-comments` | Leave an inline review comment on a labelled PR. This is the one whose three-event fan-out is easiest to get wrong. |
| `author-retarget` | Open a two-PR stack, merge the base by hand. Zero runs to date, and it was rewritten as `pull_request_target` after the `pull_request` form could not fire in Binge. |
| `author-conflicts` (resolve) | Make the two stacked PRs touch the same file. Only its scan job has ever run. |

A wrong `default_branch` shows up immediately as "path does not exist in origin/main".

## 4. Move Binge over

Binge is the risky one — it ships daily, runs on self-hosted runners, and its bot merges
labelled PRs in about fifteen minutes. Go second, with binge-seerr already green.

Move `callers/Binge/*.yml` over the five originals in `Binge/.github/workflows/`, and
change one line in `Binge/.github/workflows/ci.yml`:

```diff
-        uses: ./.github/actions/ci-setup
+        uses: ScottCooper92/binge-ci/.github/actions/ci-setup@v1
```

Then delete `Binge/.github/actions/ci-setup/`. Keeping a second copy for `ci.yml` alone
is the drift this whole exercise exists to prevent — and it is a copy the agent
workflows would *not* be using, so the two would diverge invisibly.

Binge's caller opts back out of every public-safe default: self-hosted `runner`,
`auto_merge: true`, `show_full_output: true`, `default_branch: master`, and the
`unbuilt_paths` pair that its six-pattern `paths-ignore` needs.

## 5. Write binge-integrations' governing docs, then wire it

This is the real work in that repo, and it is authoring, not plumbing. Three documents
on `main`, none of them copies of Binge's:

| File | What it has to say |
| --- | --- |
| `CLAUDE.md` | The repo's conventions. Proto style, the append-only rule, where `docs/Architecture.md` is authoritative, how follow-ups get filed. |
| `.ai/agents/pr-review-guide.md` | The review checklist and, critically, its calibration section. Binge's is about Compose, linters and a screenshot gate; this one is about wire compatibility, capability gating and the Binder 1 MB limit. |
| `.ai/agents/ci-triage.md` | A table mapping each way CI goes red here — `buf lint`, `buf breaking`, ktlint, `ProtoRoundTripTest`, a Gradle compile error — to the correct fix. Without it `author-ci-fix` triages from nothing. |

The bots are only as good as these. Porting the workflows without them produces an agent
reviewing a proto repo against a screenshot gate that does not exist.

Then replace its five 09-01 copies with `callers/binge-integrations/*.yml`.

## 6. Then the Seerr extraction

Roadmap stage 4 in binge-integrations. That is what all of this was blocking: 325 files
moving through binge-seerr, on bots that are current rather than a week stale.
