---
name: codex-code-review
description: Codex Code Review. Review a developer's own Lua changes in the draw-steel-codex for correctness and clarity, report what it found in plain words, then offer to make the fixes. Checks comments against the codex comment rules, one-off local functions, work an existing helper already does, single-letter variable names, and codex-specific traps. Use when someone says "review my code", "review my changes", "codex code review", "check my diff", or invokes /codex-code-review. Lua codex only; not for C# engine code or compendium YAML.
---

# Codex Code Review

The goal: the changed code is **correct**, and **someone new to this code can read it
and understand it** without asking the author. The review reports what it found to the
person who wrote the code, explains each point in plain words, and then offers to fix
them. It never edits anything before they say which fixes they want.

## Step 1 -- Find the changes

The argument, if given, says what to review: a branch name, a commit range, a PR number
(`gh pr diff <n>`), or file paths. With no argument, review everything this person has
changed that is not on `main` yet:

```bash
git status --short
git diff main...HEAD      # committed on this branch, not on main
git diff HEAD             # not committed yet
```

If they are working on `main` itself, the first command shows nothing and only the
uncommitted changes count. If `main` is not the right base (a fork, an unusual branch),
ask which branch to compare against. Review only `.lua` files under the codex. Skip
`Definitions/` (generated), `data/` and `compendium/` (content, not code), and `main.lua`
(generated, never run).

Separate real changes from noise before reviewing:

- `git diff HEAD --stat --ignore-cr-at-eol -w` shows the size without line-ending and
  indentation churn. Codex files can have mixed line endings.
- `git diff HEAD --color-moved=zebra --ignore-cr-at-eol` shows blocks that were only
  moved. Code moved without edits is not part of the review (see Step 3).

Read every changed function in full, plus its callers and the functions it calls. Read
the whole file when it is small. Some codex files run to thousands of lines, so don't
read those end to end.

## Step 2 -- Run the automatic checks

- **Syntax.** `luac -p` on every changed file. The interpreter ships in the DMHub repo
  at `dependencies/lua/bin/luac.exe`. From a codex clone nested inside DMHub that is
  `../dependencies/lua/bin/luac.exe`; from a clone next to the DMHub folder it is
  `../DMHub/dependencies/lua/bin/luac.exe`. If neither exists, say so in the report and
  carry on; do not hunt the disk for one.
- **Types.** If the DMHub repo has `tools/lua-typing/check.ps1`, run it with `-Changed`
  and `-CodexRoot <this codex clone>`. Without `-CodexRoot` it checks the DMHub nested
  copy instead and can report clean for the wrong files. Any problem it reports is a
  finding. If it fails to start (for example no LuaLS installed), write "not run" and the
  reason in the report.
- **ASCII only.** Use the Grep tool with the pattern `[^\x00-\x7F]` on each changed
  file. (In Git Bash, plain `grep -P` fails silently without `LC_ALL=C.UTF-8`.) Any hit
  anywhere in a changed file is a must-fix, even on an old line: the runtime cannot load
  the file at all.

## Step 3 -- Review against the checklist

Look only at lines this change added or modified. Old code that was already there is not
part of the review, even if it breaks the same rules. Mention it at most once, at the end,
as "not part of this change".

Code that was only moved or re-indented counts as old code. Once the author edited lines
inside a moved block, review the lines they edited and anything those edits touch.

### A. Correctness (must fix)

Read the logic as if you had to prove it works. Look for:

- Wrong conditions, off-by-one, `nil` reaching a concatenation, index or method call.
- A case the code forgets: empty table, missing token, no target, the player is not the
  Director, the creature is a monster rather than a hero.
- `cond(a, b, c)` used as if it short-circuits. It evaluates both branches, so a branch
  that can error must be a real `if`.
- A local that its own initializer's closure uses (a `click` handler referring to the
  panel it lives in) without being declared first.
- Token property changes outside the character sheet not wrapped in
  `token:ModifyProperties{}`. Shared document writes not wrapped in
  `BeginChange`/`CompleteChange`.
- Reading a `_tmp_` field that may never have been set (use `try_get`), or checking
  `obj.SomeMethod == nil` on a game type (it raises instead of returning nil).
- Scheduled or coroutine callbacks that don't check `mod.unloaded` before doing work.
- Iterating a data table with `pairs` instead of `unhidden_pairs` (shows deleted entries).
- A missing `local` that makes a new global by accident.
- A padded panel (`pad`, `hpad`, `vpad`) without `borderBox = true`.
- A new `.lua` file that was not registered with its CodeMod (it will never load).

### B. Reuse: does something already do this? (should fix)

For every new function, and every block of more than a few lines inside a function, ask:
does the codex already have this? Search before deciding:

- `DMHub Utils/Utils.lua` for table and string helpers (`table.contains`, `table.keys`,
  `table.shallow_copy`, `map`, `filter`, `sorted_pairs`, `string.trim`,
  `string.starts_with`, `math.clamp`, ...).
- The other files in the same folder, and the type the code works on (methods on
  `creature`, `ActivatedAbility`, `CharacterToken`, ...).
- `Grep` for two or three key words from what the new code does, across the codex.

When you find a match, name it with its file and line, and show what the new code would
look like using it. Do not report a "maybe there is a helper for this" without having
looked.

### C. One-off local functions (should fix)

A `local function` defined for a change and called from exactly one place usually makes
the reader jump away and back for nothing. Flag it when:

- it is called once, **and**
- it is short (roughly under 10 lines), **and**
- its body would read clearly at the call site.

Suggest inlining it. Leave it alone when the name genuinely explains a tricky step that
would otherwise need a comment, when it is passed as a callback, or when it is recursive.
Count its uses with `Grep` before flagging; don't guess.

### D. Names (should fix)

Single-letter names tell the reader nothing. Flag every new single-letter variable,
parameter or loop variable, and suggest a name that says what it holds
(`for _, token in ipairs(tokens)`, not `for _, t in ipairs(tokens)`).

Allowed: `_` for a value that is ignored, and `i`, `j` as the counter of a short numeric
`for` loop. Everything else gets a real name, including `k, v` in `pairs` loops.

Also flag names that are not single letters but still say nothing (`data`, `tmp`, `val`,
`thing`, `obj2`) when a better one is obvious.

### E. Comments (should fix)

The codex rule: comments are written for someone new to this code. Plain words, 1-3
lines, and they say **why** the code is there or **what the user sees**, never just what
the line below already says. A comment documenting a new function and its parameters may
be longer.

Flag a comment when it:

- restates the code below it ("loop over the tokens", "set hidden to true");
- runs past 3 lines (except a function's doc comment);
- explains how the bug was found, or argues the fix to a reviewer, instead of saying what
  happens. The story of the debugging belongs in the commit message;
- names functions, fields or mechanisms from other files that the reader cannot see in
  the lines right below it (`(see Foo.Bar)`, internal flag names, engine plumbing);
- uses internal jargon where an everyday word would do;
- contains a report or ticket id, measurements, or old values (those go in the commit
  message);
- is now false because the code around it changed in this diff;
- uses `--` as a dash inside the sentence, or any non-ASCII character.

A comment that says what the player used to see is fine and encouraged, for example:
"Only the player who clicked roll gets the prompt. Rolling for a follower used to prompt
other players too."

Also flag the opposite: a tricky change (a non-obvious order, a value that looks wrong, a
deliberate omission) with **no** comment where the next reader will need one.

Every comment finding includes a suggested rewrite.

### F. Clarity (should fix)

- Deep nesting that an early `return` would flatten.
- A function doing several unrelated things.
- Magic numbers or strings with no name or comment.
- Dead code and commented-out code.
- New `print` calls. Some files keep tagged trace prints on purpose (`XFLOOR::`,
  `MARK::` ...). A new print that follows the file's existing tag is a question for the
  author ("keep this?"), not a finding. Any other new print is a finding.
- New code that does not match the style of the file around it (indentation, naming
  case, `--Text` comment spacing).

## Step 4 -- Report

Write the report to the person who wrote the code. Be direct and kind, and explain each
point so they learn the rule, not just the fix.

```
## Codex Code Review: <branch or files>

Checked: <n> files, +<added> / -<removed> lines (<n> of them moved or whitespace only).
Syntax: OK / <errors>. Types: OK / <n problems> / not run (why). ASCII: OK / <hits>.

### Must fix
1. **<short title>** - `File.lua:123`
   What: <what is wrong, plain words>
   Why it matters: <what goes wrong for the user or the next reader>
   Suggested fix: <code or description>

### Should fix
<same format, grouped: Reuse, One-off functions, Names, Comments, Clarity>

### Looks good
<one or two specific things done well, if there are any. Skip if nothing stands out.>
```

Rules for the report:

- Every finding has a `file:line` and a concrete suggestion. No vague "consider
  improving".
- Only report what you checked. If you think a helper exists but did not find it, do not
  report it.
- Leave out any heading or group that has no findings.
- Group repeats: five single-letter names in one function are one finding listing all
  five, not five findings.
- If nothing needs fixing, say so plainly. Don't invent findings to fill the report.

## Step 5 -- Offer the fixes

End by asking which fixes to make, using `AskUserQuestion` with multiSelect: one option
per finding group (for example "All must-fix items", "Comments", "Names", "Inline one-off
functions", "Use existing helpers"). Then:

- Make only the fixes they picked. Do not touch lines outside the change.
- Write code changes first, then do the comments in a separate pass against section E.
- Re-run `luac -p` (and the type check if it ran before) on every file you edited.
- Do not commit. Tell them what changed so they can review it and commit it themselves.
