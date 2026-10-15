# Pre-release pass (2026-10-15)

Status: Wave A done (the bug, 4a and 4b); its other background checks moved to Wave A2, awaiting Walker's go. Before releasing main (a97c4ac) over the installed build 49, which predates
every wave of `2026-10-14-browser-features.md`.

Three waves, each about 45 minutes or less, run in this session with no sub-agents: the checks drive one running app
and one screen, so parallel agents would collide. At each wave's end: changed files, anything now stale, an offer to
commit, and a wait for Walker's go. The installed Paddle is quit during the waves (data backed up first and restored
with `cmp` after, as in every wave so far).

Screen rule: the screen is taken only for checks that need real keys, modifier clicks, right-clicks, middle-clicks
or hover. Each screen window is announced first with its length (at most about 3 minutes), runs as one batch, and is
released straight after. Everything else goes through the control bridge or background clicks.

Done when: every item below is ticked with a note of what was seen, or marked as not checkable with the reason; the
Settings growth bug is fixed with the same check passing before and after; and the memory table is in, with any
scenario over the threshold explained.

## Wave A: Settings growth bug and the background checks (about 45 min)

- [x] Settings growth bug: with a Settings tab showing, Reload Config (⌥⌘,) makes its window 1323 pt wide (build 49
  too). (Found: Reload Config wasn't the trigger; opening the Sites pane grew a 1000 x 800 window to 3306 pt tall.
  The window's NSHostingView made the SwiftUI minimum size a window constraint, and the Sites pane, not in a scroll
  view, ends in a caption marked fixedSize(vertical), which SwiftUI measures at near-zero width. Fixed: the browser
  window's hosting view has no sizing options; the window keeps its own 480 x 320 minimum. Checked: all nine panes,
  three Reload Configs each, stay 1000 x 800; the Sites pane fits.) Repro first: capture the window frame before and after Reload Config through the bridge (`window_snapshot`
  size and `paddle_state`) and log the window's frame and min size at each step, then name the mechanism before
  editing. Hypothesis to test first, not a finding: the Settings tab's SwiftUI view re-renders on the config change
  and its hosting view's sizing options raise the window's minimum or ideal width. Fix at the cause; the check is
  the window width staying put through three Reload Configs.
- [x] Wave 4a and 4b checks (done 2026-10-15; notes in the roadmap): high contrast in the sidebar, the toolbar icons
  now following text size, a custom accent, the tint cap.
- [ ] Wave A2, the remaining background checks (no screen), about 40 min:
  - (done) Wave 4a: `highContrastTabs` in the sidebar (measure fill and edge contrast against the unselected rows, as was
    done for the strip). `interfaceTextSize` leaves the extension toolbar buttons and the ≡ button unscaled: a
    known gap, so fix it if small, or mark it.
  - (done) Wave 4b: a custom `#rrggbb` accent, and a tint strong enough to show the "Capped at N %" caption (measure the
    cap).
  - Wave 6: New Window in Profile (app menu), and suggestions, the History window and Clear History in a second
    profile.
  - Wave 7: pins and groups inside a second space, and Next/Previous Space. An extension activating a tab in another
    space, using the test extension already in the scratchpad.
  - Wave 7b: the Settings bridge section, Disconnect, and private windows invisible to every tool.
  - Wave 8: Focus Other Side; a split ended by pin, move to another space and group; the sidebar pair; what the test
    extension sees of both sides; the 25 % / 320 pt minimums and the narrow-window fallback (resize by dragging the
    window corner in the background).
  - Wave 9: the Settings toggle; a preview over a split; the progress line on a slow probe page; Copy Link
    (`pbpaste`); a popup and a download from a preview; the hidden split button on a pinned tab; closing by tab and
    space switch; a preview in a second profile.
- Wave A2 ends with: those items ticked or marked, build green, `swift test` passing.
- Follow-up seen in Wave A: the address suggestions open when the field's text changes while it has focus (a tab
  switch under a focused field), not only on typing; a click elsewhere closes them. Small; for Wave B.

## Wave B: screen checks and small fixes (about 30 min)

- [ ] Screen window 1 (about 3 min): the tab group label's right-click (Rename, Ungroup, Close Group, Move Group to
  New Window); a link ⌘-clicked from a grouped tab joining the group; dragging a tab out of a group; the sidebar's
  drag to reorder and middle-click to close.
- [ ] Screen window 2 (about 2 min): the ≡ menu's Developer Tools submenu; the tab right-click items Split with
  Current Tab and End Split; ⇧⌘Return on a preview; swipe back in a preview.
- [ ] Small fixes found by Waves A and B, each re-checked the same way it failed. Anything bigger than about 20 lines
  or outside the item goes on a follow-up list for Walker instead.
- [ ] Walker's call: Wave 3's "Add to New Tab Page" in a page's right-click menu was left out because Paddle had no
  hook into WebKit's page menu. Wave 9 added one (`_webView:getContextMenuFromProposedMenu:…`), so it is now about
  15 lines. Build it here, or leave it.
- Not checkable here, marked as such unless Walker wants them: reduce motion and reduce transparency (0.15-0.2 s
  animations over flat backgrounds; reviewed in code only), and the bridge with the screen locked (needs Walker to
  lock the screen while a probe runs).

## Wave C: memory, main against build 49 (about 35 min; Paddle unavailable meanwhile)

- Builds: A is the installed build 49; B is a Release build of main at `build/ReleaseDerivedData.noindex`, run from
  there and not installed. Nothing else heavy runs meanwhile (no builds, renders or model checks), and the
  installed Paddle stays quit.
- Same data for both: a fresh measurement config and session, written before each run (build 49 ignores newer
  keys); the real data is restored afterwards.
- Scenarios, each measured after loads finish and 60 s of settling:
  1. Idle: one window, one New Tab page.
  2. Restored: 8 tabs from the session, only the selected one awake.
  3. Loaded: the same 8 sites opened from another app (`open -a`), all awake (under the default `maxAwakeTabs` of
     10).
  Sites: Wikipedia (WebKit article), GitHub (WebKit repo), MDN (HTML), BBC News, Hacker News, apple.com, a long
  Wikipedia list page, and the local probe page. No video sites, so nothing plays sound.
- Metric: `footprint` phys_footprint (checked: readable without sudo) for Paddle itself and for every WebContent,
  Networking and GPU process that wasn't running before launch, plus the WebContent count.
- Runs: A, B, A, B, A, B per scenario, reported as the median and range per build. Threshold, for Walker to adjust:
  B within 10 % or 50 MB of A, whichever is larger; any scenario over it gets its cause found before release.
- Wave C ends with: the table in chat, the comparison noted in this file, and a release recommendation.

Not in this pass: the release itself (Walker's go after Wave C), and the features the roadmap left unchosen.
