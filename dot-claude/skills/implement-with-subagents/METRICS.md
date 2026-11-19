# Recording a run

After §6, or whenever the run ends without a commit. Skip steps 1 and 2 on an aborted run.

1. Run the mutation proxy below.
2. Close each real survivor with a test, amending the §6 commit so the slice stays one commit.
   - First confirm the tree matches the §6 commit. If the mutation worker left changes, restore the tracked files to that commit and delete the files it created.
   - The parent writes each test's expected value from the worker's survivor line; an implementer writes the test around it. Each new test passes on the unchanged commit.
   - When a new test fails there, the parent judges the cause. A wrong expected value it rewrites and redispatches; a real bug goes to an implementer to fix in the code, landing in the amended commit. A survivor still open after one redispatch goes to the user (unattended: SKILL.md *Unattended mode*).
   - An equivalent mutant needs no test; say so in `--note`.

   Done when every real survivor has a new test that fails with its mutant reapplied, or is named open in `--note`, and the slice's tests pass on the amended commit.
3. Append the row, passing the amended sha:

   ```sh
   ~/.claude/skills/implement-with-subagents/ab.sh finish --run <run> --status ready \
     --branch <b> --sha <s> --killed <0-5> --redos <n> --fanin-failures <n> \
     --models '{"<assignment>":"<model>"}' [--forced] [--fit-fallback] [--note <text>]
   ```

   - `killed`: the proxy's catch count as the worker measured it, before step 2 closed any survivor.
   - `redos`: implementer redispatches, the §4 contract escalations plus the §5 triage dispatches. Single's fit-fallback dispatches (flagged by `--fit-fallback`), split's §4 re-split dispatches, and step 2's survivor-closing dispatches are not redos.
   - `models`: one key per assignment; a single-arm run repeats the one implementer's model under every key.
   - `fanin-failures`: the §5 count.
   - An aborted run passes `--status aborted` and drops `--branch`, `--sha` and `--killed`.

The script supplies everything else from the start row and the session transcripts: arm, wall-clock, token usage across the parent and every subagent since `assign`, and the coding-standards arm the session ran under. `notices` (SKILL.md §8) defines what to report from `ab.sh` output.

## Mutation proxy

One mutation worker (Agent, `general-purpose`) takes **5 mutants**, one at a time: it writes one plausible-wrong implementation somewhere in the slice, runs the slice's tests, records whether they caught it, then reverts it before the next. It returns the catch count out of 5 and a line per survivor, each carrying enough to reapply the mutant (file, location and the exact change as a diff), and returns only once the tree matches the §6 commit. The worker's prompt names the slice and its tests, never the arm or how many implementers built it.
